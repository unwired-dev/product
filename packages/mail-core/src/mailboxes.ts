import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';

import type {
  GmailInbox,
  GmailInboxState,
  NativeGmailMailbox,
} from './gmail-inbox.ts';
import type { Registration, RegistrationSnapshot } from './registration.ts';

import { createBodyLoads, createGmailInbox } from './gmail-inbox.ts';
import { canOpenInbox, mailboxesOf } from './registration.ts';

type Scope = Readonly<{
  connection: string;
  address: string;
  generation: string;
}>;

// The native module's mailbox operations, each naming the Mailbox Connection it belongs to.
export interface NativeGmailMailboxes {
  readonly gmailRequest: (
    path: string,
    query: ReadonlyArray<readonly [string, string]>,
    mailbox: Scope & Readonly<{ signal?: Readonly<AbortSignal> }>,
  ) => Promise<unknown>;
  readonly gmailModify: (
    change: Parameters<NativeGmailMailbox['gmailModify']>[0],
    mailbox: Scope,
  ) => Promise<unknown>;
  readonly openMailbox: (connection: string) => Promise<unknown>;
  readonly commitMailbox: (
    mailbox: Scope,
    expectedRevision: number,
    document: string,
  ) => Promise<unknown>;
  readonly openMessageBody: (mailbox: Scope, id: string) => Promise<unknown>;
  readonly commitMessageBody: (
    mailbox: Scope,
    id: string,
    admission: Parameters<NativeGmailMailbox['commitMessageBody']>[2],
  ) => Promise<unknown>;
  readonly listMessageBodies: (
    mailbox: Scope,
    ids: readonly string[],
  ) => Promise<unknown>;
  readonly retainMessageBodies: (
    mailbox: Scope & Readonly<{ revision: number }>,
    ids: readonly string[],
    protectedIds: readonly string[],
  ) => Promise<unknown>;
  readonly saveAttachment: (
    mailbox: Scope,
    attachment: Parameters<NativeGmailMailbox['saveAttachment']>[1],
  ) => Promise<unknown>;
  readonly discardAttachment: (
    mailbox: Scope,
    file: string,
  ) => Promise<unknown>;
  readonly presentAttachment: (
    mailbox: Scope,
    file: string,
    action: 'open' | 'share',
  ) => Promise<unknown>;
}

// One connection's view of the native module: every call names that connection, and only the
// fields native code checks cross the bridge.
const bound = (
  native: NativeGmailMailboxes,
  connection: string,
): NativeGmailMailbox => {
  const scope = ({
    address,
    generation,
  }: Readonly<{ address: string; generation: string }>) => ({
    connection,
    address,
    generation,
  });
  return {
    gmailRequest: (path, query, mailbox) =>
      native.gmailRequest(path, query, {
        ...scope(mailbox),
        ...(mailbox.signal === undefined ? {} : { signal: mailbox.signal }),
      }),
    gmailModify: (change, mailbox) =>
      native.gmailModify(change, scope(mailbox)),
    openMailbox: () => native.openMailbox(connection),
    commitMailbox: (mailbox, expectedRevision, document) =>
      native.commitMailbox(scope(mailbox), expectedRevision, document),
    openMessageBody: (mailbox, id) =>
      native.openMessageBody(scope(mailbox), id),
    commitMessageBody: (mailbox, id, admission) =>
      native.commitMessageBody(scope(mailbox), id, admission),
    listMessageBodies: (mailbox, ids) =>
      native.listMessageBodies(scope(mailbox), ids),
    retainMessageBodies: (mailbox, ids, protectedIds) =>
      native.retainMessageBodies(
        { ...scope(mailbox), revision: mailbox.revision },
        ids,
        protectedIds,
      ),
    saveAttachment: (mailbox, attachment) =>
      native.saveAttachment(scope(mailbox), attachment),
    discardAttachment: (mailbox, file) =>
      native.discardAttachment(scope(mailbox), file),
    presentAttachment: (mailbox, file, action) =>
      native.presentAttachment(scope(mailbox), file, action),
  };
};

export type Mailbox = Readonly<{
  id: string;
  address: string;
  inbox: GmailInbox;
  state: GmailInboxState;
}>;

const loading: GmailInboxState = { kind: 'loading' };

type OpenMailbox = Readonly<{ id: string; address: string; owner: string }>;

// The connections whose Inbox can open, each owned by its Product Account, connection and address.
const openMailboxes = (
  account: RegistrationSnapshot,
): readonly OpenMailbox[] =>
  canOpenInbox(account) && account.kind !== 'signed-out'
    ? mailboxesOf(account)
        .filter(({ state }) => state !== 'authorization')
        .map(({ id, address, epoch }) => ({
          id,
          address,
          owner: [
            account.productAccountId,
            id,
            address,
            epoch ?? 'legacy',
          ].join('\n'),
        }))
    : [];

