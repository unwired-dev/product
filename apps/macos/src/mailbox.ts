import { useEffect, useSyncExternalStore } from 'react';
import { AppState } from 'react-native';

import { inbox } from './private-storage.ts';

export function useInbox() {
  useEffect(() => {
    void inbox.load();
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        void inbox.load();
      }
    });
    return () => {
      subscription.remove();
    };
  }, []);
  return useSyncExternalStore(inbox.subscribe, inbox.getSnapshot);
}

export function useInboxActions() {
  return inbox;
}
