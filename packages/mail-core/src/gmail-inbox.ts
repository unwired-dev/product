import * as Arr from 'effect/Array';
import * as DateTime from 'effect/DateTime';
import * as Deferred from 'effect/Deferred';
import * as Effect from 'effect/Effect';
import * as Latch from 'effect/Latch';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Predicate from 'effect/Predicate';
import * as Random from 'effect/Random';
import * as Schedule from 'effect/Schedule';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { GmailAction, GmailLabel } from './gmail-actions.ts';
import type {
  BodyDocument,
  GmailPart,
  MessagePresentation,
} from './message-body.ts';
import type { Registration } from './registration.ts';

import {
  decodeDiagnostic,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';
import {
  canOrganize,
  GmailActionSchema,
  GmailLabelSchema,
  inInbox,
  relabel,
} from './gmail-actions.ts';
import { sanitizeHtml } from './html-sanitizer.ts';
import { inlineImageLimits } from './inline-images.ts';
import {
  bodyParts,
  contentIdsOf,
  decodeAttachment,
  decodeBodyDocument,
  decodeCachedBody,
  decodeFullMessage,
  encodeBodyDocument,
  imageTally,
  inlineImageParts,
  partText,
  presentation,
  recentWorkingSet,
  singleReadablePart,
  unescapeHtml,
} from './message-body.ts';
import { canOpenInbox } from './registration.ts';

// The native Registration module's mailbox operations. Native code attaches the Gmail credential
// and keeps the cache encrypted; this module chooses the Gmail requests and owns the cached document.
export interface NativeGmailMailbox {
  // Resolves `{ status, body }` for a read of `gmail/v1/users/me/<path>`.
  readonly gmailRequest: (
    path: string,
    query: ReadonlyArray<readonly [string, string]>,
    mailbox: Readonly<{ address: string; generation: string }>,
  ) => Promise<unknown>;
  // Resolves `{ status, body }` for Gmail's modify of one message's labels.
  readonly gmailModify: (
    change: Readonly<{
      message: string;
      add: readonly string[];
      remove: readonly string[];
    }>,
    mailbox: Readonly<{ address: string; generation: string }>,
  ) => Promise<unknown>;
  // Resolves `{ revision, address, generation, document }`; another mailbox's document reads as null.
  readonly openMailbox: () => Promise<unknown>;
  // Replaces the document read at `expectedRevision`, or rejects with `conflict`.
  readonly commitMailbox: (
    mailbox: Readonly<{ address: string; generation: string }>,
    expectedRevision: number,
    document: string,
  ) => Promise<unknown>;
  // The Bounded Encrypted Body Cache, bound to the mailbox and message ID. Opening resolves
  // `{ document }`, null when absent; an unreadable entry is discarded and reads as null.
  readonly openMessageBody: (
    mailbox: Readonly<{ address: string; generation: string }>,
    id: string,
  ) => Promise<unknown>;
  // Stores a body in the 'opened' or 'prefetched' eviction tier, evicting least recently read
  // bodies outside the protected working set; resolves `{ admitted }`, false when it cannot fit.
  readonly commitMessageBody: (
    mailbox: Readonly<{ address: string; generation: string }>,
    id: string,
    admission: Readonly<{
      document: string;
      tier: 'opened' | 'prefetched';
      protectedIds: readonly string[];
    }>,
  ) => Promise<unknown>;
  // Resolves `{ stored }`: which of these messages have a cached body or exclusion marker.
  readonly listMessageBodies: (
    mailbox: Readonly<{ address: string; generation: string }>,
    ids: readonly string[],
  ) => Promise<unknown>;
  // Removes cached bodies only if the named Inbox revision is still current. Reconciling an
  // over-budget cache keeps the protected bodies that fit, in the order given.
  readonly retainMessageBodies: (
    mailbox: Readonly<{
      address: string;
      generation: string;
      revision: number;
    }>,
    ids: readonly string[],
    protectedIds: readonly string[],
  ) => Promise<unknown>;
}

// ponytail: the newest Inbox messages kept on this device; older ones stay in Gmail. Each commit
// rewrites the whole document, so complete Historical Metadata Backfill needs an indexed store.
const cacheLimit = 200;
const pageSize = 50;

const GmailId = Schema.String.check(Schema.isPattern(/^[0-9A-Za-z]+$/u));
const HistoryId = Schema.String.check(Schema.isPattern(/^\d+$/u));

const GmailMessageSchema = Schema.Struct({
  id: GmailId,
  threadId: Schema.String,
  sender: Schema.String,
  address: Schema.String,
  subject: Schema.String,
  preview: Schema.String,
  receivedAt: Schema.String,
  unread: Schema.Boolean,
  // Gmail's label IDs; absent in caches written before organizing, which are listed again.
  labels: Schema.optionalKey(Schema.Array(Schema.String)),
});
export type GmailMessage = typeof GmailMessageSchema.Type;

// A requested change Gmail has not confirmed, with the message as it was shown, so restoring a
// message that already left the cache can show it again.
const PendingActionSchema = Schema.Struct({
  id: Schema.optionalKey(Schema.NonEmptyString),
  attempts: Schema.optionalKey(
    Schema.Array(
      Schema.Struct({ id: Schema.NonEmptyString, at: Schema.Finite }),
    ),
  ),
  retryFrom: Schema.optionalKey(
    Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  ),
  // Gmail refused this change for good; only its current labels remain to be read.
  refused: Schema.optionalKey(Schema.Literal(true)),
  action: GmailActionSchema,
  message: GmailMessageSchema,
});
type PendingAction = typeof PendingActionSchema.Type;

// The checkpoint is committed with the messages it produced, so a restart repeats no step twice.
const MailboxDocumentSchema = Schema.Struct({
  version: Schema.Literal(1),
  messages: Schema.Array(GmailMessageSchema),
  // Provider-confirmed messages stay in `messages`; requested changes wait here, in order.
  pending: Schema.optionalKey(Schema.Array(PendingActionSchema)),
  // The mailbox's own labels, for labeling and moving.
  labels: Schema.optionalKey(Schema.Array(GmailLabelSchema)),
  checkpoint: Schema.Union([
    // Listing the Inbox from the history ID read before the first page; `seen` survives an
    // interruption so a replacement listing can drop messages that left the Inbox.
    Schema.Struct({
      kind: Schema.Literal('backfill'),
      historyId: HistoryId,
      pageToken: Schema.optionalKey(Schema.String),
      seen: Schema.Array(GmailId),
    }),
    Schema.Struct({ kind: Schema.Literal('current'), historyId: HistoryId }),
  ]),
});
type MailboxDocument = typeof MailboxDocumentSchema.Type;
const decodeDocument = Schema.decodeUnknownEffect(
  Schema.fromJsonString(MailboxDocumentSchema),
);
const encodeDocument = Schema.encodeEffect(
  Schema.fromJsonString(MailboxDocumentSchema),
);

const CacheSchema = Schema.Struct({
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  address: Schema.NonEmptyString,
  generation: Schema.NonEmptyString,
  owner: Schema.optionalKey(Schema.NonEmptyString),
  document: Schema.NullOr(Schema.String),
  availability: Schema.optionalKey(Schema.Literal('retry')),
});
type Cache = typeof CacheSchema.Type;
type MailboxScope = Pick<Cache, 'address' | 'generation' | 'owner'>;
const decodeCache = Schema.decodeUnknownEffect(CacheSchema);
const sameMailbox = (left: MailboxScope, right: MailboxScope) =>
  left.address === right.address &&
  (left.owner !== undefined && right.owner !== undefined
    ? left.owner === right.owner
    : left.generation === right.generation);

const decodeResponse = Schema.decodeUnknownEffect(
  Schema.Struct({ status: Schema.Int, body: Schema.String }),
);
const json = <S extends Schema.Top>(schema: S) =>
  Schema.decodeUnknownEffect(Schema.fromJsonString(schema));
const decodeProfile = json(
  Schema.Struct({ emailAddress: Schema.String, historyId: HistoryId }),
);
const decodeList = json(
  Schema.Struct({
    messages: Schema.optionalKey(Schema.Array(Schema.Struct({ id: GmailId }))),
    nextPageToken: Schema.optionalKey(Schema.String),
  }),
);
const decodeMetadata = json(
  Schema.Struct({
    id: GmailId,
    threadId: Schema.String,
    labelIds: Schema.optionalKey(Schema.Array(Schema.String)),
    snippet: Schema.optionalKey(Schema.String),
    internalDate: Schema.String.check(Schema.isPattern(/^\d{1,15}$/u)),
    payload: Schema.optionalKey(
      Schema.Struct({
        headers: Schema.optionalKey(
          Schema.Array(
            Schema.Struct({ name: Schema.String, value: Schema.String }),
          ),
        ),
      }),
    ),
  }),
);
const HistoryMessages = Schema.optionalKey(
  Schema.Array(Schema.Struct({ message: Schema.Struct({ id: GmailId }) })),
);
const HistoryRecord = Schema.Struct({
  id: HistoryId,
  messagesAdded: HistoryMessages,
  messagesDeleted: HistoryMessages,
  labelsAdded: HistoryMessages,
  labelsRemoved: HistoryMessages,
});
const decodeHistory = json(
  Schema.Struct({
    history: Schema.optionalKey(Schema.Array(HistoryRecord)),
    nextPageToken: Schema.optionalKey(Schema.String),
    historyId: HistoryId,
  }),
);
const decodeLabels = json(
  Schema.Struct({
    labels: Schema.optionalKey(
      Schema.Array(
        Schema.Struct({
          id: Schema.String,
          name: Schema.String,
          type: Schema.optionalKey(Schema.String),
        }),
      ),
    ),
  }),
);
const decodeModified = json(
  Schema.Struct({
    id: GmailId,
    labelIds: Schema.optionalKey(Schema.Array(Schema.String)),
  }),
);
// Gmail's documented 403 usage limits; authorizing Gmail again cannot resolve them.
const rateLimited = Schema.decodeUnknownOption(
  Schema.fromJsonString(
    Schema.Struct({
      error: Schema.Struct({
        errors: Schema.Array(
          Schema.Struct({
            reason: Schema.Literals([
              'dailyLimitExceeded',
              'rateLimitExceeded',
              'userRateLimitExceeded',
            ]),
          }),
        ),
      }),
    }),
  ),
);

// 'authentication' needs Gmail authorized again; 'retry' may succeed on a later synchronization.
class SyncFailure extends Schema.TaggedError<SyncFailure>()('SyncFailure', {
  kind: Schema.Literals([
    'authentication',
    'retry',
    'locked',
    'conflict',
    // Native work started before a registration change; a new synchronization opens the cache again.
    'invalidated',
    'revoked',
    'failed',
  ]),
  cause: Schema.Defect(),
  // Logged instead of the cause; see rejectionDiagnostic.
  diagnostic: Schema.String,
}) {}

// A message or history that Gmail no longer has.
class GmailNotFound extends Schema.TaggedError<GmailNotFound>()(
  'GmailNotFound',
  {},
) {}

// Gmail refused the mailbox's grant; authorizing Gmail again is the only remedy.
const rejectedGrant = (error: unknown) =>
  error instanceof SyncFailure && error.kind === 'authentication';

class GmailInvalidPage extends Schema.TaggedError<GmailInvalidPage>()(
  'GmailInvalidPage',
  {},
) {}

const rejectionCode = (cause: unknown) =>
  Predicate.hasProperty(cause, 'code') && Predicate.isString(cause.code)
    ? cause.code
    : undefined;

const rejected = (
  cause: unknown,
  otherwise: 'retry' | 'failed',
): SyncFailure => {
  const code = rejectionCode(cause);
  let kind: SyncFailure['kind'] = otherwise;
  if (code === 'gmail-unavailable') {
    kind = 'authentication';
  } else if (code === 'locked' || code === 'conflict') {
    kind = code;
  } else if (code === 'mailbox-revoked') {
    kind = 'revoked';
  } else if (code === 'mailbox-invalidated') {
    kind = 'invalidated';
  }
  return new SyncFailure({
    kind,
    cause,
    diagnostic: rejectionDiagnostic(cause),
  });
};

const malformed = (error: Schema.SchemaError, kind: 'retry' | 'failed') =>
  new SyncFailure({ kind, cause: error, diagnostic: decodeDiagnostic(error) });

// The latest organizing outcome, until the next one; unsaved batches also report their size.
export type OrganizeNotice = Readonly<
  {
    action: GmailAction;
    message: GmailMessage;
  } & ({ kind: 'done' | 'rejected' } | { kind: 'unsaved'; count: number })
>;

type Sync = 'syncing' | 'current' | 'authentication' | 'retry';

export type GmailInboxState =
  | { readonly kind: 'loading' | 'locked' | 'failed' }
  | {
      readonly kind: 'ready';
      // Absent when no Gmail mailbox is connected on this device.
      readonly address?: string;
      readonly messages: readonly GmailMessage[];
      readonly sync: Sync;
      // The mailbox's own labels, empty until Gmail lists them.
      readonly labels: readonly GmailLabel[];
      // Changes saved on this device that Gmail has not confirmed yet.
      readonly pending: number;
      readonly saving: number;
      readonly blocked: boolean;
      readonly blockedAction?: PendingAction;
      // False while only the saved Inbox is open, before Gmail access verifies again; nothing can
      // be saved then.
      readonly organize: boolean;
      readonly notice?: OrganizeNotice;
    };

// An opened message's body. 'download' means it is not on this device and Gmail could not
// provide it now; 'missing' means Gmail no longer has the message.
export type MessageBodyState =
  | { readonly kind: 'loading' }
  | { readonly kind: 'ready'; readonly presentation: MessagePresentation }
  | {
      readonly kind: 'unavailable';
      readonly reason:
        | 'download'
        | 'authentication'
        | 'missing'
        | 'locked'
        | 'failed';
    };

const loadingBody: MessageBodyState = { kind: 'loading' };

const decodeStoredBodies = Schema.decodeUnknownEffect(
  Schema.Struct({ stored: Schema.Array(Schema.String) }),
);

const bodyFailure = (kind: SyncFailure['kind']): MessageBodyState => {
  let reason: Extract<MessageBodyState, { kind: 'unavailable' }>['reason'] =
    'download';
  if (kind === 'authentication' || kind === 'locked' || kind === 'failed') {
    reason = kind;
  }
  return { kind: 'unavailable', reason };
};

// ponytail: opened bodies held in memory; reopening an older one reads the encrypted cache again.
const bodiesInMemory = 20;

const mailbox = /^\s*(?:"?(?<name>[^"<]*?)"?\s*)?<(?<address>[^<>]+)>\s*$/u;

