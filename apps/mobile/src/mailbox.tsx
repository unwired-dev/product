import type { ReactNode } from 'react';

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useSyncExternalStore,
} from 'react';
import { AppState } from 'react-native';

import type { InboxStore } from './private-storage.ts';

import { inbox } from './private-storage.ts';
import { AccountContext } from './registration-gate.tsx';

const InboxContext = createContext<InboxStore>(inbox);

const waitingForMailbox = { kind: 'loading' } as const;

export function InboxProvider({
  children,
  store = inbox,
}: {
  readonly children: ReactNode;
  readonly store?: InboxStore;
}) {
  const account = useContext(AccountContext);
  useEffect(() => {
    void store.load();
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        void (account === undefined
          ? store.load()
          : account.refreshInbox(store.load));
      }
    });
    return () => {
      subscription.remove();
    };
  }, [account, store]);
  return <InboxContext value={store}>{children}</InboxContext>;
}

export function useInbox() {
  const store = useContext(InboxContext);
  const account = useContext(AccountContext);
  const getSnapshot = useCallback(() => {
    const state = store.getSnapshot();
    return account !== undefined &&
      state.kind === 'ready' &&
      (!('address' in state) || state.address !== account.address)
      ? waitingForMailbox
      : state;
  }, [account, store]);
  return useSyncExternalStore<ReturnType<InboxStore['getSnapshot']>>(
    store.subscribe,
    getSnapshot,
  );
}

export function useInboxActions() {
  return useContext(InboxContext);
}
