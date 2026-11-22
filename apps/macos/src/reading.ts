import { messageZooms } from '@private-email/mail-core/message-body';
import { useSyncExternalStore } from 'react';
import { Settings } from 'react-native';

// The reader's Message Zoom, in percent: kept in this Mac's user defaults, read once and then
// followed by every window.
const key = 'UnwiredMessageZoom';
let current: number | undefined = undefined;
const listeners = new Set<() => void>();
const snapshot = () => {
  const stored: unknown = Settings.get(key);
  current ??= messageZooms.find((each) => each === stored) ?? 100;
  return current;
};
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};

export const setMessageZoom = (value: number) => {
  Settings.set({ [key]: value });
  current = value;
  for (const listener of listeners) {
    listener();
  }
};
export const useMessageZoom = () => useSyncExternalStore(subscribe, snapshot);
