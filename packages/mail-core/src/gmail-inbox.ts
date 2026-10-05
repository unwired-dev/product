import * as Arr from 'effect/Array';
import * as DateTime from 'effect/DateTime';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Predicate from 'effect/Predicate';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import {
  decodeDiagnostic,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';

// The native Registration module's mailbox operations. Native code attaches the Gmail credential
// and keeps the cache encrypted; this module chooses the Gmail reads and owns the cached document.
export interface NativeGmailMailbox {
  // Resolves `{ status, body }` for a read of `gmail/v1/users/me/<path>`.
  readonly gmailRequest: (
    path: string,
    query: ReadonlyArray<readonly [string, string]>,
    address: string,
  ) => Promise<unknown>;
  // Resolves `{ revision, address, document }`; another mailbox's document reads as null.
  readonly openMailbox: () => Promise<unknown>;
  // Replaces the document read at `expectedRevision`, or rejects with `conflict`.
  readonly commitMailbox: (
    address: string,
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
  document: Schema.NullOr(Schema.String),
  availability: Schema.optionalKey(Schema.Literal('retry')),
});
type Cache = typeof CacheSchema.Type;
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
const decodeHistory = json(
  Schema.Struct({
    history: Schema.optionalKey(
      Schema.Array(
        Schema.Struct({
          id: HistoryId,
          messagesAdded: HistoryMessages,
          messagesDeleted: HistoryMessages,
          labelsAdded: HistoryMessages,
          labelsRemoved: HistoryMessages,
        }),
      ),
    ),
    nextPageToken: Schema.optionalKey(Schema.String),
    historyId: HistoryId,
  }),
);
const rateLimited = Schema.decodeUnknownOption(
  Schema.fromJsonString(
    Schema.Struct({
      error: Schema.Struct({
        errors: Schema.Array(
          Schema.Struct({
            reason: Schema.Literals([
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
    kind = 'failed';
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

export function createGmailInbox(native: NativeGmailMailbox) {
  // One Gmail read; a missing resource is GmailNotFound and other HTTP failures are classified.
  const gmail =
    (address: string) =>
    <A>(
      path: string,
      query: ReadonlyArray<readonly [string, string]>,
      decode: (body: unknown) => Effect.Effect<A, Schema.SchemaError>,
    ) =>
      Effect.gen(function* () {
        const value = yield* Effect.tryPromise({
          try: () => native.gmailRequest(path, query, address),
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

  const metadata = (address: string, id: string) =>
    gmail(address)(
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
        const received = labels.includes('INBOX')
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
          })),
        );
      }),
      // A message that left the Inbox or Gmail is removed from the cache.
      Effect.catchTag('GmailNotFound', () => Effect.succeedNone),
      Effect.map((message) => [id, Option.getOrUndefined(message)] as const),
    );
  const fetchAll = (address: string, ids: readonly string[]) =>
    Effect.forEach(ids, (id) => metadata(address, id), { concurrency: 4 });

  // A new listing starts from the current history ID, so changes during it are replayed after.
  const startListing = Effect.fnUntraced(function* (
    address: string,
    messages: readonly GmailMessage[],
  ): Effect.fn.Return<
    MailboxDocument,
    SyncFailure | GmailNotFound | GmailInvalidPage
  > {
    const profile = yield* gmail(address)('profile', [], decodeProfile);
    if (profile.emailAddress.toLowerCase() !== address.toLowerCase()) {
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

  // The next document to commit, or none when the cache is current.
  const advance = Effect.fnUntraced(function* (
    address: string,
    document: MailboxDocument | undefined,
  ): Effect.fn.Return<
    Option.Option<MailboxDocument>,
    SyncFailure | GmailNotFound | GmailInvalidPage
  > {
    if (document === undefined) {
      return Option.some(yield* startListing(address, []));
    }
    const { checkpoint, messages } = document;
    if (checkpoint.kind === 'backfill') {
      const page = yield* gmail(address)(
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
        return Option.some(yield* startListing(address, messages));
      }
      const ids = (page.value.messages ?? []).map(({ id }) => id);
      const found = yield* fetchAll(address, ids);
      const seen = Arr.dedupe([...checkpoint.seen, ...ids]);
      const merged = merge(messages, found);
      const listed = new Set(seen);
      const verified = merged.filter((message) => listed.has(message.id));
      if (
        page.value.nextPageToken !== undefined &&
        verified.length < cacheLimit
      ) {
        // Newly verified entries take priority over stale entries retained during a relisting.
        const retained = merged.filter((message) => !listed.has(message.id));
        return Option.some({
          ...document,
          messages: Arr.sort(
            [...verified, ...retained].slice(0, cacheLimit),
            newestFirst,
          ),
          checkpoint: {
            ...checkpoint,
            pageToken: page.value.nextPageToken,
            seen,
          },
        });
      }
      // Messages kept from before this listing that it never saw have left the Inbox.
      return Option.some({
        ...document,
        messages: merged
          .filter((message) => listed.has(message.id))
          .slice(0, cacheLimit),
        checkpoint: { kind: 'current', historyId: checkpoint.historyId },
      });
    }
    const history = yield* gmail(address)(
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
      return Option.some(yield* startListing(address, messages));
    }
    const records = history.value.history ?? [];
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
    // Within a page, the last record is a valid start for the next one.
    const historyId =
      history.value.nextPageToken === undefined
        ? history.value.historyId
        : (records.at(-1)?.id ?? history.value.historyId);
    if (records.length === 0 && historyId === checkpoint.historyId) {
      return Option.none();
    }
    const merged = merge(messages, yield* fetchAll(address, changed), deleted);
    const remaining = new Set(merged.map(({ id }) => id));
    const updated = merged.slice(0, cacheLimit);
    // History cannot name the unchanged older message that now fits after an entry leaves.
    if (
      messages.length === cacheLimit &&
      messages.some(({ id }) => !remaining.has(id))
    ) {
      return Option.some(yield* startListing(address, updated));
    }
    return Option.some({
      ...document,
      messages: updated,
      checkpoint: { kind: 'current', historyId },
    });
  });

  const semaphore = Semaphore.makeUnsafe(1);
  let state: GmailInboxState = { kind: 'loading' };
  // A synchronization queued behind the running one.
  let waiting: Promise<void> | null = null;
  const listeners = new Set<() => void>();
  const publish = (next: GmailInboxState) => {
    state = next;
    for (const listener of listeners) {
      listener();
    }
  };
  const ready = (
    address: string | undefined,
    messages: readonly GmailMessage[],
    sync: Extract<GmailInboxState, { kind: 'ready' }>['sync'],
  ) =>
    Effect.sync(() => {
      publish(
        address === undefined
          ? { kind: 'ready', messages, sync }
          : { kind: 'ready', address, messages, sync },
      );
    });

  const synchronize = Effect.gen(function* () {
    let cache = yield* storage(native.openMailbox);
    let document = Option.getOrUndefined(yield* documentOf(cache));
    if (cache.availability === 'retry') {
      return yield* ready(cache.address, document?.messages ?? [], 'retry');
    }
    yield* ready(cache.address, document?.messages ?? [], 'syncing');
    let restarts = 0;
    while (true) {
      const next = yield* advance(cache.address, document);
      if (Option.isNone(next)) {
        break;
      }
      if (
        document?.checkpoint.kind === 'backfill' &&
        document.checkpoint.pageToken !== undefined &&
        next.value.checkpoint.kind === 'backfill' &&
        next.value.checkpoint.pageToken === undefined
      ) {
        restarts += 1;
        if (restarts > 2) {
          return yield* new SyncFailure({
            kind: 'retry',
            cause: 400,
            diagnostic: 'rejected page token',
          });
        }
      }
      const text = yield* encodeDocument(next.value).pipe(
        Effect.mapError((error) => malformed(error, 'failed')),
      );
      const { address, revision } = cache;
      cache = yield* storage(() =>
        native.commitMailbox(address, revision, text),
      );
      document = next.value;
      yield* ready(cache.address, document.messages, 'syncing');
    }
    yield* ready(cache.address, document?.messages ?? [], 'current');
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
    // Another store instance committed first; start again from its document.
    Effect.retry({
      times: 2,
      while: (error) =>
        error instanceof SyncFailure && error.kind === 'conflict',
    }),
    Effect.catchTags({
      SyncFailure: (error) =>
        Effect.gen(function* () {
          if (error.kind !== 'authentication' && error.kind !== 'locked') {
            yield* Effect.logError('Gmail Inbox failed:', error.diagnostic);
          }
          const shown = state.kind === 'ready' ? state : undefined;
          if (error.kind === 'authentication' || error.kind === 'retry') {
            return yield* ready(
              shown?.address,
              shown?.messages ?? [],
              error.kind,
            );
          }
          // Locked or unreadable storage hides cached mail rather than showing it stale.
          publish({ kind: error.kind === 'locked' ? 'locked' : 'failed' });
        }),
    }),
  );

  return {
    getSnapshot: () => state,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
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
  };
}

export type GmailInbox = ReturnType<typeof createGmailInbox>;

// What the Inbox says about synchronization while it keeps showing the cached messages.
export const gmailSyncCopy = {
  syncing: 'Checking Gmail…',
  current: undefined,
  authentication: 'Gmail needs your permission again to show new mail.',
  retry: 'Gmail could not be reached. Showing mail saved on this device.',
} as const;
