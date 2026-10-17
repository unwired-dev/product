import type { TurboModule } from 'react-native';

import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import { TurboModuleRegistry } from 'react-native';

import type { SettingsDestination } from './settings.tsx';

// AppKit's one Settings window, which Command-, and every Inbox window's Settings entry point open.
interface SettingsHost extends TurboModule {
  // Opens the Settings window, or brings the open one forward.
  readonly openSettings: () => void;
  readonly closeSettings: () => void;
  // Brings an Inbox window forward, opening one when none is open.
  readonly focusInbox: () => void;
}

export const settingsHost = () =>
  TurboModuleRegistry.get<SettingsHost>('UnwiredCommands');

// The latest request to open Settings; each is a new value, so an open window follows it.
export type SettingsRequest = Readonly<{
  account?: string;
  destination?: SettingsDestination;
}>;

const emptyRequest: SettingsRequest = {};

let request: SettingsRequest = {};
const listeners = new Set<() => void>();

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};

const latest = () => request;

// Opens Settings beside the Inbox, which keeps its Draft, mailbox and selected message.
export function openSettings(
  account: string,
  destination?: SettingsDestination,
) {
  request = destination === undefined ? { account } : { account, destination };
  for (const listener of listeners) {
    listener();
  }
  settingsHost()?.openSettings();
}

// The Settings window's requests. Closing it forgets the last one it followed, so Command-,
// opens it afresh, but keeps a newer request made for the next window.
export function useSettingsRequest() {
  const current = useSyncExternalStore(subscribe, latest);
  const followed = useRef(current);
  useLayoutEffect(() => {
    followed.current = current;
  }, [current]);
  useEffect(
    () => () => {
      if (request === followed.current) {
        request = emptyRequest;
      }
    },
    [],
  );
  return current;
}

// A request retires with its Product Account, even if that account later returns.
export function useAccountSettingsRequest(
  account: string | undefined,
  incoming: SettingsRequest,
) {
  const [followed, setFollowed] = useState({
    account,
    incoming,
    current:
      incoming.account === undefined || incoming.account === account
        ? incoming
        : emptyRequest,
  });
  let next = followed;
  if (followed.account !== account || followed.incoming !== incoming) {
    next = {
      account,
      incoming,
      current:
        followed.account === account && incoming.account === account
          ? incoming
          : emptyRequest,
    };
    setFollowed(next);
  }
  return next.current;
}
