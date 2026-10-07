import type { ReactNode } from 'react';

import { createContext, use, useEffect, useSyncExternalStore } from 'react';
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