// One Gmail Inbox per Mailbox Connection that can open, in the order the connections were added.
// Each keeps its own cache, changes, synchronization and authorization; a connection that needs
// Gmail again, is removed, or changes Product Account or address loses its Inbox and the mail it
// held in memory.
export function createMailboxes(
  native: NativeGmailMailboxes,
  registration: Pick<Registration, 'subscribe' | 'getSnapshot'>,
  { removed }: Readonly<{ removed?: () => void }> = {},
) {
  const shared = createBodyLoads();
  const inboxes = new Map<
    string,
    {
      readonly owner: string;
      readonly address: string;
      readonly inbox: GmailInbox;
      readonly unsubscribe: () => void;
    }
  >();
  let order: readonly string[] = [];
  let snapshot: readonly Mailbox[] = [];
  // Set once the host loads, so a connection added later synchronizes as soon as it appears.
  let started = false;
  const listeners = new Set<() => void>();
  const notify = () => {
    snapshot = order.flatMap((id) => {
      const entry = inboxes.get(id);
      if (entry === undefined) {
        return [];
      }
      const state = entry.inbox.getSnapshot();
      // The Inbox shows only its own mailbox's mail, never a previous address's.
      const shown =
        state.kind === 'ready' && state.address !== entry.address
          ? loading
          : state;
      const previous = snapshot.find((mailbox) => mailbox.id === id);
      return previous?.inbox === entry.inbox && previous.state === shown
        ? [previous]
        : [{ id, address: entry.address, inbox: entry.inbox, state: shown }];
    });
    for (const listener of listeners) {
      listener();
    }
  };
  // Forgets each Inbox whose connection left, then opens one for each new connection.
  const forgetClosed = (open: readonly OpenMailbox[]) => {
    let changed = false;
    for (const [id, entry] of inboxes) {
      if (!open.some((mailbox) => mailbox.owner === entry.owner)) {
        inboxes.delete(id);
        entry.unsubscribe();
        entry.inbox.forget();
        changed = true;
      }
    }
    return changed;
  };
  const openNew = (open: readonly OpenMailbox[]) => {
    const added = open.filter(({ id }) => !inboxes.has(id));
    for (const { id, address, owner } of added) {
      const inbox = createGmailInbox(bound(native, id), { removed, shared });
      inboxes.set(id, {
        owner,
        address,
        inbox,
        unsubscribe: inbox.subscribe(notify),
      });
      if (started) {
        void inbox.load();
      }
    }
    return added.length > 0;
  };
  const follow = () => {
    const open = openMailboxes(registration.getSnapshot().snapshot);
    const closed = forgetClosed(open);
    const opened = openNew(open);
    const next = open.map(({ id }) => id);
    if (closed || opened || next.join('\n') !== order.join('\n')) {
      order = next;
      notify();
    }
  };
  registration.subscribe(follow);
  follow();
  return {
    getSnapshot: () => snapshot,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    // Changes whenever any connection saves or prunes bodies, so saved states can be read again.
    bodies: {
      getSnapshot: shared.cache.getSnapshot,
      subscribe: shared.cache.subscribe,
    },
    // Synchronizes every open connection; each one's failure stays its own.
    load: async () => {
      started = true;
      await Promise.all([...inboxes.values()].map(({ inbox }) => inbox.load()));
    },
  };
}

export type Mailboxes = ReturnType<typeof createMailboxes>;

// One Inbox store as the only mailbox, such as the preview fixture, which has no address.
export function singleMailbox<
  S extends Readonly<{
    getSnapshot: () => unknown;
    subscribe: (listener: () => void) => () => void;
    load: () => Promise<void>;
  }>,
>(inbox: S, id: string) {
  let shown: ReadonlyArray<
    Readonly<{ id: string; inbox: S; state: ReturnType<S['getSnapshot']> }>
  > = [];
  return {
    getSnapshot: () => {
      // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The store's own snapshot type.
      const state = inbox.getSnapshot() as ReturnType<S['getSnapshot']>;
      if (shown[0]?.state !== state) {
        shown = [{ id, inbox, state }];
      }
      return shown;
    },
    subscribe: inbox.subscribe,
    load: inbox.load,
  };
}

// Any Inbox listing: a connection's Gmail Inbox, or the preview fixture.
type Listing = Readonly<{ id: string; state: Readonly<{ kind: string }> }>;
type MessageOf<L extends Listing> = L['state'] extends infer S
  ? S extends Readonly<{ messages: ReadonlyArray<infer M> }>
    ? M
    : never
  : never;
