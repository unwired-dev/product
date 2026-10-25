import type { Translate } from '@private-email/localization';

import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';

import type {
  GmailInbox,
  GmailInboxState,
  GmailMessage,
} from './gmail-inbox.ts';
import type {
  ImapFolderView,
  ImapInbox,
  ImapInboxState,
} from './imap-inbox.ts';
import type { ImapFolder } from './imap-model.ts';
import type { InboxState, PersistentInbox } from './persistent-inbox.ts';
import type {
  MailboxConnection,
  MailProvider,
} from './registration-snapshot.ts';

import {
  allMail,
  gmailArchive,
  gmailViewSymbol,
  gmailViewTitle,
  microsoftAllMailViews,
  offeredViews,
  providerViews,
  systemViews,
} from './gmail-actions.ts';
import { imapRoleFolder } from './imap-actions.ts';
import { imapFolderFailed, imapFolderName, inboxFolder } from './imap-inbox.ts';

// The mailboxes owned by exactly `profile`, in the order the connections were added.
export const profileMailboxes = <L extends Readonly<{ profile: string }>>(
  mailboxes: readonly L[],
  profile: string,
) => mailboxes.filter((mailbox) => mailbox.profile === profile);

// A problem the mailbox's Inbox explains in full: its storage, or a provider that could not be
// reached or needs authorization again while the saved mail stays readable.
export type MailboxProblem = 'locked' | 'failed' | 'retry' | 'authentication';

const syncOf = (state: InboxState | GmailInboxState | ImapInboxState) => {
  if ('sync' in state) {
    return state.sync;
  }
  if ('status' in state) {
    return state.status;
  }
  return undefined;
};

const problemOf = (
  state: InboxState | GmailInboxState | ImapInboxState,
): MailboxProblem | undefined => {
  if (state.kind === 'locked' || state.kind === 'failed') {
    return state.kind;
  }
  const sync = state.kind === 'ready' ? syncOf(state) : undefined;
  return sync === 'retry' || sync === 'authentication' ? sync : undefined;
};

// The listed IMAP folders, other than the Inbox, whose last read failed. A folder read can fail
// without changing the connection's status, so the failure rides on its own sidebar row.
export const failedFolders = (
  inbox: Readonly<{ folder: (name: string) => ImapFolderView }>,
  names: readonly string[],
) =>
  names.filter(
    (name) => name !== inboxFolder && imapFolderFailed(inbox.folder(name)),
  );

// The Gmail or Microsoft view a window shows: the one it chose while the mailbox still has it,
// otherwise the Inbox, as for an IMAP folder the server no longer offers.
export const gmailViewName = (
  state: GmailInboxState,
  requested: string,
  provider: MailProvider | undefined,
) =>
  state.kind !== 'ready' ||
  requested === inboxFolder ||
  offeredViews(provider, state.unavailableActions).includes(requested) ||
  state.labels.some(({ id }) => id === requested)
    ? requested
    : inboxFolder;

// Stable list entries for the same messages and mailbox snapshot, without retaining old messages.
export const createGmailViewEntries = <M>() => {
  const entries = new WeakMap<
    readonly GmailMessage[],
    ReadonlyArray<Readonly<{ mailbox: M; message: GmailMessage }>>
  >();
  return (mailbox: M, messages: readonly GmailMessage[]) => {
    const cached = entries.get(messages);
    if (cached !== undefined && (cached[0]?.mailbox ?? mailbox) === mailbox) {
      return cached;
    }
    const listed = messages.map((message) => ({ mailbox, message }));
    entries.set(messages, listed);
    return listed;
  };
};

type BrowsableMailbox = Readonly<{
  provider?: MailProvider;
  inbox: Readonly<GmailInbox | ImapInbox | PersistentInbox>;
  state: GmailInboxState | ImapInboxState | InboxState;
}>;

// A ready Gmail or Microsoft connection offers views of its labels or folders; Microsoft shares
// the Gmail store.
export const gmailMailbox = (mailbox: BrowsableMailbox | undefined) => {
  const provider = mailbox?.provider ?? 'gmail';
  if (mailbox === undefined || provider === 'imap') {
    return undefined;
  }
  const { inbox, state } = mailbox;
  return 'openView' in inbox && state.kind === 'ready' && 'labels' in state
    ? { inbox, state, provider }
    : undefined;
};

