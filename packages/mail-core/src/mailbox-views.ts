import type { Translate } from '@private-email/localization';

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
import type { InboxState, PersistentInbox } from './persistent-inbox.ts';
import type {
  MailboxConnection,
  MailProvider,
} from './registration-snapshot.ts';

import {
  gmailViewSymbol,
  gmailViewTitle,
  systemViews,
} from './gmail-actions.ts';
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

// The Gmail view a window shows: the one it chose while the mailbox still has it, otherwise the
// Inbox, as for an IMAP folder the server no longer offers.
export const gmailViewName = (state: GmailInboxState, requested: string) =>
  state.kind !== 'ready' ||
  requested === inboxFolder ||
  systemViews.some((view) => view === requested) ||
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

// Only a ready Gmail connection offers label views; Microsoft shares its store, without views.
export const gmailMailbox = (mailbox: BrowsableMailbox | undefined) => {
  if (mailbox === undefined || (mailbox.provider ?? 'gmail') !== 'gmail') {
    return undefined;
  }
  const { inbox, state } = mailbox;
  return 'openView' in inbox && state.kind === 'ready' && 'labels' in state
    ? { inbox, state }
    : undefined;
};

// A Gmail view as both hosts show it, in the sidebar and the list: its name, SF Symbol, the
// notice for a failed read, and whether it keeps only its newest messages.
export const gmailViewRow = (
  t: Translate,
  state: Extract<GmailInboxState, { kind: 'ready' }>,
  label: string,
) => {
  const view = state.views?.find((entry) => entry.label === label);
  const title = gmailViewTitle(t, label, state.labels);
  return {
    title,
    icon: gmailViewSymbol(label),
    failure:
      view?.status === 'failed'
        ? t('mailboxes.viewUnavailable', {
            view: title,
            provider: t('mailProviders.gmail'),
          })
        : undefined,
    limited: view?.limited === true,
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
    : gmailViewName(gmail.state, requested);
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

// A mailbox's sidebar rows: an IMAP connection's selectable folders, or a Gmail mailbox's Inbox,
// its own labels by name, then All Mail, Spam and Trash; other mailboxes list their Inbox.
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
  return 'labels' in state && (provider ?? 'gmail') === 'gmail'
    ? [inboxFolder, ...state.labels.map(({ id }) => id), ...systemViews]
    : [inboxFolder];
};

// The unread mail of an opened Gmail label's saved view; Gmail counts none for All Mail, Spam
// and Trash, and an IMAP folder's count is not known here.
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
  view: Readonly<{ mailbox?: string | undefined; folder?: string | undefined }>;
}>) {
  const chosen = mailboxes.find(({ id }) => id === view.mailbox);
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
    allSelected: !inboxChoice({
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
