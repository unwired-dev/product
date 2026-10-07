import type { ReactNode } from 'react';

import { savedMessageBodies } from '@private-email/mail-core/mailboxes';
import {
  createContext,
  use,
  useEffect,
  useState,
  useSyncExternalStore,
} from 'react';
import { AppState } from 'react-native';

import type {
  InboxMailbox,
  InboxStore,
  MailboxList,
} from './private-storage.ts';

import { mailboxes as defaultMailboxes } from './private-storage.ts';
import { AccountContext } from './registration-gate.tsx';

const MailboxesContext = createContext<MailboxList>(defaultMailboxes);
// The mailbox a reader or status belongs to.
const MailboxContext = createContext<InboxMailbox | undefined>(undefined);

const waitingForMailbox = { kind: 'loading' } as const;

export function InboxProvider({
  children,
  mailboxes = defaultMailboxes,
}: {
  readonly children: ReactNode;
  readonly mailboxes?: MailboxList;
}) {
  const account = use(AccountContext);
  useEffect(() => {
    void mailboxes.load();
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        void (account === undefined
          ? mailboxes.load()
          : account.refreshInbox(mailboxes.load));
      }
    });
    return () => {
      subscription.remove();
    };
  }, [account, mailboxes]);
  return <MailboxesContext value={mailboxes}>{children}</MailboxesContext>;
}

// Every mailbox the Inbox shows, in the order the connections were added.
export function useMailboxes() {
  const mailboxes = use(MailboxesContext);
  return useSyncExternalStore(mailboxes.subscribe, mailboxes.getSnapshot);
}

export function useReloadMailboxes() {
  return use(MailboxesContext).load;
}

// Scopes the Inbox hooks below to one mailbox; without it, `fallback` shows instead.
export function MailboxScope({
  id,
  children,
  fallback = null,
}: {
  readonly id: string;
  readonly children: ReactNode;
  readonly fallback?: ReactNode;
}) {
  const mailbox = useMailboxes().find((item) => item.id === id);
  return mailbox === undefined ? (
    fallback
  ) : (
    <MailboxContext value={mailbox}>{children}</MailboxContext>
  );
}

export function useMailbox() {
  return use(MailboxContext);
}

// The scoped mailbox's Inbox state.
export function useInbox(): InboxMailbox['state'] {
  return use(MailboxContext)?.state ?? waitingForMailbox;
}

export function useInboxActions(): InboxStore {
  const mailbox = use(MailboxContext);
  if (mailbox === undefined) {
    throw new Error('Inbox actions need a MailboxScope');
  }
  return mailbox.inbox;
}

type Result = Readonly<{
  mailbox: InboxMailbox;
  message: Readonly<{ id: string }>;
}>;

// Whether each search result's body opens from this device, by `resultKey`; absent while unknown.
// Each answer belongs to the results and `refresh` it was asked for, so a slower reply for an
// earlier query, scope or set of mailboxes never replaces the current one. A new `refresh`, such
// as a reader opening or closing a result, asks again, and so does any body saved or pruned in
// the background while the results are shown; only the latest of those answers is kept.
export function useSavedBodies(
  results: readonly Result[] | undefined,
  refresh: string,
) {
  const { bodies } = use(MailboxesContext);
  const [answer, setAnswer] = useState<
    Readonly<{
      results: readonly Result[];
      refresh: string;
      saved: ReadonlyMap<string, boolean>;
    }>
  >();
  useEffect(() => {
    if (results === undefined) {
      return;
    }
    let current = true;
    let asked = 0;
    const lookup = async () => {
      asked += 1;
      const question = asked;
      const saved = await savedMessageBodies(results);
      if (current && question === asked) {
        setAnswer({ results, refresh, saved });
      }
    };
    void lookup();
    const unsubscribe = bodies?.subscribe(() => {
      void lookup();
    });
    return () => {
      current = false;
      unsubscribe?.();
    };
  }, [results, refresh, bodies]);
  return answer !== undefined &&
    answer.results === results &&
    answer.refresh === refresh
    ? answer.saved
    : undefined;
}
