import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';
import * as Schema from 'effect/Schema';

// ponytail: the newest messages kept per folder, as for Gmail's Inbox; older ones stay on the
// server until Historical Metadata Backfill.
export const window = 200;
// Folders whose messages stay cached besides the Inbox; the least recently opened leaves first.
export const cachedFolders = 8;
export const inboxFolder = 'INBOX';

const Uid = Schema.Int.check(
  Schema.isBetween({ minimum: 1, maximum: 4_294_967_295 }),
);
const Validity = Schema.Int.check(
  Schema.isBetween({ minimum: 1, maximum: 4_294_967_295 }),
);
// Moving without expunging other messages (MOVE, or UIDPLUS's UID EXPUNGE), and IDLE.
const Capabilities = Schema.Struct({
  moves: Schema.Boolean,
  idle: Schema.Boolean,
});
export type ImapCapabilities = typeof Capabilities.Type;

const FolderSchema = Schema.Struct({
  name: Schema.NonEmptyString,
  roles: Schema.Array(Schema.String),
  selectable: Schema.Boolean,
});
export type ImapFolder = typeof FolderSchema.Type;

const ImapMessageSchema = Schema.Struct({
  // The folder, UIDVALIDITY and UID together identify a message; none is reused within them.
  id: Schema.NonEmptyString,
  folder: Schema.NonEmptyString,
  uidValidity: Validity,
  uid: Uid,
  sender: Schema.String,
  address: Schema.String,
  subject: Schema.String,
  // IMAP has no snippet; the reader shows the body once opened.
  preview: Schema.String,
  receivedAt: Schema.String,
  unread: Schema.Boolean,
});
export type ImapMessage = typeof ImapMessageSchema.Type;

// One organizing change. Read state is a flag; every other action moves the message to its
// `destination` folder, chosen by role when the change was made.
const ImapActionSchema = Schema.Union([
  Schema.Struct({ kind: Schema.Literals(['read', 'unread']) }),
  Schema.Struct({
    // `restore` undoes a move, back to the folder the message came from.
    kind: Schema.Literals(['archive', 'trash', 'spam', 'move', 'restore']),
    destination: Schema.NonEmptyString,
  }),
]);
export type ImapAction = typeof ImapActionSchema.Type;

// A change saved on this device until the server applies or refuses it, oldest first.
const PendingSchema = Schema.Struct({
  id: Schema.NonEmptyString,
  action: ImapActionSchema,
  // The message as shown when the change was made; its UIDVALIDITY keeps the change from reaching
  // a different generation of the folder.
  message: ImapMessageSchema,
  // Persisted before dispatch: without a destination mapping, a move may not be replayed.
  attempts: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  // COPYUID is committed before the fallback may delete its source. Recovery finishes this copy.
  copied: Schema.optionalKey(
    Schema.Struct({ uidValidity: Validity, uid: Uid }),
  ),
});
export type ImapPending = typeof PendingSchema.Type;

const FolderCacheSchema = Schema.Struct({
  uidValidity: Validity,
  uidNext: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  messages: Schema.Array(ImapMessageSchema),
});
type FolderCache = typeof FolderCacheSchema.Type;

// Each folder's checkpoint is committed with the messages it produced, so an interrupted
// synchronization repeats at most the step that did not commit.
const DocumentSchema = Schema.Struct({
  version: Schema.Literal(1),
  folders: Schema.Array(FolderSchema),
  // Cached folders, most recently opened first after the Inbox.
  mailboxes: Schema.Array(
    Schema.Struct({ name: Schema.NonEmptyString, cache: FolderCacheSchema }),
  ),
  // What the server advertised at the last listing; absent before it was first read.
  capabilities: Schema.optionalKey(Capabilities),
  pending: Schema.optionalKey(Schema.Array(PendingSchema)),
});
export type ImapDocument = typeof DocumentSchema.Type;
export const decodeDocument = Schema.decodeUnknownEffect(
  Schema.fromJsonString(DocumentSchema),
);
export const encodeDocument = Schema.encodeEffect(
  Schema.fromJsonString(DocumentSchema),
);

