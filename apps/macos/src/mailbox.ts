import {
  useCallback,
  useContext,
  useEffect,
  useSyncExternalStore,
} from 'react';
import { AppState } from 'react-native';

import type { InboxStore } from './private-storage.ts';

import { inbox } from './private-storage.ts';
import { AccountContext } from './registration-gate.tsx';

const waitingForMailbox = { kind: 'loading' } as const;

export function useInbox() {
  const account = useContext(AccountContext);
  useEffect(() => {
    void inbox.load();
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        void (account === undefined
          ? inbox.load()
          : account.refreshInbox(inbox.load));
      }
    });
    return () => {
      subscription.remove();
    };
  }, [account]);
  const getSnapshot = useCallback(() => {
    const state = inbox.getSnapshot();
    return account !== undefined &&
      state.kind === 'ready' &&
      (!('address' in state) || state.address !== account.address)
      ? waitingForMailbox
      : state;
  }, [account]);
  return useSyncExternalStore<ReturnType<InboxStore['getSnapshot']>>(
    inbox.subscribe,
    getSnapshot,
  );
}

export function useInboxActions() {
  return inbox;
}
