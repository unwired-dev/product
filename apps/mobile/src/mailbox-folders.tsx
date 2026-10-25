import type { UnifiedRole } from '@private-email/mail-core/mailboxes';

import {
  imapFolderFailed,
  inboxFolder,
} from '@private-email/mail-core/imap-inbox';
import {
  createGmailViewEntries,
  createUnifiedMailboxRetention,
  gmailMailbox,
  gmailViewRow,
  mailboxFolder,
  unifiedMailbox,
  unifiedRow,
} from '@private-email/mail-core/mailboxes';
import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useReducer,
  useSyncExternalStore,
} from 'react';

import type { InboxMailbox } from './private-storage.ts';
import type { MailboxView } from './sidebar.tsx';

import { useLocalization } from './localization.ts';

const noSubscription = () => () => undefined;

// A mailbox shown on its own lists the IMAP folder or Gmail view its window chose; the Inbox is
// listed otherwise. A folder or label the mailbox no longer offers falls back to the Inbox and
// drops the choice, so a recreated one of that name is not reopened from a stale cache.
function useMailboxFolder<E>(
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
  const { t } = useLocalization();
  const [single] = shown;
  const chosen =
    shown.length === 1 && single !== undefined && view.mailbox === single.id
      ? single
      : undefined;
  const requested = view.folder ?? inboxFolder;
  const folder = mailboxFolder(chosen, requested);
  const dropped = chosen !== undefined && folder !== requested;
  useEffect(() => {
    if (dropped) {
      onView({ mailbox: view.mailbox });
    }
  }, [dropped, onView, view.mailbox]);
  const browsing = useFolderEntries(chosen, folder);
  const gmail = useGmailView(chosen, folder);
  if (gmail !== undefined) {
    return { folder, ...gmail };
  }
  return {
    folder,
    title: folder === inboxFolder ? undefined : folder,
    listed: browsing?.entries ?? inbox,
    failure: imapFolderFailed(browsing?.view)
      ? t('imap.foldersUnavailable')
      : undefined,
    limited: undefined,
  };
}

const noEntries: readonly [] = [];
const viewEntries = createGmailViewEntries<InboxMailbox>();

// The chosen Gmail view's messages as list entries, or undefined for the Inbox and other
// providers. Its window retains the view before requesting it, so another cannot evict it.
function useGmailView(mailbox: InboxMailbox | undefined, folder: string) {
  const { t } = useLocalization();
  const gmail = folder === inboxFolder ? undefined : gmailMailbox(mailbox);
  const shown = gmail?.state.views?.find(({ label }) => label === folder);
  const store = gmail?.inbox;
  useLayoutEffect(() => {
    if (store === undefined) {
      return undefined;
    }
    const release = store.retainView(folder);
    void store.openView(folder);
    return release;
  }, [store, folder]);
  const listed =
    mailbox === undefined || shown === undefined
      ? noEntries
      : viewEntries(mailbox, shown.messages);
  if (gmail === undefined) {
    return undefined;
  }
  const { title, failure, limited } = gmailViewRow(t, gmail, folder);
  return { title, listed, failure, limited };
}

// The chosen IMAP folder's messages as list entries, or undefined for the Inbox.
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

// The list a window shows: the Unified Mailbox it chose, or else its chosen mailbox's folder.
// `folderOf` names the folder or view a row is listed in, which its actions are those of.
export function useListedMailbox<E>(
  shown: readonly InboxMailbox[],
  // The Inbox entries listed when no other folder is chosen.
  inbox: readonly E[],
  options: Readonly<{
    view: MailboxView;
    onView: (view: MailboxView) => void;
  }>,
) {
  const { t } = useLocalization();
  const chosen = useMailboxFolder(shown, inbox, options);
  const role = options.view.unified;
  const unified = useUnifiedMailbox(shown, role);
  const rowFolder = useMemo(
    () =>
      new Map(
        unified?.entries.map(({ mailbox, message, folder }) => [
          `${mailbox.id}\n${message.id}`,
          folder,
        ]),
      ),
    [unified],
  );
  if (role === undefined || unified === undefined) {
    return {
      ...chosen,
      missing: [],
      folderOf: (_mailbox: string, _id: string) => chosen.folder,
    };
  }
  return {
    ...chosen,
    title: unifiedRow(t, role).title,
    listed: unified.entries,
    failure:
      unified.failed.length === 0 ? undefined : t('imap.foldersUnavailable'),
    // Mailboxes whose provider marks no folder with the role, which the list names as left out.
    missing: unified.missing,
    folderOf: (mailbox: string, id: string) =>
      rowFolder.get(`${mailbox}\n${id}`) ?? inboxFolder,
  };
}

// A Unified Mailbox of the window's mailboxes. Each mailbox's folders or views with the role are
// retained and opened while it is shown, and the list follows them as they sync.
function useUnifiedMailbox(
  mailboxes: readonly InboxMailbox[],
  role: UnifiedRole | undefined,
) {
  const [, changed] = useReducer((count: number) => count + 1, 0);
  const retained = useMemo(
    () => createUnifiedMailboxRetention(changed),
    [changed],
  );
  useLayoutEffect(() => {
    retained.update(mailboxes, role);
  }, [retained, mailboxes, role]);
  useLayoutEffect(
    () => () => {
      retained.dispose();
    },
    [retained],
  );
  return role === undefined ? undefined : unifiedMailbox(mailboxes, role);
}
