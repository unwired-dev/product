import type { Translate } from '@private-email/localization';

import { lastUpdated } from '@private-email/localization';
import { createContext, use, useSyncExternalStore } from 'react';

import type { InboxMailbox, MailboxList } from './private-storage.ts';

import { mailboxes as defaultMailboxes } from './private-storage.ts';

// The Inbox's mailboxes. Settings, outside the Inbox, reads the default list the Inbox opens.
export const MailboxesContext = createContext<MailboxList | undefined>(
  undefined,
);
export const useMailboxList = () => use(MailboxesContext) ?? defaultMailboxes;

// Every Profile's mailboxes, which the Profile Menu's unread counts and Settings read.
export function useAllMailboxes() {
  const mailboxes = useMailboxList();
  return useSyncExternalStore(mailboxes.subscribe, mailboxes.getSnapshot);
}

// The minute freshness and the list's dividers read by, so a day ends at midnight while it is open.
const minute = 60_000;
// One clock for every reader of the minute, ticking on the minute, so the list and an open reader
// always read the same minute and change day together.
const minuteListeners = new Set<() => void>();
const currentMinute = () => Math.floor(Date.now() / minute) * minute;
let shownMinute = currentMinute();
let minuteTimer: ReturnType<typeof setTimeout> | undefined = undefined;
const tickMinute = () => {
  shownMinute = currentMinute();
  minuteTimer = setTimeout(
    () => {
      tickMinute();
      for (const listener of minuteListeners) {
        listener();
      }
    },
    shownMinute + minute - Date.now(),
  );
};
const subscribeMinute = (notify: () => void) => {
  minuteListeners.add(notify);
  if (minuteTimer === undefined) {
    tickMinute();
  }
  return () => {
    minuteListeners.delete(notify);
    if (minuteListeners.size === 0) {
      clearTimeout(minuteTimer);
      minuteTimer = undefined;
    }
  };
};
export const useNow = () =>
  useSyncExternalStore(subscribeMinute, () =>
    minuteTimer === undefined ? currentMinute() : shownMinute,
  );

// How long ago a mailbox last synchronized; undefined before its first synchronization.
export const updatedOf = (
  t: Translate,
  state: InboxMailbox['state'] | undefined,
  now: number,
) =>
  state?.kind === 'ready' &&
  'synchronizedAt' in state &&
  state.synchronizedAt !== undefined
    ? lastUpdated(t, [state.synchronizedAt], now)
    : undefined;