const CacheSchema = Schema.Struct({
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  address: Schema.NonEmptyString,
  generation: Schema.NonEmptyString,
  document: Schema.NullOr(Schema.String),
  availability: Schema.optionalKey(Schema.Literal('retry')),
});
export const decodeCache = Schema.decodeUnknownEffect(CacheSchema);
export const decodeCommit = Schema.decodeUnknownEffect(
  Schema.Struct({ revision: Schema.Int }),
);
export const decodeFolders = Schema.decodeUnknownEffect(
  Schema.Struct({
    folders: Schema.Array(FolderSchema),
    ...Capabilities.fields,
  }),
);
// A change's outcome: applied, moved (to a known UID when the server reported it), or the folder
// no longer holds the UID.
export const decodeModify = Schema.decodeUnknownEffect(
  Schema.Union([
    Schema.Struct({ outcome: Schema.Literals(['stored', 'absent']) }),
    Schema.Struct({
      outcome: Schema.Literal('copied'),
      uidValidity: Validity,
      uid: Uid,
    }),
    Schema.Struct({
      outcome: Schema.Literal('moved'),
      uidValidity: Schema.optionalKey(Validity),
      uid: Schema.optionalKey(Uid),
    }),
  ]),
);
export const decodeIdle = Schema.decodeUnknownEffect(
  Schema.Struct({ changed: Schema.Boolean }),
);
// How many Sent messages carry a MIME boundary.
export const decodeCount = Schema.decodeUnknownEffect(
  Schema.Struct({
    count: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  }),
);
const EnvelopeSchema = Schema.Struct({
  uid: Uid,
  flags: Schema.Array(Schema.String),
  received: Schema.Finite,
  size: Schema.Int,
  sender: Schema.String,
  address: Schema.String,
  subject: Schema.String,
});
type Envelope = typeof EnvelopeSchema.Type;
// Each searched folder's newest matches, and how many folders the server no longer selects.
export const decodeSearch = Schema.decodeUnknownEffect(
  Schema.Struct({
    folders: Schema.Array(
      Schema.Struct({
        folder: Schema.NonEmptyString,
        uidValidity: Validity,
        messages: Schema.Array(EnvelopeSchema),
        // Older matches were left out.
        more: Schema.Boolean,
      }),
    ),
    skipped: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  }),
);
const FolderReadSchema = Schema.Struct({
  uidValidity: Validity,
  uidNext: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  reset: Schema.Boolean,
  messages: Schema.Array(EnvelopeSchema),
  flags: Schema.Array(
    Schema.Struct({ uid: Uid, flags: Schema.Array(Schema.String) }),
  ),
});
type FolderRead = typeof FolderReadSchema.Type;
export const decodeFolderRead = Schema.decodeUnknownEffect(FolderReadSchema);
export const decodeRaw = Schema.decodeUnknownEffect(
  Schema.Struct({ data: Schema.String }),
);
export const decodeBodyCommit = Schema.decodeUnknownEffect(
  Schema.Struct({ admitted: Schema.Boolean }),
);

const seen = String.raw`\seen`;

export const messageId = (folder: string, uidValidity: number, uid: number) =>
  `${uidValidity}.${uid}.${folder}`;

const unreadOf = (flags: readonly string[]) =>
  !flags.some((flag) => flag.toLowerCase() === seen);

// A listed message from its envelope in the folder at that UIDVALIDITY.
export const listedMessage = (
  folder: string,
  uidValidity: number,
  message: Envelope,
): ImapMessage => ({
  id: messageId(folder, uidValidity, message.uid),
  folder,
  uidValidity,
  uid: message.uid,
  sender: message.sender === '' ? message.address : message.sender,
  address: message.address,
  subject: message.subject,
  preview: '',
  receivedAt: new Date(message.received).toISOString(),
  unread: unreadOf(message.flags),
});

// Newest UID first: the order a folder's arrivals take, which trims the cache window.
const byUid = Order.flip(
  Order.mapInput(Order.Number, ({ uid }: ImapMessage) => uid),
);
const newestReceived = Order.combine(
  Order.flip(
    Order.mapInput(Order.String, ({ receivedAt }: ImapMessage) => receivedAt),
  ),
  byUid,
);
export const newestFirst = (messages: readonly ImapMessage[]) =>
  Arr.sort(messages, newestReceived);

// Applies one folder synchronization to its cache: a reset or a new UIDVALIDITY replaces it, and
// otherwise known messages keep only those still present, with the flags read now.
export function applyFolderRead(
  folder: string,
  cached: FolderCache | undefined,
  read: FolderRead,
): FolderCache {
  const fresh = read.messages.map((message) =>
    listedMessage(folder, read.uidValidity, message),
  );
  const replaced =
    read.reset ||
    cached === undefined ||
    cached.uidValidity !== read.uidValidity;
  const flags = new Map(read.flags.map(({ uid, flags: set }) => [uid, set]));
  const kept = replaced
    ? []
    : cached.messages.flatMap((message) => {
        const current = flags.get(message.uid);
        return current === undefined
          ? []
          : [{ ...message, unread: unreadOf(current) }];
      });
  const known = new Set(kept.map(({ uid }) => uid));
  const merged = Arr.sort(
    [...kept, ...fresh.filter(({ uid }) => !known.has(uid))],
    byUid,
  ).slice(0, window);
  return {
    uidValidity: read.uidValidity,
    uidNext: read.uidNext,
    messages: newestFirst(merged),
  };
}
