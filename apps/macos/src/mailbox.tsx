import type { Drafts } from '@private-email/mail-core/drafts';
import type { ReactNode } from 'react';

import {
  createContext,
  use,
  useEffect,
  useMemo,
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
import { drafts as defaultDrafts } from './registration.ts';

const MailboxesContext = createContext<MailboxList>(defaultMailboxes);
const DraftsContext = createContext<Drafts>(defaultDrafts);
// The mailbox a reader or status belongs to.
const MailboxContext = createContext<InboxMailbox | undefined>(undefined);

interface ComposerNavigation {
  readonly register: (finish: () => Promise<boolean>) => () => void;
  readonly leave: () => Promise<boolean>;
}
function createComposerNavigation(): ComposerNavigation {
  let finish: (() => Promise<boolean>) | undefined = undefined;
  let pending = false;
  return {
    register: (next) => {
      finish = next;
      return () => {
        if (finish === next) {
          finish = undefined;
        }
      };
    },
    leave: async () => {
      if (pending) {
        return false;
      }
      pending = true;
      try {
        return (await finish?.()) ?? true;
      } catch {
        // A composer that failed to finish stays open; a later attempt can leave again.
        return false;
      } finally {
        pending = false;
      }
    },
  };
}
const ComposerNavigationContext = createContext(createComposerNavigation());
export function useComposerNavigation() {
  return use(ComposerNavigationContext);
}
export function useLeaveComposer() {
  return useComposerNavigation().leave;
}

const waitingForMailbox = { kind: 'loading' } as const;

export function InboxProvider({
  children,
  mailboxes = defaultMailboxes,
  drafts = defaultDrafts,
}: {
  readonly children: ReactNode;
  readonly mailboxes?: MailboxList;
  readonly drafts?: Drafts;
}) {
  const account = use(AccountContext);
  const navigation = useMemo(() => createComposerNavigation(), []);
  useEffect(() => {
    void drafts.load();
  }, [drafts]);
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
  return (
    <MailboxesContext value={mailboxes}>
      <DraftsContext value={drafts}>
        <ComposerNavigationContext value={navigation}>
          {children}
        </ComposerNavigationContext>
      </DraftsContext>
    </MailboxesContext>
  );
}

// The signed-in Product Account's Drafts store and its state.
export function useDraftStore() {
  return use(DraftsContext);
}

export function useDrafts() {
  const drafts = use(DraftsContext);
  return useSyncExternalStore(drafts.subscribe, drafts.getSnapshot);
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
