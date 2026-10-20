import * as Arr from 'effect/Array';
import * as DateTime from 'effect/DateTime';
import * as Deferred from 'effect/Deferred';
import * as Effect from 'effect/Effect';
import * as Latch from 'effect/Latch';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Random from 'effect/Random';
import * as Schedule from 'effect/Schedule';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';
import * as Struct from 'effect/Struct';

import type { DeliveryProblem } from './draft-model.ts';
import type { GmailAction, GmailLabel } from './gmail-actions.ts';
import type { ProviderPayload } from './graph-inbox.ts';
import type {
  Cache,
  GmailMessage,
  MailboxDocument,
  MailboxScope,
  PendingAction,
} from './mailbox-document.ts';
import type { GmailInvalidPage, NativeGraphMailbox } from './mailbox-read.ts';
import type {
  BodyDocument,
  GmailPart,
  MessagePresentation,
} from './message-body.ts';
import type { MessageSegment } from './outgoing-message.ts';
import type { MailGrantProvider } from './registration-snapshot.ts';
import type {
  NativeRemoteContentCache,
  RetainedRemote,
} from './remote-content-loader.ts';

import { rejectionCode, runLogged } from './diagnostics.ts';
import {
  allMail,
  canOrganize,
  GmailLabelSchema,
  inInbox,
  inView,
  relabel,
  systemViews,
} from './gmail-actions.ts';
import { createGraphReader } from './graph-inbox.ts';
import { sanitizeHtml } from './html-sanitizer.ts';
import { decodedSize, inlineImageLimits } from './inline-images.ts';
import {
  cachedViews,
  cacheLimit,
  decodeCache,
  decodeDocument,
  encodeDocument,
  GmailId,
  HistoryId,
  merge,
  newestFirst,
  sameMailbox,
} from './mailbox-document.ts';
import {
  decodeResponse,
  GmailNotFound,
  malformed,
  providerRead,
  providerWrite,
  rateLimited,
  rejected,
  rejectedGrant,
  SyncFailure,
} from './mailbox-read.ts';
import {
  attachmentLimit,
  bodyParts,
  contentIdsOf,
  decodeAttachment,
  decodeBodyDocument,
  decodeCachedBody,
  decodeFullMessage,
  encodeBodyDocument,
  imageTally,
  inlineImageParts,
  partBytes,
  partText,
  presentation,
  receivedAttachments,
  recentWorkingSet,
  responseHeadersOf,
  singleReadablePart,
  unescapeHtml,
  withinMetadataBudgets,
} from './message-body.ts';
import { graphChange } from './microsoft-graph.ts';
import {
  createRemoteContentLoader,
  shownRemote,
} from './remote-content-loader.ts';

export type { GmailMessage } from './mailbox-document.ts';
export type { RemoteResource } from './remote-content-loader.ts';

