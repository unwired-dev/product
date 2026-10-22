import * as Arr from 'effect/Array';
import * as DateTime from 'effect/DateTime';
import * as Deferred from 'effect/Deferred';
import * as Duration from 'effect/Duration';
import * as Effect from 'effect/Effect';
import * as Base64 from 'effect/encoding/Base64';
import * as Option from 'effect/Option';
import * as Pull from 'effect/Pull';
import * as Random from 'effect/Random';
import * as Result from 'effect/Result';
import * as Schedule from 'effect/Schedule';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { AttachmentFailure } from './attachment-downloads.ts';
import type { DeliveryProblem } from './draft-model.ts';
import type {
  NativeGmailMailbox,
  OutgoingSend,
  SendOutcome,
} from './gmail-inbox.ts';
import type {
  ImapAction,
  ImapCapabilities,
  ImapDocument,
  ImapFolder,
  ImapMessage,
  ImapPending,
} from './imap-model.ts';
import type {
  BodyDocument,
  GmailPart,
  MessagePresentation,
} from './message-body.ts';
import type { NativeRemoteContentCache } from './remote-content-loader.ts';

import {
  createAttachmentDownloads,
  sameAttachment,
} from './attachment-downloads.ts';
import {
  decodeDiagnostic,
  rejectionCode,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';
import {
  createBodyLoads,
  downloadFailure,
  sendRejection,
} from './gmail-inbox.ts';
import { sanitizeHtml } from './html-sanitizer.ts';
import { imapRoleFolder, searchedFolders } from './imap-actions.ts';
import {
  applyFolderRead,
  cachedFolders,
  decodeBodyCommit,
  decodeCache,
  decodeCommit,
  decodeDocument,
  decodeFolderRead,
  decodeFolders,
  decodeCount,
  decodeHeaders,
  decodeIdle,
  decodeModify,
  decodeRaw,
  decodeSearch,
  encodeDocument,
  inboxFolder,
  listedMessage,
  messageId,
  newestFirst,
  ofOtherGeneration,
  window,
} from './imap-model.ts';
import { inlineImageLimits } from './inline-images.ts';
import { SyncFailure } from './mailbox-read.ts';
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
  recentWorkingSet,
  singleReadablePart,
} from './message-body.ts';
import { parseMime } from './mime.ts';
import { withoutBcc } from './outgoing-message.ts';
import {
  createRemoteContentLoader,
  shownRemote,
} from './remote-content-loader.ts';

export { applyFolderRead, inboxFolder } from './imap-model.ts';
export type {
  ImapAction,
  ImapCapabilities,
  ImapFolder,
  ImapMessage,
} from './imap-model.ts';