// A Gmail or Microsoft view as both hosts show it, in the sidebar and the list: its name, SF
// Symbol, the notice for a failed read, and whether it keeps only its newest messages.
export const gmailViewRow = (
  t: Translate,
  {
    state,
    provider,
  }: Readonly<{
    state: Extract<GmailInboxState, { kind: 'ready' }>;
    provider: MailProvider;
  }>,
  label: string,
) => {
  const view = state.views?.find((entry) => entry.label === label);
  const title = gmailViewTitle(t, label, { labels: state.labels, provider });
  const name = t(
    provider === 'microsoft-graph'
      ? 'mailProviders.microsoft-graph'
      : 'mailProviders.gmail',
  );
  return {
    title,
    icon: gmailViewSymbol(label),
    failure:
      view?.status === 'failed'
        ? t('mailboxes.viewUnavailable', { view: title, provider: name })
        : undefined,
    // Says that only the view's newest mail is saved on this device.
    limited:
      view?.limited === true
        ? t('inbox.footerView', { provider: name })
        : undefined,
  };
};

// A window keeps its chosen folder while the provider still offers it.
export const mailboxFolder = (
  mailbox: BrowsableMailbox | undefined,
  requested: string,
) => {
  if (mailbox === undefined) {
    return inboxFolder;
  }
  const { inbox, state } = mailbox;
  if ('openFolder' in inbox) {
    return imapFolderName(
      state.kind === 'ready' && 'folders' in state ? state : undefined,
      requested,
    );
  }
  const gmail = gmailMailbox(mailbox);
  return gmail === undefined
    ? requested
    : gmailViewName(gmail.state, requested, gmail.provider);
};

// A window's chosen mailbox and the connections whose authorization notices its Inbox shows. A
// chosen connection waiting for provider authorization has no Inbox store but stays chosen with
// its own notice, so New Message cannot fall back to another sender; a removed mailbox's view
// falls back to every mailbox, which shows every waiting connection.
export function inboxChoice<C extends Pick<MailboxConnection, 'id' | 'state'>>({
  mailboxes,
  connections,
  view,
}: Readonly<{
  mailboxes: ReadonlyArray<Readonly<{ id: string }>>;
  // The window's Profile's connections.
  connections: readonly C[];
  view: Readonly<{ mailbox?: string | undefined }>;
}>): Readonly<{
  // Whether the view stays on its chosen mailbox.
  keepsChoice: boolean;
  chosenWaiting: C | undefined;
  waiting: readonly C[];
}> {
  if (mailboxes.some(({ id }) => id === view.mailbox)) {
    return { keepsChoice: true, chosenWaiting: undefined, waiting: [] };
  }
  const waiting = connections.filter(({ state }) => state === 'authorization');
  const chosenWaiting = waiting.find(({ id }) => id === view.mailbox);
  return chosenWaiting === undefined
    ? { keepsChoice: false, chosenWaiting, waiting }
    : { keepsChoice: true, chosenWaiting, waiting: [chosenWaiting] };
}

// A mailbox's sidebar rows: an IMAP connection's selectable folders, a Gmail mailbox's Inbox, its
// own labels by name, then All Mail, Spam and Trash, or a Microsoft mailbox's Inbox, Sent Items,
// the Archive, Junk Email and Deleted Items it has, then its own folders by path; other
// mailboxes list their Inbox.
const folderNames = (
  state: InboxState | GmailInboxState | ImapInboxState,
  provider: MailProvider | undefined,
): readonly string[] => {
  if (state.kind !== 'ready') {
    return [inboxFolder];
  }
  if ('folders' in state) {
    return state.folders
      .filter(({ selectable }) => selectable)
      .map(({ name }) => name);
  }
  if (!('labels' in state)) {
    return [inboxFolder];
  }
  const labels = state.labels.map(({ id }) => id);
  const views = providerViews(provider, state.unavailableActions);
  return provider === 'microsoft-graph'
    ? [inboxFolder, ...views, ...labels]
    : [inboxFolder, ...labels, ...views];
};

