import * as Effect from 'effect/Effect';
import * as Base64 from 'effect/encoding/Base64';
import * as Option from 'effect/Option';
import * as Result from 'effect/Result';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { NativeGmailMailbox } from './gmail-inbox.ts';
import type { ImapDocument, ImapFolder, ImapMessage } from './imap-model.ts';
import type {
  BodyDocument,
  GmailPart,
  MessagePresentation,
} from './message-body.ts';

import {
  decodeDiagnostic,
  rejectionCode,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';
import { createBodyLoads } from './gmail-inbox.ts';
import { sanitizeHtml } from './html-sanitizer.ts';
import {
  applyFolderRead,
  cachedFolders,
  decodeBodyCommit,
  decodeCache,
  decodeCommit,
  decodeDocument,
  decodeFolderRead,
  decodeFolders,
  decodeRaw,
  encodeDocument,
  inboxFolder,
  window,
} from './imap-model.ts';
import { inlineImageLimits } from './inline-images.ts';
import {
  bodyParts,
  contentIdsOf,
  decodeBodyDocument,
  decodeCachedBody,
  encodeBodyDocument,
  imageTally,
  inlineImageParts,
  partText,
  presentation,
  receivedAttachments,
} from './message-body.ts';
import { parseMime } from './mime.ts';

export { applyFolderRead, inboxFolder } from './imap-model.ts';
export type { ImapFolder, ImapMessage } from './imap-model.ts';

// The native Registration module's IMAP operations for one Standards-Based Mailbox Connection.
// Native code logs in with the connection's password and keeps the cache encrypted; this module
// chooses what to read and owns the cached document. Messages are read without setting \Seen.
export interface NativeImapMailbox
  // The connection's encrypted cache, as for Gmail.
  extends Pick<
    NativeGmailMailbox,
    | 'openMailbox'
    | 'commitMailbox'
    | 'openMessageBody'
    | 'commitMessageBody'
    | 'listMessageBodies'
  > {
  // Resolves `{ folders: [{ name, roles, selectable }] }`.
  readonly imapFolders: (
    mailbox: Readonly<{ address: string; generation: string }>,
  ) => Promise<unknown>;
  // Resolves the folder's `{ uidValidity, uidNext, reset, messages, flags }` since `from`.
  readonly imapSynchronize: (
    mailbox: Readonly<{ address: string; generation: string }>,
    request: Readonly<{
      folder: string;
      window: number;
      from?: Readonly<{
        uidValidity: number;
        uidNext: number;
        known: readonly number[];
      }>;
    }>,
  ) => Promise<unknown>;
  // Resolves `{ data }`, the raw message as standard base64; rejects with `imap-changed` when the
  // folder's UIDVALIDITY no longer matches.
  readonly imapMessage: (
    mailbox: Readonly<{ address: string; generation: string }>,
    message: Readonly<{ folder: string; uidValidity: number; uid: number }>,
  ) => Promise<unknown>;
}

// 'authentication' needs the password again; 'retry' may succeed on a later synchronization.
type Sync = 'syncing' | 'current' | 'authentication' | 'retry';

export type ImapFolderView =
  | { readonly kind: 'loading' | 'failed' }
  | {
      readonly kind: 'ready';
      readonly messages: readonly ImapMessage[];
      readonly status: Sync;
    };

export type ImapInboxState =
  | { readonly kind: 'loading' | 'locked' | 'failed' }
  | {
      readonly kind: 'ready';
      readonly address: string;
      // The Inbox folder's messages, newest first.
      readonly messages: readonly ImapMessage[];
      readonly status: Sync;
      readonly folders: readonly ImapFolder[];
      // A Standards-Based Mailbox Connection sends nothing until SMTP is authorized.
      readonly receiveOnly: true;
    };

/**
 * Retires unavailable folder choices after a ready listing, preserving them
 * while it is unresolved.
 *
 * @example
 *   imapFolderName(undefined, 'Archive'); // 'Archive'
 *
 * @param {ImapInboxState | undefined} state The subscribed Inbox state, or no
 *   IMAP connection.
 * @param {string} requested The folder this window chose.
 * @returns {string} The admitted folder name, or Inbox when the listing rejects
 *   it.
 */
export const imapFolderName = (
  state: ImapInboxState | undefined,
  requested: string,
) =>
  state?.kind === 'ready' &&
  !state.folders.some(
    ({ name, selectable }) => selectable && name === requested,
  )
    ? inboxFolder
    : requested;

/**
 * Reports refresh failure even when cached rows remain readable.
 *
 * @example
 *   imapFolderFailed({ kind: 'ready', messages: [], status: 'retry' }); // true
 *
 * @param {ImapFolderView | undefined} view The subscribed view of the chosen
 *   folder.
 * @returns {boolean} Whether the folder needs a synchronization failure notice.
 */
export const imapFolderFailed = (view: ImapFolderView | undefined) =>
  view?.kind === 'failed' ||
  (view?.kind === 'ready' &&
    (view.status === 'retry' || view.status === 'authentication'));

export type ImapBodyState =
  | { readonly kind: 'loading' }
  | {
      readonly kind: 'ready';
      readonly presentation: MessagePresentation;
      // Received attachments this reader cannot open yet.
      readonly attachments: number;
    }
  | {
      readonly kind: 'unavailable';
      readonly reason:
        | 'imap-download'
        | 'imap-authentication'
        | 'imap-missing'
        | 'too-large'
        | 'locked'
        | 'failed';
    };

class ImapFailure extends Schema.TaggedError<ImapFailure>()('ImapFailure', {
  kind: Schema.Literals([
    'authentication',
    'retry',
    'locked',
    'conflict',
    'invalidated',
    'revoked',
    'changed',
    'missing',
    'too-large',
    'failed',
  ]),
  cause: Schema.Defect(),
  // Logged instead of the cause; see rejectionDiagnostic.
  diagnostic: Schema.String,
}) {}

const failureKinds: Readonly<Record<string, ImapFailure['kind']>> = {
  'gmail-unavailable': 'authentication',
  'imap-refused': 'authentication',
  locked: 'locked',
  conflict: 'conflict',
  'mailbox-invalidated': 'invalidated',
  'mailbox-revoked': 'revoked',
  'imap-changed': 'changed',
  'imap-missing': 'missing',
  'too-large': 'too-large',
  'imap-insecure': 'retry',
  offline: 'retry',
  unavailable: 'retry',
};

const call = (operation: () => Promise<unknown>) =>
  Effect.tryPromise({
    try: operation,
    catch: (cause) => {
      const code = rejectionCode(cause);
      return new ImapFailure({
        kind:
          code !== undefined && Object.hasOwn(failureKinds, code)
            ? (failureKinds[code] ?? 'failed')
            : 'failed',
        cause,
        diagnostic: rejectionDiagnostic(cause),
      });
    },
  });
const decodeStoredBodies = Schema.decodeUnknownEffect(
  Schema.Struct({
    stored: Schema.Array(Schema.String),
    excluded: Schema.Array(Schema.String),
  }),
);

const malformed = (error: Schema.SchemaError) =>
  new ImapFailure({
    kind: 'failed',
    cause: error,
    diagnostic: decodeDiagnostic(error),
  });

type Scope = Readonly<{
  address: string;
  generation: string;
  lifetime: number;
}>;

type Failure = Readonly<Pick<ImapFailure, 'kind' | 'diagnostic'>>;

// Refused or transient server access, which the Inbox states rather than logs.
const expected = (kind: ImapFailure['kind']) =>
  kind === 'authentication' || kind === 'retry';
const closesAccess = (kind: ImapFailure['kind']) =>
  kind === 'locked' || kind === 'revoked' || kind === 'invalidated';
const changesAccess = (kind: ImapFailure['kind']) =>
  closesAccess(kind) || kind === 'authentication';
const statusOf = (kind: ImapFailure['kind']): Sync =>
  kind === 'authentication' ? 'authentication' : 'retry';

// Why a body could not be shown, as the reader explains it.
const bodyFailures: Partial<
  Record<
    ImapFailure['kind'],
    Extract<ImapBodyState, { kind: 'unavailable' }>['reason']
  >
> = {
  authentication: 'imap-authentication',
  changed: 'imap-missing',
  missing: 'imap-missing',
  'too-large': 'too-large',
  locked: 'locked',
  retry: 'imap-download',
};
const unavailable = ({ kind }: Failure): ImapBodyState => ({
  kind: 'unavailable',
  reason: bodyFailures[kind] ?? 'failed',
});

// A readable part's text in its declared charset.
const textOf = (part: GmailPart) =>
  partText(part, part.body?.data ?? '').pipe(
    Effect.mapError(
      (cause) =>
        new ImapFailure({
          kind: 'failed',
          cause,
          diagnostic: 'invalid body encoding',
        }),
    ),
  );

// The body the reader presents: the readable alternatives, received attachments' metadata, and the
// inline images the HTML names within the per-message bounds. Remote content is never fetched.
const bodyDocument = Effect.fnUntraced(function* (
  id: string,
  payload: GmailPart,
) {
  const { html, text, path } = bodyParts(payload);
  const body: BodyDocument = {
    version: 2,
    id,
    attachments: receivedAttachments(payload).map(
      ({ locator, name, mimeType, size }) => ({
        locator,
        name,
        mimeType,
        size,
      }),
    ),
    ...(text === undefined ? {} : { text: yield* textOf(text) }),
    ...(html === undefined ? {} : { html: yield* textOf(html) }),
  };
  const parts = inlineImageParts(path);
  const tally = imageTally();
  for (const [index, contentId] of contentIdsOf(body).entries()) {
    const part = parts.get(contentId);
    if (part === undefined || !tally.request(part, index)) {
      tally.refuse(contentId);
    } else {
      tally.receive(contentId, part, part.body?.data);
    }
  }
  return { ...body, images: tally.result().images };
});

// One IMAP connection's Inbox, its folder list and the folders a reader opened, from the encrypted
// cache first and then from the server. Messages are addressed by folder, UIDVALIDITY and UID.
export function createImapInbox(
  native: NativeImapMailbox,
  {
    removed,
    shared = createBodyLoads(),
  }: Readonly<{
    // Called after native code purged this device because another device removed it.
    removed?: (() => void) | undefined;
    shared?: Readonly<ReturnType<typeof createBodyLoads>>;
  }> = {},
) {
  const semaphore = Semaphore.makeUnsafe(1);
  const listeners = new Set<() => void>();
  let state: ImapInboxState = { kind: 'loading' };
  let opened: (Scope & { revision: number }) | undefined = undefined;
  let document: ImapDocument | undefined = undefined;
  let forgotten = false;
  let lifetime = 0;
  const closedFolder = { kind: 'failed' } as const;
  // Folder snapshots read before any view is recorded stay the same object across reads, as
  // React's external stores require; a cached listing keeps its view while its messages do.
  const loadingFolder = { kind: 'loading' } as const;
  const cachedViews = new WeakMap<readonly ImapMessage[], ImapFolderView>();
  // Folder views per name, and the bodies opened in this process by message ID.
  const folderViews = new Map<string, ImapFolderView>();
  const bodies = new Map<string, ImapBodyState>();
  const documents = new Map<string, BodyDocument>();
  const readers = new Map<string, number>();
  const legacyReaders = new Map<string, number>();
  const viewReaders = new Map<symbol, string>();
  const viewBodies = new Map<symbol, ImapBodyState>();
  const imageOwner = Symbol('IMAP images');
  const reservations = new Map<
    string | symbol,
    { bytes: number; pixels: number }
  >();
  const reading = new Map<string, Promise<void>>();

  const notify = () => {
    for (const listener of listeners) {
      listener();
    }
  };
  const cacheOf = (name: string) =>
    document?.mailboxes.find((entry) => entry.name === name)?.cache;
  const otherImageUsage = (key: string | symbol) => {
    let bytes = 0;
    let pixels = 0;
    for (const ledger of shared.images.values()) {
      for (const [other, reserved] of ledger) {
        if (ledger !== reservations || other !== key) {
          bytes += reserved.bytes;
          pixels += reserved.pixels;
        }
      }
    }
    return { bytes, pixels };
  };
  // Gmail and IMAP readers share one budget; every visible occurrence and window counts.
  const present = (
    key: string | symbol,
    body: BodyDocument,
    count = 1,
  ): ImapBodyState => {
    let { bytes, pixels } = otherImageUsage(key);
    let occurrences: readonly string[] = [];
    try {
      occurrences = sanitizeHtml(body.html ?? '').contentIdOccurrences;
    } catch {
      // Presentation retains the readable fallback when sanitization fails.
    }
    let reservedBytes = 0;
    let reservedPixels = 0;
    const images = (body.images?.admitted ?? []).filter((image) => {
      const copies =
        count * occurrences.filter((id) => id === image.contentId).length;
      const size =
        Math.floor((image.data.replace(/=+$/u, '').length * 3) / 4) * copies;
      const area = image.width * image.height * copies;
      if (
        bytes + size > inlineImageLimits.aggregateBytes ||
        pixels + area > inlineImageLimits.aggregatePixels
      ) {
        return false;
      }
      bytes += size;
      pixels += area;
      reservedBytes += size;
      reservedPixels += area;
      return true;
    });
    reservations.set(key, { bytes: reservedBytes, pixels: reservedPixels });
    shared.images.set(imageOwner, reservations);
    return {
      kind: 'ready',
      presentation: presentation(body, images),
      attachments: body.attachments?.length ?? 0,
    };
  };
  const render = (status: Sync) => {
    if (forgotten || opened === undefined || document === undefined) {
      return;
    }
    state = {
      kind: 'ready',
      address: opened.address,
      messages: cacheOf(inboxFolder)?.messages ?? [],
      status,
      folders: document.folders,
      receiveOnly: true,
    };
    notify();
  };
  // A folder never read shows loading, or failed once its first read fails.
  const showFolder = (name: string, status: Sync) => {
    if (forgotten) {
      return;
    }
    const cache = cacheOf(name);
    let view: ImapFolderView = {
      kind: 'ready',
      messages: cache?.messages ?? [],
      status,
    };
    if (cache === undefined && status === 'syncing') {
      view = { kind: 'loading' };
    } else if (cache === undefined && status !== 'current') {
      view = { kind: 'failed' };
    }
    folderViews.set(name, view);
    notify();
  };

  const open = Effect.gen(function* () {
    const cache = yield* decodeCache(yield* call(native.openMailbox)).pipe(
      Effect.mapError(malformed),
    );
    if (forgotten) {
      return;
    }
    // Only an absent cache starts a listing; preserve an unreadable document for later recovery.
    const stored: ImapDocument =
      cache.document === null
        ? { version: 1, folders: [], mailboxes: [] }
        : yield* decodeDocument(cache.document).pipe(
            Effect.mapError(malformed),
          );
    opened = {
      address: cache.address,
      generation: cache.generation,
      revision: cache.revision,
      lifetime,
    };
    document = stored;
    folderViews.clear();
    for (const { name, cache: folder } of stored.mailboxes) {
      folderViews.set(name, {
        kind: 'ready',
        messages: folder.messages,
        status: 'current',
      });
    }
    return cache.availability === undefined;
  });

  const commit = Effect.fnUntraced(function* (next: ImapDocument) {
    const scope = opened;
    if (scope === undefined || forgotten) {
      return yield* new ImapFailure({
        kind: 'invalidated',
        cause: 'closed',
        diagnostic: 'Inbox closed',
      });
    }
    const text = yield* encodeDocument(next).pipe(Effect.mapError(malformed));
    const reply = yield* decodeCommit(
      yield* call(() => native.commitMailbox(scope, scope.revision, text)),
    ).pipe(Effect.mapError(malformed));
    if (forgotten) {
      return;
    }
    opened = { ...scope, revision: reply.revision };
    document = next;
  });

  const synchronizeFolder = Effect.fnUntraced(function* (name: string) {
    const scope = opened;
    if (scope === undefined || document === undefined) {
      return;
    }
    const cached = cacheOf(name);
    const read = yield* decodeFolderRead(
      yield* call(() =>
        native.imapSynchronize(scope, {
          folder: name,
          window,
          ...(cached === undefined
            ? {}
            : {
                from: {
                  uidValidity: cached.uidValidity,
                  uidNext: cached.uidNext,
                  known: cached.messages.map(({ uid }) => uid),
                },
              }),
        }),
      ),
    ).pipe(Effect.mapError(malformed));
    if (forgotten || document === undefined) {
      return;
    }
    const current = document;
    const others = current.mailboxes.filter((entry) => entry.name !== name);
    const inbox = others.filter((entry) => entry.name === inboxFolder);
    const rest = others.filter((entry) => entry.name !== inboxFolder);
    const entry = { name, cache: applyFolderRead(name, cached, read) };
    yield* commit({
      ...current,
      mailboxes:
        name === inboxFolder
          ? [entry, ...rest]
          : [...inbox, entry, ...rest].slice(0, cachedFolders + 1),
    });
  });

  // A removed device purged its data; the account page, not the Inbox, explains it. Locked storage
  // and transient or refused server access are expected; anything else is logged.
  const loadFailed = ({ kind, diagnostic }: Failure) => {
    if (forgotten) {
      return Effect.void;
    }
    if (closesAccess(kind)) {
      lifetime += 1;
      opened = undefined;
      document = undefined;
      folderViews.clear();
      bodies.clear();
      documents.clear();
      viewBodies.clear();
      reservations.clear();
      shared.images.delete(imageOwner);
      state = { kind: kind === 'locked' ? 'locked' : 'failed' };
      notify();
      if (kind === 'revoked') {
        removed?.();
      }
      return Effect.void;
    }
    if (opened === undefined || document === undefined) {
      state = { kind: 'failed' };
      notify();
      return Effect.logError('IMAP Inbox could not open:', diagnostic);
    }
    render(statusOf(kind));
    return expected(kind)
      ? Effect.void
      : Effect.logError('IMAP synchronization failed:', diagnostic);
  };

  // Opens the cache, then reads the folder list and the Inbox. Each failure keeps what the cache
  // already shows; a conflicting commit from another window starts again from the cache once.
  const load = () =>
    runLogged(
      semaphore.withPermit(
        Effect.gen(function* () {
          if (forgotten) {
            return;
          }
          const verified = yield* open;
          render('syncing');
          if (!verified) {
            render('retry');
            return;
          }
          const scope = opened;
          if (scope !== undefined) {
            const folders = yield* decodeFolders(
              yield* call(() => native.imapFolders(scope)),
            ).pipe(Effect.mapError(malformed));
            if (document !== undefined) {
              yield* commit({ ...document, folders: folders.folders });
            }
          }
          yield* synchronizeFolder(inboxFolder);
          render('current');
        }).pipe(
          Effect.retry({
            times: 1,
            while: (failure) =>
              failure.kind === 'conflict' || failure.kind === 'invalidated',
          }),
          // oxlint-disable-next-line promise/prefer-await-to-then -- Effect's typed error channel.
          Effect.catch(loadFailed),
        ),
      ),
    );

  const folderFailed = (name: string) => (failure: Failure) => {
    const { kind, diagnostic } = failure;
    if (changesAccess(kind)) {
      return loadFailed(failure).pipe(
        Effect.andThen(
          Effect.sync(() => {
            if (kind === 'authentication') {
              showFolder(name, 'authentication');
            }
          }),
        ),
      );
    }
    showFolder(name, statusOf(kind));
    return expected(kind)
      ? Effect.void
      : Effect.logError('IMAP folder failed:', diagnostic);
  };

  // Reads another folder on demand; its view shows the cached messages first.
  const openFolder = (name: string) => {
    if (forgotten) {
      return Promise.resolve();
    }
    if (name === inboxFolder) {
      return load();
    }
    showFolder(name, 'syncing');
    return runLogged(
      semaphore.withPermit(
        Effect.gen(function* () {
          if (forgotten) {
            return;
          }
          if (opened === undefined) {
            yield* open;
          }
          yield* synchronizeFolder(name);
          showFolder(name, 'current');
          // oxlint-disable-next-line promise/prefer-await-to-then -- Effect's typed error channel.
        }).pipe(Effect.catch(folderFailed(name))),
      ),
    );
  };

  // Still the cache generation the caller read from; commits change only its revision.
  const current = (scope: Scope) =>
    !forgotten &&
    scope.lifetime === lifetime &&
    opened?.address === scope.address &&
    opened.generation === scope.generation;
  const listed = (id: string) =>
    document?.mailboxes.some(({ cache }) =>
      cache.messages.some((message) => message.id === id),
    ) === true;
  const messageOf = (id: string) =>
    document?.mailboxes
      .flatMap(({ cache }) => cache.messages)
      .find((message) => message.id === id);

  // The message's raw source from the server, as the body the reader presents.
  const bodyOf = Effect.fnUntraced(function* (message: ImapMessage) {
    const scope = opened;
    if (scope === undefined) {
      return yield* new ImapFailure({
        kind: 'retry',
        cause: 'closed',
        diagnostic: 'Inbox closed',
      });
    }
    const raw = yield* decodeRaw(
      yield* call(() =>
        native.imapMessage(scope, {
          folder: message.folder,
          uidValidity: message.uidValidity,
          uid: message.uid,
        }),
      ),
    ).pipe(Effect.mapError(malformed));
    const bytes = Base64.decode(raw.data);
    const payload = Result.isSuccess(bytes)
      ? parseMime(bytes.success)
      : undefined;
    if (payload === undefined) {
      return yield* new ImapFailure({
        kind: 'failed',
        cause: 'mime',
        diagnostic: 'unreadable message',
      });
    }
    return yield* bodyDocument(message.id, payload);
  });

  // Which of these cached messages have a body saved on this device, read without the server and
  // without touching what the cache keeps. A reply for an Inbox that closed or changed meanwhile
  // names none, and a failed read leaves the answer unknown.
  const savedBodies = (ids: readonly string[]) => {
    const scope = opened;
    const wanted = ids.filter(listed);
    if (scope === undefined || wanted.length === 0) {
      return Promise.resolve(new Set<string>());
    }
    return runLogged(
      call(() => native.listMessageBodies(scope, wanted)).pipe(
        Effect.flatMap((reply) =>
          decodeStoredBodies(reply).pipe(Effect.mapError(malformed)),
        ),
        Effect.map(({ stored, excluded }) => {
          const markers = new Set(excluded);
          return new Set(
            current(scope)
              ? stored.filter((id) => !markers.has(id) && listed(id))
              : [],
          );
        }),
        Effect.catchTag('ImapFailure', ({ kind, diagnostic }) =>
          expected(kind) || closesAccess(kind)
            ? Effect.void.pipe(Effect.as(undefined))
            : Effect.logError(
                'Saved IMAP bodies could not be listed:',
                diagnostic,
              ).pipe(Effect.as(undefined)),
        ),
      ),
    );
  };

  // Opens a body from this device, or downloads it; windows opening the same message share one read.
  const readMessage = (id: string) => {
    if (bodies.get(id)?.kind === 'ready') {
      return Promise.resolve();
    }
    const pending = reading.get(id);
    if (pending !== undefined) {
      return pending;
    }
    const message = messageOf(id);
    const scope = opened;
    if (message === undefined || scope === undefined) {
      return Promise.resolve();
    }
    if (bodies.get(id)?.kind !== 'ready') {
      bodies.set(id, { kind: 'loading' });
      notify();
    }
    const read = runLogged(
      Effect.gen(function* () {
        const cached = yield* decodeCachedBody(
          yield* call(() => native.openMessageBody(scope, id)),
        ).pipe(Effect.mapError(malformed));
        const saved = Option.fromNullishOr(cached.document).pipe(
          Option.flatMap(decodeBodyDocument),
          Option.filter((body) => body.id === id),
        );
        if (Option.isSome(saved)) {
          return saved.value;
        }
        const body = yield* bodyOf(message);
        // Bodies are stored only for listed messages of the open cache; a full cache keeps none.
        if (listed(id) && current(scope)) {
          const text = yield* encodeBodyDocument(body).pipe(
            Effect.mapError(malformed),
          );
          yield* call(() =>
            native.commitMessageBody(scope, id, {
              document: text,
              tier: 'opened',
              protectedIds: [...readers.keys()],
            }),
          ).pipe(
            Effect.flatMap((reply) =>
              decodeBodyCommit(reply).pipe(Effect.mapError(malformed)),
            ),
            Effect.flatMap(({ admitted }) =>
              admitted ? shared.cache.changed : Effect.void,
            ),
            Effect.catchIf(
              (failure) => !changesAccess(failure.kind),
              ({ kind, diagnostic }) =>
                expected(kind)
                  ? Effect.void
                  : Effect.logError(
                      'IMAP body cache write failed:',
                      diagnostic,
                    ),
            ),
          );
        }
        return body;
      }).pipe(
        Effect.tapError((failure) =>
          current(scope) && changesAccess(failure.kind)
            ? loadFailed(failure)
            : Effect.void,
        ),
        Effect.match({
          onFailure: unavailable,
          onSuccess: (body): ImapBodyState => {
            if (!readers.has(id) || !current(scope)) {
              return { kind: 'loading' };
            }
            documents.set(id, body);
            for (const [reader, shownId] of viewReaders) {
              if (shownId === id) {
                viewBodies.set(reader, present(reader, body));
              }
            }
            const count = legacyReaders.get(id) ?? 0;
            return count === 0
              ? {
                  kind: 'ready',
                  presentation: presentation(body, []),
                  attachments: body.attachments?.length ?? 0,
                }
              : present(id, body, count);
          },
        }),
        Effect.tap((shown) =>
          Effect.sync(() => {
            if (readers.has(id) && current(scope)) {
              bodies.set(id, shown);
              notify();
            }
          }),
        ),
        Effect.asVoid,
        Effect.ensuring(Effect.sync(() => reading.delete(id))),
      ),
    );
    reading.set(id, read);
    return read;
  };

  return {
    getSnapshot: () => state,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    load,
    openFolder,
    // A folder's messages as last read, cached ones first; the Inbox reads `messages`.
    folder: (name: string): ImapFolderView => {
      if (state.kind === 'locked' || state.kind === 'failed') {
        return closedFolder;
      }
      const recorded = folderViews.get(name);
      const messages = cacheOf(name)?.messages;
      if (recorded !== undefined || messages === undefined) {
        return recorded ?? loadingFolder;
      }
      const cached = cachedViews.get(messages) ?? {
        kind: 'ready',
        messages,
        status: 'current',
      };
      cachedViews.set(messages, cached);
      return cached;
    },
    // A cached message from any folder, for the reader.
    message: messageOf,
    savedBodies,
    readMessage,
    messageBody: (id: string, reader?: symbol) => {
      if (reader === undefined) {
        return bodies.get(id);
      }
      return viewReaders.get(reader) === id
        ? (viewBodies.get(reader) ?? bodies.get(id))
        : undefined;
    },
    // Visible readers keep their body; the last one to close releases it.
    retainMessage: (id: string, reader?: symbol) => {
      readers.set(id, (readers.get(id) ?? 0) + 1);
      if (reader === undefined) {
        legacyReaders.set(id, (legacyReaders.get(id) ?? 0) + 1);
      } else {
        viewReaders.set(reader, id);
      }
      const body = documents.get(id);
      if (body !== undefined && bodies.get(id)?.kind === 'ready') {
        if (reader === undefined) {
          bodies.set(id, present(id, body, legacyReaders.get(id)));
        } else {
          viewBodies.set(reader, present(reader, body));
        }
        notify();
      }
      return () => {
        if (forgotten) {
          return;
        }
        if (reader === undefined) {
          const count = legacyReaders.get(id) ?? 1;
          if (count === 1) {
            legacyReaders.delete(id);
            reservations.delete(id);
          } else {
            legacyReaders.set(id, count - 1);
            const reserved = reservations.get(id);
            if (reserved !== undefined) {
              reservations.set(id, {
                bytes: (reserved.bytes * (count - 1)) / count,
                pixels: (reserved.pixels * (count - 1)) / count,
              });
            }
          }
        } else {
          viewReaders.delete(reader);
          viewBodies.delete(reader);
          reservations.delete(reader);
        }
        const count = (readers.get(id) ?? 1) - 1;
        if (count === 0) {
          readers.delete(id);
          bodies.delete(id);
          documents.delete(id);
        } else {
          readers.set(id, count);
        }
      };
    },
    // A failed rich view falls back to the readable text.
    discardRichMessage: (
      id: string,
      failed: MessagePresentation,
      reader?: symbol,
    ) => {
      const shown =
        reader === undefined ? bodies.get(id) : viewBodies.get(reader);
      if (shown?.kind === 'ready' && shown.presentation === failed) {
        const next = {
          ...shown,
          presentation: { readable: failed.readable },
        };
        if (reader === undefined) {
          bodies.set(id, next);
        } else {
          viewBodies.set(reader, next);
        }
        reservations.delete(reader ?? id);
        notify();
      }
    },
    // Forgets the mail held in memory when the connection or its account leaves the Inbox.
    forget: () => {
      forgotten = true;
      opened = undefined;
      document = undefined;
      folderViews.clear();
      bodies.clear();
      documents.clear();
      readers.clear();
      legacyReaders.clear();
      viewReaders.clear();
      viewBodies.clear();
      reservations.clear();
      shared.images.delete(imageOwner);
      state = { kind: 'loading' };
      notify();
    },
  };
}

export type ImapInbox = ReturnType<typeof createImapInbox>;
