import { useSyncExternalStore } from 'react';
import { Settings } from 'react-native';

// The user defaults keys the choices are kept under, on this device only.
const zoomKey = 'UnwiredMessageZoom';
const fitKey = 'UnwiredFitWideMessages';
// Safari's page zoom levels, in percent.
export const messageZooms = [
  50, 75, 85, 100, 115, 125, 150, 175, 200, 250, 300,
] as const;

export type Reading = Readonly<{ zoom: number; fit: boolean }>;

const stored = (): Reading => {
  const zoom: unknown = Settings.get(zoomKey);
  const fit: unknown = Settings.get(fitKey);
  return {
    zoom: messageZooms.find((each) => each === zoom) ?? 100,
    fit: fit === true || fit === 1,
  };
};

let current: Reading | undefined = undefined;
const listeners = new Set<() => void>();
const snapshot = () => (current ??= stored());
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};
export const saveReading = (change: Partial<Reading>) => {
  if (change.zoom !== undefined) {
    Settings.set({ [zoomKey]: change.zoom });
  }
  if (change.fit !== undefined) {
    Settings.set({ [fitKey]: change.fit });
  }
  current = { ...snapshot(), ...change };
  for (const listener of listeners) {
    listener();
  }
};

// The reader's Message Zoom, in percent, and whether wide messages shrink to the reader's width.
export const useReading = () => useSyncExternalStore(subscribe, snapshot);

// The sanitized document zoomed by `scale`; the app's own style, so the message is unchanged.
export const zoomedDocument = (html: string, scale: number) =>
  scale === 1
    ? html
    : html.replace('</head>', `<style>body{zoom:${scale}}</style></head>`);