// The unread mail of an opened Gmail label's or Microsoft folder's saved view; none is counted for
// All Mail, Spam and Trash, nor Junk Email and Deleted Items, and an IMAP folder's count is not
// known here.
const viewUnread = (
  state: InboxState | GmailInboxState | ImapInboxState,
  name: string,
) =>
  state.kind !== 'ready' ||
  !('labels' in state) ||
  systemViews.some((system) => system === name)
    ? 0
    : (state.views
        ?.find(({ label }) => label === name)
        ?.messages.filter((message) => message.unread).length ?? 0);

// The sidebar projects already-decoded stores; hosts retain rendering and navigation callbacks.
export function mailboxSidebar<
  L extends Readonly<{
    id: string;
    provider?: MailProvider | undefined;
    state: InboxState | GmailInboxState | ImapInboxState;
  }>,
  C extends Pick<MailboxConnection, 'id' | 'profile' | 'provider' | 'state'>,
>({
  mailboxes,
  connections,
  profile,
  view,
}: Readonly<{
  mailboxes: readonly L[];
  connections: readonly C[];
  profile: string;
  view: Readonly<{
    mailbox?: string | undefined;
    folder?: string | undefined;
    unified?: UnifiedRole | undefined;
  }>;
}>) {
  const chosen =
    view.unified === undefined
      ? mailboxes.find(({ id }) => id === view.mailbox)
      : undefined;
  const sections = mailboxes.map((mailbox) => {
    const { state } = mailbox;
    const unread =
      'messages' in state
        ? state.messages.filter((message) => message.unread).length
        : 0;
    return {
      mailbox,
      unread,
      problem: problemOf(state),
      folders: folderNames(state, mailbox.provider).map((name) => ({
        name,
        inbox: name === inboxFolder,
        unread: name === inboxFolder ? unread : viewUnread(state, name),
        selected: chosen === mailbox && (view.folder ?? inboxFolder) === name,
      })),
    };
  });
  const profileConnections = profileMailboxes(connections, profile);
  const waitingEntry = (connection: C) => ({
    id: connection.id,
    waiting: {
      connection,
      recovery: connection.provider === 'imap' ? 'account' : 'authorization',
      selected: connection.id === view.mailbox,
    },
  });
  type Entry =
    | Readonly<{ id: string; section: (typeof sections)[number] }>
    | ReturnType<typeof waitingEntry>;
  return {
    unread: sections.reduce((sum, section) => sum + section.unread, 0),
    // All inboxes is selected exactly when the Inbox shows every mailbox.
    allSelected:
      view.unified === undefined &&
      !inboxChoice({
        mailboxes,
        connections: profileConnections,
        view,
      }).keepsChoice,
    // Open and waiting connections in their saved order, so a section keeps its place while its
    // authorization lapses; a mailbox without a connection, such as the preview, comes first.
    entries: [
      ...sections
        .filter(({ mailbox }) =>
          profileConnections.every(({ id }) => id !== mailbox.id),
        )
        .map((section): Entry => ({ id: section.mailbox.id, section })),
      // Waiting connections have no store until authorization succeeds; never duplicate a store row.
      ...profileConnections.flatMap((connection): Entry[] => {
        const section = sections.find(
          ({ mailbox }) => mailbox.id === connection.id,
        );
        if (section !== undefined) {
          return [{ id: connection.id, section }];
        }
        return connection.state === 'authorization'
          ? [waitingEntry(connection)]
          : [];
      }),
    ],
  };
}

// Newest first. Equal times keep the connections' order, then the message ID, so a list never
// reorders between renders.
export const newestFirst = <
  E extends Readonly<{
    mailbox: Readonly<{ id: string }>;
    message: Readonly<{ id: string; receivedAt: string }>;
  }>,
>(
  mailboxes: ReadonlyArray<Readonly<{ id: string }>>,
  entries: readonly E[],
) => {
  const rank = new Map(mailboxes.map(({ id }, index) => [id, index]));
  const message = (entry: E) => entry.message;
  return Arr.sort(
    entries,
    Order.combine(
      Order.flip(
        Order.mapInput(Order.String, (entry: E) => message(entry).receivedAt),
      ),
      Order.combine(
        Order.mapInput(
          Order.Number,
          ({ mailbox }: E) => rank.get(mailbox.id) ?? 0,
        ),
        Order.mapInput(Order.String, (entry: E) => message(entry).id),
      ),
    ),
  );
};