const sender = (from: string) => {
  const match = mailbox.exec(from)?.groups;
  const address = (match?.address ?? from).trim();
  const name = match?.name?.trim() ?? '';
  return { sender: name === '' ? address : name, address };
};

const newestFirst = Order.flip(
  Order.combine(
    Order.mapInput(Order.String, (message: GmailMessage) => message.receivedAt),
    Order.mapInput(Order.String, (message: GmailMessage) => message.id),
  ),
);

// Applies changes by message ID, so repeating a step never duplicates a message.
const merge = (
  messages: readonly GmailMessage[],
  // Messages no longer in the Inbox are undefined.
  found: ReadonlyArray<readonly [string, GmailMessage | undefined]>,
  deleted: ReadonlySet<string> = new Set(),
) => {
  const byId = new Map(messages.map((message) => [message.id, message]));
  for (const id of deleted) {
    byId.delete(id);
  }
  for (const [id, message] of found) {
    if (message === undefined) {
      byId.delete(id);
    } else {
      byId.set(id, message);
    }
  }
  return Arr.sort(byId.values(), newestFirst);
};

const labelsOf = (message: GmailMessage) =>
  message.labels ?? (message.unread ? ['INBOX', 'UNREAD'] : ['INBOX']);

const withLabels = (
  message: GmailMessage,
  labels: readonly string[],
): GmailMessage => ({ ...message, labels, unread: labels.includes('UNREAD') });

// Provider-confirmed messages with the requested changes applied in order. A message that left
// the cache returns only for a change that puts it back into the Inbox.
const organized = (
  messages: readonly GmailMessage[],
  pending: readonly PendingAction[],
) => {
  const byId = new Map(
    messages.map((message) => [
      message.id,
      { message, labels: labelsOf(message) },
    ]),
  );
  for (const { action, message } of pending) {
    const current =
      byId.get(message.id) ??
      (action.add.includes('INBOX')
        ? { message, labels: labelsOf(message) }
        : undefined);
    if (current !== undefined) {
      const labels = relabel(current.labels, action);
      byId.set(message.id, {
        labels,
        // Legacy pending work may also lack labels. Project it without claiming a known baseline
        // for new actions or Undo until Gmail supplies the memberships.
        message: canOrganize(current.message)
          ? withLabels(current.message, labels)
          : { ...current.message, unread: labels.includes('UNREAD') },
      });
    }
  }
  return Arr.sort(
    [...byId.values()]
      .filter(({ labels }) => inInbox(labels))
      .map(({ message }) => message),
    newestFirst,
  );
};

// The document after Gmail answered its oldest pending change: confirmed labels replace the
// cached ones, and a refused change only leaves the queue.
const settled = (
  document: MailboxDocument,
  confirmed: readonly string[] | undefined,
): MailboxDocument => {
  const [head, ...rest] = document.pending ?? [];
  if (head === undefined || confirmed === undefined) {
    return { ...document, pending: rest };
  }
  const cached = document.messages.find(({ id }) => id === head.message.id);
  return {
    ...document,
    messages:
      cached === undefined && !inInbox(confirmed)
        ? document.messages
        : merge(document.messages, [
            [head.message.id, withLabels(cached ?? head.message, confirmed)],
          ]),
    pending: rest,
  };
};

const attemptCount = (pending: PendingAction) =>
  (pending.attempts?.length ?? 0) - (pending.retryFrom ?? 0);
const requestedLabels = (labels: readonly string[], action: GmailAction) =>
  action.add.every((label) => labels.includes(label)) &&
  action.remove.every((label) => !labels.includes(label));

const storage = (operation: () => Promise<unknown>) =>
  Effect.tryPromise({
    try: operation,
    catch: (cause) => rejected(cause, 'failed'),
  }).pipe(
    Effect.flatMap(decodeCache),
    Effect.mapError((failure) =>
      Schema.isSchemaError(failure) ? malformed(failure, 'failed') : failure,
    ),
  );

// One Gmail request's `{ status, body }`; a rejected or malformed reply may pass on a later try.
const gmailResponse = (request: () => Promise<unknown>) =>
  Effect.tryPromise({
    try: request,
    catch: (cause) => rejected(cause, 'retry'),
  }).pipe(
    Effect.flatMap(decodeResponse),
    Effect.mapError((failure) =>
      Schema.isSchemaError(failure) ? malformed(failure, 'retry') : failure,
    ),
  );

// The oldest change after five unconfirmed attempts waits for Retry or Discard.
const blockedHead = (pending: readonly PendingAction[]) => {
  const [head] = pending;
  return head !== undefined && attemptCount(head) >= 5 ? head : undefined;
};

// The document once Gmail's current labels for the oldest change are known; a message Gmail no
// longer has leaves the cache.
const settleObserved = (
  document: MailboxDocument,
  head: PendingAction,
  labels: readonly string[] | undefined,
): MailboxDocument =>
  labels === undefined
    ? {
        ...settled(document, undefined),
        messages: document.messages.filter(({ id }) => id !== head.message.id),
      }
    : settled(document, labels);

// Appends intents by intake ID, so a commit whose reply was lost never saves one twice.
const withIntents = (
  document: MailboxDocument,
  intents: readonly PendingAction[],
): MailboxDocument => {
  const pending = document.pending ?? [];
  return {
    ...document,
    pending: [
      ...pending,
      ...intents.filter(
        (item) => !pending.some(({ id }) => id !== undefined && id === item.id),
      ),
    ],
  };
};

// Exponential delay with jitter before each attempt after the first.
const backoff = (count: number) =>
  count === 0
    ? Effect.void
    : Effect.void.pipe(
        Effect.schedule(
          Schedule.max([
            Schedule.spaced(`${100 * 2 ** (count - 1)} millis`).pipe(
              Schedule.jittered,
            ),
            Schedule.recurs(1),
          ]),
        ),
      );

// The change with one more dispatch attempt recorded.
const withAttempt = (head: PendingAction, at: number): PendingAction => ({
  ...head,
  attempts: [
    ...(head.attempts ?? []),
    {
      id: `${head.id ?? head.message.id}:${head.attempts?.length ?? 0}`,
      at,
    },
  ],
});

const samePending = (left: PendingAction | undefined, right: PendingAction) =>
  left?.id === right.id && left?.message.id === right.message.id;

