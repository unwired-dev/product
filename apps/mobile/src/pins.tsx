import type { Pins } from '@private-email/mail-core/pins';

import { pinnedThread } from '@private-email/mail-core/pins';
import { createContext, use, useEffect, useState } from 'react';
import { Alert, AppState } from 'react-native';

import { useLocalization } from './localization.ts';
import { pins } from './registration.ts';

export const PinsContext = createContext<Pins>(pins);

// A listed message: its ID and, unless it has none, its provider conversation.
type Listed = Parameters<typeof pinnedThread>[0];

const key = (connection: string, thread: string) => `${connection}\n${thread}`;

// Whether a message's Thread is pinned in its Mailbox Connection, among `connections`. Storage is
// read again after every Pin or Unpin and when the app becomes active, so a read refused while storage
// was locked recovers; until it is read, nothing is pinned.
export function usePinned(connections: readonly string[]) {
  const store = use(PinsContext);
  const [pinned, setPinned] = useState<ReadonlySet<string>>(new Set());
  const listed = connections.join('\n');
  useEffect(() => {
    let read = 0;
    const load = async () => {
      read += 1;
      const reading = read;
      const stored = await store.pins(listed.split('\n'));
      if (reading === read && stored !== undefined) {
        setPinned(
          new Set(
            stored.map(({ connection, thread }) => key(connection, thread)),
          ),
        );
      }
    };
    void load();
    const unsubscribe = store.subscribe(() => {
      void load();
    });
    const activation = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        void load();
      }
    });
    return () => {
      read += 1;
      unsubscribe();
      activation.remove();
    };
  }, [store, listed]);
  return (connection: string, message: Listed) =>
    pinned.has(key(connection, pinnedThread(message)));
}

// Pin, or Unpin when `pinned`, for a message's Thread in `connection`, as a row or toolbar action.
// A change storage refuses is explained in a system alert.
export function usePinAction() {
  const store = use(PinsContext);
  const { t } = useLocalization();
  return (connection: string, message: Listed, pinned: boolean) => {
    const name = pinned ? 'unpin' : 'pin';
    const change = async () => {
      const thread = pinnedThread(message);
      if (
        !(await (pinned
          ? store.unpin(connection, thread)
          : store.pin(connection, thread)))
      ) {
        Alert.alert(t(`pins.${name}Failed`), t('pins.tryAgain'), [
          { text: t('common.ok') },
        ]);
      }
    };
    return {
      name,
      label: t(`contextMenu.${name}`),
      run: () => {
        void change();
      },
    } as const;
  };
}