// The Unified Mailboxes the Favorites list after All inboxes, by Mailbox Role. All Mail is the
// product's own: every message outside Spam and Trash.
export const unifiedRoles = [
  'SENT',
  'ARCHIVE',
  allMail,
  'SPAM',
  'TRASH',
] as const;
export type UnifiedRole = (typeof unifiedRoles)[number];

const unifiedTitles = {
  SENT: 'mailboxes.sent',
  ARCHIVE: 'mailboxes.archive',
  [allMail]: 'mailboxes.allMail',
  SPAM: 'mailboxes.spam',
  TRASH: 'mailboxes.trash',
} as const;

// A Unified Mailbox's Favorites row and list title.
export const unifiedRow = (t: Translate, role: UnifiedRole) => ({
  title: t(unifiedTitles[role]),
  icon: gmailViewSymbol(role),
});

const imapRoles = {
  SENT: 'sent',
  ARCHIVE: 'archive',
  SPAM: 'junk',
  TRASH: 'trash',
} as const;

// An IMAP mailbox's folders with the role. A server's readable \All folder may hold Junk and
// Trash, and mail found nowhere else, so it is never taken for a role and a connection with one
// is not included in All Mail. Otherwise All Mail reads every real folder outside Junk and Trash;
// a virtual \Flagged folder may gather Junk and Trash too.
const imapUnifiedFolders = (
  folders: readonly ImapFolder[],
  role: UnifiedRole,
): readonly string[] | undefined => {
  const holdsAll = (name: string) =>
    folders.some(
      (folder) =>
        folder.name === name &&
        folder.selectable &&
        folder.roles.includes('all'),
    );
  if (role !== allMail) {
    const name = imapRoleFolder(folders, imapRoles[role]);
    return name === undefined || holdsAll(name) ? undefined : [name];
  }
  if (folders.some(({ name }) => holdsAll(name))) {
    return undefined;
  }
  return folders
    .filter(
      ({ selectable, roles }) =>
        selectable &&
        !['junk', 'trash', 'flagged'].some((excluded) =>
          roles.includes(excluded),
        ),
    )
    .map(({ name }) => name);
};

// A Gmail mailbox's system label with the role, or a Microsoft mailbox's well-known folders.
const providerUnifiedFolders = (
  { provider, state }: Readonly<NonNullable<ReturnType<typeof gmailMailbox>>>,
  role: UnifiedRole,
): readonly string[] | undefined => {
  if (provider !== 'microsoft-graph') {
    return [role === 'ARCHIVE' ? gmailArchive : role];
  }
  const views = providerViews(provider, state.unavailableActions);
  if (role !== allMail) {
    return views.includes(role) ? [role] : undefined;
  }
  return [
    inboxFolder,
    ...views.filter((view) => view !== 'SPAM' && view !== 'TRASH'),
    ...microsoftAllMailViews,
    ...state.labels.map(({ id }) => id),
  ];
};

// The folders or views a mailbox lists in a Unified Mailbox, or undefined when its provider marks
// none with that role. A role is never guessed from a folder's name.
export const unifiedFolders = (
  mailbox: BrowsableMailbox,
  role: UnifiedRole,
): readonly string[] | undefined => {
  const { inbox, state } = mailbox;
  if (state.kind !== 'ready') {
    return [];
  }
  if ('openFolder' in inbox && 'folders' in state) {
    return imapUnifiedFolders(state.folders, role);
  }
  const gmail = gmailMailbox(mailbox);
  if (gmail === undefined) {
    return role === allMail ? [inboxFolder] : [];
  }
  return providerUnifiedFolders(gmail, role);
};

