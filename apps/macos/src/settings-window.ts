import { useState, useSyncExternalStore } from 'react';

import type { SettingsDestination } from './settings.tsx';

import {
  observeSettingsClose,
  settingsHost,
} from './settings-window-client.ts';

// The latest request to open Settings; each is a new value, so an open window follows it.
export type SettingsRequest = Readonly<{
  account?: string | undefined;
  destination?: SettingsDestination;
}>;

const emptyRequest: SettingsRequest = {};

let request: SettingsRequest = {};
let requestSerial = 0;
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
  account: string | undefined,
  destination?: SettingsDestination,
) {
  observeSettingsClose((closedSerial) => {
    if (closedSerial === requestSerial) {
      request = emptyRequest;
    }
  });
  requestSerial += 1;
  request = destination === undefined ? { account } : { account, destination };
  for (const listener of listeners) {
    listener();
  }
  settingsHost()?.openSettings(requestSerial);
}

// AppKit retires the request its window accepted. React teardown cannot retire a newer one.
export function useSettingsRequest() {
  return useSyncExternalStore(subscribe, latest);
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
