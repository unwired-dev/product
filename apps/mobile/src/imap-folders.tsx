import {
  imapFolderFailed,
  imapFolderName,
  inboxFolder,
} from '@private-email/mail-core/imap-inbox';
import { useEffect, useMemo, useSyncExternalStore } from 'react';

import type { InboxMailbox } from './private-storage.ts';
import type { MailboxView } from './sidebar.tsx';

const noSubscription = () => () => undefined;

// An IMAP mailbox shown on its own lists the folder its view names; the Inbox is listed
// otherwise. A folder the server no longer offers falls back to the Inbox and drops the choice,
// so a recreated folder of that name is not reopened from a stale cache.
export function useImapFolder<E>(
  shown: readonly InboxMailbox[],
  // The Inbox entries listed when no other folder is chosen.
  inbox: readonly E[],
  {
    view,
    onView,
  }: Readonly<{
    view: MailboxView;
    onView: (view: MailboxView) => void;
  }>,
) {
  const [single] = shown;
  const imap =
    shown.length === 1 && single !== undefined && 'openFolder' in single.inbox
      ? single
      : undefined;
  const requested =
    imap !== undefined && view.mailbox === imap.id
      ? (view.folder ?? inboxFolder)
      : inboxFolder;
  const state = imap?.state;
  const folder = imapFolderName(
    state?.kind === 'ready' && 'folders' in state ? state : undefined,
    requested,
  );
  const dropped = folder !== requested;
  useEffect(() => {
    if (dropped) {
      onView({ mailbox: view.mailbox });
    }
  }, [dropped, onView, view.mailbox]);
  const browsing = useFolderEntries(imap, folder);
  return {
    folder,
    listed: browsing?.entries ?? inbox,
    failed: imapFolderFailed(browsing?.view),
  };
}

// The chosen folder's messages as list entries, or undefined for the Inbox.
function useFolderEntries(
  mailbox: InboxMailbox | undefined,
  folder: string | undefined,
) {
  const inbox =
    mailbox !== undefined && 'openFolder' in mailbox.inbox
      ? mailbox.inbox
      : undefined;
  const view = useSyncExternalStore(inbox?.subscribe ?? noSubscription, () =>
    inbox === undefined || folder === undefined || folder === inboxFolder
      ? undefined
      : inbox.folder(folder),
  );
  return useMemo(
    () =>
      mailbox === undefined || view === undefined
        ? undefined
        : {
            view,
            entries:
              view.kind === 'ready'
                ? view.messages.map((message) => ({ mailbox, message }))
                : [],
          },
    [mailbox, view],
  );
}