// The native Registration module's mailbox operations. Native code attaches the Gmail credential
// and keeps the cache encrypted; this module chooses the Gmail requests and owns the cached document.
export interface NativeGmailMailbox
  extends NativeGraphMailbox, NativeRemoteContentCache {
  // Resolves `{ status, body }` for a read of `gmail/v1/users/me/<path>`.
  readonly gmailRequest: (
    path: string,
    query: ReadonlyArray<readonly [string, string]>,
    mailbox: Readonly<{
      address: string;
      generation: string;
      signal?: Readonly<AbortSignal>;
    }>,
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
  // Sends one message through Gmail's messages.send upload, inserting each asset segment's
  // verified bytes, and joins `threadId` when given. Resolves `{ status, body }` once Gmail
  // answers. Rejects with 'delivery-unknown' when the request may have reached Gmail without an
  // answer; any other rejection means it never left this device.
  readonly gmailSend: (
    message: OutgoingSend,
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
  // Stores a body in the 'opened' or 'prefetched' eviction tier, or a prefetch exclusion marker in
  // the 'excluded' tier, evicting least recently read bodies outside the protected working set;
  // resolves `{ admitted }`, false when it cannot fit.
  readonly commitMessageBody: (
    mailbox: Readonly<{ address: string; generation: string }>,
    id: string,
    admission: Readonly<{
      document: string;
      tier: BodyTier;
      protectedIds: readonly string[];
    }>,
  ) => Promise<unknown>;
  // Resolves `{ stored, excluded }`: which of these messages have a cached body or exclusion
  // marker, and which of those are only exclusion markers.
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
  // Writes a verified Downloaded Attachment's base64url bytes into the connection's private
  // temporary storage, which native code clears with the connection. Resolves `{ file }`, an opaque
  // name; the data never leaves this device.
  readonly saveAttachment: (
    mailbox: Readonly<{ address: string; generation: string }>,
    attachment: Readonly<{ name: string; data: string; size: number }>,
  ) => Promise<unknown>;
  // Deletes a saved attachment; deleting is allowed after the mailbox's generation changed.
  readonly discardAttachment: (
    mailbox: Readonly<{ address: string; generation: string }>,
    file: string,
  ) => Promise<unknown>;
  // Shows the system Attachment Preview, or the system share sheet, for a saved attachment.
  readonly presentAttachment: (
    mailbox: Readonly<{ address: string; generation: string }>,
    file: string,
    action: 'open' | 'share',
  ) => Promise<unknown>;
}

type BodyTier = 'opened' | 'prefetched' | 'excluded';

const pageSize = 50;
// Online search results per page and mailbox.
const searchPageSize = 20;
// The newest Sent messages read for a message whose handoff had no answer.
const sentPageSize = 20;

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
// The latest organizing outcome, until the next one; unsaved batches also report their size.
export type OrganizeNotice = Readonly<
  {
    action: GmailAction;
    message: GmailMessage;
  } & ({ kind: 'done' | 'rejected' } | { kind: 'unsaved'; count: number })
>;

type Sync = 'syncing' | 'current' | 'authentication' | 'retry';

// A Gmail view other than the Inbox: its newest messages with requested changes applied. A view
// whose last read failed keeps its saved messages.
export type GmailView = Readonly<{
  label: string;
  messages: readonly GmailMessage[];
  status: 'syncing' | 'current' | 'failed';
  // The view keeps as many messages as it can; older ones stay in Gmail.
  limited?: true;
}>;

export type GmailInboxState =
  | { readonly kind: 'loading' | 'locked' | 'failed' }
  | {
      readonly kind: 'ready';
      // Absent when no Gmail mailbox is connected on this device.
      readonly address?: string;
      readonly messages: readonly GmailMessage[];
      // Online search results the reader can open, kept in memory only until the Inbox closes.
      readonly found?: readonly GmailMessage[];
      readonly sync: Sync;
      // The mailbox's own labels, empty until Gmail lists them, or its folders.
      readonly labels: readonly GmailLabel[];
      // More folders exist than `labels` lists.
      readonly labelsLimited?: true;
      // The Gmail views a reader opened, most recently opened first.
      readonly views?: readonly GmailView[];
      // Folder-role actions this mailbox cannot perform, including while roles are unknown.
      readonly unavailableActions?: ReadonlyArray<GmailAction['kind']>;
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

// A received attachment's availability on this device. 'oversized' attachments are listed but
// never downloaded; 'damaged' means Gmail's bytes were incomplete or did not decode.
export type AttachmentState =
  | {
      readonly kind: 'available' | 'oversized' | 'downloading' | 'downloaded';
    }
  | {
      readonly kind: 'unavailable';
      readonly reason:
        | 'download'
        | 'authentication'
        | 'missing'
        | 'locked'
        | 'failed'
        | 'damaged';
    };

export type ReceivedAttachment = Readonly<{
  locator: string;
  name: string;
  mimeType: string;
  size: number;
  state: AttachmentState;
}>;

const attachmentStates = {
  available: { kind: 'available' },
  oversized: { kind: 'oversized' },
  downloading: { kind: 'downloading' },
  downloaded: { kind: 'downloaded' },
} as const satisfies Record<string, AttachmentState>;

const decodeSavedAttachment = Schema.decodeUnknownEffect(
  Schema.Struct({
    file: Schema.String.check(Schema.isPattern(/^[\dA-Fa-f-]{36}$/u)),
  }),
);

// Gmail sent bytes that do not decode to the attachment's declared size.
class AttachmentDamaged extends Schema.TaggedError<AttachmentDamaged>()(
  'AttachmentDamaged',
  {},
) {}

const attachmentKey = (id: string, locator: string) => `${id}\n${locator}`;

type AttachmentFailure = Extract<
  AttachmentState,
  { kind: 'unavailable' }
>['reason'];
const unavailable = (reason: AttachmentFailure) => ({
  state: { kind: 'unavailable', reason } as const,
});
// Offline, quota and server failures can pass on a later try; stale work shows nothing new.
const downloadFailure = (kind: SyncFailure['kind']): AttachmentFailure => {
  if (kind === 'locked' || kind === 'failed') {
    return kind;
  }
  return kind === 'retry' ? 'download' : 'failed';
};

type AttachmentDescriptor = NonNullable<BodyDocument['attachments']>[number];
const sameAttachment = (
  left: AttachmentDescriptor,
  right: AttachmentDescriptor,
) =>
  left.locator === right.locator &&
  left.name === right.name &&
  left.mimeType === right.mimeType &&
  left.size === right.size;

const attachmentMetadata = (payload: GmailPart) =>
  receivedAttachments(payload).map(({ locator, name, mimeType, size }) => ({
    locator,
    name,
    mimeType,
    size,
  }));

const decodeStoredBodies = Schema.decodeUnknownEffect(
  Schema.Struct({
    stored: Schema.Array(Schema.String),
    excluded: Schema.Array(Schema.String),
  }),
);

// One page of a mailbox's online search, or why Gmail could not answer.
export type GmailSearchPage =
  | Readonly<{
      kind: 'found';
      messages: readonly GmailMessage[];
      next?: string;
    }>
  | Readonly<{
      kind: 'unavailable';
      reason: 'offline' | 'authentication' | 'failed';
    }>;

const searchUnavailable = (
  reason: Extract<GmailSearchPage, { kind: 'unavailable' }>['reason'],
): GmailSearchPage => ({ kind: 'unavailable', reason });

// A presentation's plain-text fallback after its rich view failed, still collapsible.
const readableOnly = ({
  readable,
  withoutQuotedHistory,
}: MessagePresentation): MessagePresentation => ({
  readable,
  ...(withoutQuotedHistory === undefined
    ? {}
    : { withoutQuotedHistory: { readable: withoutQuotedHistory.readable } }),
});

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

// A message listed in the exact view its reader belongs to.
export const viewMessage = (
  state: Extract<GmailInboxState, { kind: 'ready' }>,
  id: string,
  view: string,
) =>
  (view === 'INBOX'
    ? state.messages
    : state.views?.find(({ label }) => label === view)?.messages
  )?.find((message) => message.id === id);

// A message the Inbox or another opened view lists.
export const listedMessage = (
  state: Extract<GmailInboxState, { kind: 'ready' }>,
  id: string,
) =>
  [state.messages, ...(state.views ?? []).map((view) => view.messages)]
    .flat()
    .find((message) => message.id === id);

// The cached conversation for a message in this mailbox; the Inbox's metadata wins over other
// views', and listed metadata over search copies.
export function threadMessages(state: GmailInboxState, id: string) {
  if (state.kind !== 'ready') {
    return [];
  }
  const messages = new Map(
    [
      ...(state.found ?? []),
      ...(state.views ?? []).flatMap((view) => view.messages),
      ...state.messages,
    ].map((message) => [message.id, message]),
  );
  const opened = messages.get(id);
  return opened === undefined
    ? []
    : Arr.sort(
        [...messages.values()].filter(
          (message) =>
            message.id === opened.id ||
            (opened.threadId !== '' && message.threadId === opened.threadId),
        ),
        newestFirst,
      );
}

const labelsOf = (message: GmailMessage) =>
  message.labels ?? (message.unread ? ['INBOX', 'UNREAD'] : ['INBOX']);

const withLabels = (
  message: GmailMessage,
  labels: readonly string[],
): GmailMessage => ({ ...message, labels, unread: labels.includes('UNREAD') });

// Provider-confirmed messages with the requested changes applied in order. A message that left
// the cache returns only for a change that puts it back into the view, which is the Inbox, or
// a label, All Mail, Spam or Trash.
const organized = (
  messages: readonly GmailMessage[],
  pending: readonly PendingAction[],
  view = 'INBOX',
) => {
  const byId = new Map(
    messages.map((message) => [
      message.id,
      { message, labels: labelsOf(message) },
    ]),
  );
  for (const { action, message } of pending) {
    const before = labelsOf(message);
    const current =
      byId.get(message.id) ??
      (action.add.includes(view === allMail ? 'INBOX' : view) ||
      (!inView(view, before) && inView(view, relabel(before, action)))
        ? { message, labels: before }
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
      .filter(({ labels }) => inView(view, labels))
      .map(({ message }) => message),
    newestFirst,
  );
};

// The document with `change` applied to the Inbox's messages and to every other view's.
const everyView = (
  document: MailboxDocument,
  change: (
    view: string,
    messages: readonly GmailMessage[],
  ) => readonly GmailMessage[],
): MailboxDocument => ({
  ...document,
  messages: change('INBOX', document.messages),
  ...(document.views === undefined
    ? {}
    : {
        views: document.views.map((entry) => ({
          ...entry,
          messages: change(entry.label, entry.messages),
        })),
      }),
});

// Every message the document keeps, once, whether in the Inbox or in other views.
const cachedMessages = (document: MailboxDocument) => [
  ...new Map(
    [
      ...(document.views ?? []).flatMap((view) => view.messages),
      ...document.messages,
    ].map((message) => [message.id, message]),
  ).values(),
];

// History and delta cannot name the older message that now fits after a settlement removes one, so a
// full Inbox or view it shortened is listed again from the history already applied.
const withRefills = (
  before: MailboxDocument,
  after: MailboxDocument,
): MailboxDocument => {
  const { checkpoint } = before;
  const shortened =
    before.messages.length === cacheLimit && after.messages.length < cacheLimit;
  if (checkpoint.kind === 'graph-current' && shortened) {
    return {
      ...after,
      checkpoint: { kind: 'graph-listing', link: checkpoint.link },
    };
  }
  if (checkpoint.kind !== 'current' && checkpoint.kind !== 'backfill') {
    return after;
  }
  const inbox =
    checkpoint.kind === 'current' && shortened
      ? {
          checkpoint: {
            kind: 'backfill' as const,
            historyId: checkpoint.historyId,
            seen: [],
          },
        }
      : {};
  return {
    ...after,
    ...inbox,
    ...(after.views === undefined
      ? {}
      : {
          views: after.views.map((entry, index) =>
            entry.listing === undefined &&
            before.views?.[index]?.messages.length === cacheLimit &&
            entry.messages.length < cacheLimit
              ? {
                  ...entry,
                  listing: { historyId: checkpoint.historyId, seen: [] },
                }
              : entry,
          ),
        }),
  };
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
  // A confirmed message leaves every view it no longer belongs to and joins those it now does.
  return withRefills(document, {
    ...everyView(document, (view, messages) => {
      const cached = messages.find(({ id }) => id === head.message.id);
      if (!inView(view, confirmed)) {
        return cached === undefined
          ? messages
          : messages.filter(({ id }) => id !== head.message.id);
      }
      return merge(messages, [
        [head.message.id, withLabels(cached ?? head.message, confirmed)],
      ]).slice(0, cacheLimit);
    }),
    pending: rest,
  });
};

// Whether refreshed labels leave a document's labels and views as they were.
const sameListing = (before: MailboxDocument, after: MailboxDocument) => {
  const left = before.labels ?? [];
  const right = after.labels ?? [];
  return (
    after.labelsLimited === before.labelsLimited &&
    after.views?.length === before.views?.length &&
    left.length === right.length &&
    left.every(
      (label, index) =>
        label.id === right[index]?.id && label.name === right[index]?.name,
    )
  );
};

// Whether a mailbox with these labels still offers a view: its own labels, All Mail, Spam and Trash.
const offeredBy =
  (labels: readonly GmailLabel[]) =>
  ({ label }: Readonly<{ label: string }>) =>
    systemViews.some((view) => view === label) ||
    labels.some(({ id }) => id === label);

// The labels or folders a document lists, and whether some were left out.
const listedLabels = (document: MailboxDocument | undefined) => ({
  labels: document?.labels ?? [],
  ...(document?.labelsLimited === true ? { labelsLimited: true as const } : {}),
});

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

// ponytail: hosts have one store/process; same-process contenders share live attempt ownership.
// A multi-process host would need a storage-backed owner and explicit completion fencing.
const sendingAttempts = new Set<string>();
const sending = (head: PendingAction) => {
  const attempt = head.attempts?.at(-1);
  return attempt !== undefined && sendingAttempts.has(attempt.id);
};

// The oldest change after five completed unconfirmed attempts waits for Retry or Discard.
const blockedHead = (pending: readonly PendingAction[]) => {
  const [head] = pending;
  return head !== undefined && !sending(head) && attemptCount(head) >= 5
    ? head
    : undefined;
};

// The document once Gmail's current labels for the oldest change are known; a message Gmail no
// longer has leaves the cache.
const settleObserved = (
  document: MailboxDocument,
  head: PendingAction,
  labels: readonly string[] | undefined,
): MailboxDocument =>
  labels === undefined
    ? withRefills(
        document,
        everyView(settled(document, undefined), (_view, messages) =>
          messages.filter(({ id }) => id !== head.message.id),
        ),
      )
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
const withAttempt = (
  head: PendingAction,
  at: number,
  id: string,
): PendingAction => ({
  ...head,
  attempts: [
    ...(head.attempts ?? []),
    {
      id,
      at,
    },
  ],
});

const samePending = (left: PendingAction | undefined, right: PendingAction) =>
  left?.id === right.id && left?.message.id === right.message.id;

const sameProgress = (left: PendingAction, right: PendingAction) =>
  left.refused === right.refused &&
  left.retryFrom === right.retryFrom &&
  (left.attempts?.length ?? 0) === (right.attempts?.length ?? 0) &&
  (left.attempts ?? []).every(
    (attempt, index) =>
      attempt.id === right.attempts?.[index]?.id &&
      attempt.at === right.attempts?.[index]?.at,
  );

// `next` over the latest saved document: intents saved since `base` was read are added, and
// intents another store instance settled since then leave instead of being sent again.
const rebasedOnto = (
  base: MailboxDocument | undefined,
  saved: MailboxDocument,
  next: MailboxDocument,
) => {
  const known = new Set((base?.pending ?? []).map(({ id }) => id));
  const remaining = new Set((saved.pending ?? []).map(({ id }) => id));
  const advanced = (item: PendingAction) => {
    const previous = base?.pending?.find((entry) => samePending(entry, item));
    return previous !== undefined && !sameProgress(previous, item);
  };
  return withIntents(
    {
      ...next,
      pending: [
        // A stale label read or Discard cannot remove a newly prepared attempt or Retry.
        ...(saved.pending ?? []).filter(
          (item) =>
            advanced(item) &&
            !next.pending?.some((entry) => samePending(entry, item)),
        ),
        ...(next.pending ?? [])
          .filter(
            ({ id }) => id === undefined || !known.has(id) || remaining.has(id),
          )
          .map((item) => {
            const latest = saved.pending?.find((entry) =>
              samePending(entry, item),
            );
            // A CAS winner owns its newer attempt/refusal/retry state; a stale writer cannot
            // replace it with a competing preparation or an older copy of the pending head.
            return latest !== undefined && advanced(latest) ? latest : item;
          }),
      ],
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

// A listing that started again from its first page after Gmail rejected a saved page token, or
// after Graph expired a delta link.
const restartedListing = (
  previous: MailboxDocument | undefined,
  next: MailboxDocument,
) =>
  (previous?.checkpoint.kind === 'backfill' &&
    previous.checkpoint.pageToken !== undefined &&
    next.checkpoint.kind === 'backfill' &&
    next.checkpoint.pageToken === undefined) ||
  ((previous?.checkpoint.kind === 'graph-current' ||
    (previous?.checkpoint.kind === 'graph-listing' &&
      previous.checkpoint.link !== undefined)) &&
    next.checkpoint.kind === 'graph-listing' &&
    next.checkpoint.link === undefined);

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

export type OutgoingSend = Readonly<{
  segments: readonly MessageSegment[];
  threadId?: string;
}>;

// What became of a message handed to its provider: sent, accepted by SMTP with its Sent copy still
// to file ('accepted'), never delivered and safe to try again ('queued'), refused for good
// ('failed'), or possibly delivered without a confirmed answer.
export type SendOutcome =
  | Readonly<{ kind: 'sent'; message?: string }>
  | Readonly<{ kind: 'accepted' }>
  | Readonly<{ kind: 'queued' | 'failed'; problem: DeliveryProblem }>
  | Readonly<{ kind: 'unknown' }>;

const decodeSent = Schema.decodeUnknownOption(
  Schema.fromJsonString(Schema.Struct({ id: GmailId })),
);

// Native code rejects with 'delivery-unknown' once the request may have reached the provider; every
// other rejection happened before the provider could accept it.
const rejectionOutcomes = new Map<string, SendOutcome>([
  ['delivery-unknown', { kind: 'unknown' }],
  ['gmail-unavailable', { kind: 'failed', problem: 'authorization' }],
  // An SMTP server refused the password, or refused the message for good.
  ['smtp-refused', { kind: 'failed', problem: 'authorization' }],
  ['smtp-rejected', { kind: 'failed', problem: 'refused' }],
  ['mailbox-revoked', { kind: 'failed', problem: 'mailbox' }],
  // A mailbox generation refreshed meanwhile, as on returning to the app: nothing left the device,
  // so it waits. A connection that is really gone fails on the next pass, before any handoff.
  ['mailbox-invalidated', { kind: 'queued', problem: 'offline' }],
  ['attachment-missing', { kind: 'failed', problem: 'assets' }],
  ['too-large', { kind: 'failed', problem: 'too-large' }],
  ['locked', { kind: 'queued', problem: 'locked' }],
]);
export const sendRejection = (cause: unknown): SendOutcome =>
  rejectionOutcomes.get(rejectionCode(cause) ?? '') ?? {
    kind: 'queued',
    problem: 'offline',
  };

// The provider answered: a 2xx accepted the message. Refusals reported before accepting it are
// final, apart from rate limits; a server error may follow acceptance, so its outcome is unknown.
// Final refusals by status, apart from Gmail's rate-limit 403.
const refusedStatuses = new Map<number, SendOutcome>([
  [401, { kind: 'failed', problem: 'authorization' }],
  [403, { kind: 'failed', problem: 'authorization' }],
  [413, { kind: 'failed', problem: 'too-large' }],
  [429, { kind: 'queued', problem: 'rate-limited' }],
]);
const sendStatus = ({
  status,
  body,
}: Readonly<{ status: number; body: string }>): SendOutcome => {
  if (status >= 200 && status < 300) {
    return {
      kind: 'sent',
      ...Option.match(decodeSent(body), {
        onNone: () => ({}),
        onSome: ({ id }) => ({ message: id }),
      }),
    };
  }
  if (status === 403 && Option.isSome(rateLimited(body))) {
    return { kind: 'queued', problem: 'rate-limited' };
  }
  const refused = refusedStatuses.get(status);
  if (refused !== undefined) {
    return refused;
  }
  return status >= 400 && status < 500
    ? { kind: 'failed', problem: 'refused' }
    : { kind: 'unknown' };
};

// The `boundary` parameter of a Content-Type header, quoted or not.
const boundaryParameter = (contentType: string | undefined) =>
  /;\s*boundary="?(?<boundary>[^";]+)"?/iu.exec(contentType ?? '')?.[1];

interface WaitingBodyLoad {
  readonly connection: symbol | undefined;
  readonly rank: () => number;
  wake: (() => void) | undefined;
}

const createBodyLoadQueue = () => {
  let free = 4;
  const active = new Map<symbol, number>();
  const waiting = new Set<WaitingBodyLoad>();
  const first = () => {
    let next: WaitingBodyLoad | undefined = undefined;
    for (const entry of waiting) {
      if (
        (entry.connection === undefined ||
          (active.get(entry.connection) ?? 0) < 2) &&
        (next === undefined || entry.rank() < next.rank())
      ) {
        next = entry;
      }
    }
    return next;
  };
  const wakeWaiting = () => {
    if (free > 0) {
      first()?.wake?.();
    }
  };
  return {
    withPermit: <A, E, R>(
      effect: Effect.Effect<A, E, R>,
      connection?: symbol,
      rank: () => number = () => -1,
    ) =>
      Effect.uninterruptibleMask((restore) => {
        const entry: WaitingBodyLoad = { connection, rank, wake: undefined };
        waiting.add(entry);
        const acquire: Effect.Effect<A, E, R> = Effect.suspend(() => {
          if (free > 0 && first() === entry) {
            waiting.delete(entry);
            free -= 1;
            if (connection !== undefined) {
              active.set(connection, (active.get(connection) ?? 0) + 1);
            }
            wakeWaiting();
            return restore(effect).pipe(
              Effect.ensuring(
                Effect.sync(() => {
                  free += 1;
                  if (connection !== undefined) {
                    active.set(connection, (active.get(connection) ?? 1) - 1);
                  }
                  wakeWaiting();
                }),
              ),
            );
          }
          return restore(
            Effect.callback<undefined>((resume) => {
              entry.wake = () => {
                resume(Effect.undefined);
              };
              wakeWaiting();
              return Effect.sync(() => {
                waiting.delete(entry);
                wakeWaiting();
              });
            }),
          ).pipe(Effect.andThen(acquire));
        });
        return acquire;
      }),
  } as const;
};

// Body loads shared by every connection's Inbox on this device: four at a time account-wide,
// and speculative prefetch in any connection waits while an explicit read waits or runs.
export function createBodyLoads() {
  const idle = Latch.makeUnsafe(true);
  const waiting = new Map<symbol, () => void>();
  let interactive = 0;
  let cacheVersion = 0;
  const cacheListeners = new Set<() => void>();
  return {
    // Advances whenever a connection saves a body or prunes its cache. The limit is device-wide,
    // so saving one connection's body can also evict another's.
    cache: {
      getSnapshot: () => cacheVersion,
      subscribe: (listener: () => void) => {
        cacheListeners.add(listener);
        return () => {
          cacheListeners.delete(listener);
        };
      },
      changed: Effect.sync(() => {
        cacheVersion += 1;
        for (const listener of cacheListeners) {
          listener();
        }
      }),
    } as const,
    loads: createBodyLoadQueue(),
    // Remote Message Content requests, twelve at a time account-wide.
    remote: Semaphore.makeUnsafe(12),
    remoteImages: new Map<symbol, ReadonlyMap<string, RetainedRemote>>(),
    // Separate owner ledgers share one presentation budget without colliding on Gmail IDs.
    images: new Map<
      symbol,
      ReadonlyMap<string | symbol, { bytes: number; pixels: number }>
    >(),
    // Each ledger owner's way to present again the readers the budget held back.
    waiting,
    // A store that releases part of the budget offers it to the readers every other store holds back.
    released: (owner: symbol) => {
      for (const [other, present] of waiting) {
        if (other !== owner) {
          present();
        }
      }
    },
    idle,
    begin: Effect.sync(() => {
      interactive += 1;
      idle.closeUnsafe();
    }),
    end: Effect.sync(() => {
      interactive -= 1;
      if (interactive === 0) {
        idle.openUnsafe();
      }
    }),
  };
}
type BodyLoads = ReturnType<typeof createBodyLoads>;

const requireAttachments = (payload: ProviderPayload) =>
  payload.attachmentsPending === true
    ? Effect.fail(
        new SyncFailure({
          kind: payload.authentication === true ? 'authentication' : 'retry',
          cause: 'attachments',
          diagnostic: 'attachment metadata unavailable',
        }),
      )
    : Effect.succeed(payload);

export function createGmailInbox(
  native: NativeGmailMailbox,
  {
    removed,
    arrived,
    shared = createBodyLoads(),
    connection = '',
    provider = 'gmail',
  }: Readonly<{
    // Called after native code purged this device because another device removed it; the account
    // page, not the Inbox, explains what happened.
    removed?: (() => void) | undefined;
    // Called once a committed history page brought unread messages newly into the Inbox. Listing,
    // backfill and messages moved into the Inbox never arrive.
    arrived?:
      | ((scope: MailboxScope, messages: readonly GmailMessage[]) => void)
      | undefined;
    shared?: Readonly<BodyLoads>;
    connection?: string;
    // Microsoft mail is read, organized and sent through Graph.
    provider?: MailGrantProvider;
  }> = {},
) {
  const graph =
    provider === 'microsoft-graph' ? createGraphReader(native) : undefined;
  // One Gmail read; Gmail refusing a listing's page token is GmailInvalidPage.
  const gmail =
    (scope: MailboxScope) =>
    <A>(
      path: string,
      query: ReadonlyArray<readonly [string, string]>,
      decode: (body: unknown) => Effect.Effect<A, Schema.SchemaError>,
    ) =>
      providerRead(
        (signal) => native.gmailRequest(path, query, { ...scope, signal }),
        (status) =>
          status === 400 &&
          path === 'messages' &&
          query.some(([name]) => name === 'pageToken'),
        decode,
      );

  // Search results keep a message `anywhere` in Gmail; the Inbox keeps only its own.
  const metadata = (scope: MailboxScope, id: string, anywhere = false) =>
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
        const received =
          anywhere || inInbox(labels)
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
  const fetchAll = (
    scope: MailboxScope,
    ids: readonly string[],
    anywhere = false,
  ) =>
    Effect.forEach(ids, (id) => metadata(scope, id, anywhere), {
      concurrency: 4,
    });

  // A new listing starts from the current history ID, or from the still-valid one it was given,
  // so changes during it are replayed after. Cached messages stay visible meanwhile; pending
  // changes, labels and other views carry over from the document it replaces. Without a valid
  // history ID, the other views are listed again.
  const startListing = Effect.fnUntraced(function* (
    scope: MailboxScope,
    previous: MailboxDocument | undefined,
    from?: string,
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
      messages: previous?.messages ?? [],
      checkpoint: {
        kind: 'backfill',
        historyId: from ?? profile.historyId,
        seen: [],
      },
      ...(from === undefined && previous?.views !== undefined
        ? {
            views: previous.views.map((entry) => ({
              ...entry,
              listing: { historyId: profile.historyId, seen: [] },
            })),
          }
        : {}),
    };
  });

  type Step = Effect.fn.Return<
    Option.Option<MailboxDocument>,
    SyncFailure | GmailNotFound | GmailInvalidPage
  >;
  type ViewEntry = NonNullable<MailboxDocument['views']>[number];
  type ListedView = ViewEntry &
    Readonly<{ listing: NonNullable<ViewEntry['listing']> }>;

  // The new Inbox mail the page being committed brought; the next commit reports it.
  let arrivals: readonly GmailMessage[] = [];

  // Reads and reconciles one page for the Inbox or another Gmail view. Callers own their
  // checkpoint publication and recovery when Gmail rejects a page token.
  const readListingPage = Effect.fnUntraced(function* (
    scope: MailboxScope,
    { label: view, messages, listing }: ListedView,
  ) {
    const page = yield* gmail(scope)(
      'messages',
      [
        ...(view === allMail ? [] : [['labelIds', view] as const]),
        // Gmail leaves Spam and Trash out of a listing unless it is asked to include them.
        ...(view === 'SPAM' || view === 'TRASH'
          ? [['includeSpamTrash', 'true'] as const]
          : []),
        ['maxResults', String(pageSize)],
        ...(listing.pageToken === undefined
          ? []
          : [['pageToken', listing.pageToken] as const]),
      ],
      decodeList,
    );
    const ids = (page.messages ?? []).map(({ id }) => id);
    const seen = Arr.dedupe([...listing.seen, ...ids]);
    const { nextPageToken } = page;
    const found = (yield* fetchAll(scope, ids, view !== 'INBOX')).map(
      ([id, message]) =>
        [
          id,
          message !== undefined && inView(view, labelsOf(message))
            ? message
            : undefined,
        ] as const,
    );
    return {
      ...listedPage(messages, found, {
        seen,
        more: nextPageToken !== undefined,
      }),
      seen,
      nextPageToken,
    };
  });

  // Lists the next Inbox page from a backfill checkpoint.
  const continueListing = Effect.fnUntraced(function* (
    scope: MailboxScope,
    document: MailboxDocument,
    checkpoint: Extract<MailboxDocument['checkpoint'], { kind: 'backfill' }>,
  ): Step {
    const page = yield* readListingPage(scope, {
      label: 'INBOX',
      messages: document.messages,
      listing: checkpoint,
    }).pipe(
      Effect.asSome,
      Effect.catchTag('GmailInvalidPage', () => Effect.succeedNone),
    );
    if (Option.isNone(page)) {
      return Option.some(
        yield* startListing(scope, document, checkpoint.historyId),
      );
    }
    const { nextPageToken, seen, messages, done } = page.value;
    return Option.some({
      ...document,
      messages,
      checkpoint:
        done || nextPageToken === undefined
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
      return Option.some(yield* startListing(scope, document));
    }
    const records = history.value.history ?? [];
    const historyId = nextHistoryId(history.value, records);
    if (records.length === 0 && historyId === checkpoint.historyId) {
      return Option.none();
    }
    const { deleted, changed } = historyChanges(records);
    const fetched = yield* fetchAll(
      scope,
      changed,
      document.views !== undefined,
    );
    const added = new Set(
      records.flatMap((record) =>
        (record.messagesAdded ?? []).map(({ message }) => message.id),
      ),
    );
    arrivals = fetched.flatMap(([id, message]) =>
      message !== undefined &&
      added.has(id) &&
      message.unread &&
      inInbox(labelsOf(message))
        ? [message]
        : [],
    );
    // History cannot name the unchanged older message that now fits after an entry leaves, so
    // a full view that lost one is listed again.
    const refilled = new Set<string>();
    const next = everyView(document, (view, before) => {
      const after = merge(
        before,
        fetched.map(([id, message]) => [
          id,
          message !== undefined && inView(view, labelsOf(message))
            ? message
            : undefined,
        ]),
        deleted,
      );
      const remaining = new Set(after.map(({ id }) => id));
      if (
        before.length === cacheLimit &&
        before.some(({ id }) => !remaining.has(id))
      ) {
        refilled.add(view);
      }
      return after.slice(0, cacheLimit);
    });
    const updated: MailboxDocument = {
      ...next,
      ...(next.views === undefined
        ? {}
        : {
            views: next.views.map((entry) =>
              entry.listing === undefined && refilled.has(entry.label)
                ? { ...entry, listing: { historyId, seen: [] } }
                : entry,
            ),
          }),
    };
    if (refilled.has('INBOX')) {
      return Option.some(yield* startListing(scope, updated, historyId));
    }
    return Option.some({
      ...updated,
      checkpoint: { kind: 'current', historyId },
    });
  });

  // Views a reader asked to open, in request order, until the saved document lists each first;
  // and views whose read failed during this synchronization, which wait for the next one.
  const requestedViews = new Set<string>();
  const failedViews = new Set<string>();
  // Window lifetimes protect shown views from another window's LRU eviction.
  const activeViews = new Map<symbol, string>();
  const retainedViews = (views: NonNullable<MailboxDocument['views']>) => {
    // A lease on a view the mailbox no longer has, such as a removed label's, protects nothing.
    const active = new Set([
      ...[...activeViews.values()].filter((label) =>
        views.some((view) => view.label === label),
      ),
      ...requestedViews,
    ]);
    let spare = Math.max(cachedViews, active.size) - active.size;
    return views.filter(({ label }) => {
      if (active.has(label)) {
        return true;
      }
      if (spare === 0) {
        return false;
      }
      spare -= 1;
      return true;
    });
  };

  // Lists the next page of a view, as continueListing does for the Inbox.
  const continueView = Effect.fnUntraced(function* (
    scope: MailboxScope,
    document: MailboxDocument,
    entry: ListedView,
  ): Step {
    const { listing } = entry;
    const { messages, done, seen, nextPageToken } = yield* readListingPage(
      scope,
      entry,
    );
    const next: ViewEntry = {
      label: entry.label,
      messages,
      ...(done || nextPageToken === undefined
        ? {}
        : {
            listing: {
              historyId: listing.historyId,
              pageToken: nextPageToken,
              seen,
            },
          }),
    };
    return Option.some({
      ...document,
      // History may have advanced while this listing was interrupted. Preserve any earlier
      // replay another completed listing needs so unseen additions discarded by listedPage return.
      ...(next.listing === undefined
        ? {
            checkpoint: {
              kind: 'current' as const,
              historyId:
                document.checkpoint.kind === 'current' &&
                BigInt(document.checkpoint.historyId) <
                  BigInt(listing.historyId)
                  ? document.checkpoint.historyId
                  : listing.historyId,
            },
          }
        : {}),
      views: (document.views ?? []).map((view) =>
        view.label === entry.label ? next : view,
      ),
    });
  });

  // The document with the first requested view most recently opened, or none once every
  // requested view is.
  const openedView = (document: MailboxDocument, historyId: string) => {
    for (const requested of requestedViews) {
      const views = document.views ?? [];
      if (views[0]?.label !== requested) {
        const entry = views.find(({ label }) => label === requested) ?? {
          label: requested,
          messages: [],
          listing: { historyId, seen: [] },
        };
        return {
          ...document,
          views: retainedViews([
            entry,
            ...views.filter(({ label }) => label !== requested),
          ]),
        };
      }
      requestedViews.delete(requested);
    }
    return undefined;
  };

  // The next page of a view, or none when Gmail cannot list it now: the view keeps its saved
  // messages until the next synchronization, which lists it from its first page when Gmail
  // refused its page token.
  const listView = (
    scope: MailboxScope,
    document: MailboxDocument,
    listing: ListedView,
  ) => {
    const failed = Effect.sync(() => {
      failedViews.add(listing.label);
    });
    return continueView(scope, document, listing).pipe(
      Effect.catchTags({
        GmailNotFound: () => failed.pipe(Effect.as(Option.none())),
        GmailInvalidPage: () =>
          failed.pipe(
            Effect.as(
              Option.some({
                ...document,
                views: (document.views ?? []).map((view) =>
                  view === listing
                    ? {
                        ...view,
                        listing: {
                          historyId: listing.listing.historyId,
                          seen: [],
                        },
                      }
                    : view,
                ),
              }),
            ),
          ),
        SyncFailure: (failure) =>
          failure.kind === 'retry'
            ? failed.pipe(Effect.as(Option.none()))
            : Effect.fail(failure),
      }),
    );
  };

  // The next document to commit, or none when the cache is current. After the Inbox's own
  // listing, a requested view becomes the most recently opened and the views are listed, before
  // the history that keeps them all current.
  const advance = (
    scope: MailboxScope,
    document: MailboxDocument | undefined,
    step: number,
  ): Effect.Effect<
    Option.Option<MailboxDocument>,
    SyncFailure | GmailNotFound | GmailInvalidPage
  > => {
    if (graph !== undefined) {
      return graph.advance(scope, document, step);
    }
    if (document === undefined) {
      return startListing(scope, undefined).pipe(Effect.asSome);
    }
    const { checkpoint } = document;
    if (checkpoint.kind === 'backfill') {
      return continueListing(scope, document, checkpoint);
    }
    // A cache written before messages kept their labels needs a fresh Inbox listing.
    if (
      checkpoint.kind !== 'current' ||
      document.messages.some(({ labels }) => labels === undefined)
    ) {
      return startListing(scope, document).pipe(Effect.asSome);
    }
    const opened = openedView(document, checkpoint.historyId);
    if (opened !== undefined) {
      return Effect.succeedSome(opened);
    }
    const listing = document.views?.find(
      (view): view is ListedView =>
        view.listing !== undefined && !failedViews.has(view.label),
    );
    if (listing !== undefined) {
      return listView(scope, document, listing).pipe(
        Effect.filterOrElse(Option.isSome, () =>
          advance(scope, document, step),
        ),
      );
    }
    return applyHistory(scope, document, checkpoint);
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
  // Online search results, by Gmail ID, held for the reader until the open Inbox closes. They are
  // never committed to the cache, and their bodies are read from Gmail without being saved.
  // ponytail: grows only with the result pages the person asks for; evict when that matters.
  const found = new Map<string, GmailMessage>();
  // Membership at the last durable publication, before any later optimistic hiding.
  let settledMessages = new Set<string>();
  // A requested view waits for the synchronization it started; a saved view still being listed
  // after a synchronization could not be read.
  const viewStatus = (entry?: ViewEntry): GmailView['status'] => {
    if (entry === undefined) {
      return sync === 'retry' || sync === 'authentication'
        ? 'failed'
        : 'syncing';
    }
    if (
      failedViews.has(entry.label) ||
      (entry.listing !== undefined && sync !== 'syncing')
    ) {
      return 'failed';
    }
    return entry.listing === undefined ? 'current' : 'syncing';
  };
  // The requested and saved views with the requested changes applied, most recent first, each
  // message claimed for organizing; none when no view was opened.
  const renderedViews = (
    document: MailboxDocument | undefined,
    changes: readonly PendingAction[],
  ): Readonly<{ views?: readonly GmailView[] }> => {
    const saved = document?.views ?? [];
    const views: GmailView[] = [
      ...[...requestedViews]
        .filter((label) => saved.every((entry) => entry.label !== label))
        .map((label) => ({
          label,
          messages: [],
          status: viewStatus(),
          limited: true as const,
        })),
      ...saved.map((entry) => ({
        label: entry.label,
        messages: organized(entry.messages, changes, entry.label),
        status: viewStatus(entry),
        limited: true as const,
      })),
    ];
    claim(views.flatMap((view) => view.messages));
    return views.length === 0 ? {} : { views };
  };
  const render = (): Extract<GmailInboxState, { kind: 'ready' }> => {
    const document = shown?.document;
    const durable = document?.pending ?? [];
    const changes = [...durable, ...queued.map((item) => item.pending)];
    const messages = organized(document?.messages ?? [], changes);
    claim(messages);
    return {
      kind: 'ready',
      messages,
      ...(found.size === 0 ? {} : { found: [...found.values()] }),
      ...renderedViews(document, changes),
      sync: shownSyncState(),
      ...listedLabels(document),
      ...(graph === undefined
        ? {}
        : { unavailableActions: graph.unavailableActions() }),
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
  const imageOwner = Symbol('mailbox-images');
  const imageReservations = new Map<
    string | symbol,
    { bytes: number; pixels: number }
  >();
  // Readers whose inline images the shared budget withheld, presented again when it frees.
  const limitedReaders = new Set<string | symbol>();
  const readingBodies = new Map<string, Promise<void>>();
  const remoteContent = createRemoteContentLoader(native, {
    connection,
    shared,
    scope: readableScope,
    ...shownRemote({ viewReaders, viewBodies, bodies, legacyReaders }),
    inlineImages: (id) => documents.get(id)?.images?.admitted.length ?? 0,
    present: prepareRemotePresentations,
    notify: () => {
      notify(state);
    },
  });
  // Each opened message's attachment downloads by `id\nlocator`. A saved file belongs to the
  // mailbox scope it was saved in and is deleted when its message leaves memory.
  type Download = Readonly<{
    state: AttachmentState;
    saved?: Readonly<{ scope: MailboxScope; file: string }>;
    abort?: AbortController;
  }>;
  const downloads = new Map<string, Download>();
  const attachmentViews = new Map<string, readonly ReceivedAttachment[]>();
  const discardSaved = (
    saved: Readonly<{ scope: MailboxScope; file: string }> | undefined,
  ) => {
    if (saved !== undefined) {
      void runLogged(
        Effect.tryPromise({
          try: () => native.discardAttachment(saved.scope, saved.file),
          catch: (cause) => rejected(cause, 'failed'),
        }).pipe(
          Effect.catchTag('SyncFailure', ({ diagnostic }) =>
            Effect.logError('Attachment was not discarded:', diagnostic),
          ),
        ),
      );
    }
  };
  const discardDownloads = (id?: string) => {
    for (const [key, download] of downloads) {
      if (id === undefined || key.startsWith(`${id}\n`)) {
        downloads.delete(key);
        download.abort?.abort();
        discardSaved(download.saved);
      }
    }
    if (id === undefined) {
      attachmentViews.clear();
    } else {
      attachmentViews.delete(id);
    }
  };
  const releaseBody = (id: string) => {
    discardDownloads(id);
    remoteContent.release(id);
    bodies.delete(id);
    documents.delete(id);
    imageReservations.delete(id);
    limitedReaders.delete(id);
    for (const [reader, message] of viewReaders) {
      if (message === id) {
        viewBodies.delete(reader);
        imageReservations.delete(reader);
        limitedReaders.delete(reader);
      }
    }
    presentWaiting();
    shared.released(imageOwner);
  };

  // Search readers keep their bodies after Inbox removal, but removal still ends file ownership.
  const settle = (next: Sync) => {
    sync = next;
    const rendered = render();
    const listed = new Set(
      [
        ...rendered.messages,
        ...(rendered.views ?? []).flatMap((view) => view.messages),
      ].map(({ id }) => id),
    );
    const previouslyListed = settledMessages;
    settledMessages = listed;
    for (const id of bodies.keys()) {
      if (!listed.has(id)) {
        if (!found.has(id)) {
          releaseBody(id);
        } else if (previouslyListed.has(id)) {
          discardDownloads(id);
        }
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
  // Bodies of messages that left the cached Inbox and every other cached view leave the device
  // with them; the recent working set's bodies stay protected as far as they fit. A failed prune is retried at the end of the
  // next synchronization, even when it commits nothing.
  const retainBodies = (
    { address, generation, revision }: Cache,
    document: MailboxDocument | undefined,
  ) =>
    referenceInstant.pipe(
      Effect.flatMap((reference) =>
        Effect.tryPromise({
          try: () =>
            native.retainMessageBodies(
              { address, generation, revision },
              (document === undefined ? [] : cachedMessages(document)).map(
                ({ id }) => id,
              ),
              // Other views' bodies stay, but only the Inbox's recent working set is protected.
              recentWorkingSet(document?.messages ?? [], reference),
            ),
          catch: (cause) => rejected(cause, 'failed'),
        }),
      ),
      Effect.andThen(shared.cache.changed),
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
    yield* retainBodies(committed, document);
    return committed;
  });

  // The mailbox whose cache the current Inbox shows; body reads use its native generation.
  let opened: MailboxScope | undefined = undefined;
  // Advances when the open Inbox closes, so a body read for the previous owner is dropped.
  let owner = 0;
  // Connection and account admission happen together, so all waiting reads can be reprioritized.
  const bodyLoadConnection = Symbol('body-load-connection');
  // The order a reader wants its messages' bodies in; unranked loads go first.
  let bodyRanks: ReadonlyMap<string, number> = new Map();
  const bodyLoads = {
    withPermit: <A, E, R>(
      effect: Effect.Effect<A, E, R>,
      rank: () => number = () => -1,
    ) => shared.loads.withPermit(effect, bodyLoadConnection, rank),
  };
  const speculativeBodies = new Map<string, Deferred.Deferred<undefined>>();

  const releaseLegacyReader = (id: string) => {
    const previous = legacyReaders.get(id) ?? 1;
    const reservation = imageReservations.get(id);
    if (previous === 1) {
      legacyReaders.delete(id);
      imageReservations.delete(id);
      limitedReaders.delete(id);
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
    presentWaiting();
    shared.released(imageOwner);
  };

  const reservedImages = (key: string | symbol) => {
    let bytes = 0;
    let pixels = 0;
    for (const reservations of shared.images.values()) {
      for (const [other, reserved] of reservations) {
        if (reservations !== imageReservations || other !== key) {
          bytes += reserved.bytes;
          pixels += reserved.pixels;
        }
      }
    }
    return { bytes, pixels };
  };

  // Admits a body's inline images in document order while the budget shared by every displayed
  // body allows; the rest stay placeholders.
  const present = (key: string | symbol, document: BodyDocument, count = 1) => {
    const { id } = document;
    let { bytes, pixels } = reservedImages(key);
    shared.images.set(imageOwner, imageReservations);
    shared.waiting.set(imageOwner, presentWaiting);
    let occurrences: readonly string[] = [];
    let remoteOccurrences: readonly string[] = [];
    try {
      // A body without HTML has no image references.
      const sanitized = sanitizeHtml(document.html ?? '');
      occurrences = sanitized.contentIdOccurrences;
      remoteOccurrences = sanitized.remoteImages;
    } catch {
      imageReservations.delete(key);
      limitedReaders.delete(key);
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
      const size = decodedSize(image.data) * occurrencesCount;
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
    const remote = remoteContent.admit(id, remoteOccurrences, {
      bytes,
      pixels,
      count,
    });
    imageReservations.set(key, {
      bytes: reservedBytes + remote.bytes,
      pixels: reservedPixels + remote.pixels,
    });
    if (visibleImages.length < (document.images?.admitted.length ?? 0)) {
      limitedReaders.add(key);
    } else {
      limitedReaders.delete(key);
    }
    return presentation(document, visibleImages, remote.admitted);
  };

  const refreshedRemotePresentation = (
    previous: Extract<MessageBodyState, { kind: 'ready' }>,
    next: MessagePresentation,
  ): MessageBodyState => {
    // Replacing an unchanged presentation would make measured readers retry deferred cache hits.
    if (
      previous.presentation.rich?.document === next.rich?.document &&
      previous.presentation.rich?.initialDocument === next.rich?.initialDocument
    ) {
      return previous;
    }
    return { kind: 'ready', presentation: next };
  };

  // Updates every reader before the caller publishes its reconciled remote state.
  function prepareRemotePresentations(id: string) {
    const document = documents.get(id);
    const body = bodies.get(id);
    if (document === undefined || body?.kind !== 'ready') {
      return false;
    }
    let legacyChanged = false;
    const count = legacyReaders.get(id) ?? 0;
    if (count > 0 && body.presentation.rich !== undefined) {
      const next = refreshedRemotePresentation(
        body,
        present(id, document, count),
      );
      legacyChanged = next !== body;
      bodies.set(id, next);
    }
    // A terminal fallback stays plain until a fresh body or reader prepares a rich presentation.
    const rich = [...viewReaders].flatMap(([reader, message]) => {
      const view = viewBodies.get(reader);
      return message === id &&
        view?.kind === 'ready' &&
        view.presentation.rich !== undefined
        ? [[reader, view] as const]
        : [];
    });
    const changed = rich.map(([reader, view]) => {
      const next = refreshedRemotePresentation(view, present(reader, document));
      viewBodies.set(reader, next);
      return next !== view;
    });
    return [legacyChanged, ...changed].includes(true);
  }

  // A released reservation lets the readers the budget held back, of any message, show their images.
  const presentLimited = () => {
    let changed = false;
    const refresh = (key: string | symbol, id: string, count = 1) => {
      const previous =
        typeof key === 'symbol' ? viewBodies.get(key) : bodies.get(key);
      const document = documents.get(id);
      if (
        !limitedReaders.has(key) ||
        document === undefined ||
        previous?.kind !== 'ready' ||
        previous.presentation.rich === undefined
      ) {
        return previous;
      }
      const next = refreshedRemotePresentation(
        previous,
        present(key, document, count),
      );
      changed ||= next !== previous;
      return next;
    };
    for (const [reader, id] of viewReaders) {
      const next = refresh(reader, id);
      if (next !== undefined) {
        viewBodies.set(reader, next);
      }
    }
    for (const [id, count] of legacyReaders) {
      const next = refresh(id, id, count);
      if (next !== undefined) {
        bodies.set(id, next);
      }
    }
    return changed;
  };
  // Another store released part of the budget.
  function presentWaiting() {
    if (presentLimited()) {
      notify(state);
    }
  }

  // A closing reader's view and reservation go before reconciliation, so the readers that remain
  // are presented again with the budget it held.
  const releaseReader = (id: string, reader: symbol | undefined) => {
    if (reader === undefined) {
      releaseLegacyReader(id);
      if (!legacyReaders.has(id)) {
        remoteContent.withdraw(id, id);
      }
    } else {
      viewReaders.delete(reader);
      viewBodies.delete(reader);
      imageReservations.delete(reader);
      limitedReaders.delete(reader);
      remoteContent.withdraw(id, reader);
    }
    if (remoteContent.has(id)) {
      prepareRemotePresentations(id);
      notify(state);
    }
  };

  // A refreshed body keeps a download only while its attachment's descriptor is unchanged; a
  // changed or removed attachment at the same position loses its saved file.
  const discardChangedDownloads = (id: string, document: BodyDocument) => {
    const previous = documents.get(id)?.attachments ?? [];
    const kept = new Set(
      (document.attachments ?? [])
        .filter((next) =>
          previous.some((before) => sameAttachment(before, next)),
        )
        .map(({ locator }) => locator),
    );
    for (const [key, download] of downloads) {
      if (key.startsWith(`${id}\n`) && !kept.has(key.slice(id.length + 1))) {
        downloads.delete(key);
        download.abort?.abort();
        discardSaved(download.saved);
      }
    }
  };

  const prepareReaders = (id: string, document: BodyDocument) => {
    discardChangedDownloads(id, document);
    documents.set(id, document);
    attachmentViews.delete(id);
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
    state.kind === 'ready' && listedMessage(state, id) !== undefined;
  // The reader also opens online search results, which the cache never keeps.
  const readable = (id: string) =>
    state.kind === 'ready' && (listed(id) || found.has(id));
  // The mailbox an open reader of a readable message reads it from.
  function readableScope(id: string) {
    return readers.has(id) && readable(id) ? opened : undefined;
  }

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

  // A part's bytes and their exact size: inline in the message, or served separately when Gmail
  // splits a large part. Only complete data matching Gmail's declared size is returned.
  const gmailPartData = Effect.fnUntraced(function* (
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
    return { data: downloaded.data, size: downloaded.size };
  });

  // Graph serves only attachments separately; its body parts are inline, as Gmail's small ones.
  const partData = (scope: MailboxScope, id: string, part: GmailPart) => {
    const attachmentId =
      graph === undefined ? undefined : part.body?.attachmentId;
    return graph === undefined || attachmentId === undefined
      ? gmailPartData(scope, id, part)
      : graph.partData(scope, id, attachmentId);
  };

  const fetchPart = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
    part: GmailPart,
  ) {
    const { data } = yield* partData(scope, id, part);
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

  // Graph reads inline images only for a full read, as Gmail returns part data only then.
  const fullMessage = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
    query: ReadonlyArray<readonly [string, string]>,
  ): Effect.fn.Return<ProviderPayload, SyncFailure | GmailNotFound> {
    if (graph !== undefined) {
      return yield* graph.fullMessage(scope, id);
    }
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

  // An explicit read's full message. MIME metadata over its budgets is never parsed, so the body
  // fails instead of stalling the reader; prefetch leaves such a message on demand.
  const boundedMessage = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
  ) {
    const payload = yield* fullMessage(scope, id, [['format', 'full']]);
    if (!withinMetadataBudgets(payload)) {
      return yield* new SyncFailure({
        kind: payload.authentication === true ? 'authentication' : 'failed',
        cause: 'metadata',
        diagnostic: 'oversized MIME metadata',
      });
    }
    return payload;
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
          Effect.catchIf(rejectedGrant, () =>
            Effect.succeed('authentication' as const),
          ),
          Effect.orElseSucceed(() => ({ data: undefined, size: undefined })),
        );
        if (attempt === 'authentication') {
          return { ...tally.result(), complete: false, authentication: true };
        }
        // Graph's listed size includes overhead. Actual bytes must fit the reservation, then
        // image decoding checks their exact size instead of the approximate metadata size.
        const reserved = part.body?.size ?? 0;
        const received = attempt.size ?? reserved;
        tally.receive(
          contentId,
          { ...part, body: { ...part.body, size: received } },
          received <= reserved ? attempt.data : undefined,
        );
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
    const payload = yield* boundedMessage(scope, id);
    const { html, text, path } = bodyParts(payload);
    const document: BodyDocument = {
      version: 2,
      id,
      ...(payload.attachmentsPending === true
        ? {}
        : { attachments: attachmentMetadata(payload) }),
      headers: responseHeadersOf(payload),
      ...(text === undefined
        ? {}
        : { text: yield* fetchPart(scope, id, text) }),
      ...(html === undefined
        ? {}
        : { html: yield* fetchPart(scope, id, html) }),
    };
    if (payload.attachmentsPending === true) {
      return { document, authentication: payload.authentication === true };
    }
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

  // A cached body opened explicitly before its inline images were resolved, or before its
  // attachment metadata was kept, completes them now when Gmail answers; offline, it opens with
  // placeholders and no attachment list.
  const completeImages = Effect.fnUntraced(function* (
    scope: MailboxScope,
    document: BodyDocument,
  ) {
    const references = contentIdsOf(document);
    const needsImages = document.images === undefined && references.length > 0;
    // Bodies cached before headers were kept read them too, so the message can be answered.
    const needsAttachments =
      document.attachments === undefined || document.headers === undefined;
    if (!needsImages && !needsAttachments) {
      return { document, changed: false, authentication: false };
    }
    const payload = yield* boundedMessage(scope, document.id).pipe(
      Effect.flatMap(requireAttachments),
    );
    const withList = needsAttachments
      ? {
          ...document,
          attachments: document.attachments ?? attachmentMetadata(payload),
          headers: responseHeadersOf(payload),
        }
      : document;
    if (!needsImages) {
      return { document: withList, changed: true, authentication: false };
    }
    const resolved = yield* resolveImages(scope, document.id, {
      path: bodyParts(payload).path,
      references,
    });
    return resolved.complete
      ? {
          document: { ...withList, images: resolved.images },
          changed: true,
          authentication: false,
        }
      : {
          document: withList,
          changed: needsAttachments,
          authentication: resolved.authentication,
        };
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
      tier: BodyTier;
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
                  Effect.tap(({ admitted }) =>
                    admitted ? shared.cache.changed : Effect.void,
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

  // Saves an Inbox message's body; an online search result is shown without being kept.
  const keepBody = (
    document: BodyDocument,
    admission: Parameters<typeof store>[1],
  ) =>
    listed(document.id)
      ? store(document, admission)
      : Effect.succeed({ admitted: false });

  // The cached body when this device has one, otherwise Gmail's, which is then cached when it fits.
  // Images a rejected grant left unresolved are read again after Gmail is authorized.
  const imagesAwaitingGmail = new Set<string>();
  // Publishes the Inbox's authentication state for the reader that met a rejected grant.
  const askForGmail = (reading: number, id: string) =>
    Effect.sync(() => {
      if (owner === reading && readable(id)) {
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
    if (reading !== owner || !readable(id)) {
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
        yield* keepBody(completed.document, { scope, tier, reading }).pipe(
          Effect.ignore,
        );
      }
      return completed.document;
    }
    const { document, authentication } = yield* fetchBody(scope, id);
    if (authentication) {
      yield* askForGmail(reading, id);
    }
    yield* keepBody(document, { scope, tier, reading }).pipe(
      // A body that could not be kept is still shown, unless its mailbox changed meanwhile.
      Effect.catchIf(
        (failure) => failure.kind !== 'invalidated',
        (failure) =>
          Effect.logError('Message body was not cached:', failure.diagnostic),
      ),
    );
    return document;
  });

  const setDownload = (
    id: string,
    locator: string,
    // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- The controller is only kept to abort.
    next: Download | undefined,
  ) => {
    const key = attachmentKey(id, locator);
    if (next === undefined) {
      downloads.delete(key);
    } else {
      downloads.set(key, next);
    }
    attachmentViews.delete(id);
    notify(state);
  };

  // A received attachment's bytes from Gmail, read again from the current message so a changed
  // or removed attachment is never mistaken for the listed one. Only base64url data decoding to
  // exactly its size is returned: Gmail's declared size, or the decoded size of Graph's bytes.
  const fetchAttachment = Effect.fnUntraced(function* (
    scope: MailboxScope,
    id: string,
    listedAttachment: NonNullable<BodyDocument['attachments']>[number],
  ) {
    // Locating the attachment needs no inline images from Graph.
    const payload = yield* boundedMessage(scope, id).pipe(
      Effect.flatMap(requireAttachments),
    );
    const current = receivedAttachments(payload).find((candidate) =>
      sameAttachment(candidate, listedAttachment),
    );
    if (current === undefined) {
      return yield* new GmailNotFound();
    }
    const downloaded = yield* partData(scope, id, current.part).pipe(
      Effect.catchIf(
        (failure) => failure.cause === 'body size',
        () => Effect.fail(new AttachmentDamaged()),
      ),
    );
    if (
      downloaded.size === undefined ||
      downloaded.size > attachmentLimit ||
      partBytes(downloaded.data, downloaded.size) === undefined
    ) {
      return yield* new AttachmentDamaged();
    }
    return { data: downloaded.data, size: downloaded.size };
  });

  // Downloads one listed attachment into private temporary storage. Cancelling, closing the
  // message or a change of mailbox drops the result and deletes any file saved for it.
  const downloadAttachment = (id: string, locator: string) => {
    const scope = opened;
    const listedAttachment = documents
      .get(id)
      ?.attachments?.find((attachment) => attachment.locator === locator);
    const current = downloads.get(attachmentKey(id, locator))?.state.kind;
    if (
      scope === undefined ||
      !readable(id) ||
      listedAttachment === undefined ||
      listedAttachment.size > attachmentLimit ||
      current === 'downloading' ||
      current === 'downloaded'
    ) {
      return Promise.resolve();
    }
    const reading = owner;
    const abort = new AbortController();
    setDownload(id, locator, { state: attachmentStates.downloading, abort });
    const live = () =>
      owner === reading &&
      downloads.get(attachmentKey(id, locator))?.abort === abort;
    // Saving and recording the file cannot be interrupted, so a cancelled download still deletes it.
    const save = ({ data, size }: Readonly<{ data: string; size: number }>) =>
      Effect.tryPromise({
        try: () =>
          native.saveAttachment(scope, {
            name: listedAttachment.name,
            data,
            size,
          }),
        catch: (cause) => rejected(cause, 'failed'),
      }).pipe(
        Effect.flatMap(decodeSavedAttachment),
        Effect.mapError((failure) =>
          Schema.isSchemaError(failure)
            ? malformed(failure, 'failed')
            : failure,
        ),
        Effect.flatMap(({ file }) =>
          Effect.sync(() => {
            const saved = { scope, file };
            if (live()) {
              setDownload(id, locator, {
                state: attachmentStates.downloaded,
                saved,
              });
            } else {
              discardSaved(saved);
            }
          }),
        ),
        Effect.uninterruptible,
      );
    const program = Effect.acquireUseRelease(
      shared.begin,
      () => bodyLoads.withPermit(fetchAttachment(scope, id, listedAttachment)),
      () => shared.end,
    ).pipe(
      Effect.flatMap(save),
      Effect.catchTags({
        GmailNotFound: () => Effect.succeed(unavailable('missing')),
        AttachmentDamaged: () =>
          Effect.logError('Attachment download failed:', 'damaged').pipe(
            Effect.as(unavailable('damaged')),
          ),
        SyncFailure: ({ kind, diagnostic }) => {
          if (kind === 'authentication') {
            return askForGmail(reading, id).pipe(
              Effect.as(unavailable('authentication')),
            );
          }
          // Work from an earlier mailbox generation failed for staleness, not storage; the row
          // offers Download again.
          if (kind === 'invalidated') {
            return Effect.succeed('stale' as const);
          }
          const reason = downloadFailure(kind);
          return (
            kind === 'locked'
              ? Effect.void
              : Effect.logError('Attachment download failed:', diagnostic)
          ).pipe(Effect.as(unavailable(reason)));
        },
      }),
      Effect.flatMap((failure) =>
        Effect.sync(() => {
          if (failure === undefined || !live()) {
            return;
          }
          setDownload(id, locator, failure === 'stale' ? undefined : failure);
        }),
      ),
    );
    // Cancelling ends the download as soon as its uninterruptible save, if any, completes.
    const cancelled = Effect.callback<unknown>((resume) => {
      if (abort.signal.aborted) {
        resume(Effect.void);
      }
      abort.signal.addEventListener('abort', () => {
        resume(Effect.void);
      });
    });
    return runLogged(Effect.raceFirst(program, cancelled).pipe(Effect.asVoid));
  };

  // A read shows as loading, except a refresh, which keeps the shown body, and a background read
  // nobody retains, whose body is released once it reaches this device.
  const startReading = (
    id: string,
    {
      refresh,
      background,
    }: Readonly<{ refresh: boolean; background: boolean }>,
  ) => {
    if (background && !readers.has(id)) {
      endedReaders.add(id);
    } else if (!refresh) {
      setBody(id, loadingBody);
    }
  };

  // A refresh reloads a shown body in place: it keeps showing until the reload succeeds. A
  // background read brings the body onto this device, keeping it only if a reader retains it.
  const readMessage = (
    id: string,
    {
      refresh = false,
      background = false,
    }: Readonly<{ refresh?: boolean; background?: boolean }> = {},
  ) => {
    const pending = readingBodies.get(id);
    if (pending !== undefined) {
      return pending;
    }
    const current = bodies.get(id);
    const scope = opened;
    // Only messages the open Inbox lists or found online are read, so no body outlives them.
    if (
      scope === undefined ||
      !readable(id) ||
      current?.kind === 'loading' ||
      (current?.kind === 'ready') !== refresh
    ) {
      return Promise.resolve();
    }
    const reading = owner;
    startReading(id, { refresh, background });
    const run = runLogged(
      Effect.acquireUseRelease(
        shared.begin,
        () =>
          Effect.gen(function* () {
            const speculative = speculativeBodies.get(id);
            if (speculative !== undefined) {
              yield* Deferred.await(speculative);
            }
            return yield* bodyLoads.withPermit(
              loadBody(scope, id, reading),
              () =>
                bodyRanks.get(id) ??
                (background && !readers.has(id) ? Infinity : -1),
            );
          }),
        () => shared.end,
      ).pipe(
        Effect.map((document): MessageBodyState => {
          if (owner !== reading || !readable(id) || endedReaders.has(id)) {
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
                if (owner === reading && readable(id)) {
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
            if (owner === reading && readable(id)) {
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
    // The marker has its own tier, so listing can tell it from a saved body.
    const exclude = () =>
      store(
        { version: 2, id, excluded: true },
        { ...admission, tier: 'excluded' },
      );
    const preflight = yield* fullMessage(scope, id, [
      ['format', 'metadata'],
      ['metadataHeaders', 'Content-Type'],
      ['metadataHeaders', 'Content-Disposition'],
    ]).pipe(Effect.flatMap(requireAttachments));
    if (!singleReadablePart(preflight)) {
      return yield* exclude();
    }
    const payload =
      graph === undefined
        ? yield* fullMessage(scope, id, [['format', 'full']])
        : preflight;
    if (!singleReadablePart(payload)) {
      return yield* exclude();
    }
    const content = yield* fetchPart(scope, id, payload);
    const html = bodyParts(payload).html !== undefined;
    return yield* store(
      {
        version: 2,
        id,
        attachments: [],
        headers: responseHeadersOf(payload),
        ...(html ? { html: content } : { text: content }),
      },
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
      yield* shared.idle.await;
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
    remoteContent.releaseAll();
    queued.length = 0;
    shown = undefined;
    notice = undefined;
    authenticationRejected = false;
    imagesAwaitingGmail.clear();
    opened = undefined;
    discardDownloads();
    found.clear();
    requestedViews.clear();
    failedViews.clear();
    activeViews.clear();
    settledMessages.clear();
    bodies.clear();
    readers.clear();
    legacyReaders.clear();
    viewReaders.clear();
    viewBodies.clear();
    documents.clear();
    endedReaders.clear();
    readingBodies.clear();
    imageReservations.clear();
    limitedReaders.clear();
    shared.images.delete(imageOwner);
    shared.waiting.delete(imageOwner);
    selection = [];
    selectionReference = undefined;
    speculativeBodies.clear();
    if (!forgotten || state.kind !== 'loading') {
      forgotten = true;
      notify({ kind: 'loading' });
    }
    shared.released(imageOwner);
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
    const modified = yield* providerWrite(
      () =>
        native.gmailModify(
          { message: message.id, add: action.add, remove: action.remove },
          scope,
        ),
      (status) => status === 200,
      decodeModified,
    );
    if (Option.isSome(modified) && modified.value.id !== message.id) {
      return yield* new SyncFailure({
        kind: 'retry',
        cause: 'message mismatch',
        diagnostic: 'another message',
      });
    }
    return modified.pipe(Option.map(({ labelIds }) => labelIds ?? []));
  });

  // The mailbox's provider: Gmail's label changes, or Graph's read-state changes and moves.
  const providerModify = graph?.modify ?? modify;
  // Microsoft mail offers only the actions Graph can make.
  const offered = (message: GmailMessage, action: GmailAction) =>
    canOrganize(message) &&
    (graph === undefined ||
      (graphChange(action) !== undefined &&
        !graph.unavailableActions().includes(action.kind)));
  const providerLabels = graph?.readLabels ?? readLabels;
  const providerRequested = (labels: readonly string[], action: GmailAction) =>
    requestedLabels(labels, action) &&
    (graph === undefined ||
      action.kind !== 'archive' ||
      labels.includes('ARCHIVE'));

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
    const observed = yield* providerLabels(current.cache, head.message);
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
    const attemptId = `${yield* Random.nextInt}:${yield* Random.nextInt}`;
    sendingAttempts.add(attemptId);
    return yield* Effect.gen(function* () {
      const attempted = withAttempt(
        head,
        DateTime.toEpochMillis(yield* DateTime.now),
        attemptId,
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
      if (
        prepared.document.pending?.[0]?.attempts?.at(-1)?.id !==
        attempted.attempts?.at(-1)?.id
      ) {
        // Another store instance won this preparation and sends the change itself.
        return prepared;
      }
      const outcome = yield* providerModify(prepared.cache, attempted);
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
    }).pipe(
      Effect.ensuring(Effect.sync(() => sendingAttempts.delete(attemptId))),
    );
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
    const observed = yield* providerLabels(current.cache, head.message);
    if (
      Option.isSome(observed) &&
      !providerRequested(observed.value, head.action)
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
      if (sending(head)) {
        return current;
      }
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

  // Gmail's user labels, by name; Gmail lists every one.
  const gmailLabels = (cache: Cache) =>
    gmail(cache)('labels', [], decodeLabels).pipe(
      Effect.map((response) => ({
        labels: Arr.sort(
          (response.labels ?? [])
            .filter(({ type }) => type === 'user')
            .map(({ id, name }) => ({ id, name }))
            // A label whose ID this client cannot send is left out rather than failing the list.
            .filter(Schema.is(GmailLabelSchema)),
          Order.mapInput(Order.String, (label: GmailLabel) => label.name),
        ),
        limited: false,
      })),
    );

  // The mailbox's own labels, listed once per synchronization; resolves the latest cache.
  const refreshLabels = Effect.fnUntraced(function* (
    cache: Cache,
    document: MailboxDocument,
  ) {
    const { labels, limited } = yield* graph === undefined
      ? gmailLabels(cache)
      : graph.labels(cache);
    const next: MailboxDocument = {
      ...Struct.omit(document, ['labelsLimited', 'views']),
      labels,
      ...(limited ? { labelsLimited: true as const } : {}),
      // A view of a label Gmail no longer has leaves with it.
      ...(document.views === undefined
        ? {}
        : { views: document.views.filter(offeredBy(labels)) }),
    };
    if (sameListing(document, next)) {
      return { cache, document };
    }
    const saved = yield* commitOver(cache, document, next);
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
        retainBodies(cache, document).pipe(
          Effect.andThen(
            Effect.sync(() => {
              settle('current');
            }),
          ),
        ),
      )
      .pipe(Effect.andThen(schedulePrefetch), Effect.andThen(rereadBodies));

  // Window exits release protection immediately; the next sync durably trims inactive extras.
  const trimViewCache = Effect.fnUntraced(function* (
    cache: Cache,
    document: MailboxDocument | undefined,
  ) {
    if (document?.views === undefined) {
      return { cache, document };
    }
    const views = retainedViews(document.views);
    return views.length === document.views.length
      ? { cache, document }
      : yield* commitOver(cache, document, { ...document, views });
  });

  const synchronize = Effect.gen(function* () {
    let cache = yield* storage(native.openMailbox);
    const { address, generation } = cache;
    selectionReference = yield* DateTime.now;
    if (!forgotten) {
      opened = { address, generation };
    }
    failedViews.clear();
    let document = Option.getOrUndefined(yield* documentOf(cache));
    if (cache.availability === 'retry') {
      return yield* ready(cache, document, 'retry');
    }
    yield* ready(cache, document, 'syncing');
    ({ cache, document } = yield* trimViewCache(cache, document));
    let restarts = 0;
    for (let step = 0; ; step += 1) {
      if (document !== undefined) {
        ({ cache, document } = yield* sendPending(cache, document));
      }
      arrivals = [];
      const next = yield* advance(cache, document, step);
      if (Option.isNone(next)) {
        break;
      }
      restarts += restartedListing(document, next.value) ? 1 : 0;
      yield* restartLimit(restarts);
      const brought = arrivals;
      ({ cache, document } = yield* commitOver(cache, document, next.value));
      if (brought.length > 0) {
        arrived?.(cache, brought);
      }
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
    !sending(head) &&
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

  // Which of these listed messages have a body saved on this device, read without Gmail and
  // without touching what the cache keeps or evicts. A prefetch exclusion marker is not a body.
  // A reply for an Inbox that closed or changed owner meanwhile names none, and a failed read
  // leaves the answer unknown.
  const savedBodies = Effect.fnUntraced(
    function* (ids: readonly string[]) {
      const scope = opened;
      const reading = owner;
      const wanted = ids.filter(listed);
      if (scope === undefined || wanted.length === 0) {
        return new Set<string>();
      }
      const reply = yield* Effect.tryPromise({
        try: () => native.listMessageBodies(scope, wanted),
        catch: (cause) => rejected(cause, 'failed'),
      });
      const { stored, excluded } = yield* decodeStoredBodies(reply).pipe(
        Effect.mapError((error) => malformed(error, 'failed')),
      );
      const markers = new Set(excluded);
      return new Set(
        owner === reading
          ? stored.filter((id) => !markers.has(id) && listed(id))
          : [],
      );
    },
    Effect.catchTag('SyncFailure', ({ diagnostic }) =>
      Effect.logError('Saved bodies could not be listed:', diagnostic).pipe(
        Effect.as(undefined),
      ),
    ),
  );

  // One page of Gmail's own search of this mailbox, newest first as Gmail orders it.
  const gmailSearch = Effect.fnUntraced(function* (
    scope: MailboxScope,
    { query, pageToken }: Readonly<{ query: string; pageToken?: string }>,
  ) {
    const page = yield* gmail(scope)(
      'messages',
      [
        ['q', query],
        ['maxResults', String(searchPageSize)],
        ...(pageToken === undefined ? [] : [['pageToken', pageToken] as const]),
      ],
      decodeList,
    );
    const messages = (yield* Effect.forEach(
      (page.messages ?? []).map(({ id }) => id),
      (id) => metadata(scope, id, true),
      { concurrency: 4 },
    )).flatMap(([, message]) => (message === undefined ? [] : [message]));
    return { messages, next: page.nextPageToken };
  });

  // One page of the provider's search of this mailbox: Gmail's, or Graph's across every folder.
  // Results are held for the reader; a reply for an Inbox that closed or changed owner meanwhile
  // is dropped.
  const searchPage = Effect.fnUntraced(function* (
    scope: MailboxScope,
    reading: number,
    request: Readonly<{ query: string; pageToken?: string }>,
  ) {
    const page = yield* graph === undefined
      ? gmailSearch(scope, request)
      : graph.search(scope, request, searchPageSize);
    const { messages } = page;
    if (owner !== reading || state.kind !== 'ready') {
      return undefined;
    }
    for (const message of messages) {
      found.set(message.id, message);
    }
    publish(render());
    const result: GmailSearchPage = {
      kind: 'found',
      messages,
      ...(page.next === undefined ? {} : { next: page.next }),
    };
    return result;
  });
  // Gmail's evidence for a message whose handoff had no answer: sent only when exactly one of the
  // newest Sent messages carries its MIME boundary. Anything else leaves the outcome unknown.
  const sentWith = Effect.fnUntraced(function* (
    scope: MailboxScope,
    boundary: string,
  ) {
    const page = yield* gmail(scope)(
      'messages',
      [
        ['labelIds', 'SENT'],
        ['maxResults', String(sentPageSize)],
      ],
      decodeList,
    );
    const matches = yield* Effect.forEach(
      page.messages ?? [],
      ({ id }) =>
        gmail(scope)(
          `messages/${id}`,
          [
            ['format', 'metadata'],
            ['metadataHeaders', 'Content-Type'],
          ],
          decodeMetadata,
        ).pipe(
          Effect.map((message) =>
            boundaryParameter(
              message.payload?.headers?.find(
                ({ name }) => name.toLowerCase() === 'content-type',
              )?.value,
            ) === boundary
              ? [message.id]
              : [],
          ),
          // A message deleted meanwhile is not this one.
          Effect.catchTag('GmailNotFound', () => Effect.succeed([])),
        ),
      { concurrency: 4 },
    );
    const [match, ...others] = matches.flat();
    return match !== undefined && others.length === 0
      ? ({ kind: 'sent', message: match } satisfies SendOutcome)
      : ({ kind: 'unknown' } satisfies SendOutcome);
  });
  const searchFailed = (
    { kind, diagnostic }: Readonly<Pick<SyncFailure, 'kind' | 'diagnostic'>>,
    reading: number,
  ): Effect.Effect<GmailSearchPage | undefined> => {
    // Native work started for a mailbox that changed; nothing is shown.
    if (kind === 'invalidated' || owner !== reading || state.kind !== 'ready') {
      return Effect.void.pipe(Effect.as(undefined));
    }
    if (kind === 'locked' || kind === 'revoked') {
      return recover({ kind, diagnostic }).pipe(Effect.as(undefined));
    }
    if (kind === 'retry') {
      return Effect.succeed(searchUnavailable('offline'));
    }
    if (kind !== 'authentication') {
      return Effect.logError('Gmail search failed:', diagnostic).pipe(
        Effect.as(searchUnavailable('failed')),
      );
    }
    // A refused grant asks for Gmail again, as a reader does.
    return Effect.sync(() => {
      if (owner === reading && opened !== undefined) {
        authenticationRejected = true;
        settle('authentication');
      }
      return searchUnavailable('authentication');
    });
  };
  const searchGmail = (query: string, pageToken: string | undefined) =>
    Effect.suspend(() => {
      const scope = opened;
      const reading = owner;
      if (scope === undefined || state.kind !== 'ready') {
        return Effect.succeed(searchUnavailable('failed'));
      }
      return searchPage(scope, reading, {
        query,
        ...(pageToken === undefined ? {} : { pageToken }),
      }).pipe(
        Effect.catchTags({
          SyncFailure: (failure) => searchFailed(failure, reading),
          GmailNotFound: () => Effect.succeed(searchUnavailable('failed')),
          // Gmail no longer accepts the page token; the search can start again.
          GmailInvalidPage: () => Effect.succeed(searchUnavailable('failed')),
        }),
      );
    });

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
    // A window protects its chosen view before opening it, then releases this exact lease on exit.
    retainView: (label: string) => {
      const token = Symbol('gmail-view');
      activeViews.set(token, label);
      return () => {
        activeViews.delete(token);
      };
    },
    // Lists a Gmail label, All Mail, Spam or Trash, kept current through mailbox history.
    openView: (label: string) => {
      const labels = shown?.document?.labels ?? [];
      if (
        graph !== undefined ||
        forgotten ||
        (systemViews.every((view) => view !== label) &&
          labels.every(({ id }) => id !== label))
      ) {
        return Promise.resolve();
      }
      requestedViews.add(label);
      publish(render());
      return load();
    },
    // Shows the change at once, saves it with the cache and sends it to Gmail in order. Without a
    // verified open mailbox nothing could be saved, so nothing changes.
    organize: (message: GmailMessage, action: GmailAction) => {
      if (
        forgotten ||
        shown === undefined ||
        !shown.organize ||
        !offered(message, action)
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
            limitedReaders.delete(id);
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
        releaseReader(id, reader);
        const count = (readers.get(id) ?? 1) - 1;
        if (count === 0) {
          readers.delete(id);
          discardDownloads(id);
          // The presentation ended: its image budget returns, and a later open reads the cache.
          if (bodies.get(id)?.kind === 'loading' || readingBodies.has(id)) {
            endedReaders.add(id);
          } else {
            releaseBody(id);
          }
        } else {
          readers.set(id, count);
        }
        if (presentLimited()) {
          notify(state);
        }
        shared.released(imageOwner);
      };
    },
    // Opens a body from this device, or downloads it from Gmail; a failed read can be tried again.
    // Windows opening the same message share one read.
    readMessage,
    // Waiting body reads of these messages start in this order, after unranked loads; a reader
    // ranks again as what it shows changes. The returned function ends this ranking.
    rankBodies: (ids: readonly string[]) => {
      const ranks = new Map(ids.map((id, index) => [id, index]));
      bodyRanks = ranks;
      return () => {
        if (bodyRanks === ranks) {
          bodyRanks = new Map();
        }
      };
    },
    // An opened message's received attachments with their availability, once its body is ready;
    // listing them never downloads their bytes.
    messageAttachments: (id: string) => {
      const attachments = documents.get(id)?.attachments;
      if (attachments === undefined) {
        return undefined;
      }
      const cached = attachmentViews.get(id);
      if (cached !== undefined) {
        return cached;
      }
      const view = attachments.map((attachment): ReceivedAttachment => ({
        ...attachment,
        state:
          downloads.get(attachmentKey(id, attachment.locator))?.state ??
          (attachment.size > attachmentLimit
            ? attachmentStates.oversized
            : attachmentStates.available),
      }));
      attachmentViews.set(id, view);
      return view;
    },
    downloadAttachment,
    cancelAttachment: (id: string, locator: string) => {
      if (
        downloads.get(attachmentKey(id, locator))?.state.kind === 'downloading'
      ) {
        const { abort } = downloads.get(attachmentKey(id, locator)) ?? {};
        setDownload(id, locator, undefined);
        abort?.abort();
      }
    },
    // Opens the system Attachment Preview or share sheet for a Downloaded Attachment. A file the
    // device no longer has, or one saved before the mailbox changed, is downloaded again.
    presentAttachment: (
      id: string,
      locator: string,
      action: 'open' | 'share',
    ) => {
      const download = downloads.get(attachmentKey(id, locator));
      const scope = opened;
      const saved = download?.saved;
      if (saved === undefined || scope === undefined || !readable(id)) {
        return Promise.resolve();
      }
      const stale = () =>
        Effect.sync(() => {
          if (downloads.get(attachmentKey(id, locator)) === download) {
            setDownload(id, locator, undefined);
            discardSaved(saved);
          }
        });
      if (
        saved.scope.address !== scope.address ||
        saved.scope.generation !== scope.generation
      ) {
        return runLogged(stale());
      }
      return runLogged(
        Effect.tryPromise({
          try: () => native.presentAttachment(scope, saved.file, action),
          catch: (cause) => rejected(cause, 'failed'),
        }).pipe(
          Effect.asVoid,
          // Only a file the device no longer has, or one from another mailbox generation, is
          // downloaded again; a presenter that could not show the file keeps it.
          Effect.catchTag('SyncFailure', ({ kind, cause, diagnostic }) =>
            Effect.logError(
              'Attachment could not be presented:',
              diagnostic,
            ).pipe(
              Effect.andThen(
                kind === 'invalidated' ||
                  rejectionCode(cause) === 'attachment-missing'
                  ? stale()
                  : Effect.void,
              ),
            ),
          ),
        ),
      );
    },
    // A Downloaded Attachment saved for the open mailbox generation, which a Draft can copy; native
    // code reads it only while that generation is current.
    attachmentFile: (id: string, locator: string) => {
      const saved = downloads.get(attachmentKey(id, locator))?.saved;
      const descriptor = documents
        .get(id)
        ?.attachments?.find((attachment) => attachment.locator === locator);
      const scope = opened;
      if (
        saved === undefined ||
        descriptor === undefined ||
        scope === undefined ||
        !readable(id) ||
        saved.scope.address !== scope.address ||
        saved.scope.generation !== scope.generation
      ) {
        return undefined;
      }
      return {
        name: descriptor.name,
        type: descriptor.mimeType,
        address: scope.address,
        generation: scope.generation,
        file: saved.file,
      };
    },
    // Sends one message from this mailbox's open generation. A mailbox not open yet reaches no
    // provider, so the message waits.
    send: (message: OutgoingSend) => {
      const scope = opened;
      if (scope === undefined || forgotten) {
        return Promise.resolve<SendOutcome>({
          kind: 'queued',
          problem: 'offline',
        });
      }
      const reading = owner;
      return runLogged(
        Effect.tryPromise({
          // Microsoft threads a reply by its headers; Graph has no thread to join.
          try: () =>
            graph === undefined
              ? native.gmailSend(message, scope)
              : native.graphSend({ segments: message.segments }, scope),
          catch: sendRejection,
        }).pipe(
          Effect.flatMap((reply) =>
            decodeResponse(reply).pipe(
              Effect.map(sendStatus),
              // A reply that cannot be read may follow acceptance.
              Effect.orElseSucceed((): SendOutcome => ({ kind: 'unknown' })),
            ),
          ),
          // A rejection is itself an outcome.
          Effect.match({
            onFailure: (outcome) => outcome,
            onSuccess: (outcome) => outcome,
          }),
          // Microsoft refusing the grant, as for a connection authorized before sending was
          // offered, asks for Microsoft again as a refused read does.
          Effect.tap((outcome) =>
            Effect.sync(() => {
              if (
                graph !== undefined &&
                outcome.kind === 'failed' &&
                outcome.problem === 'authorization' &&
                owner === reading &&
                opened !== undefined
              ) {
                authenticationRejected = true;
                settle('authentication');
              }
            }),
          ),
        ),
      );
    },
    // Looks for a message whose handoff had no answer in this mailbox's Sent messages: Gmail's by
    // its MIME boundary, Microsoft's by its Message-ID. Resolves sent, unknown when the provider
    // cannot establish it, or undefined when the open mailbox was not looked at, as when it closed
    // or changed meanwhile.
    findSent: (boundary: string, messageId?: string) => {
      const scope = opened;
      if (scope === undefined || forgotten) {
        return Promise.resolve(undefined);
      }
      let evidence = sentWith(scope, boundary);
      if (graph !== undefined) {
        evidence =
          messageId === undefined
            ? Effect.succeed({ kind: 'unknown' })
            : graph.sentCopy(scope, messageId);
      }
      const reading = owner;
      return runLogged(
        evidence.pipe(
          Effect.catchTags({
            // A lock, revocation or refused grant found here recovers the Inbox as a search does.
            SyncFailure: (failure) =>
              searchFailed(failure, reading).pipe(
                Effect.map((page) =>
                  page === undefined
                    ? undefined
                    : ({ kind: 'unknown' } satisfies SendOutcome),
                ),
              ),
            GmailNotFound: () =>
              Effect.succeed<SendOutcome | undefined>({ kind: 'unknown' }),
            GmailInvalidPage: () =>
              Effect.succeed<SendOutcome | undefined>({ kind: 'unknown' }),
          }),
        ),
      );
    },
    // An opened message's body and headers, which Reply, Reply All and Forward start from;
    // undefined until both are read.
    responseSource: (id: string) => {
      const document = documents.get(id);
      return readable(id) && document?.headers !== undefined
        ? document
        : undefined;
    },
    // The listed messages whose bodies open from this device without Gmail; undefined when unknown.
    savedBodies: (ids: readonly string[]) => runLogged(savedBodies(ids)),
    // Searches this mailbox at its provider; undefined when the Inbox closed or changed meanwhile.
    searchGmail: (query: string, pageToken?: string) =>
      runLogged(searchGmail(query, pageToken)),
    // Loads an opened message's Remote Message Content: from the Authorized Remote Content Cache,
    // and with `network` also through the isolated native fetch, which only an authorized
    // presentation asks for. Six requests run per message and twelve account-wide; the readers
    // are presented again once the requested sources settle.
    loadRemoteImages: remoteContent.load,
    // Drops a message's loaded Remote Message Content from memory and presents it again, as when
    // its policy becomes Never; cached bytes stay until eviction or Clear Remote Content.
    forgetRemoteImages: (id: string) => {
      remoteContent.forget(id);
      presentWaiting();
      shared.released(imageOwner);
    },
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
          // Its remote requests end with the rich view; nothing it loads could be shown.
          imageReservations.delete(reader);
          limitedReaders.delete(reader);
          viewBodies.set(reader, {
            kind: 'ready',
            presentation: readableOnly(expected),
          });
          remoteContent.discard(id, reader);
          presentLimited();
          notify(state);
          shared.released(imageOwner);
        }
        return;
      }
      const current = bodies.get(id);
      if (current?.kind === 'ready' && current.presentation === expected) {
        imageReservations.delete(id);
        limitedReaders.delete(id);
        const fallback = {
          kind: 'ready',
          presentation: readableOnly(expected),
        } as const;
        bodies.set(id, fallback);
        remoteContent.discard(id, id);
        presentLimited();
        setBody(id, fallback);
        shared.released(imageOwner);
      }
    },
  };
}

export type GmailInbox = ReturnType<typeof createGmailInbox>;
