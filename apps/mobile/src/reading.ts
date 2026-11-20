import { useSyncExternalStore } from 'react';
import { Settings } from 'react-native';

// Safari's page zoom levels, in percent.
export const messageZooms = [
  50, 75, 85, 100, 115, 125, 150, 175, 200, 250, 300,
] as const;

// A choice kept in user defaults under `key`, on this device only, read once and then followed.
const deviceSetting = <A>(key: string, read: (stored: unknown) => A) => {
  let current: { readonly value: A } | undefined = undefined;
  const listeners = new Set<() => void>();
  const snapshot = () => {
    current ??= { value: read(Settings.get(key)) };
    return current.value;
  };
  const subscribe = (listener: () => void) => {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  };
  return {
    set: (value: A) => {
      Settings.set({ [key]: value });
      current = { value };
      for (const listener of listeners) {
        listener();
      }
    },
    useValue: () => useSyncExternalStore(subscribe, snapshot),
  };
};

const messageZoom = deviceSetting(
  'UnwiredMessageZoom',
  (stored) => messageZooms.find((each) => each === stored) ?? 100,
);
export const setMessageZoom = messageZoom.set;
// The reader's Message Zoom, in percent.
export const useMessageZoom = messageZoom.useValue;

// Fit Wide Messages to the Screen; on until turned off.
const fitWideMessages = deviceSetting(
  'UnwiredFitWideMessages',
  (stored) => stored !== false && stored !== 0,
);
export const setFitWideMessages = fitWideMessages.set;
export const useFitWideMessages = fitWideMessages.useValue;

// The sanitized document zoomed by `scale`; the app's own style, so the message is unchanged.
export const zoomedDocument = (html: string, scale: number) =>
  scale === 1
    ? html
    : html.replace('</head>', `<style>body{zoom:${scale}}</style></head>`);

// The sanitized document shrunk to `scale` of its laid-out size. A transform keeps the layout, so
// one measurement at the reader's width gives the scale that fits; with no height of its own, the
// root measures at the shrunk height.
export const fittedDocument = (html: string, scale: number) =>
  scale === 1
    ? html
    : html.replace(
        '</head>',
        `<style>html{height:0}body{transform:scale(${scale});transform-origin:0 0}</style></head>`,
      );
