import { useSyncExternalStore } from 'react';
import { Settings } from 'react-native';

// The user defaults key the Message Zoom is kept under, on this device only.
const key = 'UnwiredMessageZoom';
// Safari's page zoom levels, in percent.
export const messageZooms = [
  50, 75, 85, 100, 115, 125, 150, 175, 200, 250, 300,
] as const;

let current: number | undefined = undefined;
const listeners = new Set<() => void>();
const snapshot = () => {
  if (current === undefined) {
    const stored: unknown = Settings.get(key);
    current = messageZooms.find((each) => each === stored) ?? 100;
  }
  return current;
};
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};

export const setMessageZoom = (zoom: number) => {
  Settings.set({ [key]: zoom });
  current = zoom;
  for (const listener of listeners) {
    listener();
  }
};

// The reader's Message Zoom, in percent.
export const useMessageZoom = () => useSyncExternalStore(subscribe, snapshot);

// The sanitized document zoomed by `scale`; the app's own style, so the message is unchanged.
export const zoomedDocument = (html: string, scale: number) =>
  scale === 1
    ? html
    : html.replace('</head>', `<style>body{zoom:${scale}}</style></head>`);
