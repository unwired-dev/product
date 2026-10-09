import type { Drafts } from '@private-email/mail-core/drafts';
import type { Outbox } from '@private-email/mail-core/outbox';
import type { ReactNode } from 'react';

import { createComposerNavigation } from '@private-email/mail-core/composer-navigation';
import {
  createGmailSearch,
  savedMessageBodies,
} from '@private-email/mail-core/mailboxes';
import {
  createContext,
  use,
  useEffect,
  useMemo,
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
import {
  drafts as defaultDrafts,
  outbox as defaultOutbox,
} from './registration.ts';

const MailboxesContext = createContext<MailboxList>(defaultMailboxes);
const DraftsContext = createContext<Drafts>(defaultDrafts);
const OutboxContext = createContext<Outbox>(defaultOutbox);
// The mailbox a reader or status belongs to.
const MailboxContext = createContext<InboxMailbox | undefined>(undefined);

const ComposerNavigationContext = createContext(createComposerNavigation());
export function useComposerNavigation() {
  return use(ComposerNavigationContext);
}
export function useLeaveComposer() {
  return useComposerNavigation().leave;
}

const waitingForMailbox = { kind: 'loading' } as const;

// Every window shows the same Draft store, so one lifecycle subscription serves them all: returning
// picks up other devices' Draft changes, and leaving publishes this device's.
const lifecycles = new Map<Drafts, { windows: number; remove: () => void }>();
const followLifecycle = (drafts: Drafts) => {
  const followed = lifecycles.get(drafts);
  if (followed === undefined) {
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active' || state === 'background') {
        void drafts.syncInBackground();
      }
    });
    lifecycles.set(drafts, {
      windows: 1,
      remove: () => {
        subscription.remove();
      },
    });
  } else {
    followed.windows += 1;
  }
  return () => {
    const current = lifecycles.get(drafts);
    if (current !== undefined) {
      current.windows -= 1;
      if (current.windows === 0) {
        current.remove();
        lifecycles.delete(drafts);
      }
    }
  };
};

export function InboxProvider({
  children,
  mailboxes = defaultMailboxes,
  drafts = defaultDrafts,
  outbox = defaultOutbox,
}: {
  readonly children: ReactNode;
  readonly mailboxes?: MailboxList;
  readonly drafts?: Drafts;
  // Sends the Drafts admitted to `drafts`' Outbox.
  readonly outbox?: Outbox;
}) {
  const account = use(AccountContext);
  const navigation = useMemo(() => createComposerNavigation(), []);
  useEffect(() => {
    void drafts.load();
    return followLifecycle(drafts);
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
  useEffect(() => {
    // Returning tries queued messages again at once.
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        void outbox.process();
      }
    });
    return () => {
      subscription.remove();
    };
  }, [outbox]);
  return (
    <MailboxesContext value={mailboxes}>
      <DraftsContext value={drafts}>
        <OutboxContext value={outbox}>
          <ComposerNavigationContext value={navigation}>
            {children}
          </ComposerNavigationContext>
        </OutboxContext>
      </DraftsContext>
    </MailboxesContext>
  );
}

export function useOutbox() {
  return use(OutboxContext);
}

// The Outbox of the signed-in Product Account, oldest Send first.
export function useOutboxEntries() {
  const drafts = use(DraftsContext);
  return useSyncExternalStore(drafts.subscribe, drafts.getOutbox);
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

// Each query/view owns a separate shared store. A changed view hides the previous store during
// render, before its effect cleanup, including when the person later returns to that view.
export function useGmailSearch(
  shown: readonly InboxMailbox[],
  query: string,
  scope: string | undefined,
) {
  const [search, setSearch] = useState(() =>
    createGmailSearch(shown, query, scope),
  );
  if (!search.matches(shown, query, scope)) {
    setSearch(createGmailSearch(shown, query, scope));
  }
  const state = useSyncExternalStore(search.subscribe, search.getSnapshot);
  useEffect(() => search.forget, [search]);
  return {
    ...state,
    available: search.available,
    search: search.search,
    more: search.more,
  };
}
