import type { GmailInboxState } from './gmail-inbox.ts';
import type { ImapFolderView, ImapInboxState } from './imap-inbox.ts';
import type { InboxState } from './persistent-inbox.ts';
import type { MailboxConnection } from './registration.ts';

import { imapFolderFailed, inboxFolder } from './imap-inbox.ts';

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

// The sidebar projects already-decoded stores; hosts retain rendering and navigation callbacks.
export function mailboxSidebar<
  L extends Readonly<{
    id: string;
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
    const folders =
      state.kind === 'ready' && 'folders' in state
        ? state.folders.filter(({ selectable }) => selectable)
        : [{ name: inboxFolder }];
    return {
      mailbox,
      unread,
      problem: problemOf(state),
      folders: folders.map(({ name }) => ({
        name,
        inbox: name === inboxFolder,
        unread: name === inboxFolder ? unread : 0,
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
