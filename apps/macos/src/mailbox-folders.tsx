import type { GmailMessage } from '@private-email/mail-core/gmail-inbox';

import { gmailViewTitle } from '@private-email/mail-core/gmail-actions';
import {
  imapFolderFailed,
  inboxFolder,
} from '@private-email/mail-core/imap-inbox';
import {
  gmailMailbox,
  mailboxFolder,
} from '@private-email/mail-core/mailboxes';
import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useSyncExternalStore,
} from 'react';

import type { InboxMailbox } from './private-storage.ts';
import type { MailboxView } from './sidebar.tsx';

import { useLocalization } from './localization.ts';

const noSubscription = () => () => undefined;

// A mailbox shown on its own lists the IMAP folder or Gmail view its window chose; the Inbox is
// listed otherwise. A folder or label the mailbox no longer offers falls back to the Inbox and
// drops the choice, so a recreated one of that name is not reopened from a stale cache.
export function useMailboxFolder<E>(
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
  // A message chosen outside the Inbox names its view, which its actions can take it out of.
  const selection = folder === inboxFolder ? {} : { folder };
  if (gmail !== undefined) {
    return {
      folder,
      selection,
      title: gmail.title,
      listed: gmail.listed,
      failure: gmail.failed
        ? t('mailboxes.viewUnavailable', {
            view: gmail.title,
            provider: t('mailProviders.gmail'),
          })
        : undefined,
      limited: gmail.limited,
    };
  }
  return {
    folder,
    selection,
    title: folder === inboxFolder ? undefined : folder,
    listed: browsing?.entries ?? inbox,
    failure: imapFolderFailed(browsing?.view)
      ? t('imap.foldersUnavailable')
      : undefined,
    limited: false,
  };
}

const noEntries: readonly [] = [];
// List entries stay the same array while the store publishes the same messages, so searches and
// saved-body checks over them are not repeated on every render.
const entriesOf = new WeakMap<
  readonly GmailMessage[],
  ReadonlyArray<Readonly<{ mailbox: InboxMailbox; message: GmailMessage }>>
>();
const viewEntries = (
  mailbox: InboxMailbox,
  messages: readonly GmailMessage[],
) => {
  const cached = entriesOf.get(messages);
  // A newer snapshot of the same mailbox lists entries again, so rows act on its current state.
  if (cached !== undefined && (cached[0]?.mailbox ?? mailbox) === mailbox) {
    return cached;
  }
  const entries = messages.map((message) => ({ mailbox, message }));
  entriesOf.set(messages, entries);
  return entries;
};

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
  return gmail === undefined
    ? undefined
    : {
        title: gmailViewTitle(t, folder, gmail.state.labels),
        listed,
        failed: shown?.status === 'failed',
        // The view keeps only its newest messages; older ones stay in Gmail.
        limited: shown?.limited === true,
      };
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