// One window's retained Unified Mailbox views. Store identity is part of ownership, so repairing
// a connection releases its old views before opening the replacement store's.
export function createUnifiedMailboxRetention(changed: () => void) {
  const held = new Map<
    string,
    Readonly<{ inbox: BrowsableMailbox['inbox']; release: () => void }>
  >();
  return {
    update: (
      mailboxes: ReadonlyArray<BrowsableMailbox & Readonly<{ id: string }>>,
      role: UnifiedRole | undefined,
    ) => {
      const opened =
        role === undefined
          ? []
          : mailboxes.flatMap((mailbox) =>
              (unifiedFolders(mailbox, role) ?? []).map((name) => ({
                key: `${mailbox.id}\n${name}`,
                mailbox,
                name,
              })),
            );
      const owners = new Map(
        opened.map(({ key, mailbox }) => [key, mailbox.inbox]),
      );
      for (const [key, { inbox, release }] of held) {
        if (owners.get(key) !== inbox) {
          release();
          held.delete(key);
        }
      }
      for (const { key, mailbox, name } of opened) {
        if (name !== inboxFolder && !held.has(key)) {
          held.set(key, {
            inbox: mailbox.inbox,
            release: openUnifiedFolder(mailbox, name, changed),
          });
        }
      }
    },
    dispose: () => {
      for (const { release } of held.values()) {
        release();
      }
      held.clear();
    },
  };
}

// Retains a Gmail or Microsoft view, or follows an IMAP folder. IMAP synchronizes only its Inbox,
// so the folder is read again each time that synchronization finishes. Store actions own errors.
function openUnifiedFolder(
  mailbox: BrowsableMailbox,
  name: string,
  changed: () => void,
) {
  const gmail = gmailMailbox(mailbox);
  if (gmail !== undefined) {
    const release = gmail.inbox.retainView(name);
    void gmail.inbox.openView(name);
    return release;
  }
  if ('openFolder' in mailbox.inbox) {
    const { inbox } = mailbox;
    const statusOf = () => {
      const state = inbox.getSnapshot();
      return state.kind === 'ready' ? state.status : undefined;
    };
    let status = statusOf();
    void inbox.openFolder(name);
    return inbox.subscribe(() => {
      const finished = status === 'syncing';
      status = statusOf();
      if (finished && status === 'current') {
        void inbox.openFolder(name);
      }
      changed();
    });
  }
  return () => undefined;
}

const viewMessages = (
  views: Extract<GmailInboxState, { kind: 'ready' }>['views'],
  label: string,
) => {
  const view = views?.find((shown) => shown.label === label);
  return { messages: view?.messages ?? [], failed: view?.status === 'failed' };
};

const imapFolderMessages = (view: ImapFolderView | undefined) => ({
  messages: view?.kind === 'ready' ? view.messages : [],
  failed: imapFolderFailed(view),
});

// The messages a mailbox lists in one of its folders or views, and whether reading it failed.
const folderMessages = (mailbox: BrowsableMailbox, name: string) => {
  const { inbox, state } = mailbox;
  if (name === inboxFolder) {
    return {
      messages: 'messages' in state ? state.messages : [],
      failed: false,
    };
  }
  const gmail = gmailMailbox(mailbox);
  if (gmail !== undefined) {
    return viewMessages(gmail.state.views, name);
  }
  return imapFolderMessages(
    'openFolder' in inbox ? inbox.folder(name) : undefined,
  );
};

// A Unified Mailbox of a Profile's ready mailboxes, newest first. Each entry names the folder or
// view it is listed in, so its actions are those of that folder at its own connection. Mailboxes
// without the role are `missing`; a folder or view that could not be read makes its mailbox
// `failed`.
export const unifiedMailbox = <
  M extends BrowsableMailbox & Readonly<{ id: string }>,
>(
  mailboxes: readonly M[],
  role: UnifiedRole,
) => {
  const missing: M[] = [];
  const failed: M[] = [];
  const entries = mailboxes.flatMap((mailbox) => {
    const names = unifiedFolders(mailbox, role);
    if (names === undefined) {
      missing.push(mailbox);
      return [];
    }
    const messagesIn = (name: string) => {
      const listed = folderMessages(mailbox, name);
      if (listed.failed) {
        failed.push(mailbox);
      }
      return listed.messages;
    };
    return names.flatMap((name) =>
      messagesIn(name).map((message) => ({
        mailbox,
        message,
        folder: name,
      })),
    );
  });
  return {
    entries: newestFirst(mailboxes, entries),
    missing,
    failed: Arr.dedupe(failed),
  };
};