// The native Registration module's IMAP operations for one Standards-Based Mailbox Connection.
// Native code logs in with the connection's password and keeps the cache encrypted; this module
// chooses what to read and owns the cached document. Messages are read without setting \Seen.
export interface NativeImapMailbox
  // The connection's encrypted cache, Authorized Remote Content Cache and Downloaded Attachments,
  // as for Gmail.
  extends
    Pick<
      NativeGmailMailbox,
      | 'openMailbox'
      | 'commitMailbox'
      | 'openMessageBody'
      | 'commitMessageBody'
      | 'listMessageBodies'
      | 'retainMessageBodies'
      | 'saveAttachment'
      | 'discardAttachment'
      | 'presentAttachment'
    >,
    NativeRemoteContentCache {
  // Resolves `{ folders: [{ name, roles, selectable, delimiter? }] }`.
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
  // Resolves `{ messages: [{ uid, headers: [{ name, value }] }] }`: the Content-Type and
  // Content-Disposition fields of each message still present, without reading any body. Rejects
  // with `imap-changed` when the folder's UIDVALIDITY no longer matches.
  readonly imapHeaders: (
    mailbox: Readonly<{ address: string; generation: string }>,
    request: Readonly<{
      folder: string;
      uidValidity: number;
      uids: readonly number[];
    }>,
  ) => Promise<unknown>;
  // Marks the message read or unread, or moves it to `destination`. Resolves `{ outcome }`:
  // `stored`, `moved` with the new `uidValidity` and `uid` when the server reported them, or
  // `absent` when the folder no longer holds the UID. Rejects with `imap-changed` for another
  // UIDVALIDITY, `imap-rejected` when the server refuses the change, and `imap-unsupported`
  // without MOVE or UIDPLUS.
  readonly imapModify: (
    mailbox: Readonly<{ address: string; generation: string }>,
    change: Readonly<{
      folder: string;
      uidValidity: number;
      uid: number;
      read?: boolean;
      destination?: string;
      copied?: Readonly<{ uidValidity: number; uid: number }>;
    }>,
  ) => Promise<unknown>;
  // Resolves `{ folders: [{ folder, uidValidity, messages }], skipped }`: each folder's newest
  // matches, in the order asked.
  readonly imapSearch: (
    mailbox: Readonly<{ address: string; generation: string }>,
    request: Readonly<{ query: string; folders: readonly string[] }>,
  ) => Promise<unknown>;
  // Resolves `{ changed }` once the server reports a change in the folder or `seconds` pass;
  // rejects with `imap-unsupported` without IDLE.
  readonly imapIdle: (
    mailbox: Readonly<{ address: string; generation: string }>,
    request: Readonly<{ folder: string; seconds: number }>,
  ) => Promise<unknown>;
  // Submits the message as given through the connection's SMTP server to `recipients`. Resolves
  // once SMTP accepted it; rejects with `delivery-unknown` when it may have.
  readonly imapSend: (
    message: Readonly<{
      segments: OutgoingSend['segments'];
      recipients: readonly string[];
    }>,
    mailbox: Readonly<{ address: string; generation: string }>,
  ) => Promise<unknown>;
  // Appends the message to the Sent `folder` unless a copy with its MIME `boundary` is there.
  readonly imapFileSent: (
    mailbox: Readonly<{ address: string; generation: string }>,
    request: Readonly<{
      folder: string;
      boundary: string;
      segments: OutgoingSend['segments'];
    }>,
  ) => Promise<unknown>;
  // Resolves `{ count }`, the messages in the Sent `folder` carrying the MIME `boundary`.
  readonly imapFindSent: (
    mailbox: Readonly<{ address: string; generation: string }>,
    request: Readonly<{ folder: string; boundary: string }>,
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

// The latest organizing outcome: shown at once, or refused by the server.
export type ImapNotice = Readonly<{
  kind: 'done' | 'rejected' | 'blocked';
  action: ImapAction;
  message: Readonly<{ subject: string }>;
}>;

export type ImapInboxState =
  | { readonly kind: 'loading' | 'locked' | 'failed' }
  | {
      readonly kind: 'ready';
      readonly address: string;
      // The Inbox folder's messages, newest first, with changes not yet applied by the server.
      readonly messages: readonly ImapMessage[];
      readonly status: Sync;
      readonly folders: readonly ImapFolder[];
      // What the server advertised at its last listing; unknown before one was read.
      readonly capabilities: ImapCapabilities | undefined;
      // Changes saved on this device that the server has not applied yet.
      readonly pending: number;
      readonly blocked: string | undefined;
      readonly notice?: ImapNotice;
      // Whether Undo can still reverse the notice's move.
      readonly undo: boolean;
      // Marks an IMAP Inbox among other providers'.
      readonly imap: true;
    };

// One online search of this connection: each searched folder's newest matches, and whether some
// folders or older matches were left out.
export type ImapSearchPage =
  | Readonly<{
      kind: 'found';
      messages: readonly ImapMessage[];
      limited: boolean;
    }>
  | Readonly<{
      kind: 'unavailable';
      reason: 'offline' | 'authentication' | 'failed';
    }>;

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
    'rejected',
    'unsupported',
    'interrupted',
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
  'imap-rejected': 'rejected',
  'imap-unsupported': 'unsupported',
  'imap-interrupted': 'interrupted',
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
const decodeAccepted = Schema.decodeUnknownEffect(
  Schema.Struct({ accepted: Schema.Literal(true) }),
);
const decodeFiled = Schema.decodeUnknownEffect(Schema.Struct({}));
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

// Folders one online search asks the server about, and the longest single IDLE wait, inside the
// 29 minutes after which servers may drop an idle client.
const searchFolderLimit = 50;
const idleSeconds = 300;

const moves = (
  action: ImapAction,
): action is Extract<ImapAction, { destination: string }> =>
  'destination' in action;

const roleChanged = (change: ImapPending, folders: readonly ImapFolder[]) => {
  const role = change.action.kind === 'spam' ? 'junk' : change.action.kind;
  return (
    (role === 'archive' || role === 'trash' || role === 'junk') &&
    moves(change.action) &&
    change.attempts === 0 &&
    imapRoleFolder(folders, role) !== change.action.destination
  );
};

// The server's answer to one change: decoded, or a refusal that repeating cannot change.
type Answer =
  | Readonly<{ outcome: 'stored' | 'absent' }>
  | Readonly<{ outcome: 'copied'; uidValidity: number; uid: number }>
  | Readonly<{ outcome: 'moved'; uidValidity?: number; uid?: number }>
  | Readonly<{ outcome: 'refused'; failure: Failure }>;
const refused = (kind: ImapFailure['kind']) =>
  kind === 'changed' ||
  kind === 'missing' ||
  kind === 'rejected' ||
  kind === 'unsupported';

// Absence alone cannot prove a move: another client may have removed the source.
const applied = (answer: Answer) =>
  answer.outcome === 'stored' || answer.outcome === 'moved';

// The folder an applied move delivered the message to.
const deliveredTo = (change: ImapPending, answer: Answer) =>
  moves(change.action) && applied(answer)
    ? change.action.destination
    : undefined;

// Where a move the server mapped to a new UID left the message, which Undo moves back. Undo
// itself is not undone.
const movedTo = (
  { action, message }: ImapPending,
  answer: Answer,
): ImapMessage | undefined =>
  answer.outcome === 'moved' &&
  answer.uid !== undefined &&
  answer.uidValidity !== undefined &&
  moves(action) &&
  action.kind !== 'restore'
    ? {
        ...message,
        id: messageId(action.destination, answer.uidValidity, answer.uid),
        folder: action.destination,
        uidValidity: answer.uidValidity,
        uid: answer.uid,
      }
    : undefined;

// Listings with the changes the server has not applied yet: read state shows at once, and a moved
// message leaves the folder it was in.
const projected = (
  messages: readonly ImapMessage[],
  changes: readonly ImapPending[],
) =>
  changes.reduce<readonly ImapMessage[]>(
    (shown, { action, message }) =>
      moves(action)
        ? shown.filter(({ id }) => id !== message.id)
        : shown.map((item) =>
            item.id === message.id
              ? { ...item, unread: action.kind === 'unread' }
              : item,
          ),
    messages,
  );

// Updates every retained view by full message identity, including evicted folders.
const settledMessages = (
  messages: readonly ImapMessage[],
  change: ImapPending,
  answer: Answer,
) =>
  answer.outcome === 'moved' || answer.outcome === 'absent'
    ? messages.filter(({ id }) => id !== change.message.id)
    : messages.map((item) =>
        item.id === change.message.id && answer.outcome === 'stored'
          ? { ...item, unread: change.action.kind === 'unread' }
          : item,
      );

// The cache after the server answered the change: it leaves the queue, a moved or absent message
// leaves its folder, and read state is kept. A refusal changes nothing until the next read.
const settle = (
  current: ImapDocument,
  change: ImapPending,
  answer: Answer,
): ImapDocument => {
  const { message } = change;
  return {
    ...current,
    pending: (current.pending ?? []).filter(({ id }) => id !== change.id),
    mailboxes: current.mailboxes.map((entry) =>
      entry.name === message.folder &&
      entry.cache.uidValidity === message.uidValidity
        ? {
            ...entry,
            cache: {
              ...entry.cache,
              messages: settledMessages(entry.cache.messages, change, answer),
            },
          }
        : entry,
    ),
  };
};

type Failure = Readonly<Pick<ImapFailure, 'kind' | 'diagnostic'>>;

// Refused or transient server access, which the Inbox states rather than logs.
const expected = (kind: ImapFailure['kind']) =>
  kind === 'authentication' || kind === 'retry' || kind === 'interrupted';
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
// Why an attachment could not be downloaded, as its row explains it.
const attachmentFailures: Partial<
  Record<ImapFailure['kind'], AttachmentFailure>
> = {
  authentication: 'authentication',
  retry: 'download',
  interrupted: 'download',
  changed: 'missing',
  missing: 'missing',
  locked: 'locked',
};

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

type HeaderFields = ReadonlyArray<Readonly<{ name: string; value: string }>>;
// Messages per header preflight: the native read bounds each one's fields to 256 KiB.
const preflightSize = 20;
// Whether a message's Content-Type and Content-Disposition fields describe one plain-text or HTML
// part, parsed as its full source would be.
const describesReadablePart = (fields: HeaderFields) => {
  const described = parseMime(
    new TextEncoder().encode(
      `${fields.map(({ name, value }) => `${name}: ${value}\r\n`).join('')}\r\n`,
    ),
  );
  return described !== undefined && singleReadablePart(described);
};

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
    connection = '',
  }: Readonly<{
    // Called after native code purged this device because another device removed it.
    removed?: (() => void) | undefined;
    shared?: Readonly<ReturnType<typeof createBodyLoads>>;
    connection?: string;
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
  // One reference instant per synchronization, including cache admission before prefetch starts.
  let selectionReference: DateTime.Utc | undefined = undefined;
  const referenceInstant = Effect.suspend(() =>
    selectionReference === undefined
      ? DateTime.now
      : Effect.succeed(selectionReference),
  );
  // An explicit read of the same message waits for its prefetch.
  const speculative = new Map<string, Deferred.Deferred<undefined>>();
  // Changes made in this process and not yet saved with the cache; saving moves them to its queue.
  let queued: readonly ImapPending[] = [];
  // Undo can withdraw an intent while its first cache commit is still in flight.
  const withdrawals = new Set<string>();
  let shownStatus: Sync = 'current';
  let authenticationRejected = false;
  // The change being dispatched; its pending move cannot be withdrawn.
  let sending: string | undefined = undefined;
  let notice: ImapNotice | undefined = undefined;
  // The change the notice reports, and where the server moved its message, which Undo reverses.
  let noticed:
    | Readonly<{ id: string; original: ImapMessage; restore?: ImapMessage }>
    | undefined = undefined;
  // Online search results, by message ID, held for the reader until the Inbox closes.
  const found = new Map<string, ImapMessage>();
  // Saved and queued changes, the same array while neither changes.
  let changeList: Readonly<{
    durable: readonly ImapPending[] | undefined;
    queued: readonly ImapPending[];
    all: readonly ImapPending[];
  }> = { durable: undefined, queued, all: [] };
  const changes = () => {
    const durable = document?.pending;
    if (changeList.durable !== durable || changeList.queued !== queued) {
      changeList = { durable, queued, all: [...(durable ?? []), ...queued] };
    }
    return changeList.all;
  };
  // Projected views and messages stay the same objects while their source and the changes do.
  const projectedViews = new WeakMap<
    ImapFolderView,
    Readonly<{ changes: readonly ImapPending[]; view: ImapFolderView }>
  >();
  const projectView = (view: ImapFolderView) => {
    const current = changes();
    if (view.kind !== 'ready' || current.length === 0) {
      return view;
    }
    const memo = projectedViews.get(view);
    if (memo?.changes === current) {
      return memo.view;
    }
    const next = { ...view, messages: projected(view.messages, current) };
    projectedViews.set(view, { changes: current, view: next });
    return next;
  };
  const projectedMessages = new WeakMap<
    ImapMessage,
    Readonly<{ changes: readonly ImapPending[]; message: ImapMessage }>
  >();
  const projectMessage = (message: ImapMessage) => {
    const current = changes();
    const memo = projectedMessages.get(message);
    if (memo?.changes === current) {
      return memo.message;
    }
    const read = Arr.reverse(current).find(
      (change) => change.message.id === message.id && !moves(change.action),
    );
    const next =
      read === undefined
        ? message
        : { ...message, unread: read.action.kind === 'unread' };
    projectedMessages.set(message, { changes: current, message: next });
    return next;
  };

  const notify = () => {
    for (const listener of listeners) {
      listener();
    }
  };
  const cacheOf = (name: string) =>
    document?.mailboxes.find((entry) => entry.name === name)?.cache;
  // Working-set membership sets the tier; open readers also receive temporary eviction protection.
  const bodyProtection = referenceInstant.pipe(
    Effect.map((reference) => {
      const selected = recentWorkingSet(
        cacheOf(inboxFolder)?.messages ?? [],
        reference,
      );
      return {
        selected,
        protectedIds: [...new Set([...readers.keys(), ...selected])],
      };
    }),
  );
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
  // Readers whose inline images the shared budget withheld, presented again when it frees.
  const limited = new Set<string | symbol>();
  const remoteContent = createRemoteContentLoader(native, {
    connection,
    shared,
    scope: readableScope,
    ...shownRemote({ viewReaders, viewBodies, bodies, legacyReaders }),
    inlineImages: (id) => documents.get(id)?.images?.admitted.length ?? 0,
    present: presentRemote,
    notify,
    failed: (mailbox, cause) => {
      const kind = failureKinds[rejectionCode(cause) ?? ''];
      return kind !== undefined &&
        closesAccess(kind) &&
        opened?.address === mailbox.address &&
        opened.generation === mailbox.generation
        ? loadFailed({ kind, diagnostic: rejectionDiagnostic(cause) })
        : Effect.void;
    },
  });
  // Gmail and IMAP readers share one budget; every visible occurrence and window counts.
  const present = (
    key: string | symbol,
    body: BodyDocument,
    count = 1,
  ): Extract<ImapBodyState, { kind: 'ready' }> => {
    let { bytes, pixels } = otherImageUsage(key);
    let occurrences: readonly string[] = [];
    let remoteOccurrences: readonly string[] = [];
    try {
      const sanitized = sanitizeHtml(body.html ?? '');
      occurrences = sanitized.contentIdOccurrences;
      remoteOccurrences = sanitized.remoteImages;
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
    // Loaded Remote Message Content takes what the inline images leave of the budget.
    const remote = remoteContent.admit(body.id, remoteOccurrences, {
      bytes,
      pixels,
      count,
    });
    reservations.set(key, {
      bytes: reservedBytes + remote.bytes,
      pixels: reservedPixels + remote.pixels,
    });
    shared.images.set(imageOwner, reservations);
    shared.waiting.set(imageOwner, presentWaiting);
    if (images.length < (body.images?.admitted.length ?? 0)) {
      limited.add(key);
    } else {
      limited.delete(key);
    }
    return {
      kind: 'ready',
      presentation: presentation(body, images, remote.admitted),
    };
  };
  // Presents every reader of the message again with its loaded Remote Message Content; true when
  // a presentation changed. A failed rich view stays readable until the message opens again.
  function presentRemote(id: string) {
    const body = documents.get(id);
    if (body === undefined) {
      return false;
    }
    let changed = false;
    const refresh = (
      key: string | symbol,
      previous: ImapBodyState | undefined,
      count = 1,
    ) => {
      if (
        previous?.kind !== 'ready' ||
        previous.presentation.rich === undefined
      ) {
        return previous;
      }
      const next = present(key, body, count);
      // Replacing an unchanged presentation would make measured readers retry deferred cache hits.
      if (
        previous.presentation.rich.document ===
          next.presentation.rich?.document &&
        previous.presentation.rich.initialDocument ===
          next.presentation.rich.initialDocument
      ) {
        return previous;
      }
      changed = true;
      return next;
    };
    for (const [reader, shown] of viewReaders) {
      const next =
        shown === id ? refresh(reader, viewBodies.get(reader)) : undefined;
      if (next !== undefined) {
        viewBodies.set(reader, next);
      }
    }
    const count = legacyReaders.get(id) ?? 0;
    const next = count > 0 ? refresh(id, bodies.get(id), count) : undefined;
    if (next !== undefined) {
      bodies.set(id, next);
    }
    return changed;
  }
  // A released reservation lets the readers the budget held back show their images.
  const presentLimited = () => {
    let changed = false;
    const refresh = (key: string | symbol, body: BodyDocument, count = 1) => {
      const previous =
        typeof key === 'symbol' ? viewBodies.get(key) : bodies.get(key);
      const next = present(key, body, count);
      if (
        previous?.kind === 'ready' &&
        previous.presentation.rich?.document ===
          next.presentation.rich?.document
      ) {
        return previous;
      }
      changed = true;
      return next;
    };
    for (const [reader, id] of viewReaders) {
      const body = documents.get(id);
      if (limited.has(reader) && body !== undefined) {
        viewBodies.set(reader, refresh(reader, body));
      }
    }
    for (const [id, count] of legacyReaders) {
      const body = documents.get(id);
      if (limited.has(id) && body !== undefined) {
        bodies.set(id, refresh(id, body, count));
      }
    }
    return changed;
  };
  // Another store released part of the budget.
  function presentWaiting() {
    if (presentLimited()) {
      notify();
    }
  }
  // A closing legacy reader keeps its share of the reservation only while others remain.
  function releaseLegacyReader(id: string) {
    const count = legacyReaders.get(id) ?? 1;
    if (count === 1) {
      legacyReaders.delete(id);
      reservations.delete(id);
      limited.delete(id);
      remoteContent.withdraw(id, id);
      return;
    }
    legacyReaders.set(id, count - 1);
    const reserved = reservations.get(id);
    if (reserved !== undefined) {
      reservations.set(id, {
        bytes: (reserved.bytes * (count - 1)) / count,
        pixels: (reserved.pixels * (count - 1)) / count,
      });
    }
  }
  // A change the server cannot have received yet, which Undo withdraws.
  const unsent = (target: string) =>
    target !== sending &&
    changes().some(({ id, attempts }) => id === target && attempts === 0);
  const blockedChange = () => {
    const [head] = changes();
    return head !== undefined &&
      moves(head.action) &&
      head.attempts > 0 &&
      head.copied === undefined &&
      head.id !== sending
      ? head
      : undefined;
  };
  const reportBlocked = () => {
    const blocked = blockedChange();
    if (blocked !== undefined && notice?.kind !== 'blocked') {
      notice = {
        kind: 'blocked',
        action: blocked.action,
        message: { subject: blocked.message.subject },
      };
      noticed = undefined;
    }
  };
  // A queued move can still be withdrawn; an applied one is reversed where the server put it.
  const undoable = () =>
    notice?.kind === 'done' &&
    noticed !== undefined &&
    moves(notice.action) &&
    notice.action.kind !== 'restore' &&
    (noticed.restore !== undefined || unsent(noticed.id));
  const render = (next: Sync = shownStatus) => {
    if (forgotten || opened === undefined || document === undefined) {
      return;
    }
    reportBlocked();
    shownStatus = authenticationRejected ? 'authentication' : next;
    state = {
      kind: 'ready',
      address: opened.address,
      messages: projected(cacheOf(inboxFolder)?.messages ?? [], changes()),
      status: shownStatus,
      folders: document.folders,
      capabilities: document.capabilities,
      pending: changes().length,
      blocked: blockedChange()?.id,
      ...(notice === undefined ? {} : { notice }),
      undo: undoable(),
      imap: true,
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
    retireSuperseded();
    // Reopening refreshes no other folder, so one whose last read failed keeps saying so.
    const previous = new Map(folderViews);
    folderViews.clear();
    for (const { name, cache: folder } of stored.mailboxes) {
      const last = previous.get(name);
      folderViews.set(name, {
        kind: 'ready',
        messages: folder.messages,
        status: last?.kind === 'ready' ? last.status : 'current',
      });
    }
    // Keep shown evicted rows and failed first reads until their folder is read or retired;
    // access-closing failures have already cleared every view.
    for (const [name, view] of previous) {
      if (view.kind !== 'loading' && !folderViews.has(name)) {
        folderViews.set(name, view);
      }
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
    retireSuperseded();
  });

  // A refreshed listing retires the cache and views of folders the server no longer offers, so
  // pruning stops keeping their bodies. The Inbox always stays.
  const acceptListing = Effect.fnUntraced(function* (
    current: ImapDocument,
    folders: ImapDocument['folders'],
    capabilities: ImapCapabilities,
  ) {
    const offered = new Set(
      folders.filter(({ selectable }) => selectable).map(({ name }) => name),
    );
    const kept = (name: string) => name === inboxFolder || offered.has(name);
    yield* commit({
      ...current,
      folders,
      capabilities,
      mailboxes: current.mailboxes.filter(({ name }) => kept(name)),
    });
    for (const name of folderViews.keys()) {
      if (!kept(name)) {
        folderViews.delete(name);
      }
    }
  });

  // Bodies of messages that no cached folder lists and no view still shows leave the device, so
  // expunged or reset mail never crowds out bodies that stay listed. Open readers' and the recent
  // working set's bodies stay protected as far as they fit. A skipped prune happens after the
  // next folder read.
  const pruneBodies = Effect.gen(function* () {
    const scope = opened;
    if (scope === undefined || document === undefined) {
      return;
    }
    const cached = new Set(document.mailboxes.map(({ name }) => name));
    // A cached folder's document is authoritative; only an evicted folder's shown rows add to it.
    const kept = new Set(
      [
        ...document.mailboxes.flatMap(({ cache }) => cache.messages),
        ...[...folderViews].flatMap(([name, view]) =>
          view.kind === 'ready' && !cached.has(name) ? view.messages : [],
        ),
      ].map(({ id }) => id),
    );
    const { protectedIds } = yield* bodyProtection;
    yield* call(() =>
      native.retainMessageBodies(scope, [...kept], protectedIds),
    ).pipe(
      Effect.andThen(shared.cache.changed),
      Effect.catchIf(
        (failure) => !changesAccess(failure.kind),
        ({ kind, diagnostic }) =>
          expected(kind) || kind === 'conflict'
            ? Effect.void
            : Effect.logError(
                'IMAP message bodies were not pruned:',
                diagnostic,
              ),
      ),
    );
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
    yield* pruneBodies;
  });

  // A removed device purged its data; the account page, not the Inbox, explains it. Locked storage
  // and transient or refused server access are expected; anything else is logged.
  function loadFailed({ kind, diagnostic }: Failure) {
    if (forgotten) {
      return Effect.void;
    }
    if (closesAccess(kind)) {
      authenticationRejected = false;
      lifetime += 1;
      opened = undefined;
      document = undefined;
      folderViews.clear();
      found.clear();
      selectionReference = undefined;
      discardAttachments();
      remoteContent.releaseAll();
      bodies.clear();
      documents.clear();
      viewBodies.clear();
      reservations.clear();
      shared.images.delete(imageOwner);
      shared.waiting.delete(imageOwner);
      state = { kind: kind === 'locked' ? 'locked' : 'failed' };
      notify();
      shared.released(imageOwner);
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
  }

  // What the notice says once the server answered: a refusal replaces it, and a move the server
  // mapped to a new UID can be undone from there.
  const announce = (change: ImapPending, answer: Answer) => {
    const { action, message } = change;
    if (applied(answer)) {
      const restore = movedTo(change, answer);
      if (noticed?.id === change.id && restore !== undefined) {
        noticed = { ...noticed, restore };
      }
      return;
    }
    notice = {
      kind: 'rejected',
      action,
      message: { subject: message.subject },
    };
    noticed = undefined;
  };

  // Sends one saved change; an unmapped move remains recorded if its result is uncertain.
  const send = Effect.fnUntraced(
    function* (scope: Scope, head: ImapPending, rest: readonly ImapPending[]) {
      const { message, action } = head;
      sending = head.id;
      render();
      // Persist dispatch before the network call so a crash cannot replay an unmapped move.
      if (
        moves(action) &&
        head.copied === undefined &&
        document !== undefined
      ) {
        yield* commit({
          ...document,
          pending: [{ ...head, attempts: 1 }, ...rest],
        });
      }
      return yield* call(() =>
        native.imapModify(scope, {
          folder: message.folder,
          uidValidity: message.uidValidity,
          uid: message.uid,
          ...(moves(action)
            ? {
                destination: action.destination,
                ...(head.copied === undefined ? {} : { copied: head.copied }),
              }
            : { read: action.kind === 'read' }),
        }),
      ).pipe(
        Effect.flatMap((reply) =>
          decodeModify(reply).pipe(Effect.mapError(malformed)),
        ),
        Effect.catchIf(
          ({ kind }) => refused(kind),
          ({ kind, diagnostic }): Effect.Effect<Answer> =>
            Effect.succeed({
              outcome: 'refused',
              failure: { kind, diagnostic },
            }),
        ),
        Effect.tapError(({ kind }) =>
          moves(action) &&
          head.copied === undefined &&
          (kind === 'retry' || kind === 'authentication') &&
          document !== undefined
            ? commit({
                ...document,
                pending: [{ ...head, attempts: 0 }, ...rest],
              })
            : Effect.void,
        ),
      );
    },
    Effect.ensuring(
      Effect.sync(() => {
        sending = undefined;
      }),
    ),
  );

  // Saves local intents and withdrawals before the cache's queue may dispatch.
  const saveQueued = Effect.gen(function* () {
    while (queued.length > 0 || withdrawals.size > 0) {
      if (document === undefined) {
        return;
      }
      const taken = queued;
      const withdrawn = new Set(withdrawals);
      const durable = (document.pending ?? []).filter(
        ({ id }) => !withdrawn.has(id),
      );
      // A commit whose reply was lost already saved some of them.
      const known = new Set(durable.map(({ id }) => id));
      yield* commit({
        ...document,
        pending: [...durable, ...taken.filter(({ id }) => !known.has(id))],
      });
      queued = queued.filter((change) => !taken.includes(change));
      for (const id of withdrawn) {
        withdrawals.delete(id);
      }
    }
  });

  const settleViews = (change: ImapPending, answer: Answer) => {
    // Opened and evicted folders have their own snapshots, which must settle with the cache.
    const view = folderViews.get(change.message.folder);
    if (view?.kind === 'ready') {
      folderViews.set(change.message.folder, {
        ...view,
        messages: settledMessages(view.messages, change, answer),
      });
    }
    const searched = found.get(change.message.id);
    if (searched !== undefined) {
      const [retained] = settledMessages([searched], change, answer);
      if (retained === undefined) {
        found.delete(change.message.id);
      } else {
        found.set(change.message.id, retained);
      }
    }
  };

  const acceptAnswer = Effect.fnUntraced(function* (
    head: ImapPending,
    rest: readonly ImapPending[],
    answer: Answer,
  ) {
    if (forgotten || document === undefined) {
      return undefined;
    }
    if (answer.outcome === 'copied') {
      yield* commit({
        ...document,
        pending: [
          {
            ...head,
            attempts: 1,
            copied: { uidValidity: answer.uidValidity, uid: answer.uid },
          },
          ...rest,
        ],
      });
      return {};
    }
    yield* commit(settle(document, head, answer));
    settleViews(head, answer);
    announce(head, answer);
    render();
    return { delivered: deliveredTo(head, answer) };
  });

  // Sends the oldest saved change and keeps its answer. Resolves the folder a move delivered to,
  // or undefined once nothing remains to send.
  const sendNext = Effect.gen(function* () {
    yield* saveQueued;
    const scope = opened;
    const [head, ...rest] = document?.pending ?? [];
    if (head === undefined || scope === undefined) {
      return undefined;
    }
    if (blockedChange() !== undefined) {
      render();
      return undefined;
    }
    const remapped = roleChanged(head, document?.folders ?? []);
    const answer = remapped
      ? ({
          outcome: 'refused',
          failure: { kind: 'rejected', diagnostic: 'Folder role changed' },
        } as const)
      : yield* send(scope, head, rest);
    return yield* acceptAnswer(head, rest, answer);
  });

  // Sends saved changes in order until none remain or the server cannot be reached. Cached
  // folders that received a moved message are read again afterwards, so a message moved back
  // shows there.
  const drain = Effect.gen(function* () {
    const received = new Set<string>();
    for (
      let sent = yield* sendNext;
      sent !== undefined;
      sent = yield* sendNext
    ) {
      if (sent.delivered !== undefined) {
        received.add(sent.delivered);
      }
    }
    for (const name of [...received].filter(
      (folder) => cacheOf(folder) !== undefined,
    )) {
      yield* synchronizeFolder(name);
      showFolder(name, 'current');
    }
    render();
  });

  // Draining outside a load: a commit from another window reopens the cache once, and failures
  // leave the changes saved for the next opportunity.
  const drainNow = () =>
    runLogged(
      semaphore.withPermit(
        drain.pipe(
          Effect.catchIf(
            ({ kind }) => kind === 'conflict' || kind === 'invalidated',
            () => open.pipe(Effect.andThen(drain)),
          ),
          // oxlint-disable-next-line promise/prefer-await-to-then -- Effect's typed error channel.
          Effect.catch(loadFailed),
        ),
      ),
    );

  // Shows the change at once and saves it on this device; it reaches the server in order.
  const organize = async (message: ImapMessage, action: ImapAction) => {
    const started = await runLogged(
      Effect.gen(function* () {
        if (forgotten || opened === undefined || document === undefined) {
          return false;
        }
        const id = `${yield* Random.nextInt}:${yield* Random.nextInt}`;
        queued = [...queued, { id, action, message, attempts: 0 }];
        notice = {
          kind: 'done',
          action,
          message: { subject: message.subject },
        };
        noticed = { id, original: message };
        render();
        return true;
      }),
    );
    if (started) {
      await drainNow();
    }
  };

  // Withdraws a move the server has not received yet, or moves the message back from where the
  // server put it.
  const undo = () => {
    const target = noticed;
    if (target === undefined || !undoable()) {
      return Promise.resolve();
    }
    if (target.restore !== undefined) {
      return organize(target.restore, {
        kind: 'restore',
        destination: target.original.folder,
      });
    }
    const withdrawn = () => {
      if (noticed === target) {
        notice = undefined;
        noticed = undefined;
      }
      render();
    };
    if (queued.some(({ id }) => id === target.id)) {
      withdrawals.add(target.id);
      queued = queued.filter(({ id }) => id !== target.id);
      withdrawn();
      return drainNow();
    }
    return runLogged(
      semaphore.withPermit(
        Effect.gen(function* () {
          if (document !== undefined && unsent(target.id)) {
            yield* commit({
              ...document,
              pending: (document.pending ?? []).filter(
                ({ id }) => id !== target.id,
              ),
            });
            withdrawn();
          }
        }).pipe(
          // oxlint-disable-next-line promise/prefer-await-to-then -- Effect's typed error channel.
          Effect.catch(loadFailed),
        ),
      ),
    );
  };

  // Discard acknowledges an unknown move outcome without replaying it; later changes may resume.
  const discardPending = (id: string) =>
    runLogged(
      semaphore.withPermit(
        Effect.gen(function* () {
          yield* open;
          const head = blockedChange();
          if (head === undefined || head.id !== id || document === undefined) {
            return;
          }
          yield* commit({
            ...document,
            pending: (document.pending ?? []).filter(
              (change) => change.id !== head.id,
            ),
          });
          notice = undefined;
          noticed = undefined;
          yield* synchronizeFolder(head.message.folder);
          showFolder(head.message.folder, 'current');
          yield* drain;
        }).pipe(
          // oxlint-disable-next-line promise/prefer-await-to-then -- Effect's typed error channel.
          Effect.catch(loadFailed),
        ),
      ),
    );

  // Opens the cache, then reads the folder list and the Inbox. Each failure keeps what the cache
  // already shows; a conflicting commit from another window starts again from the cache once.
  const load = () =>
    runLogged(
      semaphore.withPermit(
        Effect.suspend(() => {
          // Internal retries must preserve a refusal raised during this load.
          authenticationRejected = false;
          return Effect.gen(function* () {
            if (forgotten) {
              return;
            }
            selectionReference = yield* DateTime.now;
            const verified = yield* open;
            render('syncing');
            if (!verified) {
              render('retry');
              return;
            }
            const scope = opened;
            if (scope !== undefined) {
              const { folders, ...capabilities } = yield* decodeFolders(
                yield* call(() => native.imapFolders(scope)),
              ).pipe(Effect.mapError(malformed));
              if (document !== undefined) {
                yield* acceptListing(document, folders, capabilities);
              }
            }
            yield* synchronizeFolder(inboxFolder);
            yield* drain;
            render('current');
            schedulePrefetch();
          }).pipe(
            Effect.retry({
              times: 1,
              while: (failure) =>
                failure.kind === 'conflict' || failure.kind === 'invalidated',
            }),
            // oxlint-disable-next-line promise/prefer-await-to-then -- Effect's typed error channel.
            Effect.catch(loadFailed),
          );
        }),
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
    // Another window or process may have committed this cache since it opened; like `load`, the
    // folder read reopens it and tries once more.
    const read = Effect.fnUntraced(function* (reopen: boolean) {
      if (forgotten) {
        return;
      }
      if (reopen || opened === undefined) {
        yield* open;
      }
      yield* synchronizeFolder(name);
      showFolder(name, 'current');
    });
    return runLogged(
      semaphore.withPermit(
        read(false).pipe(
          Effect.catchIf(
            (failure) =>
              failure.kind === 'conflict' || failure.kind === 'invalidated',
            () => read(true),
          ),
          // oxlint-disable-next-line promise/prefer-await-to-then -- Effect's typed error channel.
          Effect.catch(folderFailed(name)),
        ),
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
  // A folder evicted from the cache keeps its shown rows openable until its view is replaced.
  // Search results open too, and read state shows changes not yet applied.
  const messageOf = (id: string) => {
    const shown =
      [
        ...(document?.mailboxes.flatMap(({ cache }) => cache.messages) ?? []),
        ...[...folderViews.values()].flatMap((view) =>
          view.kind === 'ready' ? view.messages : [],
        ),
      ].find((message) => message.id === id) ?? found.get(id);
    return shown === undefined ? undefined : projectMessage(shown);
  };
  // A row still shown from an evicted folder reads its saved body offline too.
  const visibleRow = (id: string) => messageOf(id) !== undefined;
  // The mailbox an open reader of a readable message reads it from.
  function readableScope(id: string) {
    return readers.has(id) && visibleRow(id) ? opened : undefined;
  }

  // The message's raw source from the server, as the body the reader presents.
  // Two concurrent body downloads for this connection, within the device-wide four.
  const connectionLoads = Semaphore.makeUnsafe(2);
  const sourceOf = Effect.fnUntraced(function* (
    scope: Scope | undefined,
    message: ImapMessage,
  ) {
    if (scope === undefined) {
      return yield* new ImapFailure({
        kind: 'retry',
        cause: 'closed',
        diagnostic: 'Inbox closed',
      });
    }
    // shortcut: native IMAP reads have no cancel handle, so a cancelled download keeps its load
    // permits until the read settles and cancel and retry cannot stack reads; upgrade once native
    // IMAP reads accept cancellation.
    const raw = yield* decodeRaw(
      yield* Effect.uninterruptible(
        call(() =>
          native.imapMessage(scope, {
            folder: message.folder,
            uidValidity: message.uidValidity,
            uid: message.uid,
          }),
        ),
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
    return payload;
  });
  const bodyOf = (message: ImapMessage) =>
    sourceOf(opened, message).pipe(
      Effect.flatMap((payload) => bodyDocument(message.id, payload)),
    );
  // Downloads share the device's body loads: four at a time across connections, two for this one,
  // and speculative prefetch elsewhere waits while an explicit read runs.
  const explicitLoad = <A>(read: Effect.Effect<A, ImapFailure>) =>
    Effect.acquireUseRelease(
      shared.begin,
      () => connectionLoads.withPermit(shared.loads.withPermit(read)),
      () => shared.end,
    );

  // Each opened message's attachment downloads. Download reads the message's source again at its
  // folder's UIDVALIDITY and keeps the attachment only while its descriptor is unchanged; a saved
  // file is deleted when the message's last reader closes.
  const attachments = createAttachmentDownloads(native, {
    scope: () => opened,
    owner: () => lifetime,
    readable: (id) => visibleRow(id) && !superseded(id),
    listed: (id) => documents.get(id)?.attachments,
    fetch: (scope, id, listedAttachment) =>
      explicitLoad(
        Effect.gen(function* () {
          const message = messageOf(id);
          const descriptor =
            message === undefined
              ? undefined
              : receivedAttachments(yield* sourceOf(scope, message)).find(
                  (candidate) => sameAttachment(candidate, listedAttachment),
                );
          if (descriptor?.part.body === undefined) {
            return yield* new ImapFailure({
              kind: 'missing',
              cause: 'attachment',
              diagnostic: 'attachment changed',
            });
          }
          return {
            data: descriptor.part.body.data ?? '',
            size: descriptor.part.body.size,
          };
        }),
      ).pipe(
        Effect.tapError((failure) =>
          current(scope) && changesAccess(failure.kind)
            ? loadFailed(failure)
            : Effect.void,
        ),
      ),
    failed: (failure) => {
      if (failure.kind === 'invalidated') {
        return Effect.succeed('stale');
      }
      const reason =
        failure instanceof SyncFailure
          ? downloadFailure(failure.kind)
          : (attachmentFailures[failure.kind] ?? 'failed');
      return (
        reason === 'failed'
          ? Effect.logError('Attachment download failed:', failure.diagnostic)
          : Effect.void
      ).pipe(Effect.as(reason));
    },
    notify,
  });
  // Callers above drop downloads through this, declared once the downloads exist.
  function discardAttachments(id?: string, reason?: AttachmentFailure) {
    attachments.discard(id, reason);
  }
  // A message of a folder the cache now records at another UIDVALIDITY. Like saved bodies, its
  // attachments follow the committed folder identity, even while a reader still shows it.
  function superseded(id: string) {
    return (
      document?.mailboxes.some(({ name, cache }) =>
        ofOtherGeneration(id, name, cache.uidValidity),
      ) === true
    );
  }
  // Retires the saved and in-flight downloads of superseded messages once per change.
  function retireSuperseded() {
    let retired = false;
    for (const id of documents.keys()) {
      const shown = attachments.messageAttachments(id) ?? [];
      if (
        superseded(id) &&
        shown.some(
          (attachment) =>
            attachment.state.kind !== 'unavailable' ||
            attachment.state.reason !== 'missing',
        )
      ) {
        attachments.discard(id, 'missing');
        retired = true;
      }
    }
    if (retired) {
      notify();
    }
  }

  // Which of these cached messages have a body saved on this device, read without the server and
  // without touching what the cache keeps. A reply for an Inbox that closed or changed meanwhile
  // names none, and a failed read leaves the answer unknown.
  const savedBodies = (ids: readonly string[]) => {
    const scope = opened;
    const wanted = ids.filter(visibleRow);
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
              ? stored.filter((id) => !markers.has(id) && visibleRow(id))
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
        const prefetching = speculative.get(id);
        if (prefetching !== undefined) {
          yield* Deferred.await(prefetching);
        }
        const cached = yield* decodeCachedBody(
          yield* call(() => native.openMessageBody(scope, id)),
        ).pipe(Effect.mapError(malformed));
        const saved = Option.fromNullishOr(cached.document).pipe(
          Option.flatMap(decodeBodyDocument),
          Option.filter((body) => body.id === id && body.excluded !== true),
        );
        if (Option.isSome(saved)) {
          return saved.value;
        }
        const body = yield* explicitLoad(bodyOf(message));
        const cache = opened;
        // Bodies are stored only for listed messages of the open cache; a full cache keeps none.
        if (cache !== undefined && listed(id) && current(scope)) {
          const text = yield* encodeBodyDocument(body).pipe(
            Effect.mapError(malformed),
          );
          const { selected, protectedIds } = yield* bodyProtection;
          yield* call(() =>
            native.commitMessageBody(scope, id, {
              document: text,
              // Opening a selected message keeps its prefetch status.
              tier: selected.includes(id) ? 'prefetched' : 'opened',
              protectedIds,
              expectedRevision: cache.revision,
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
            if (superseded(id)) {
              attachments.discard(id, 'missing');
            }
            for (const [reader, shownId] of viewReaders) {
              if (shownId === id) {
                viewBodies.set(reader, present(reader, body));
              }
            }
            const count = legacyReaders.get(id) ?? 0;
            return count === 0
              ? { kind: 'ready', presentation: presentation(body, []) }
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

  // Saves a prefetched body or exclusion marker under the working set's protection. Synchronization
  // commits and prunes under the same permit, so a message a new UIDVALIDITY or expunge removed
  // from the cache stores nothing.
  const keep = Effect.fnUntraced(function* (scope: Scope, body: BodyDocument) {
    const text = yield* encodeBodyDocument(body).pipe(
      Effect.mapError(malformed),
    );
    yield* semaphore.withPermit(
      Effect.gen(function* () {
        const cache = opened;
        if (cache === undefined || !current(scope) || !listed(body.id)) {
          return;
        }
        const { protectedIds } = yield* bodyProtection;
        yield* call(() =>
          native.commitMessageBody(scope, body.id, {
            document: text,
            tier: body.excluded === true ? 'excluded' : 'prefetched',
            protectedIds,
            expectedRevision: cache.revision,
          }),
        ).pipe(
          Effect.flatMap((reply) =>
            decodeBodyCommit(reply).pipe(Effect.mapError(malformed)),
          ),
          Effect.flatMap(({ admitted }) =>
            admitted ? shared.cache.changed : Effect.void,
          ),
        );
      }),
    );
  });
  // A speculative read holds one of the connection's two loads and yields the device's loads to
  // every explicit read.
  const speculativeLoad = <A>(read: Effect.Effect<A, ImapFailure>) =>
    connectionLoads.withPermit(
      shared.loads.withPermit(read, undefined, () => Infinity),
    );
  const prefetchPaused = (scope: Scope) =>
    !current(scope) ||
    shownStatus === 'authentication' ||
    shownStatus === 'retry';
  // Only a single plain-text or HTML part is saved; any other message, or one too large or
  // unreadable, gets an exclusion marker so later selections leave it on demand.
  // Waits while an explicit read waits or runs anywhere on the device; true once prefetch pauses.
  const yielded = (scope: Scope) =>
    shared.idle.await.pipe(Effect.map(() => prefetchPaused(scope)));
  // The Content-Type and Content-Disposition fields of up to `preflightSize` still-present messages,
  // read without any body. Fields beyond the native per-message bound leave every message of the
  // read without fields.
  const preflight = (
    scope: Scope,
    uidValidity: number,
    messages: readonly ImapMessage[],
  ) =>
    speculativeLoad(
      call(() =>
        native.imapHeaders(scope, {
          folder: inboxFolder,
          uidValidity,
          uids: messages.map(({ uid }) => uid),
        }),
      ),
    ).pipe(
      Effect.flatMap((reply) =>
        decodeHeaders(reply).pipe(Effect.mapError(malformed)),
      ),
      Effect.map(
        (reply): ReadonlyMap<number, HeaderFields | undefined> =>
          new Map(reply.messages.map(({ uid, headers }) => [uid, headers])),
      ),
      Effect.catchIf(
        ({ kind }: Failure) => kind === 'too-large',
        () =>
          Effect.succeed(
            new Map(messages.map(({ uid }) => [uid, undefined] as const)),
          ),
      ),
    );
  // Without fields, the message's header fields were too large to read and it stays on demand.
  const prefetchBody = Effect.fnUntraced(function* (
    scope: Scope,
    message: ImapMessage,
    fields: HeaderFields | undefined,
  ) {
    const pending = yield* Deferred.make<undefined>();
    speculative.set(message.id, pending);
    const excluded: BodyDocument = {
      version: 2,
      id: message.id,
      excluded: true,
    };
    const download = speculativeLoad(sourceOf(scope, message)).pipe(
      Effect.flatMap((payload): Effect.Effect<BodyDocument, ImapFailure> =>
        singleReadablePart(payload)
          ? bodyDocument(message.id, payload)
          : Effect.succeed(excluded),
      ),
      Effect.catchIf(
        ({ kind }: Failure) => kind === 'too-large' || kind === 'failed',
        ({ kind, diagnostic }) =>
          (kind === 'failed'
            ? Effect.logError('IMAP body prefetch failed:', diagnostic)
            : Effect.void
          ).pipe(Effect.as(excluded)),
      ),
      Effect.flatMap((body) => keep(scope, body)),
      // An expunged message or a new UIDVALIDITY leaves the cache at the next synchronization.
      Effect.catchIf(
        ({ kind }: Failure) => kind === 'changed' || kind === 'missing',
        () => Effect.void,
      ),
    );
    yield* call(() => native.listMessageBodies(scope, [message.id])).pipe(
      Effect.flatMap((reply) =>
        decodeStoredBodies(reply).pipe(Effect.mapError(malformed)),
      ),
      // An explicit open may have saved this body while the bulk preflight was pending.
      Effect.flatMap(({ stored }) => {
        if (stored.includes(message.id) || prefetchPaused(scope)) {
          return Effect.void;
        }
        return fields !== undefined && describesReadablePart(fields)
          ? download
          : keep(scope, excluded);
      }),
      Effect.ensuring(
        Effect.suspend(() => {
          if (speculative.get(message.id) === pending) {
            speculative.delete(message.id);
          }
          return Deferred.succeed(pending, undefined);
        }),
      ),
    );
  });
  // Selects the Inbox's recent working set, newest first, and returns its messages that have
  // neither a saved body nor an exclusion marker.
  const unsavedSelection = Effect.fnUntraced(function* (
    scope: Scope,
    messages: readonly ImapMessage[],
  ) {
    const byId = new Map(messages.map((item) => [item.id, item]));
    const selection = recentWorkingSet(messages, yield* referenceInstant);
    const { stored } = yield* call(() =>
      native.listMessageBodies(scope, selection),
    ).pipe(
      Effect.flatMap((reply) =>
        decodeStoredBodies(reply).pipe(Effect.mapError(malformed)),
      ),
    );
    const saved = new Set(stored);
    return selection.flatMap((id) => {
      const message = byId.get(id);
      return message === undefined || saved.has(id) ? [] : [message];
    });
  });
  // Prefetches one preflight's messages in order; false once prefetch pauses.
  const prefetchChunk = Effect.fnUntraced(function* (
    scope: Scope,
    uidValidity: number,
    chunk: readonly ImapMessage[],
  ) {
    const headers = yield* preflight(scope, uidValidity, chunk);
    for (const message of chunk) {
      if (yield* yielded(scope)) {
        return false;
      }
      // An expunged message or one an explicit read is saving needs no prefetch.
      if (headers.has(message.uid) && !reading.has(message.id)) {
        yield* prefetchBody(scope, message, headers.get(message.uid));
      }
    }
    return true;
  });
  // One speculative lane: the Inbox's recent working set, newest first. A body-free read of every
  // unsaved message's Content-Type and Content-Disposition chooses which sources to read, so no
  // attachment is downloaded speculatively.
  const prefetch = Effect.fnUntraced(function* (scope: Scope) {
    const inbox = cacheOf(inboxFolder);
    if (inbox === undefined || prefetchPaused(scope)) {
      return;
    }
    const wanted = yield* unsavedSelection(scope, inbox.messages);
    if (wanted.length === 0) {
      return;
    }
    for (const chunk of Arr.chunksOf(wanted, preflightSize)) {
      if (
        (yield* yielded(scope)) ||
        !(yield* prefetchChunk(scope, inbox.uidValidity, chunk))
      ) {
        return;
      }
    }
  });
  let prefetching = false;
  let prefetchAgain = false;
  // A refused password asks for it again; offline and server failures, and a folder that changed
  // since its synchronization, pause prefetch until the next synchronization.
  const prefetchFailed =
    (scope: Scope) =>
    ({ kind, diagnostic }: Failure) => {
      if (current(scope) && changesAccess(kind)) {
        authenticationRejected ||= kind === 'authentication';
        return loadFailed({ kind, diagnostic });
      }
      return expected(kind) ||
        kind === 'changed' ||
        kind === 'invalidated' ||
        kind === 'conflict'
        ? Effect.void
        : Effect.logError('IMAP body prefetch failed:', diagnostic);
    };
  // Starts the lane after an Inbox synchronization, or asks a running one to select again once its
  // pass ends. Declared here, after what it runs; synchronization above starts it.
  function schedulePrefetch() {
    if (prefetching) {
      prefetchAgain = true;
      return;
    }
    prefetching = true;
    void runLogged(
      Effect.gen(function* () {
        do {
          prefetchAgain = false;
          const scope = opened;
          if (scope !== undefined) {
            yield* prefetch(scope).pipe(Effect.catch(prefetchFailed(scope)));
          }
        } while (prefetchAgain);
      }).pipe(
        Effect.ensuring(
          Effect.sync(() => {
            prefetching = false;
          }),
        ),
      ),
    );
  }

  // The server's own search of the Inbox and the connection's other folders, newest first. Results
  // stay readable until the Inbox closes and are never saved.
  const search = (query: string) =>
    runLogged(
      Effect.gen(function* () {
        const scope = opened;
        if (scope === undefined || document === undefined) {
          return { kind: 'unavailable', reason: 'failed' } as const;
        }
        const folders = searchedFolders(document.folders);
        const asked = folders.slice(0, searchFolderLimit);
        const reply = yield* decodeSearch(
          yield* call(() =>
            native.imapSearch(scope, { query, folders: asked }),
          ),
        ).pipe(Effect.mapError(malformed));
        if (!current(scope)) {
          return { kind: 'found', messages: [], limited: false } as const;
        }
        const messages = newestFirst(
          reply.folders.flatMap(({ folder, uidValidity, messages: matches }) =>
            matches.map((match) => listedMessage(folder, uidValidity, match)),
          ),
        );
        for (const message of messages) {
          found.set(message.id, message);
        }
        return {
          kind: 'found',
          messages,
          limited:
            asked.length < folders.length ||
            reply.skipped > 0 ||
            reply.folders.some(({ more }) => more),
        } as const;
      }).pipe(
        Effect.catchTag(
          'ImapFailure',
          (failure): Effect.Effect<ImapSearchPage> => {
            if (failure.kind === 'authentication') {
              return Effect.succeed({
                kind: 'unavailable',
                reason: 'authentication',
              });
            }
            if (failure.kind === 'retry') {
              return Effect.succeed({ kind: 'unavailable', reason: 'offline' });
            }
            return (
              closesAccess(failure.kind)
                ? loadFailed(failure)
                : Effect.logError('IMAP search failed:', failure.diagnostic)
            ).pipe(
              Effect.as({ kind: 'unavailable', reason: 'failed' } as const),
            );
          },
        ),
      ),
    );

  // Submits one message through SMTP from this connection's open generation. A connection not open
  // yet reaches no server, so the message waits.
  const submit = (message: OutgoingSend, recipients: readonly string[]) => {
    const scope = opened;
    if (scope === undefined || forgotten) {
      return Promise.resolve<SendOutcome>({
        kind: 'queued',
        problem: 'offline',
      });
    }
    return runLogged(
      call(() =>
        native.imapSend(
          { segments: withoutBcc(message.segments), recipients },
          scope,
        ),
      ).pipe(
        Effect.tapError((failure) =>
          current(scope) && changesAccess(failure.kind)
            ? loadFailed(failure)
            : Effect.void,
        ),
        Effect.mapError(({ cause }) => sendRejection(cause)),
        Effect.flatMap((reply) =>
          decodeAccepted(reply).pipe(
            Effect.mapError((): SendOutcome => ({ kind: 'unknown' })),
          ),
        ),
        Effect.match({
          onFailure: (outcome) => outcome,
          onSuccess: (): SendOutcome => ({ kind: 'accepted' }),
        }),
      ),
    );
  };
  // Files an accepted message's copy in the Sent folder the server declares. Resolves undefined
  // once the copy is there, or why it still waits.
  const fileSent = (
    message: OutgoingSend,
    boundary: string,
  ): Promise<DeliveryProblem | undefined> => {
    const scope = opened;
    if (scope === undefined || forgotten || document === undefined) {
      return Promise.resolve('offline');
    }
    const folder = imapRoleFolder(document.folders, 'sent');
    if (folder === undefined) {
      return Promise.resolve('sent-folder');
    }
    return runLogged(
      call(() =>
        native.imapFileSent(scope, {
          folder,
          boundary,
          segments: message.segments,
        }),
      ).pipe(
        Effect.flatMap((reply) =>
          decodeFiled(reply).pipe(Effect.mapError(malformed)),
        ),
        Effect.tapError((failure) =>
          current(scope) && changesAccess(failure.kind)
            ? loadFailed(failure)
            : Effect.void,
        ),
        Effect.match({
          onSuccess: () => (current(scope) ? undefined : 'offline'),
          onFailure: ({ kind }): DeliveryProblem => {
            if (kind === 'authentication') {
              return 'authorization';
            }
            return kind === 'locked' ? 'locked' : 'offline';
          },
        }),
      ),
    );
  };
  // Looks for a message whose submission had no answer in the Sent folder by its MIME boundary.
  // Resolves sent for exactly one copy, unknown otherwise, or undefined when the open connection
  // was not looked at, as when it closed or changed meanwhile.
  const findSent = (boundary: string) => {
    const scope = opened;
    if (scope === undefined || forgotten || document === undefined) {
      return Promise.resolve(undefined);
    }
    const folder = imapRoleFolder(document.folders, 'sent');
    if (folder === undefined) {
      return Promise.resolve<SendOutcome>({ kind: 'unknown' });
    }
    return runLogged(
      call(() => native.imapFindSent(scope, { folder, boundary })).pipe(
        Effect.flatMap((reply) =>
          decodeCount(reply).pipe(Effect.mapError(malformed)),
        ),
        Effect.tapError((failure) =>
          current(scope) && changesAccess(failure.kind)
            ? loadFailed(failure)
            : Effect.void,
        ),
        Effect.match({
          onSuccess: ({ count }): SendOutcome | undefined => {
            if (!current(scope)) {
              return undefined;
            }
            return count === 1 ? { kind: 'sent' } : { kind: 'unknown' };
          },
          onFailure: ({ kind }): SendOutcome | undefined =>
            kind === 'invalidated' ? undefined : { kind: 'unknown' },
        }),
      ),
    );
  };

  // One wait: a reported change, a quiet bound, a pause before trying again, or the end.
  const waitOnce = async () => {
    const scope = opened;
    const idle = document?.capabilities?.idle;
    if (idle === false) {
      return 'stop';
    }
    return scope === undefined || idle === undefined
      ? 'pause'
      : runLogged(
          call(() =>
            native.imapIdle(scope, {
              folder: inboxFolder,
              seconds: idleSeconds,
            }),
          ).pipe(
            Effect.flatMap((reply) =>
              decodeIdle(reply).pipe(Effect.mapError(malformed)),
            ),
            Effect.match({
              onSuccess: ({ changed }) => (changed ? 'changed' : 'quiet'),
              // A refused password, a lock or a repaired connection pauses until it is usable.
              onFailure: ({ kind }) =>
                kind === 'unsupported' ? 'stop' : 'pause',
            }),
          ),
        );
  };
  // Waits with IDLE on the Inbox and reads it again whenever the server reports a change. A server
  // without IDLE leaves freshness to polling and foreground catch-up; any other failed wait, and a
  // wait before the first listing, tries again after a pause that grows to five minutes.
  // Stopping ends future waits; one already waiting ends within its bound and is ignored.
  const watch = () => {
    const controller = new AbortController();
    const pause = Schedule.min([
      Schedule.exponential(Duration.seconds(5)),
      Schedule.spaced(Duration.minutes(5)),
    ]);
    const watching = () => !controller.signal.aborted && !forgotten;
    const nextStep = () => runLogged(Schedule.toStepWithSleep(pause));
    // Pauses before the next attempt; false once stopped meanwhile.
    const rest = async (step: Awaited<ReturnType<typeof nextStep>>) => {
      try {
        await runLogged(
          step(undefined).pipe(Pull.catchDone(() => Effect.never)),
          {
            signal: controller.signal,
          },
        );
        return true;
      } catch {
        return false;
      }
    };
    const follow = async () => {
      let step = await nextStep();
      while (watching()) {
        const waited = await waitOnce();
        if (waited === 'stop' || !watching()) {
          return;
        }
        if (waited === 'pause') {
          if (!(await rest(step))) {
            return;
          }
        } else {
          step = await nextStep();
          if (waited === 'changed') {
            await load();
          }
        }
      }
    };
    void follow();
    return () => {
      controller.abort();
    };
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
        return projectView(recorded ?? loadingFolder);
      }
      const cached = cachedViews.get(messages) ?? {
        kind: 'ready',
        messages,
        status: 'current',
      };
      cachedViews.set(messages, cached);
      return projectView(cached);
    },
    organize,
    undo,
    discardPending,
    // The shared online-search contract's name; IMAP has no further pages.
    searchGmail: (query: string) => search(query),
    send: submit,
    fileSent,
    findSent,
    watch,
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
          releaseLegacyReader(id);
        } else {
          viewReaders.delete(reader);
          viewBodies.delete(reader);
          reservations.delete(reader);
          limited.delete(reader);
          remoteContent.withdraw(id, reader);
        }
        const count = (readers.get(id) ?? 1) - 1;
        if (count === 0) {
          readers.delete(id);
          attachments.discard(id);
          remoteContent.release(id);
          bodies.delete(id);
          documents.delete(id);
        } else {
          readers.set(id, count);
        }
        // The readers that remain are presented again with the budget the closed one held.
        const remoteChanged = remoteContent.has(id) && presentRemote(id);
        if (presentLimited() || remoteChanged) {
          notify();
        }
        shared.released(imageOwner);
      };
    },
    // An opened message's received attachments, downloaded, opened and shared as for Gmail.
    messageAttachments: attachments.messageAttachments,
    downloadAttachment: attachments.downloadAttachment,
    cancelAttachment: attachments.cancelAttachment,
    presentAttachment: attachments.presentAttachment,
    attachmentFile: attachments.attachmentFile,
    // Loads an opened message's Remote Message Content, as for Gmail: from the Authorized Remote
    // Content Cache, and with `network` also through the isolated native fetch.
    loadRemoteImages: remoteContent.load,
    // Drops a message's loaded Remote Message Content from memory and presents it again, as when
    // its policy becomes Never; cached bytes stay until eviction or Clear Remote Content.
    forgetRemoteImages: (id: string) => {
      remoteContent.forget(id);
      presentWaiting();
      shared.released(imageOwner);
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
        limited.delete(reader ?? id);
        // Its remote requests end with the rich view; nothing it loads could be shown.
        remoteContent.discard(id, reader ?? id);
        presentLimited();
        notify();
        shared.released(imageOwner);
      }
    },
    // Forgets the mail held in memory when the connection or its account leaves the Inbox.
    forget: () => {
      forgotten = true;
      attachments.discard();
      remoteContent.releaseAll();
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
      limited.clear();
      found.clear();
      selectionReference = undefined;
      queued = [];
      withdrawals.clear();
      notice = undefined;
      noticed = undefined;
      shared.images.delete(imageOwner);
      shared.waiting.delete(imageOwner);
      state = { kind: 'loading' };
      notify();
      shared.released(imageOwner);
    },
  };
}

export type ImapInbox = ReturnType<typeof createImapInbox>;