// `next` over the latest saved document: intents saved since `base` was read are added, and
// intents another store instance settled since then leave instead of being sent again.
const rebasedOnto = (
  base: MailboxDocument | undefined,
  saved: MailboxDocument,
  next: MailboxDocument,
) => {
  const known = new Set((base?.pending ?? []).map(({ id }) => id));
  const remaining = new Set((saved.pending ?? []).map(({ id }) => id));
  return withIntents(
    {
      ...next,
      pending: (next.pending ?? []).filter(
        ({ id }) => id === undefined || !known.has(id) || remaining.has(id),
      ),
    },
    (saved.pending ?? []).filter(
      ({ id }) => id !== undefined && !known.has(id),
    ),
  );
};

// An unreadable document is preserved; only an absent cache starts a new listing.
const documentOf = (cache: Cache) =>
  cache.document === null
    ? Effect.succeedNone
    : decodeDocument(cache.document).pipe(
        Effect.asSome,
        // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
        Effect.mapError((error) => malformed(error, 'failed')),
      );

// The messages a listing page leaves cached, and whether the listing continues.
const listedPage = (
  messages: readonly GmailMessage[],
  found: ReadonlyArray<readonly [string, GmailMessage | undefined]>,
  { seen, more }: Readonly<{ seen: readonly string[]; more: boolean }>,
) => {
  const merged = merge(messages, found);
  const listed = new Set(seen);
  const verified = merged.filter((message) => listed.has(message.id));
  if (more && verified.length < cacheLimit) {
    // Newly verified entries take priority over stale entries retained during a relisting.
    const retained = merged.filter((message) => !listed.has(message.id));
    return {
      done: false,
      messages: Arr.sort(
        [...verified, ...retained].slice(0, cacheLimit),
        newestFirst,
      ),
    };
  }
  // Messages kept from before this listing that it never saw have left the Inbox.
  return { done: true, messages: verified.slice(0, cacheLimit) };
};

// The deleted message IDs a history page names, and the others whose state may have changed.
const historyChanges = (records: ReadonlyArray<typeof HistoryRecord.Type>) => {
  const deleted = new Set(
    records.flatMap((record) =>
      (record.messagesDeleted ?? []).map(({ message }) => message.id),
    ),
  );
  const changed = Arr.dedupe(
    records.flatMap((record) =>
      [
        ...(record.messagesAdded ?? []),
        ...(record.labelsAdded ?? []),
        ...(record.labelsRemoved ?? []),
      ].map(({ message }) => message.id),
    ),
  ).filter((id) => !deleted.has(id));
  return { deleted, changed };
};

// A listing that started again from its first page after Gmail rejected a saved page token.
const restartedListing = (
  previous: MailboxDocument | undefined,
  next: MailboxDocument,
) =>
  previous?.checkpoint.kind === 'backfill' &&
  previous.checkpoint.pageToken !== undefined &&
  next.checkpoint.kind === 'backfill' &&
  next.checkpoint.pageToken === undefined;

// Within a history page, the last record is a valid start for the next one.
const nextHistoryId = (
  page: Readonly<{ nextPageToken?: string; historyId: string }>,
  records: ReadonlyArray<Readonly<{ id: string }>>,
) =>
  page.nextPageToken === undefined
    ? page.historyId
    : (records.at(-1)?.id ?? page.historyId);

// Gmail rejecting a saved page token repeatedly ends this synchronization as a retry.
const restartLimit = (restarts: number) =>
  restarts > 2
    ? Effect.fail(
        new SyncFailure({
          kind: 'retry',
          cause: 400,
          diagnostic: 'rejected page token',
        }),
      )
    : Effect.void;

// Gmail refusing the grant needs authorization again; other HTTP failures may pass on a later try.
const httpFailure = (status: number, body: string) =>
  new SyncFailure({
    kind:
      status === 401 || (status === 403 && Option.isNone(rateLimited(body)))
        ? 'authentication'
        : 'retry',
    cause: status,
    diagnostic: `status ${status}`,
  });

