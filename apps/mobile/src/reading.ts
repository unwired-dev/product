import { messageZooms } from '@private-email/mail-core/message-body';
import { useSyncExternalStore } from 'react';
import { Settings } from 'react-native';

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

// The sanitized document marked to fit: the reader's measurement shrinks it to the view's width
// with an app-owned transform, in place. Floats stay inside the body and shrink with it, and the
// zero-height root lets the scroll range end at the shrunk content.
export const fittedDocument = (html: string) =>
  html.replace(
    '</head>',
    '<style>:root{--unwired-fit:1}html{height:0}body{display:flow-root;transform-origin:0 0}</style></head>',
  );