type Listed = Readonly<{ id: string; receivedAt: string }>;

export type MailboxMessage<L extends Listing = Mailbox> = Readonly<{
  mailbox: L;
  message: MessageOf<L>;
}>;

// The unified Inbox, or one connection's, newest first. Equal times keep the connections' order,
// then the message ID, so the list never reorders between renders.
export function inboxMessages<L extends Listing>(
  mailboxes: readonly L[],
  scope: string | undefined,
): ReadonlyArray<MailboxMessage<L>> {
  const rank = new Map(mailboxes.map(({ id }, index) => [id, index]));
  const message = (entry: MailboxMessage<L>): Listed => entry.message;
  return Arr.sort(
    mailboxes
      .filter(({ id }) => scope === undefined || id === scope)
      .flatMap((mailbox) =>
        'messages' in mailbox.state && Array.isArray(mailbox.state.messages)
          ? (mailbox.state.messages as ReadonlyArray<MessageOf<L>>).map(
              (item) => ({ mailbox, message: item }),
            )
          : [],
      ),
    Order.combine(
      Order.flip(
        Order.mapInput(
          Order.String,
          (entry: MailboxMessage<L>) => message(entry).receivedAt,
        ),
      ),
      Order.combine(
        Order.mapInput(
          Order.Number,
          ({ mailbox }: MailboxMessage<L>) => rank.get(mailbox.id) ?? 0,
        ),
        Order.mapInput(
          Order.String,
          (entry: MailboxMessage<L>) => message(entry).id,
        ),
      ),
    ),
  );
}

// Normalize and strip accents before casing to expose compatibility letters. Lowercase so `ẞ` joins `ß`,
// then uppercase to expand sharp S and keep sigma independent of its position in a word.
const folded = (text: string) =>
  text
    .normalize('NFKD')
    .replaceAll(/\p{M}/gu, '')
    .toLowerCase()
    .toUpperCase()
    .normalize('NFKD')
    .replaceAll(/\p{M}/gu, '');

type Searched = Readonly<{ sender: string; address: string; subject: string }>;

// The listed messages whose sender name, address or subject holds every word of the query, in the
// listing's order. It reads only the metadata already on this device; nothing asks Gmail.
export function searchMessages<L extends Listing>(
  entries: ReadonlyArray<MailboxMessage<L>>,
  query: string,
): ReadonlyArray<MailboxMessage<L>> {
  const words = folded(query)
    .split(/\s+/u)
    .filter((word) => word.length > 0);
  if (words.length === 0) {
    return entries;
  }
  return entries.filter((entry) => {
    const message: Searched = entry.message;
    const fields = [message.sender, message.address, message.subject].map(
      folded,
    );
    return words.every((word) => fields.some((field) => field.includes(word)));
  });
}

// What search says, shared by both hosts.
export const searchCopy = {
  label: 'Search senders and subjects',
  saved: 'Saved on this device',
  download: 'Downloads from Gmail when opened',
  empty: (query: string) => `No mail saved on this device matches “${query}”.`,
} as const;

// A listed message whose store can report its cached bodies. Preview stores keep every body
// with the metadata and need no separate lookup.
type BodyResult = Readonly<{
  mailbox: Readonly<{
    id: string;
    inbox: Readonly<{
      getSnapshot: () => unknown;
      savedBodies?: (
        ids: readonly string[],
      ) => Promise<ReadonlySet<string> | undefined>;
    }>;
  }>;
  message: Readonly<{ id: string }>;
}>;

// Gmail message IDs are unique only within their mailbox.
export const resultKey = ({
  mailbox,
  message,
}: Pick<BodyResult, 'mailbox' | 'message'>) => `${mailbox.id}\n${message.id}`;

// Each connection answers from its own cache. Unknown answers remain absent, never unsaved. Each
// store's `savedBodies` is its own host-facing run, so this only combines their answers.
export async function savedMessageBodies(results: readonly BodyResult[]) {
  const byMailbox = new Map<BodyResult['mailbox'], BodyResult[]>();
  for (const result of results) {
    const group = byMailbox.get(result.mailbox);
    if (group === undefined) {
      byMailbox.set(result.mailbox, [result]);
    } else {
      group.push(result);
    }
  }
  const answers = await Promise.all(
    [...byMailbox].map(async ([{ inbox }, found]) => {
      const ids = found.map(({ message }) => message.id);
      const saved =
        inbox.savedBodies === undefined
          ? new Set(ids)
          : await inbox.savedBodies(ids);
      return saved === undefined
        ? []
        : found.map(
            (result) =>
              [resultKey(result), saved.has(result.message.id)] as const,
          );
    }),
  );
  return new Map(answers.flat());
}