export function createGmailInbox(
  native: NativeGmailMailbox,
  // Called after native code purged this device because another device removed it; the account
  // page, not the Inbox, explains what happened.
  { removed }: Readonly<{ removed?: () => void }> = {},
) {
  // One Gmail read; a missing resource is GmailNotFound and other HTTP failures are classified.
  const gmail =
    (scope: MailboxScope) =>
    <A>(
      path: string,
      query: ReadonlyArray<readonly [string, string]>,
      decode: (body: unknown) => Effect.Effect<A, Schema.SchemaError>,
    ) =>
      Effect.gen(function* () {
        const { status, body } = yield* gmailResponse(() =>
          native.gmailRequest(path, query, scope),
        );
        if (status === 404) {
          return yield* new GmailNotFound();
        }
        if (
          status === 400 &&
          path === 'messages' &&
          query.some(([name]) => name === 'pageToken')
        ) {
          return yield* new GmailInvalidPage();
        }
        if (status !== 200) {
          return yield* httpFailure(status, body);
        }
        return yield* decode(body).pipe(
          Effect.mapError((error) => malformed(error, 'retry')),
        );
      });

  const metadata = (scope: MailboxScope, id: string) =>
    gmail(scope)(
      `messages/${id}`,
      [
        ['format', 'metadata'],
        ['metadataHeaders', 'From'],
        ['metadataHeaders', 'Subject'],
      ],
      decodeMetadata,
    ).pipe(
      Effect.map((message) => {
        const labels = message.labelIds ?? [];
        const header = (name: string) =>
          message.payload?.headers?.find(
            (candidate) => candidate.name.toLowerCase() === name,
          )?.value;
        const received = inInbox(labels)
          ? DateTime.make(Number(message.internalDate))
          : Option.none();
        return received.pipe(
          Option.map((date): GmailMessage => ({
            id: message.id,
            threadId: message.threadId,
            ...sender(header('from') ?? ''),
            subject: header('subject') ?? '',
            preview: unescapeHtml(message.snippet ?? ''),
            receivedAt: DateTime.formatIso(date),
            unread: labels.includes('UNREAD'),
            labels,
          })),
        );
      }),
      // A message that left the Inbox or Gmail is removed from the cache.
      Effect.catchTag('GmailNotFound', () => Effect.succeedNone),
      Effect.map((message) => [id, Option.getOrUndefined(message)] as const),
    );
  const fetchAll = (scope: MailboxScope, ids: readonly string[]) =>
    Effect.forEach(ids, (id) => metadata(scope, id), { concurrency: 4 });

  // A new listing starts from the current history ID, so changes during it are replayed after.
  // Pending changes and labels carry over from the document it replaces.
  const startListing = Effect.fnUntraced(function* (
    scope: MailboxScope,
    previous: MailboxDocument | undefined,
    messages: readonly GmailMessage[],
  ): Effect.fn.Return<
    MailboxDocument,
    SyncFailure | GmailNotFound | GmailInvalidPage
  > {
    const profile = yield* gmail(scope)('profile', [], decodeProfile);
    if (profile.emailAddress.toLowerCase() !== scope.address.toLowerCase()) {
      return yield* new SyncFailure({
        kind: 'authentication',
        cause: 'mailbox',
        diagnostic: 'another mailbox',
      });
    }
    return {
      ...previous,
      version: 1,
      messages,
      checkpoint: { kind: 'backfill', historyId: profile.historyId, seen: [] },
    };
  });

  type Step = Effect.fn.Return<
    Option.Option<MailboxDocument>,
    SyncFailure | GmailNotFound | GmailInvalidPage
  >;

  // Lists the next Inbox page from a backfill checkpoint.
  const continueListing = Effect.fnUntraced(function* (
    scope: MailboxScope,
    document: MailboxDocument,
    checkpoint: Extract<MailboxDocument['checkpoint'], { kind: 'backfill' }>,
  ): Step {
    const page = yield* gmail(scope)(
      'messages',
      [
        ['labelIds', 'INBOX'],
        ['maxResults', String(pageSize)],
        ...(checkpoint.pageToken === undefined
          ? []
          : [['pageToken', checkpoint.pageToken] as const]),
      ],
      decodeList,
    ).pipe(
      Effect.asSome,
      Effect.catchTag('GmailInvalidPage', () => Effect.succeedNone),
    );
    if (Option.isNone(page)) {
      return Option.some(
        yield* startListing(scope, document, document.messages),
      );
    }
    const ids = (page.value.messages ?? []).map(({ id }) => id);
    const seen = Arr.dedupe([...checkpoint.seen, ...ids]);
    const { nextPageToken } = page.value;
    const listed = listedPage(document.messages, yield* fetchAll(scope, ids), {
      seen,
      more: nextPageToken !== undefined,
    });
    return Option.some({
      ...document,
      messages: listed.messages,
      checkpoint:
        listed.done || nextPageToken === undefined
          ? { kind: 'current', historyId: checkpoint.historyId }
          : { ...checkpoint, pageToken: nextPageToken, seen },
    });
  });

  // Applies one Gmail history page from a current checkpoint.
  const applyHistory = Effect.fnUntraced(function* (
    scope: MailboxScope,
    document: MailboxDocument,
    checkpoint: Extract<MailboxDocument['checkpoint'], { kind: 'current' }>,
  ): Step {
    const { messages } = document;
    const history = yield* gmail(scope)(
      'history',
      [
        ['startHistoryId', checkpoint.historyId],
        ['historyTypes', 'messageAdded'],
        ['historyTypes', 'messageDeleted'],
        ['historyTypes', 'labelAdded'],
        ['historyTypes', 'labelRemoved'],
      ],
      decodeHistory,
    ).pipe(
      Effect.asSome,
      Effect.catchTag('GmailNotFound', () => Effect.succeedNone),
    );
    if (Option.isNone(history)) {
      // An expired or invalid history ID lists the Inbox again; cached messages stay visible.
      return Option.some(yield* startListing(scope, document, messages));
    }
    const records = history.value.history ?? [];
    const historyId = nextHistoryId(history.value, records);
    if (records.length === 0 && historyId === checkpoint.historyId) {
      return Option.none();
    }
    const { deleted, changed } = historyChanges(records);
    const merged = merge(messages, yield* fetchAll(scope, changed), deleted);
    const remaining = new Set(merged.map(({ id }) => id));
    const updated = merged.slice(0, cacheLimit);
    // History cannot name the unchanged older message that now fits after an entry leaves.
    if (
      messages.length === cacheLimit &&
      messages.some(({ id }) => !remaining.has(id))
    ) {
      return Option.some(yield* startListing(scope, document, updated));
    }
    return Option.some({
      ...document,
      messages: updated,
      checkpoint: { kind: 'current', historyId },
    });
  });

  // The next document to commit, or none when the cache is current.
  const advance = (
    scope: MailboxScope,
    document: MailboxDocument | undefined,
  ) => {
    if (document === undefined) {
      return startListing(scope, undefined, []).pipe(Effect.asSome);
    }
    const { checkpoint } = document;
    if (checkpoint.kind === 'backfill') {
      return continueListing(scope, document, checkpoint);
    }
    // A cache written before messages kept their labels is listed again to read them.
    return document.messages.some(({ labels }) => labels === undefined)
      ? startListing(scope, document, document.messages).pipe(Effect.asSome)
      : applyHistory(scope, document, checkpoint);
  };

  const semaphore = Semaphore.makeUnsafe(1);
  const persistence = Semaphore.makeUnsafe(1);
  // The two metadata writers (sync and intake) may commit concurrently; body admission takes
  // both permits so it cannot interleave with either writer's commit, pruning and publication.
  // Each page releases its permit before provider work, so body saves never wait for a whole sync.
  const publication = Semaphore.makeUnsafe(2);
  let state: GmailInboxState = { kind: 'loading' };
  // An already-running metadata sync cannot dismiss a newer body grant rejection.
  let authenticationRejected = false;
  // The mailbox and document the Inbox shows, and whether Gmail access was verified for it.
  let shown:
    | Readonly<{
        scope: Cache;
        document: MailboxDocument | undefined;
        organize: boolean;
      }>
    | undefined = undefined;
  let sync: Sync = 'syncing';
  let notice: OrganizeNotice | undefined = undefined;
  // Requested changes not yet saved with the document, each bound to the mailbox it was made in.
  const queued: Array<{
    readonly scope: MailboxScope;
    pending: PendingAction;
  }> = [];
  // A synchronization queued behind the running one.
  let waiting: Promise<void> | null = null;
  // Set when the open Inbox closes, until the next synchronization starts; synchronizations run one
  // at a time, so this drops the late results of one started for the previous account.
  let forgotten = false;
  let ownership = 0;
  const messageOwners = new WeakMap<
    GmailMessage,
    { readonly ownership: number; readonly scope: MailboxScope }
  >();
  const listeners = new Set<() => void>();
  const notify = (next: GmailInboxState) => {
    state = next;
    for (const listener of listeners) {
      listener();
    }
  };
  // Messages the Inbox shows can be organized only for the mailbox and owner that showed them.
  const claim = (messages: readonly GmailMessage[]) => {
    if (shown !== undefined) {
      for (const message of messages) {
        messageOwners.set(message, { ownership, scope: shown.scope });
      }
    }
  };
  const presented = (durable: readonly PendingAction[]) => {
    const blockedAction = blockedHead(durable);
    return {
      ...(shown === undefined ? {} : { address: shown.scope.address }),
      ...(blockedAction === undefined ? {} : { blockedAction }),
      ...(notice === undefined ? {} : { notice }),
      blocked: blockedAction !== undefined,
      organize: shown?.organize ?? false,
    };
  };
  // A body read that met a rejected grant keeps asking for Gmail until it is authorized.
  const shownSyncState = (): Sync =>
    authenticationRejected && sync !== 'retry' ? 'authentication' : sync;
  const render = (): Extract<GmailInboxState, { kind: 'ready' }> => {
    const document = shown?.document;
    const durable = document?.pending ?? [];
    const messages = organized(document?.messages ?? [], [
      ...durable,
      ...queued.map((item) => item.pending),
    ]);
    claim(messages);
    return {
      kind: 'ready',
      messages,
      sync: shownSyncState(),
      labels: document?.labels ?? [],
      pending: durable.length,
      saving: queued.length,
      ...presented(durable),
    };
  };
  const publish = (next: GmailInboxState) => {
    if (!forgotten) {
      notify(next);
    }
  };
  // Bodies opened in this Inbox, in the order they were requested.
  const bodies = new Map<string, MessageBodyState>();
  const readers = new Map<string, number>();
  const legacyReaders = new Map<string, number>();
  const viewReaders = new Map<symbol, string>();
  const viewBodies = new Map<symbol, MessageBodyState>();
  const documents = new Map<string, BodyDocument>();
  const endedReaders = new Set<string>();
  // Each independent WebView owns a reservation and an immutable prepared presentation.
  const imageReservations = new Map<
    string | symbol,
    { bytes: number; pixels: number }
  >();
  const readingBodies = new Map<string, Promise<void>>();
  const releaseBody = (id: string) => {
    bodies.delete(id);
    documents.delete(id);
    imageReservations.delete(id);
    for (const [reader, message] of viewReaders) {
      if (message === id) {
        viewBodies.delete(reader);
        imageReservations.delete(reader);
      }
    }
  };

  // Bodies of messages the Inbox no longer lists leave memory with them.
  const settle = (next: Sync) => {
    sync = next;
    const rendered = render();
    const listed = new Set(rendered.messages.map(({ id }) => id));
    for (const id of bodies.keys()) {
      if (!listed.has(id)) {
        releaseBody(id);
      }
    }
    publish(rendered);
  };

  const ready = (
    cache: Cache,
    document: MailboxDocument | undefined,
    next: Sync,
  ) =>
    Effect.sync(() => {
      // A concurrent intake may already have published a newer durable revision.
      if (
        shown !== undefined &&
        shown.scope.address === cache.address &&
        shown.scope.owner === cache.owner &&
        shown.scope.generation === cache.generation &&
        shown.scope.revision > cache.revision
      ) {
        return;
      }
      shown = {
        scope: cache,
        document,
        organize: cache.availability === undefined,
      };
      settle(next);
    });

  // The recent working set of the latest selection; its stored bodies are protected from eviction.
  let selection: readonly string[] = [];
  let selectionReference: DateTime.Utc | undefined = undefined;
  const referenceInstant = Effect.suspend(() =>
    selectionReference === undefined
      ? DateTime.now
      : Effect.succeed(selectionReference),
  );
  // Protection at an admission: the working set of the Inbox shown now, from the first
  // published cached list on, plus the selection being prefetched, whose bodies never evict one
  // another.
  const protectedBodies = referenceInstant.pipe(
    Effect.map((reference) => [
      ...new Set([
        ...selection,
        ...recentWorkingSet(
          state.kind === 'ready' ? state.messages : [],
          reference,
        ),
      ]),
    ]),
  );
  // Bodies of messages that left the cached Inbox leave the device with them; the recent working
  // set's bodies stay protected as far as they fit. A failed prune is retried at the end of the
  // next synchronization, even when it commits nothing.
  const retainBodies = (
    { address, generation, revision }: Cache,
    messages: readonly GmailMessage[],
  ) =>
    referenceInstant.pipe(
      Effect.flatMap((reference) =>
        Effect.tryPromise({
          try: () =>
            native.retainMessageBodies(
              { address, generation, revision },
              messages.map(({ id }) => id),
              recentWorkingSet(messages, reference),
            ),
          catch: (cause) => rejected(cause, 'failed'),
        }),
      ),
      Effect.catchTag('SyncFailure', (failure) =>
        failure.kind === 'conflict' || failure.kind === 'invalidated'
          ? Effect.fail(failure)
          : Effect.logError(
              'Message bodies were not pruned:',
              failure.diagnostic,
            ),
      ),
    );

  // Commits a document over the revision this synchronization read.
  const commit = Effect.fnUntraced(function* (
    { address, revision, generation }: Cache,
    document: MailboxDocument,
  ) {
    const text = yield* encodeDocument(document).pipe(
      Effect.mapError((error) => malformed(error, 'failed')),
    );
    const committed = yield* storage(() =>
      native.commitMailbox({ address, generation }, revision, text),
    );
    yield* retainBodies(committed, document.messages);
    return committed;
  });

  // The mailbox whose cache the current Inbox shows; body reads use its native generation.
  let opened: MailboxScope | undefined = undefined;
  // Advances when the open Inbox closes, so a body read for the previous owner is dropped.
  let owner = 0;
  // ponytail: two concurrent body loads, the per-connection limit; one connection per device, so
  // the four-load account limit is never reached.
  const bodyLoads = Semaphore.makeUnsafe(2);
  // Open while no explicit read is waiting or running; speculative prefetch waits on it.
  const interactiveIdle = Latch.makeUnsafe(true);
  let interactive = 0;
  const speculativeBodies = new Map<string, Deferred.Deferred<undefined>>();

  const releaseLegacyReader = (id: string) => {
    const previous = legacyReaders.get(id) ?? 1;
    const reservation = imageReservations.get(id);
    if (previous === 1) {
      legacyReaders.delete(id);
      imageReservations.delete(id);
    } else {
      legacyReaders.set(id, previous - 1);
      if (reservation !== undefined) {
        imageReservations.set(id, {
          bytes: (reservation.bytes * (previous - 1)) / previous,
          pixels: (reservation.pixels * (previous - 1)) / previous,
        });
      }
    }
  };

  const setBody = (id: string, next: MessageBodyState) => {
    bodies.delete(id);
    bodies.set(id, next);
    for (const [stale, body] of bodies) {
      if (bodies.size <= bodiesInMemory) {
        break;
      }
      if (!readers.has(stale) && body.kind !== 'loading' && stale !== id) {
        releaseBody(stale);
      }
    }
    notify(state);
  };

  // Admits a body's inline images in document order while the budget shared by every displayed
  // body allows; the rest stay placeholders.
  const present = (key: string | symbol, document: BodyDocument, count = 1) => {
    const { id } = document;
    let bytes = 0;
    let pixels = 0;
    for (const [other, reserved] of imageReservations) {
      if (other !== key) {
        bytes += reserved.bytes;
        pixels += reserved.pixels;
      }
    }
    let occurrences: readonly string[] = [];
    try {
      occurrences =
        document.html === undefined
          ? []
          : sanitizeHtml(document.html).contentIdOccurrences;
    } catch {
      imageReservations.delete(key);
      return presentation({
        version: 2,
        id,
        ...(document.text === undefined ? {} : { text: document.text }),
      });
    }
    let reservedBytes = 0;
    let reservedPixels = 0;
    const visibleImages = (document.images?.admitted ?? []).filter((image) => {
      const occurrencesCount = occurrences.filter(
        (contentId) => contentId === image.contentId,
      ).length;
      const size =
        ((image.data.length * 3) / 4 -
          (/=+$/u.exec(image.data)?.[0].length ?? 0)) *
        occurrencesCount;
      const area = image.width * image.height * occurrencesCount;
      if (
        bytes + size * count > inlineImageLimits.aggregateBytes ||
        pixels + area * count > inlineImageLimits.aggregatePixels
      ) {
        return false;
      }
      bytes += size * count;
      pixels += area * count;
      reservedBytes += size * count;
      reservedPixels += area * count;
      return true;
    });
    imageReservations.set(key, {
      bytes: reservedBytes,
      pixels: reservedPixels,
    });
    return presentation(document, visibleImages);
  };

  const prepareReaders = (id: string, document: BodyDocument) => {
    documents.set(id, document);
    const count = legacyReaders.get(id) ?? 0;
    const prepared =
      count > 0 || !readers.has(id)
        ? present(id, document, Math.max(1, count))
        : presentation(document, []);
    for (const [reader, message] of viewReaders) {
      if (message === id) {
        viewBodies.set(reader, {
          kind: 'ready',
          presentation: present(reader, document),
        });
      }
    }
    return prepared;
  };

  const listed = (id: string) =>
    state.kind === 'ready' &&
    state.messages.some((message) => message.id === id);

  // One Gmail body read; listing-page token errors cannot occur for these resources.
  const gmailRead =
    (scope: MailboxScope) =>
    <A>(
      path: string,
      query: ReadonlyArray<readonly [string, string]>,
      decode: (body: unknown) => Effect.Effect<A, Schema.SchemaError>,
    ) =>
      gmail(scope)(path, query, decode).pipe(
        Effect.catchTag('GmailInvalidPage', Effect.die),
      );

  // A part's bytes: inline in the message, or served separately when Gmail splits a large part.
  // Only complete data matching Gmail's declared size is returned.
  const partData = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
    part: GmailPart,
  ) {
    const { attachmentId } = part.body ?? {};
    const downloaded =
      attachmentId === undefined
        ? { data: part.body?.data ?? '', size: part.body?.size }
        : yield* gmailRead(scope)(
            `messages/${id}/attachments/${attachmentId}`,
            [],
            decodeAttachment,
          );
    if (downloaded.size !== part.body?.size) {
      return yield* new SyncFailure({
        kind: 'retry',
        cause: 'body size',
        diagnostic: 'incomplete body',
      });
    }
    return downloaded.data;
  });

  const fetchPart = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
    part: GmailPart,
  ) {
    const data = yield* partData(scope, id, part);
    return yield* partText(part, data, part.body?.size).pipe(
      Effect.mapError(
        (cause) =>
          new SyncFailure({
            kind: 'retry',
            cause,
            diagnostic: 'invalid body encoding',
          }),
      ),
    );
  });

  const fullMessage = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
    query: ReadonlyArray<readonly [string, string]>,
  ) {
    const message = yield* gmailRead(scope)(
      `messages/${id}`,
      query,
      decodeFullMessage,
    );
    if (message.id !== id) {
      return yield* new SyncFailure({
        kind: 'retry',
        cause: 'message',
        diagnostic: 'another message',
      });
    }
    return message.payload;
  });

  // Resolves visible Content-ID references against the message's MIME scopes. Each image fails
  // independently; a transient failure leaves the resolution unrecorded so a later open retries.
  const resolveImages = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
    wanted: Readonly<{
      path: readonly GmailPart[];
      references: readonly string[];
    }>,
  ) {
    const parts = inlineImageParts(wanted.path);
    const tally = imageTally();
    for (const [index, contentId] of wanted.references.entries()) {
      const part = parts.get(contentId);
      if (part === undefined || !tally.request(part, index)) {
        tally.refuse(contentId);
      } else {
        // A rejected grant stops resolution: later images would meet the same rejection.
        const attempt = yield* partData(scope, id, part).pipe(
          Effect.map((data) => ({ data })),
          Effect.catchIf(rejectedGrant, () =>
            Effect.succeed('authentication' as const),
          ),
          Effect.orElseSucceed(() => ({ data: undefined })),
        );
        if (attempt === 'authentication') {
          return { ...tally.result(), complete: false, authentication: true };
        }
        tally.receive(contentId, part, attempt.data);
      }
    }
    return { ...tally.result(), authentication: false };
  });

  // An explicit open's body from Gmail: both readable alternatives and its inline images.
  const fetchBody = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
  ): Effect.fn.Return<
    Readonly<{ document: BodyDocument; authentication: boolean }>,
    SyncFailure | GmailNotFound
  > {
    const payload = yield* fullMessage(scope, id, [['format', 'full']]);
    const { html, text, path } = bodyParts(payload);
    const document: BodyDocument = {
      version: 2,
      id,
      ...(text === undefined
        ? {}
        : { text: yield* fetchPart(scope, id, text) }),
      ...(html === undefined
        ? {}
        : { html: yield* fetchPart(scope, id, html) }),
    };
    const references = contentIdsOf(document);
    if (references.length === 0) {
      return {
        document: { ...document, images: { admitted: [], refused: [] } },
        authentication: false,
      };
    }
    const resolved = yield* resolveImages(scope, id, { path, references });
    return {
      document: resolved.complete
        ? { ...document, images: resolved.images }
        : document,
      authentication: resolved.authentication,
    };
  });

  // A cached body opened explicitly before its inline images were resolved resolves them now,
  // when Gmail answers; offline, it opens with placeholders.
  const completeImages = Effect.fnUntraced(function* (
    scope: MailboxScope,
    document: BodyDocument,
  ) {
    const references = contentIdsOf(document);
    if (document.images !== undefined || references.length === 0) {
      return { document, changed: false, authentication: false };
    }
    const payload = yield* fullMessage(scope, document.id, [
      ['format', 'full'],
    ]);
    const resolved = yield* resolveImages(scope, document.id, {
      path: bodyParts(payload).path,
      references,
    });
    return resolved.complete
      ? {
          document: { ...document, images: resolved.images },
          changed: true,
          authentication: false,
        }
      : { document, changed: false, authentication: resolved.authentication };
  });

  const cachedDocument = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
  ) {
    const cached = yield* Effect.tryPromise({
      try: () => native.openMessageBody(scope, id),
      catch: (cause) => rejected(cause, 'failed'),
    });
    const reply = yield* decodeCachedBody(cached).pipe(
      Effect.mapError((error) => malformed(error, 'failed')),
    );
    return Option.fromNullishOr(reply.document).pipe(
      Option.flatMap(decodeBodyDocument),
      Option.filter((document) => document.id === id),
    );
  });

  // Stores a body under the current working set's protection. Commits are fenced like mailbox
  // commits: a message that left the Inbox, or a closed Inbox, stores nothing.
  const store = (
    document: BodyDocument,
    {
      scope,
      tier,
      reading,
    }: Readonly<{
      scope: MailboxScope;
      tier: 'opened' | 'prefetched';
      reading: number;
    }>,
  ) =>
    encodeBodyDocument(document).pipe(
      // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
      Effect.mapError((error) => malformed(error, 'failed')),
      Effect.flatMap((text) =>
        publication.withPermits(2)(
          Effect.suspend(() =>
            owner === reading && listed(document.id)
              ? protectedBodies.pipe(
                  Effect.flatMap((protectedIds) =>
                    Effect.tryPromise({
                      try: () =>
                        native.commitMessageBody(scope, document.id, {
                          document: text,
                          tier,
                          protectedIds,
                        }),
                      catch: (cause) => rejected(cause, 'failed'),
                    }),
                  ),
                  Effect.flatMap((reply) =>
                    Schema.decodeUnknownEffect(
                      Schema.Struct({ admitted: Schema.Boolean }),
                    )(reply).pipe(
                      // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed decoding channel.
                      Effect.mapError((error) => malformed(error, 'failed')),
                    ),
                  ),
                )
              : Effect.fail(
                  new SyncFailure({
                    kind: 'invalidated',
                    cause: 'message left',
                    diagnostic: 'message left Inbox',
                  }),
                ),
          ),
        ),
      ),
    );

  // The cached body when this device has one, otherwise Gmail's, which is then cached when it fits.
  // Images a rejected grant left unresolved are read again after Gmail is authorized.
  const imagesAwaitingGmail = new Set<string>();
  // Publishes the Inbox's authentication state for the reader that met a rejected grant.
  const askForGmail = (reading: number, id: string) =>
    Effect.sync(() => {
      if (owner === reading && listed(id)) {
        authenticationRejected = true;
        imagesAwaitingGmail.add(id);
        publish(render());
      }
    });

  const loadBody = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
    reading: number,
  ) {
    if (reading !== owner || !listed(id)) {
      return yield* new SyncFailure({
        kind: 'invalidated',
        cause: 'closed reader',
        diagnostic: 'message left Inbox',
      });
    }
    const stored = (yield* cachedDocument(scope, id)).pipe(
      Option.filter((document) => document.excluded !== true),
    );
    const tier = (yield* protectedBodies).includes(id)
      ? 'prefetched'
      : 'opened';
    if (Option.isSome(stored)) {
      // Offline, the cached body opens with placeholders; a rejected grant also asks for Gmail.
      const completed = yield* completeImages(scope, stored.value).pipe(
        Effect.catchIf(rejectedGrant, () =>
          Effect.succeed({
            document: stored.value,
            changed: false,
            authentication: true,
          }),
        ),
        Effect.orElseSucceed(() => ({
          document: stored.value,
          changed: false,
          authentication: false,
        })),
      );
      if (completed.authentication) {
        yield* askForGmail(reading, id);
      }
      if (completed.changed) {
        yield* store(completed.document, { scope, tier, reading }).pipe(
          Effect.ignore,
        );
      }
      return completed.document;
    }
    const { document, authentication } = yield* fetchBody(scope, id);
    if (authentication) {
      yield* askForGmail(reading, id);
    }
    yield* store(document, { scope, tier, reading }).pipe(
      // A body that could not be kept is still shown, unless its mailbox changed meanwhile.
      Effect.catchIf(
        (failure) => failure.kind !== 'invalidated',
        (failure) =>
          Effect.logError('Message body was not cached:', failure.diagnostic),
      ),
    );
    return document;
  });

  const beginInteractive = Effect.sync(() => {
    interactive += 1;
    interactiveIdle.closeUnsafe();
  });
  const endInteractive = Effect.sync(() => {
    interactive -= 1;
    if (interactive === 0) {
      interactiveIdle.openUnsafe();
    }
  });

  // A refresh reloads a shown body in place: it keeps showing until the reload succeeds.
  const readMessage = (
    id: string,
    { refresh = false }: Readonly<{ refresh?: boolean }> = {},
  ) => {
    const pending = readingBodies.get(id);
    if (pending !== undefined) {
      return pending;
    }
    const current = bodies.get(id);
    const scope = opened;
    // Only messages in the open Inbox are read, so no body outlives its listing.
    if (
      scope === undefined ||
      !listed(id) ||
      current?.kind === 'loading' ||
      (current?.kind === 'ready') !== refresh
    ) {
      return Promise.resolve();
    }
    const reading = owner;
    if (!refresh) {
      setBody(id, loadingBody);
    }
    const run = runLogged(
      Effect.acquireUseRelease(
        beginInteractive,
        () =>
          Effect.gen(function* () {
            const speculative = speculativeBodies.get(id);
            if (speculative !== undefined) {
              yield* Deferred.await(speculative);
            }
            return yield* bodyLoads.withPermit(loadBody(scope, id, reading));
          }),
        () => endInteractive,
      ).pipe(
        Effect.map((document): MessageBodyState => {
          if (owner !== reading || !listed(id) || endedReaders.has(id)) {
            return loadingBody;
          }
          return { kind: 'ready', presentation: prepareReaders(id, document) };
        }),
        Effect.catchTags({
          GmailNotFound: () =>
            Effect.succeed<MessageBodyState>({
              kind: 'unavailable',
              reason: 'missing',
            }),
          // A rejected grant also asks for Gmail again, as prefetch does, so the Inbox offers
          // authorization; retrying the body alone would repeat the same rejection.
          SyncFailure: ({ kind, diagnostic }) => {
            if (kind === 'authentication') {
              return Effect.sync(() => {
                if (owner === reading && listed(id)) {
                  authenticationRejected = true;
                  publish(render());
                }
              }).pipe(Effect.as(bodyFailure(kind)));
            }
            return (
              kind === 'locked'
                ? Effect.void
                : Effect.logError('Message body failed:', diagnostic)
            ).pipe(Effect.as(bodyFailure(kind)));
          },
        }),
        Effect.flatMap((next) =>
          Effect.sync(() => {
            if (owner === reading && listed(id)) {
              if (endedReaders.has(id)) {
                endedReaders.delete(id);
                releaseBody(id);
                notify(state);
              } else if (!refresh || next.kind === 'ready') {
                setBody(id, next);
              }
            }
          }),
        ),
        Effect.ensuring(
          Effect.sync(() => {
            if (owner === reading) {
              readingBodies.delete(id);
            }
          }),
        ),
      ),
    );
    readingBodies.set(id, run);
    return run;
  };

  // Prefetch reads only single-part plain-text or HTML messages; others get an exclusion marker
  // so later selections skip them without asking Gmail again.
  const prefetchBody = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
    reading: number,
  ) {
    const admission = { scope, tier: 'prefetched', reading } as const;
    const excluded: BodyDocument = { version: 2, id, excluded: true };
    const preflight = yield* fullMessage(scope, id, [
      ['format', 'metadata'],
      ['metadataHeaders', 'Content-Type'],
      ['metadataHeaders', 'Content-Disposition'],
    ]);
    if (!singleReadablePart(preflight)) {
      return yield* store(excluded, admission);
    }
    const payload = yield* fullMessage(scope, id, [['format', 'full']]);
    if (!singleReadablePart(payload)) {
      return yield* store(excluded, admission);
    }
    const content = yield* fetchPart(scope, id, payload);
    const html = bodyParts(payload).html !== undefined;
    return yield* store(
      { version: 2, id, ...(html ? { html: content } : { text: content }) },
      admission,
    );
  });

  const prefetchItem = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
    reading: number,
  ) {
    const pending = yield* Deferred.make<undefined>();
    speculativeBodies.set(id, pending);
    yield* bodyLoads.withPermit(prefetchBody(scope, id, reading)).pipe(
      Effect.catchTag('GmailNotFound', () => Effect.void),
      Effect.ensuring(
        Effect.gen(function* () {
          if (speculativeBodies.get(id) === pending) {
            speculativeBodies.delete(id);
          }
          yield* Deferred.succeed(pending, undefined);
        }),
      ),
    );
  });

  const prefetchPaused = (reading: number, id: string) =>
    owner !== reading ||
    !listed(id) ||
    state.kind !== 'ready' ||
    state.sync === 'authentication' ||
    state.sync === 'retry';

  // One speculative lane: selections run one at a time, and each body waits while an explicit
  // read is waiting or running, then holds one of the connection's two loads.
  const prefetch = Effect.fnUntraced(function* (reading: number) {
    const scope = opened;
    if (scope === undefined || state.kind !== 'ready' || owner !== reading) {
      return;
    }
    selection = recentWorkingSet(
      state.messages,
      selectionReference ?? (yield* DateTime.now),
    );
    const reply = yield* Effect.tryPromise({
      try: () => native.listMessageBodies(scope, selection),
      catch: (cause) => rejected(cause, 'failed'),
    });
    const stored = new Set(
      (yield* decodeStoredBodies(reply).pipe(
        Effect.mapError((error) => malformed(error, 'failed')),
      )).stored,
    );
    for (const id of selection) {
      yield* interactiveIdle.await;
      if (prefetchPaused(reading, id)) {
        return;
      }
      if (!stored.has(id) && !readingBodies.has(id)) {
        yield* prefetchItem(scope, id, reading);
      }
    }
  });

  let prefetching = false;
  let prefetchAgain = false;
  // Authentication stops provider work and asks for Gmail again; offline, quota and server
  // failures pause prefetch until the next synchronization.
  const prefetchFailure =
    (reading: number) =>
    ({
      kind,
      diagnostic,
    }: Readonly<Pick<SyncFailure, 'kind' | 'diagnostic'>>) => {
      if (kind === 'authentication') {
        return Effect.sync(() => {
          if (owner === reading) {
            authenticationRejected = true;
            publish(render());
          }
        });
      }
      return kind === 'invalidated' || kind === 'retry'
        ? Effect.void
        : Effect.logError('Body prefetch failed:', diagnostic);
    };
  // Starts the lane, or asks a running lane to select again after its current pass.
  const schedulePrefetch = Effect.sync(() => {
    if (prefetching) {
      prefetchAgain = true;
      return;
    }
    prefetching = true;
    const reading = owner;
    void runLogged(
      Effect.gen(function* () {
        let again = true;
        while (again) {
          prefetchAgain = false;
          yield* prefetch(reading);
          again = prefetchAgain && owner === reading;
        }
      }).pipe(
        Effect.catchTag('SyncFailure', prefetchFailure(reading)),
        // A request from a newer Inbox owner arrived while this lane ran; start it for that
        // owner. The same owner's paused lane waits for its next synchronization.
        Effect.ensuring(
          Effect.suspend(() => {
            prefetching = false;
            return prefetchAgain && owner !== reading
              ? schedulePrefetch
              : Effect.void;
          }),
        ),
      ),
    );
  });

  // The latest saved document with `next` over it: intents intake saved since `base` was read stay.
  const rebased = Effect.fnUntraced(function* ({
    cache,
    base,
    document,
  }: Readonly<{
    cache: Cache;
    base: MailboxDocument | undefined;
    document: MailboxDocument;
  }>) {
    const latest = yield* storage(native.openMailbox);
    const saved = Option.getOrUndefined(yield* documentOf(latest));
    if (!sameMailbox(latest, cache) || saved === undefined) {
      return yield* new SyncFailure({
        kind: 'invalidated',
        cause: 'mailbox',
        diagnostic: 'another mailbox',
      });
    }
    return {
      cache: latest,
      base: saved,
      document: rebasedOnto(base, saved, document),
    };
  });

  // Intake saves intent under its own permit, so a synchronization commit can meet a newer
  // revision. Rebase it, and keep commit, pruning and publication together against body admission.
  const commitOver = Effect.fnUntraced(function* (
    cache: Cache,
    base: MailboxDocument | undefined,
    next: MailboxDocument,
  ) {
    let target = { cache, base, document: next };
    for (let attempt = 1; ; attempt += 1) {
      const saved = yield* commit(target.cache, target.document).pipe(
        Effect.asSome,
        Effect.catchIf(
          (error) =>
            attempt <= 2 &&
            error instanceof SyncFailure &&
            error.kind === 'conflict',
          () => Effect.succeedNone,
        ),
      );
      if (Option.isSome(saved)) {
        yield* ready(saved.value, target.document, sync);
        return { cache: saved.value, document: target.document };
      }
      target = yield* rebased(target);
    }
  }, publication.withPermit);

  // Removes only matching intents: forget() may already have removed them, and newer intents stay.
  const removeQueued = (
    taken: (item: Readonly<(typeof queued)[number]>) => boolean,
  ) => {
    const kept = queued.filter((item) => !taken(item));
    queued.splice(0, queued.length, ...kept);
  };
  // Intake IDs stay on the queued intent, so a retried save after a lost reply reuses them.
  const identify = Effect.fnUntraced(function* (cache: MailboxScope) {
    for (const item of queued) {
      if (item.pending.id === undefined && sameMailbox(item.scope, cache)) {
        item.pending = {
          ...item.pending,
          id: `${yield* Random.nextInt}:${yield* Random.nextInt}`,
        };
      }
    }
  });

  // Forgets everything the open Inbox holds in memory: its mail, bodies, changes not yet saved and
  // their outcome, so another account or mailbox never renders them.
  const forgetOpenInbox = () => {
    ownership += 1;
    owner += 1;
    queued.length = 0;
    shown = undefined;
    notice = undefined;
    authenticationRejected = false;
    imagesAwaitingGmail.clear();
    opened = undefined;
    bodies.clear();
    readers.clear();
    legacyReaders.clear();
    viewReaders.clear();
    viewBodies.clear();
    documents.clear();
    endedReaders.clear();
    readingBodies.clear();
    imageReservations.clear();
    selection = [];
    selectionReference = undefined;
    speculativeBodies.clear();
    if (!forgotten || state.kind !== 'loading') {
      forgotten = true;
      notify({ kind: 'loading' });
    }
  };

  // Authentication and retry keep the shown mail; locked or unreadable storage hides it. A removed
  // device's data is already gone, so its Inbox waits for the account page instead.
  const recover = ({
    kind,
    diagnostic,
  }: Readonly<Pick<SyncFailure, 'kind' | 'diagnostic'>>) =>
    (kind === 'authentication' || kind === 'locked' || kind === 'revoked'
      ? Effect.void
      : Effect.logError('Gmail Inbox failed:', diagnostic)
    ).pipe(
      Effect.andThen(
        Effect.sync(() => {
          if (kind === 'revoked') {
            forgetOpenInbox();
            removed?.();
          } else if (kind === 'authentication' || kind === 'retry') {
            settle(
              authenticationRejected && kind === 'retry'
                ? 'authentication'
                : kind,
            );
          } else {
            publish({ kind: kind === 'locked' ? 'locked' : 'failed' });
          }
        }),
      ),
    );

  // Intake uses its own permit: a blocked Gmail read must not delay recording intent. Native
  // compare-and-swap fences concurrent sync commits; each intake ID also reconciles a lost commit
  // reply without appending the same intent twice.
  const save = Effect.suspend(() => {
    const startedFor = ownership;
    const stillOwned = () => !forgotten && startedFor === ownership;
    return Effect.gen(function* () {
      const cache = yield* storage(native.openMailbox);
      const document = Option.getOrUndefined(yield* documentOf(cache));
      if (!stillOwned()) {
        return false;
      }
      const taken = [...queued];
      const owned = taken.filter(({ scope }) => sameMailbox(scope, cache));
      if (cache.availability !== undefined) {
        // Only the saved Inbox opens now, so nothing can be saved: the unsaved changes roll back
        // and organizing waits until Gmail access verifies again.
        removeQueued((item) => taken.includes(item));
        const last = owned.at(-1);
        if (taken.length > 0) {
          notice =
            last === undefined
              ? undefined
              : {
                  kind: 'unsaved',
                  count: owned.length,
                  action: last.pending.action,
                  message: last.pending.message,
                };
        }
        yield* ready(cache, document, 'retry');
        return false;
      }
      if (owned.length === 0) {
        removeQueued((item) => taken.includes(item));
        return true;
      }
      if (document === undefined) {
        return yield* new SyncFailure({
          kind: 'failed',
          cause: 'missing cache',
          diagnostic: 'missing cache',
        });
      }
      yield* identify(cache);
      const next = withIntents(
        document,
        owned.map((item) => item.pending),
      );
      return yield* publication.withPermit(
        Effect.gen(function* () {
          const saved = yield* commit(cache, next);
          removeQueued((item) => taken.includes(item));
          if (stillOwned()) {
            yield* ready(saved, next, sync);
          }
          return stillOwned();
        }),
      );
    }).pipe(
      Effect.retry({
        times: 2,
        while: (error) =>
          error instanceof SyncFailure &&
          (error.kind === 'conflict' || error.kind === 'invalidated'),
      }),
      // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Typed Effect error recovery.
      Effect.catchTag('SyncFailure', (error) =>
        startedFor === ownership
          ? recover(error).pipe(Effect.as(false))
          : Effect.succeed(false),
      ),
    );
  });

  const readLabels = (scope: MailboxScope, message: GmailMessage) =>
    gmail(scope)(
      `messages/${message.id}`,
      [['format', 'metadata']],
      decodeModified,
    ).pipe(
      Effect.flatMap((value) =>
        value.id === message.id
          ? Effect.succeed(value.labelIds ?? [])
          : Effect.fail(
              new SyncFailure({
                kind: 'retry',
                cause: 'message mismatch',
                diagnostic: 'another message',
              }),
            ),
      ),
      Effect.asSome,
      Effect.catchTag('GmailNotFound', () => Effect.succeedNone),
    );

  // Gmail's labels after one modify, or none when Gmail refuses the change for good: the message
  // or label no longer exists. A label change applied twice leaves the same labels, so a request
  // whose response was lost is safely sent again.
  const modify = Effect.fnUntraced(function* (
    scope: MailboxScope,
    { action, message }: PendingAction,
  ) {
    const { status, body } = yield* gmailResponse(() =>
      native.gmailModify(
        { message: message.id, add: action.add, remove: action.remove },
        scope,
      ),
    );
    if (status === 400 || status === 404) {
      return Option.none<readonly string[]>();
    }
    if (status !== 200) {
      return yield* httpFailure(status, body);
    }
    const modified = yield* decodeModified(body).pipe(
      Effect.mapError((error) => malformed(error, 'retry')),
    );
    if (modified.id !== message.id) {
      return yield* new SyncFailure({
        kind: 'retry',
        cause: 'message mismatch',
        diagnostic: 'another message',
      });
    }
    return Option.some(modified.labelIds ?? []);
  });

  // A refused change leaves the queue once Gmail's current labels for its message are read.
  const settleRefusal = Effect.fnUntraced(function* (
    current: Readonly<{ cache: Cache; document: MailboxDocument }>,
    head: PendingAction,
  ) {
    // A refusal-save rebase may already have removed this head; leave later intent untouched.
    if (!samePending(current.document.pending?.[0], head)) {
      return current;
    }
    const startedFor = ownership;
    const observed = yield* readLabels(current.cache, head.message);
    const next = settleObserved(
      current.document,
      head,
      Option.getOrUndefined(observed),
    );
    // Keep rejection feedback if settlement loses its reply; a late read cannot restore the
    // previous owner's message, and forget() clears this notice while a commit is pending.
    if (startedFor === ownership && !forgotten) {
      notice = { kind: 'rejected', ...head };
    }
    const saved = yield* commitOver(current.cache, current.document, next);
    return saved;
  });

  const dispatch = Effect.fnUntraced(function* (
    current: { readonly cache: Cache; readonly document: MailboxDocument },
    head: PendingAction,
  ) {
    yield* backoff(attemptCount(head));
    const attempted = withAttempt(
      head,
      DateTime.toEpochMillis(yield* DateTime.now),
    );
    const preparing = {
      ...current.document,
      pending: [attempted, ...(current.document.pending ?? []).slice(1)],
    };
    const prepared = yield* commitOver(
      current.cache,
      current.document,
      preparing,
    );
    // Another store instance settled this change while it was being prepared; never send it twice.
    if (!samePending(prepared.document.pending?.[0], attempted)) {
      return prepared;
    }
    const outcome = yield* modify(prepared.cache, attempted);
    if (Option.isNone(outcome)) {
      // Refusal is not authoritative metadata: save it first, so a label read that is interrupted
      // settles the refusal later instead of sending the refused change again.
      const refusedHead = { ...attempted, refused: true } as const;
      const refused = yield* commitOver(prepared.cache, prepared.document, {
        ...prepared.document,
        pending: [refusedHead, ...(prepared.document.pending ?? []).slice(1)],
      });
      return yield* settleRefusal(refused, refusedHead);
    }
    const next = settled(prepared.document, outcome.value);
    const done = yield* commitOver(prepared.cache, prepared.document, next);
    return done;
  });

  // A change already sent is checked against Gmail before another attempt. It settles when Gmail
  // shows its labels or no longer has the message; otherwise it is sent again.
  const reconcile = Effect.fnUntraced(function* (
    current: Readonly<{ cache: Cache; document: MailboxDocument }>,
    head: PendingAction,
  ) {
    if (head.refused === true) {
      return Option.some(yield* settleRefusal(current, head));
    }
    if ((head.attempts?.length ?? 0) === 0) {
      return Option.none<{ cache: Cache; document: MailboxDocument }>();
    }
    const observed = yield* readLabels(current.cache, head.message);
    if (
      Option.isSome(observed) &&
      !requestedLabels(observed.value, head.action)
    ) {
      return Option.none<{ cache: Cache; document: MailboxDocument }>();
    }
    const next = settleObserved(
      current.document,
      head,
      Option.getOrUndefined(observed),
    );
    if (Option.isNone(observed)) {
      notice = { kind: 'rejected', ...head };
    }
    const saved = yield* commitOver(current.cache, current.document, next);
    return Option.some(saved);
  });

  // Sends saved changes in order. Reconcile unanswered writes before another dispatch.
  const sendPending = Effect.fnUntraced(function* (
    initial: Cache,
    document: MailboxDocument,
  ) {
    let current = { cache: initial, document };
    let [head] = current.document.pending ?? [];
    while (head !== undefined) {
      const reconciled = yield* reconcile(current, head);
      if (Option.isSome(reconciled)) {
        current = reconciled.value;
      } else if (attemptCount(head) >= 5) {
        return current;
      } else {
        current = yield* dispatch(current, head);
      }
      [head] = current.document.pending ?? [];
    }
    return current;
  });

  // The mailbox's own labels, listed once per synchronization; resolves the latest cache.
  const refreshLabels = Effect.fnUntraced(function* (
    cache: Cache,
    document: MailboxDocument,
  ) {
    const response = yield* gmail(cache)('labels', [], decodeLabels);
    const labels = Arr.sort(
      (response.labels ?? [])
        .filter(({ type }) => type === 'user')
        .map(({ id, name }) => ({ id, name }))
        // A label whose ID this client cannot send is left out rather than failing the list.
        .filter(Schema.is(GmailLabelSchema)),
      Order.mapInput(Order.String, (label: GmailLabel) => label.name),
    );
    const previous = document.labels ?? [];
    if (
      labels.length === previous.length &&
      labels.every(
        (label, index) =>
          label.id === previous[index]?.id &&
          label.name === previous[index]?.name,
      )
    ) {
      return { cache, document };
    }
    const saved = yield* commitOver(cache, document, { ...document, labels });
    return saved;
  });

  // Bodies Gmail could not provide before are read again now that it answers.
  const rereadBodies = Effect.sync(() => {
    if (authenticationRejected) {
      return;
    }
    for (const [id, body] of bodies) {
      if (body.kind === 'unavailable' && body.reason !== 'missing') {
        void readMessage(id);
      }
    }
    // Shown bodies whose images a rejected grant left unresolved resolve them now.
    for (const id of imagesAwaitingGmail) {
      imagesAwaitingGmail.delete(id);
      void readMessage(id, { refresh: true });
    }
  });

  // Prunes bodies of messages that left the cache, then publishes the current Inbox and resumes
  // body work that waited for Gmail.
  const finishSynchronization = (
    cache: Cache,
    document: MailboxDocument | undefined,
  ) =>
    publication
      .withPermit(
        retainBodies(cache, document?.messages ?? []).pipe(
          Effect.andThen(
            Effect.sync(() => {
              settle('current');
            }),
          ),
        ),
      )
      .pipe(Effect.andThen(schedulePrefetch), Effect.andThen(rereadBodies));

  const synchronize = Effect.gen(function* () {
    let cache = yield* storage(native.openMailbox);
    const { address, generation } = cache;
    selectionReference = yield* DateTime.now;
    if (!forgotten) {
      opened = { address, generation };
    }
    let document = Option.getOrUndefined(yield* documentOf(cache));
    if (cache.availability === 'retry') {
      return yield* ready(cache, document, 'retry');
    }
    yield* ready(cache, document, 'syncing');
    let restarts = 0;
    for (;;) {
      if (document !== undefined) {
        ({ cache, document } = yield* sendPending(cache, document));
      }
      const next = yield* advance(cache, document);
      if (Option.isNone(next)) {
        break;
      }
      restarts += restartedListing(document, next.value) ? 1 : 0;
      yield* restartLimit(restarts);
      ({ cache, document } = yield* commitOver(cache, document, next.value));
      // Committed Inbox pages make recent bodies eligible after Initial Mailbox Availability.
      yield* schedulePrefetch;
    }
    if (document !== undefined) {
      ({ cache, document } = yield* refreshLabels(cache, document));
    }
    yield* finishSynchronization(cache, document);
  }).pipe(
    // The profile and Inbox listing always exist; their absence is a provider failure to retry.
    Effect.catchTags({
      GmailNotFound: (notFound) =>
        Effect.fail(
          new SyncFailure({
            kind: 'retry',
            cause: notFound,
            diagnostic: 'status 404',
          }),
        ),
      GmailInvalidPage: (invalidPage) =>
        Effect.fail(
          new SyncFailure({
            kind: 'retry',
            cause: invalidPage,
            diagnostic: 'status 400',
          }),
        ),
    }),
    // Another store instance committed first, or a foreground restore renewed the mailbox's native
    // generation; start again from the committed cache. Native mailbox access waits for the
    // registration change, and a purge or another mailbox keeps the forgotten mail hidden.
    Effect.retry({
      times: 2,
      while: (error) =>
        error instanceof SyncFailure &&
        (error.kind === 'conflict' || error.kind === 'invalidated'),
    }),
    Effect.catchTag('SyncFailure', recover),
  );

  // Opens the cache and synchronizes it; requests during a synchronization share one more.
  const load = () => {
    if (waiting !== null) {
      return waiting;
    }
    let started = false;
    const requestedFor = ownership;
    const run = runLogged(
      semaphore.withPermit(
        Effect.suspend(() => {
          started = true;
          waiting = null;
          if (requestedFor !== ownership) {
            return Effect.void;
          }
          forgotten = false;
          authenticationRejected = false;
          return queued.length === 0
            ? synchronize
            : persistence
                .withPermit(save)
                .pipe(
                  Effect.flatMap((saved) =>
                    saved ? synchronize : Effect.void,
                  ),
                );
        }),
      ),
    );
    // With a free permit, the synchronization has already started.
    if (!started) {
      waiting = run;
    }
    return run;
  };

  // Only the shown mailbox's blocked change, as the person saw it, can be retried or discarded.
  const resolvable = (
    cache: Cache,
    head: PendingAction,
    expectedId: string | undefined,
  ) =>
    head.id === expectedId &&
    shown !== undefined &&
    sameMailbox(shown.scope, cache) &&
    cache.availability === undefined;
  // Retry counts attempts afresh; Discard settles on Gmail's current labels.
  const resolved = Effect.fnUntraced(function* (
    resolution: 'retry' | 'discard',
    {
      cache,
      document,
      head,
    }: Readonly<{
      cache: Cache;
      document: MailboxDocument;
      head: PendingAction;
    }>,
  ) {
    if (resolution === 'retry') {
      return {
        ...document,
        pending: [
          { ...head, retryFrom: head.attempts?.length ?? 0 },
          ...(document.pending ?? []).slice(1),
        ],
      };
    }
    const observed = yield* readLabels(cache, head.message);
    return settleObserved(document, head, Option.getOrUndefined(observed));
  });

  const resolvePending = (
    resolution: 'retry' | 'discard',
    expectedId = shown?.document?.pending?.[0]?.id,
  ) => {
    const requestedFor = ownership;
    return runLogged(
      semaphore.withPermit(
        Effect.gen(function* () {
          if (forgotten || requestedFor !== ownership) {
            return false;
          }
          const cache = yield* storage(native.openMailbox);
          const document = Option.getOrUndefined(yield* documentOf(cache));
          const head = document?.pending?.[0];
          if (
            document === undefined ||
            head === undefined ||
            !resolvable(cache, head, expectedId)
          ) {
            return false;
          }
          const next = yield* resolved(resolution, { cache, document, head });
          const saved = yield* commitOver(cache, document, next);
          notice = undefined;
          yield* ready(saved.cache, saved.document, sync);
          return requestedFor === ownership && !forgotten;
        }).pipe(
          Effect.catchTags({
            GmailInvalidPage: () => Effect.succeed(false),
            SyncFailure: (error) => recover(error).pipe(Effect.as(false)),
          }),
        ),
      ),
    ).then((saved) => (saved ? load() : undefined));
  };

  return {
    getSnapshot: () => state,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    // Clears the mail held in memory when its account or mailbox leaves the open Inbox, with
    // changes requested there and not yet saved.
    forget: forgetOpenInbox,
    load,
    resolvePending,
    // Shows the change at once, saves it with the cache and sends it to Gmail in order. Without a
    // verified open mailbox nothing could be saved, so nothing changes.
    organize: (message: GmailMessage, action: GmailAction) => {
      if (
        forgotten ||
        shown === undefined ||
        !shown.organize ||
        !canOrganize(message)
      ) {
        return Promise.resolve();
      }
      const source = messageOwners.get(message);
      if (
        source === undefined ||
        source.ownership !== ownership ||
        !sameMailbox(source.scope, shown.scope)
      ) {
        return Promise.resolve();
      }
      const requestedFor = ownership;
      queued.push({ scope: shown.scope, pending: { action, message } });
      // Every outcome is announced; only a removal from the Inbox offers Undo.
      notice = { kind: 'done', action, message };
      publish(render());
      return runLogged(persistence.withPermit(save)).then((saved) =>
        saved && requestedFor === ownership ? load() : undefined,
      );
    },
    // The body of a listed message, once readMessage has asked for it.
    messageBody: (id: string, reader?: symbol) => {
      const body = bodies.get(id);
      if (reader === undefined) {
        return body;
      }
      if (viewReaders.get(reader) !== id) {
        return undefined;
      }
      return (
        viewBodies.get(reader) ?? (body?.kind === 'ready' ? loadingBody : body)
      );
    },
    // Visible readers keep their body while other windows open additional mail.
    retainMessage: (id: string, reader?: symbol) => {
      const retainedOwner = owner;
      endedReaders.delete(id);
      readers.set(id, (readers.get(id) ?? 0) + 1);
      if (reader === undefined) {
        legacyReaders.set(id, (legacyReaders.get(id) ?? 0) + 1);
      } else {
        viewReaders.set(reader, id);
      }
      const document = documents.get(id);
      if (document !== undefined && bodies.get(id)?.kind === 'ready') {
        if (reader === undefined) {
          setBody(id, {
            kind: 'ready',
            presentation: present(id, document, legacyReaders.get(id)),
          });
        } else {
          if (!legacyReaders.has(id)) {
            imageReservations.delete(id);
          }
          viewBodies.set(reader, {
            kind: 'ready',
            presentation: present(reader, document),
          });
          notify(state);
        }
      }
      return () => {
        if (owner !== retainedOwner) {
          return;
        }
        if (reader === undefined) {
          releaseLegacyReader(id);
        } else {
          viewReaders.delete(reader);
          viewBodies.delete(reader);
          imageReservations.delete(reader);
        }
        const count = (readers.get(id) ?? 1) - 1;
        if (count === 0) {
          readers.delete(id);
          // The presentation ended: its image budget returns, and a later open reads the cache.
          if (bodies.get(id)?.kind === 'loading' || readingBodies.has(id)) {
            endedReaders.add(id);
          } else {
            releaseBody(id);
          }
        } else {
          readers.set(id, count);
        }
      };
    },
    // Opens a body from this device, or downloads it from Gmail; a failed read can be tried again.
    // Windows opening the same message share one read.
    readMessage,
    // A failed rich view discards its document immediately and returns its image reservation.
    discardRichMessage: (
      id: string,
      expected: MessagePresentation,
      reader?: symbol,
    ) => {
      if (reader !== undefined) {
        const current = viewBodies.get(reader);
        if (
          viewReaders.get(reader) === id &&
          current?.kind === 'ready' &&
          current.presentation === expected
        ) {
          imageReservations.delete(reader);
          viewBodies.set(reader, {
            kind: 'ready',
            presentation: { readable: expected.readable },
          });
          notify(state);
        }
        return;
      }
      const current = bodies.get(id);
      if (current?.kind === 'ready' && current.presentation === expected) {
        imageReservations.delete(id);
        setBody(id, {
          kind: 'ready',
          presentation: { readable: expected.readable },
        });
      }
    },
  };
}

