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

type ViewInputs<C> = Readonly<{
  mailboxes: ReadonlyArray<Readonly<{ id: string }>>;
  // The window's Profile's connections.
  connections: readonly C[];
  view: Readonly<{ mailbox?: string | undefined }>;
}>;

// The chosen connection while it waits for provider authorization: it has no Inbox store but
// stays chosen, so New Message cannot fall back to another sender.
export const waitingChoice = <
  C extends Pick<MailboxConnection, 'id' | 'state'>,
>({
  mailboxes,
  connections,
  view,
}: ViewInputs<C>) =>
  connections.find(
    ({ id, state }) =>
      id === view.mailbox &&
      state === 'authorization' &&
      !mailboxes.some((mailbox) => mailbox.id === id),
  );

// Whether a window's chosen mailbox is still shown; a removed mailbox's view falls back to every
// mailbox.
export const keepsChoice = (
  inputs: ViewInputs<Pick<MailboxConnection, 'id' | 'state'>>,
) =>
  waitingChoice(inputs) !== undefined ||
  inputs.mailboxes.some(({ id }) => id === inputs.view.mailbox);

// The authorization notices a view shows: every waiting connection under every mailbox, the chosen
// one when it waits, and none for a listed mailbox.
export const authorizationWaiting = <
  C extends Pick<MailboxConnection, 'id' | 'state'>,
>(
  connections: readonly C[],
  {
    scope,
    chosen,
  }: Readonly<{ scope: string | undefined; chosen: C | undefined }>,
) =>
  chosen === undefined
    ? connections.filter(
        ({ state }) => scope === undefined && state === 'authorization',
      )
    : [chosen];

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
  // Waiting connections have no store until authorization succeeds; never duplicate a store row.
  const waiting = profileMailboxes(connections, profile).filter(
    ({ id, state }) =>
      state === 'authorization' &&
      !mailboxes.some((mailbox) => mailbox.id === id),
  );
  // A chosen connection stays chosen while it waits for authorization; only a removed one falls
  // back to every mailbox.
  const waitingChosen = waiting.some(({ id }) => id === view.mailbox);
  return {
    unread: sections.reduce((sum, section) => sum + section.unread, 0),
    allSelected: chosen === undefined && !waitingChosen,
    sections,
    waiting: waiting.map((connection) => ({
      connection,
      recovery: connection.provider === 'imap' ? 'account' : 'authorization',
      selected: connection.id === view.mailbox,
    })),
  };
}
