import * as Arr from 'effect/Array';
import * as DateTime from 'effect/DateTime';
import * as Deferred from 'effect/Deferred';
import * as Effect from 'effect/Effect';
import * as Latch from 'effect/Latch';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Predicate from 'effect/Predicate';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

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
// and keeps the cache encrypted; this module chooses the Gmail reads and owns the cached document.
export interface NativeGmailMailbox {
  // Resolves `{ status, body }` for a read of `gmail/v1/users/me/<path>`.
  readonly gmailRequest: (
    path: string,
    query: ReadonlyArray<readonly [string, string]>,
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
  // Removes cached bodies only if the named Inbox revision is still current.
  readonly retainMessageBodies: (
    mailbox: Readonly<{
      address: string;
      generation: string;
      revision: number;
    }>,
    ids: readonly string[],
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
});
export type GmailMessage = typeof GmailMessageSchema.Type;

// The checkpoint is committed with the messages it produced, so a restart repeats no step twice.
const MailboxDocumentSchema = Schema.Struct({
  version: Schema.Literal(1),
  messages: Schema.Array(GmailMessageSchema),
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
  document: Schema.NullOr(Schema.String),
  availability: Schema.optionalKey(Schema.Literal('retry')),
});
type Cache = typeof CacheSchema.Type;
type MailboxScope = Pick<Cache, 'address' | 'generation'>;
const decodeCache = Schema.decodeUnknownEffect(CacheSchema);

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

export type GmailInboxState =
  | { readonly kind: 'loading' | 'locked' | 'failed' }
  | {
      readonly kind: 'ready';
      // Absent when no Gmail mailbox is connected on this device.
      readonly address?: string;
      readonly messages: readonly GmailMessage[];
      readonly sync: 'syncing' | 'current' | 'authentication' | 'retry';
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

// Authentication and retry keep the shown mail; locked or unreadable storage hides it.
const failureState = (
  shown: GmailInboxState,
  kind: SyncFailure['kind'],
): GmailInboxState => {
  if (kind === 'authentication' || kind === 'retry') {
    return shown.kind === 'ready'
      ? { ...shown, sync: kind }
      : { kind: 'ready', messages: [], sync: kind };
  }
  return { kind: kind === 'locked' ? 'locked' : 'failed' };
};

// Within a history page, the last record is a valid start for the next one.
const nextHistoryId = (
  page: Readonly<{ nextPageToken?: string; historyId: string }>,
  records: ReadonlyArray<Readonly<{ id: string }>>,
) =>
  page.nextPageToken === undefined
    ? page.historyId
    : (records.at(-1)?.id ?? page.historyId);

const messagesOf = (document: MailboxDocument | undefined) =>
  document?.messages ?? [];

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
          return yield* new SyncFailure({
            kind:
              status === 401 ||
              (status === 403 && Option.isNone(rateLimited(body)))
                ? 'authentication'
                : 'retry',
            cause: status,
            diagnostic: `status ${status}`,
          });
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
        // Spam and Trash never count as Inbox mail, even when Gmail keeps the INBOX label.
        const received =
          labels.includes('INBOX') &&
          !labels.includes('SPAM') &&
          !labels.includes('TRASH')
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
  const startListing = Effect.fnUntraced(function* (
    scope: MailboxScope,
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
      return Option.some(yield* startListing(scope, document.messages));
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
      return Option.some(yield* startListing(scope, messages));
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
      return Option.some(yield* startListing(scope, updated));
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
      return startListing(scope, []).pipe(Effect.asSome);
    }
    const { checkpoint } = document;
    return checkpoint.kind === 'backfill'
      ? continueListing(scope, document, checkpoint)
      : applyHistory(scope, document, checkpoint);
  };

  const semaphore = Semaphore.makeUnsafe(1);
  // Orders body admission against a page's commit, pruning and publication only, so a body
  // save never waits for a whole synchronization.
  const publication = Semaphore.makeUnsafe(1);
  let state: GmailInboxState = { kind: 'loading' };
  // A synchronization queued behind the running one.
  let waiting: Promise<void> | null = null;
  // Set when the open Inbox closes, until the next synchronization starts; synchronizations run one
  // at a time, so this drops the late results of one started for the previous account.
  let forgotten = false;
  const listeners = new Set<() => void>();
  const notify = (next: GmailInboxState) => {
    state = next;
    for (const listener of listeners) {
      listener();
    }
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

  const ready = (
    address: string | undefined,
    messages: readonly GmailMessage[],
    sync: Extract<GmailInboxState, { kind: 'ready' }>['sync'],
  ) =>
    Effect.sync(() => {
      const listed = new Set(messages.map(({ id }) => id));
      for (const id of bodies.keys()) {
        if (!listed.has(id)) {
          releaseBody(id);
        }
      }
      publish(
        address === undefined
          ? { kind: 'ready', messages, sync }
          : { kind: 'ready', address, messages, sync },
      );
    });

  const recover = ({
    kind,
    diagnostic,
  }: Readonly<Pick<SyncFailure, 'kind' | 'diagnostic'>>) =>
    (kind === 'authentication' || kind === 'locked'
      ? Effect.void
      : Effect.logError('Gmail Inbox failed:', diagnostic)
    ).pipe(
      Effect.andThen(
        Effect.sync(() => {
          publish(failureState(state, kind));
        }),
      ),
    );

  // Bodies of messages that left the cached Inbox leave the device with them. A failed prune is
  // retried at the end of the next synchronization, even when it commits nothing.
  const retainBodies = (
    { address, generation, revision }: Cache,
    messages: readonly GmailMessage[],
  ) =>
    Effect.tryPromise({
      try: () =>
        native.retainMessageBodies(
          { address, generation, revision },
          messages.map(({ id }) => id),
        ),
      catch: (cause) => rejected(cause, 'failed'),
    }).pipe(
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
  // The recent working set of the latest selection; its stored bodies are protected from eviction.
  let selection: readonly string[] = [];
  let selectionReference: DateTime.Utc | undefined = undefined;
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
    const shown = (document.images?.admitted ?? []).filter((image) => {
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
    return presentation(document, shown);
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
      if (part === undefined || !tally.requestable(part, index)) {
        tally.refuse(contentId);
      } else {
        const data = yield* partData(scope, id, part).pipe(Effect.option);
        tally.receive(contentId, part, Option.getOrUndefined(data));
      }
    }
    return tally.result();
  });

  // An explicit open's body from Gmail: both readable alternatives and its inline images.
  const fetchBody = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
  ): Effect.fn.Return<BodyDocument, SyncFailure | GmailNotFound> {
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
      return { ...document, images: { admitted: [], refused: [] } };
    }
    const resolved = yield* resolveImages(scope, id, { path, references });
    return resolved.complete
      ? { ...document, images: resolved.images }
      : document;
  });

  // A cached body opened explicitly before its inline images were resolved resolves them now,
  // when Gmail answers; offline, it opens with placeholders.
  const completeImages = Effect.fnUntraced(function* (
    scope: MailboxScope,
    document: BodyDocument,
  ) {
    const references = contentIdsOf(document);
    if (document.images !== undefined || references.length === 0) {
      return { document, changed: false };
    }
    const payload = yield* fullMessage(scope, document.id, [
      ['format', 'full'],
    ]);
    const resolved = yield* resolveImages(scope, document.id, {
      path: bodyParts(payload).path,
      references,
    });
    return resolved.complete
      ? { document: { ...document, images: resolved.images }, changed: true }
      : { document, changed: false };
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
        publication.withPermit(
          Effect.suspend(() =>
            owner === reading && listed(document.id)
              ? Effect.tryPromise({
                  try: () =>
                    native.commitMessageBody(scope, document.id, {
                      document: text,
                      tier,
                      protectedIds: selection,
                    }),
                  catch: (cause) => rejected(cause, 'failed'),
                }).pipe(
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
    const tier = selection.includes(id) ? 'prefetched' : 'opened';
    if (Option.isSome(stored)) {
      const completed = yield* completeImages(scope, stored.value).pipe(
        Effect.orElseSucceed(() => ({
          document: stored.value,
          changed: false,
        })),
      );
      if (completed.changed) {
        yield* store(completed.document, { scope, tier, reading }).pipe(
          Effect.ignore,
        );
      }
      return completed.document;
    }
    const document = yield* fetchBody(scope, id);
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

  const readMessage = (id: string) => {
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
      current?.kind === 'ready'
    ) {
      return Promise.resolve();
    }
    const reading = owner;
    setBody(id, loadingBody);
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
          SyncFailure: ({ kind, diagnostic }) =>
            (kind === 'authentication' || kind === 'locked'
              ? Effect.void
              : Effect.logError('Message body failed:', diagnostic)
            ).pipe(Effect.as(bodyFailure(kind))),
        }),
        Effect.flatMap((next) =>
          Effect.sync(() => {
            if (owner === reading && listed(id)) {
              if (endedReaders.has(id)) {
                endedReaders.delete(id);
                releaseBody(id);
                notify(state);
              } else {
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
            publish(failureState(state, kind));
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

  const synchronize = Effect.gen(function* () {
    let cache = yield* storage(native.openMailbox);
    const { address, generation } = cache;
    selectionReference = yield* DateTime.now;
    if (!forgotten) {
      opened = { address, generation };
    }
    let document = Option.getOrUndefined(yield* documentOf(cache));
    if (cache.availability === 'retry') {
      return yield* ready(cache.address, messagesOf(document), 'retry');
    }
    yield* ready(cache.address, messagesOf(document), 'syncing');
    let restarts = 0;
    let next = yield* advance(cache, document);
    while (Option.isSome(next)) {
      restarts += restartedListing(document, next.value) ? 1 : 0;
      yield* restartLimit(restarts);
      const committed = next.value;
      cache = yield* publication.withPermit(
        commit(cache, committed).pipe(
          Effect.tap((stored) =>
            ready(stored.address, committed.messages, 'syncing'),
          ),
        ),
      );
      document = committed;
      // Committed Inbox pages make recent bodies eligible after Initial Mailbox Availability.
      yield* schedulePrefetch;
      next = yield* advance(cache, document);
    }
    const current = cache;
    yield* publication.withPermit(
      retainBodies(current, messagesOf(document)).pipe(
        Effect.andThen(ready(current.address, messagesOf(document), 'current')),
      ),
    );
    yield* schedulePrefetch;
    // Bodies Gmail could not provide before are read again now that it answers.
    yield* Effect.sync(() => {
      for (const [id, body] of bodies) {
        if (body.kind === 'unavailable' && body.reason !== 'missing') {
          void readMessage(id);
        }
      }
    });
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

  return {
    getSnapshot: () => state,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    // Clears the mail held in memory when its account or mailbox leaves the open Inbox.
    forget: () => {
      owner += 1;
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
    },
    // Opens the cache and synchronizes it; requests during a synchronization share one more.
    load: () => {
      if (waiting !== null) {
        return waiting;
      }
      let started = false;
      const run = runLogged(
        semaphore.withPermit(
          Effect.suspend(() => {
            started = true;
            waiting = null;
            forgotten = false;
            return synchronize;
          }),
        ),
      );
      // With a free permit, the synchronization has already started.
      if (!started) {
        waiting = run;
      }
      return run;
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
          if (bodies.get(id)?.kind === 'loading') {
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
