import { messageZooms } from '@private-email/mail-core/message-body';
import { useEffect, useSyncExternalStore } from 'react';
import { Settings } from 'react-native';

// A value the app shares, read once and then followed; `keep` keeps each change.
const shared = <A>(read: () => A, keep?: (value: A) => void) => {
  let current: { readonly value: A } | undefined = undefined;
  const listeners = new Set<() => void>();
  const snapshot = () => {
    current ??= { value: read() };
    return current.value;
  };
  const subscribe = (listener: () => void) => {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  };
  return {
    get: snapshot,
    set: (value: A) => {
      keep?.(value);
      current = { value };
      for (const listener of listeners) {
        listener();
      }
    },
    useValue: () => useSyncExternalStore(subscribe, snapshot),
  };
};

// A choice kept in user defaults under `key`, on this device only.
const deviceSetting = <A>(key: string, read: (stored: unknown) => A) =>
  shared(
    () => read(Settings.get(key)),
    (value) => {
      Settings.set({ [key]: value });
    },
  );

const messageZoom = deviceSetting(
  'UnwiredMessageZoom',
  (stored) => messageZooms.find((each) => each === stored) ?? 100,
);
export const setMessageZoom = messageZoom.set;
export type MessageZoom = (typeof messageZooms)[number];

// Zooming one message: the open message's own zoom, in memory until the message closes.
const ownZoom = shared<Readonly<{ id: string; zoom: MessageZoom }> | undefined>(
  () => undefined,
);
export const zoomMessage = (id: string, zoom: MessageZoom) => {
  ownZoom.set({ id, zoom });
};
// Closing message `id` drops its own zoom, so it opens again at the stored Message Zoom.
export const closeMessageZoom = (id: string) => {
  if (ownZoom.get()?.id === id) {
    ownZoom.set(undefined);
  }
};

// The reader's Message Zoom, in percent: message `id`'s own zoom, otherwise the stored one.
export const useMessageZoom = (id?: string) => {
  const stored = messageZoom.useValue();
  const own = ownZoom.useValue();
  return own !== undefined && own.id === id ? own.zoom : stored;
};

// The messages whose formatted document the reader shows, the ones a zoom changes.
const formatted = shared<ReadonlySet<string>>(() => new Set());
export const useShowsFormatted = (id: string, shown: boolean) => {
  useEffect(() => {
    if (!shown) {
      return undefined;
    }
    formatted.set(new Set([...formatted.get(), id]));
    return () => {
      formatted.set(
        new Set([...formatted.get()].filter((each) => each !== id)),
      );
    };
  }, [id, shown]);
};
export const useFormatted = (id: string) => formatted.useValue().has(id);

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

// The sanitized document marked to fit: the reader's measurement shrinks it to the view's width
// with an app-owned transform, in place. Floats stay inside the body and shrink with it, and the
// zero-height root lets the scroll range end at the shrunk content.
export const fittedDocument = (html: string) =>
  html.replace(
    '</head>',
    '<style>:root{--unwired-fit:1}html{height:0}body{display:flow-root;transform-origin:0 0}</style></head>',
  );
