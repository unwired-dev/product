import * as Arr from 'effect/Array';
import * as DateTime from 'effect/DateTime';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Predicate from 'effect/Predicate';
import * as Random from 'effect/Random';
import * as Schedule from 'effect/Schedule';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { GmailAction, GmailLabel } from './gmail-actions.ts';
import type { Registration } from './registration.ts';

import {
  decodeDiagnostic,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';
import {
  GmailActionSchema,
  GmailLabelSchema,
  inInbox,
  relabel,
  restoreAfter,
} from './gmail-actions.ts';
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

// The latest organizing action, until the next one: a removal that can be undone, or a change
// Gmail refused.
export type OrganizeNotice = Readonly<{
  kind: 'done' | 'rejected';
  action: GmailAction;
  message: GmailMessage;
}>;

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

const entities = new Map([
  ['amp', '&'],
  ['lt', '<'],
  ['gt', '>'],
  ['quot', '"'],
  ['apos', "'"],
  ['nbsp', ' '],
]);

// Gmail snippets are HTML-escaped plain text.
const unescape = (text: string) =>
  text.replaceAll(/&#?[\da-z]{1,8};/giu, (whole) => {
    const body = whole.slice(1, -1).toLowerCase();
    let code = Number.NaN;
    if (/^#\d+$/u.test(body)) {
      code = Number(body.slice(1));
    } else if (/^#x[\da-f]+$/u.test(body)) {
      code = Number.parseInt(body.slice(2), 16);
    } else {
      return entities.get(body) ?? whole;
    }
    return code <= 1_114_111 ? String.fromCodePoint(code) : whole;
  });

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
  const byId = new Map(messages.map((message) => [message.id, message]));
  for (const { action, message } of pending) {
    const current =
      byId.get(message.id) ??
      (action.add.includes('INBOX') ? message : undefined);
    if (current !== undefined) {
      byId.set(
        message.id,
        withLabels(current, relabel(labelsOf(current), action)),
      );
    }
  }
  return Arr.sort(
    [...byId.values()].filter((message) => inInbox(labelsOf(message))),
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

export function createGmailInbox(native: NativeGmailMailbox) {
  // One Gmail read; a missing resource is GmailNotFound and other HTTP failures are classified.
  const gmail =
    (scope: MailboxScope) =>
    <A>(
      path: string,
      query: ReadonlyArray<readonly [string, string]>,
      decode: (body: unknown) => Effect.Effect<A, Schema.SchemaError>,
    ) =>
      Effect.gen(function* () {
        const value = yield* Effect.tryPromise({
          try: () => native.gmailRequest(path, query, scope),
          catch: (cause) => rejected(cause, 'retry'),
        });
        const { status, body } = yield* decodeResponse(value).pipe(
          Effect.mapError((error) => malformed(error, 'retry')),
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
            preview: unescape(message.snippet ?? ''),
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
  let state: GmailInboxState = { kind: 'loading' };
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
  const render = (): GmailInboxState => {
    const document = shown?.document;
    const durable = document?.pending ?? [];
    const [head] = durable;
    const pending = [...durable, ...queued.map((item) => item.pending)];
    const messages = organized(document?.messages ?? [], pending);
    if (shown !== undefined) {
      for (const message of messages) {
        messageOwners.set(message, { ownership, scope: shown.scope });
      }
    }
    return {
      kind: 'ready',
      ...(shown === undefined ? {} : { address: shown.scope.address }),
      messages,
      sync,
      labels: document?.labels ?? [],
      pending: durable.length,
      saving: queued.length,
      blocked: head !== undefined && attemptCount(head) >= 5,
      ...(head !== undefined && attemptCount(head) >= 5
        ? { blockedAction: head }
        : {}),
      organize: shown?.organize ?? false,
      ...(notice === undefined ? {} : { notice }),
    };
  };
  const publish = (next: GmailInboxState) => {
    if (!forgotten) {
      notify(next);
    }
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
      sync = next;
      publish(render());
    });

  // Authentication and retry keep the shown mail; locked or unreadable storage hides it.
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
            ownership += 1;
            shown = undefined;
            queued.length = 0;
            notice = undefined;
          }
          if (kind === 'authentication' || kind === 'retry') {
            sync = kind;
            publish(render());
          } else {
            publish({ kind: kind === 'locked' ? 'locked' : 'failed' });
          }
        }),
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
    return yield* storage(() =>
      native.commitMailbox({ address, generation }, revision, text),
    );
  });

  // Intake uses its own permit: a blocked Gmail read must not delay recording intent. Native
  // compare-and-swap fences concurrent sync commits; each intake ID also reconciles a lost commit
  // reply without appending the same intent twice.
  const save = Effect.suspend(() => {
    const startedFor = ownership;
    return Effect.gen(function* () {
      const cache = yield* storage(native.openMailbox);
      const document = Option.getOrUndefined(yield* documentOf(cache));
      if (
        forgotten ||
        startedFor !== ownership ||
        cache.availability !== undefined
      ) {
        return false;
      }
      const taken = [...queued];
      const owned = taken.filter(({ scope }) => sameMailbox(scope, cache));
      if (owned.length === 0) {
        for (const item of taken) {
          const index = queued.indexOf(item);
          if (index !== -1) {
            queued.splice(index, 1);
          }
        }
        return true;
      }
      if (document === undefined) {
        return yield* new SyncFailure({
          kind: 'failed',
          cause: 'missing cache',
          diagnostic: 'missing cache',
        });
      }
      for (const item of owned) {
        if (item.pending.id === undefined) {
          item.pending = {
            ...item.pending,
            id: `${yield* Random.nextInt}:${yield* Random.nextInt}`,
          };
        }
      }
      const pending = document.pending ?? [];
      const next: MailboxDocument = {
        ...document,
        pending: [
          ...pending,
          ...owned
            .map((item) => item.pending)
            .filter(
              (item) =>
                !pending.some(({ id }) => id !== undefined && id === item.id),
            ),
        ],
      };
      const saved = yield* commit(cache, next);
      // forget() may have removed these while the commit suspended. Do not remove newer intents.
      for (const item of taken) {
        const index = queued.indexOf(item);
        if (index !== -1) {
          queued.splice(index, 1);
        }
      }
      if (!forgotten && startedFor === ownership) {
        yield* ready(saved, next, sync);
      }
      return !forgotten && startedFor === ownership;
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
    const value = yield* Effect.tryPromise({
      try: () =>
        native.gmailModify(
          { message: message.id, add: action.add, remove: action.remove },
          scope,
        ),
      catch: (cause) => rejected(cause, 'retry'),
    });
    const { status, body } = yield* decodeResponse(value).pipe(
      Effect.mapError((error) => malformed(error, 'retry')),
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

  const settleObserved = (
    document: MailboxDocument,
    head: PendingAction,
    labels: readonly string[] | undefined,
  ): MailboxDocument =>
    labels === undefined
      ? {
          ...settled(document, undefined),
          messages: document.messages.filter(
            ({ id }) => id !== head.message.id,
          ),
        }
      : settled(document, labels);

  const dispatch = Effect.fnUntraced(function* (
    current: { readonly cache: Cache; readonly document: MailboxDocument },
    head: PendingAction,
  ) {
    const count = attemptCount(head);
    if (count > 0) {
      yield* Effect.void.pipe(
        Effect.schedule(
          Schedule.max([
            Schedule.spaced(`${100 * 2 ** (count - 1)} millis`).pipe(
              Schedule.jittered,
            ),
            Schedule.recurs(1),
          ]),
        ),
      );
    }
    const attempted = {
      ...head,
      attempts: [
        ...(head.attempts ?? []),
        {
          id: `${head.id ?? head.message.id}:${head.attempts?.length ?? 0}`,
          at: DateTime.toEpochMillis(yield* DateTime.now),
        },
      ],
    };
    const preparing = {
      ...current.document,
      pending: [attempted, ...(current.document.pending ?? []).slice(1)],
    };
    const prepared = yield* commit(current.cache, preparing);
    yield* ready(prepared, preparing, sync);
    const outcome = yield* modify(prepared, attempted);
    let next = settled(preparing, Option.getOrUndefined(outcome));
    if (Option.isNone(outcome)) {
      // Refusal is not authoritative metadata: keep intent until current labels are read.
      next = settleObserved(
        preparing,
        attempted,
        Option.getOrUndefined(yield* readLabels(prepared, head.message)),
      );
      notice = { kind: 'rejected', ...head };
    }
    const cache = yield* commit(prepared, next);
    yield* ready(cache, next, sync);
    return { cache, document: next };
  });

  // Sends saved changes in order. Reconcile unanswered writes before another dispatch.
  const sendPending = Effect.fnUntraced(function* (
    initial: Cache,
    document: MailboxDocument,
  ) {
    let current = { cache: initial, document };
    let [head] = current.document.pending ?? [];
    while (head !== undefined) {
      let reconciled = false;
      if ((head.attempts?.length ?? 0) > 0) {
        const observed = yield* readLabels(current.cache, head.message);
        if (
          Option.isNone(observed) ||
          requestedLabels(observed.value, head.action)
        ) {
          const next = settleObserved(
            current.document,
            head,
            Option.getOrUndefined(observed),
          );
          if (Option.isNone(observed)) {
            notice = { kind: 'rejected', ...head };
          }
          const cache = yield* commit(current.cache, next);
          yield* ready(cache, next, sync);
          current = { cache, document: next };
          reconciled = true;
        }
      }
      if (!reconciled) {
        if (attemptCount(head) >= 5) {
          return current;
        }
        current = yield* dispatch(current, head);
      }
      [head] = current.document.pending ?? [];
    }
    return current;
  });

  // The mailbox's own labels, listed once per synchronization.
  const refreshLabels = Effect.fnUntraced(function* (
    cache: Cache,
    document: MailboxDocument,
  ) {
    const listed = yield* gmail(cache)('labels', [], decodeLabels);
    const labels = Arr.sort(
      (listed.labels ?? [])
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
      return;
    }
    const next = { ...document, labels };
    yield* ready(yield* commit(cache, next), next, sync);
  });

  const synchronize = Effect.gen(function* () {
    let cache = yield* storage(native.openMailbox);
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
      cache = yield* commit(cache, next.value);
      document = next.value;
      yield* ready(cache, document, 'syncing');
    }
    if (document !== undefined) {
      yield* refreshLabels(cache, document);
    }
    sync = 'current';
    publish(render());
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
            head.id !== expectedId ||
            shown === undefined ||
            !sameMailbox(shown.scope, cache) ||
            cache.availability !== undefined
          ) {
            return false;
          }
          let next: MailboxDocument = document;
          if (resolution === 'retry') {
            next = {
              ...document,
              pending: [
                { ...head, retryFrom: head.attempts?.length ?? 0 },
                ...(document.pending ?? []).slice(1),
              ],
            };
          } else {
            const observed = yield* readLabels(cache, head.message);
            next = Option.isSome(observed)
              ? settled(document, observed.value)
              : {
                  ...settled(document, undefined),
                  messages: document.messages.filter(
                    ({ id }) => id !== head.message.id,
                  ),
                };
          }
          const saved = yield* commit(cache, next);
          notice = undefined;
          yield* ready(saved, next, sync);
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
    forget: () => {
      ownership += 1;
      queued.length = 0;
      shown = undefined;
      notice = undefined;
      if (!forgotten || state.kind !== 'loading') {
        forgotten = true;
        notify({ kind: 'loading' });
      }
    },
    load,
    resolvePending,
    // Shows the change at once, saves it with the cache and sends it to Gmail in order. Without a
    // verified open mailbox nothing could be saved, so nothing changes.
    organize: (message: GmailMessage, action: GmailAction) => {
      if (forgotten || shown === undefined || !shown.organize) {
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
      notice =
        restoreAfter(action) === undefined
          ? undefined
          : { kind: 'done', action, message };
      publish(render());
      return runLogged(persistence.withPermit(save)).then((saved) =>
        saved && requestedFor === ownership ? load() : undefined,
      );
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
