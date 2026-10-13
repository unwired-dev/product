import type { GmailInboxState } from './gmail-inbox.ts';
import type { ImapInboxState } from './imap-inbox.ts';
import type { InboxState } from './persistent-inbox.ts';
import type { MailboxConnection } from './registration.ts';

import { inboxFolder } from './imap-inbox.ts';

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
  return {
    unread: sections.reduce((sum, section) => sum + section.unread, 0),
    allSelected: chosen === undefined,
    sections,
    // Waiting connections have no store until authorization succeeds; never duplicate a store row.
    waiting: profileMailboxes(connections, profile)
      .filter(
        ({ id, state }) =>
          state === 'authorization' &&
          !mailboxes.some((mailbox) => mailbox.id === id),
      )
      .map((connection) => ({
        connection,
        recovery: connection.provider === 'imap' ? 'account' : 'authorization',
      })),
  };
}
