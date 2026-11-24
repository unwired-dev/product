import type { UnifiedRole } from '@private-email/mail-core/mailboxes';

import { inboxFolder } from '@private-email/mail-core/imap-inbox';
import {
  createUnifiedMailboxRetention,
  folderListing,
  gmailMailbox,
  inboxUnlisted,
  listedFolder,
  notIncludedDetail,
  unifiedFolders,
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
// listed otherwise. A choice the mailbox no longer offers is dropped from the window's view.
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
  const { chosen, folder, dropped } = listedFolder(shown, view);
  useEffect(() => {
    if (dropped) {
      onView({ mailbox: view.mailbox });
    }
  }, [dropped, onView, view.mailbox]);
  useFolderUpdates(chosen, folder);
  useRetainedView(chosen, folder);
  const listing = folderListing(t, chosen, folder);
  const messages = listing?.messages;
  const entries = useMemo(
    () =>
      chosen === undefined || messages === undefined
        ? undefined
        : messages.map((message) => ({ mailbox: chosen, message })),
    [chosen, messages],
  );
  // Reaching the end reveals older Gmail mail its devices downloaded, in the chosen view or in
  // each shown mailbox's Inbox.
  const showOlder = () => {
    if (folder !== inboxFolder) {
      gmailMailbox(chosen)?.inbox.showOlder(folder);
      return;
    }
    for (const mailbox of shown) {
      gmailMailbox(mailbox)?.inbox.showOlder(inboxFolder);
    }
  };
  if (listing === undefined || entries === undefined) {
    return {
      folder,
      showOlder,
      title: folder === inboxFolder ? undefined : folder,
      listed: inbox,
      // An Inbox not yet listed has not answered a search.
      unlisted: shown.some(({ state }) => inboxUnlisted(state)),
      failure: undefined,
      limited: undefined,
      downloading: undefined,
    };
  }
  const { title, unlisted, failure, limited, downloading } = listing;
  return {
    folder,
    showOlder,
    title,
    listed: entries,
    unlisted,
    failure,
    limited,
    downloading,
  };
}

// Re-renders as the chosen IMAP folder changes; its listing reads the folder through the store.
function useFolderUpdates(mailbox: InboxMailbox | undefined, folder: string) {
  const inbox =
    mailbox !== undefined && 'openFolder' in mailbox.inbox
      ? mailbox.inbox
      : undefined;
  useSyncExternalStore(inbox?.subscribe ?? noSubscription, () =>
    inbox === undefined || folder === inboxFolder
      ? undefined
      : inbox.folder(folder),
  );
}

// A window retains its chosen Gmail view before requesting it, so another cannot evict it.
function useRetainedView(mailbox: InboxMailbox | undefined, folder: string) {
  const store =
    folder === inboxFolder ? undefined : gmailMailbox(mailbox)?.inbox;
  useLayoutEffect(() => {
    if (store === undefined) {
      return undefined;
    }
    const release = store.retainView(folder);
    void store.openView(folder);
    return release;
  }, [store, folder]);
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
    unlisted: unified.unlisted,
    failure:
      unified.failed.length === 0 ? undefined : t('imap.foldersUnavailable'),
    // Reaching the end reveals each Gmail mailbox's older downloaded mail with the role.
    showOlder: () => {
      for (const mailbox of shown) {
        for (const view of unifiedFolders(mailbox, role) ?? []) {
          gmailMailbox(mailbox)?.inbox.showOlder(view);
        }
      }
    },
    // Mailboxes left out of the role, which the list names with the reason.
    missing: unified.missing.map((mailbox) => ({
      mailbox,
      detail: notIncludedDetail(mailbox, role),
    })),
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
    () => createUnifiedMailboxRetention<InboxMailbox>(changed),
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
  return role === undefined ? undefined : retained.listed(mailboxes, role);
}
