import type { PersistentInbox } from '@private-email/mail-core/persistent-inbox';
import type { ReactNode } from 'react';

import {
  createContext,
  useContext,
  useEffect,
  useSyncExternalStore,
} from 'react';
import { AppState } from 'react-native';

import { inbox } from './private-storage.ts';

const InboxContext = createContext(inbox);

export function InboxProvider({
  children,
  store = inbox,
}: {
  readonly children: ReactNode;
  readonly store?: PersistentInbox;
}) {
  useEffect(() => {
    void store.load();
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        void store.load();
      }
    });
    return () => {
      subscription.remove();
    };
  }, [store]);
  return <InboxContext value={store}>{children}</InboxContext>;
}

export function useInbox() {
  const store = useContext(InboxContext);
  return useSyncExternalStore(store.subscribe, store.getSnapshot);
}

export function useInboxActions() {
  return useContext(InboxContext);
}