export type GmailInbox = ReturnType<typeof createGmailInbox>;

// Mail held in memory belongs to one open Inbox: its Product Account, Google account and address.
// It is forgotten as soon as registration reports another owner or no open Inbox, before the
// next account or mailbox can render it.
export function forgetMailOutsideInbox(
  registration: Pick<Registration, 'subscribe' | 'getSnapshot'>,
  inbox: Pick<GmailInbox, 'forget'>,
) {
  let owner: string | null = null;
  return registration.subscribe(() => {
    const { snapshot } = registration.getSnapshot();
    const next =
      canOpenInbox(snapshot) &&
      (snapshot.kind === 'connected' || snapshot.kind === 'cached')
        ? [
            snapshot.productAccountId,
            snapshot.providerSubject,
            snapshot.address,
          ].join('\n')
        : null;
    if (next !== owner) {
      owner = next;
      inbox.forget();
    }
  });
}

// What the Inbox says about synchronization while it keeps showing the cached messages.
export const gmailSyncCopy = {
  syncing: 'Checking Gmail…',
  current: undefined,
  authentication: 'Gmail needs your permission again to show new mail.',
  retry: 'Gmail could not be reached. Showing mail saved on this device.',
} as const;

// What the reader says when an opened message's body cannot be shown.
export const messageBodyCopy = {
  download:
    'This message is not saved on this device, and Gmail could not be reached to download it.',
  authentication: 'Gmail needs your permission again to download this message.',
  missing: 'This message is no longer in Gmail.',
  locked: 'Private storage is locked. Unlock your device and try again.',
  failed: 'This message could not be opened. Your saved mail has been kept.',
  empty: 'This message has no text.',
  images: 'Images in this message are not loaded.',
  confirmLink: 'Open this link in your browser?',
  cautionLink: 'Check this link before opening it:',
} as const;
