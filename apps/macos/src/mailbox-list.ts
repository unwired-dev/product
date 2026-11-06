import { createContext, use, useSyncExternalStore } from 'react';

import type { MailboxList } from './private-storage.ts';

import { mailboxes as defaultMailboxes } from './private-storage.ts';

// Every Profile's mailboxes, apart from the Inbox's account so Settings can read them too.
export const MailboxesContext = createContext<MailboxList>(defaultMailboxes);

// Every Profile's mailboxes, which the Profile Menu's unread counts and Settings › Email Accounts
// read.
export function useAllMailboxes() {
  const mailboxes = use(MailboxesContext);
  return useSyncExternalStore(mailboxes.subscribe, mailboxes.getSnapshot);
}
