import type { GmailInbox } from '@private-email/mail-core/gmail-inbox';
import type {
  NativeInboxStorage,
  PersistentInbox,
} from '@private-email/mail-core/persistent-inbox';
import type { TurboModule } from 'react-native';

import { loadInitialMessages } from '@private-email/mail-core/inbox-seed';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import { TurboModuleRegistry } from 'react-native';

import { gmailMailboxes } from './registration.ts';

interface PrivateInboxModule extends TurboModule, NativeInboxStorage {}

export type InboxStore = PersistentInbox | GmailInbox;
type InboxState = ReturnType<InboxStore['getSnapshot']>;

// A mailbox the Inbox shows: a Mailbox Connection, or the preview fixture, which has no address.
export type InboxMailbox = Readonly<{
  id: string;
  address?: string;
  inbox: InboxStore;
  state: InboxState;
}>;

export interface MailboxList {
  readonly getSnapshot: () => readonly InboxMailbox[];
  readonly subscribe: (listener: () => void) => () => void;
  readonly load: () => Promise<void>;
  // Gmail mailboxes' body cache; the preview fixture keeps bodies with its metadata.
  readonly bodies?: Readonly<{
    getSnapshot: () => number;
    subscribe: (listener: () => void) => () => void;
  }>;
}

// Preview builds show the synthetic fixture; others show every connected Gmail mailbox.
export const mailboxes: MailboxList = previewInbox
  ? singleMailbox(
      createPersistentInbox(
        {
          open: (seed) =>
            TurboModuleRegistry.getEnforcing<PrivateInboxModule>(
              'UnwiredPrivateInbox',
            ).open(seed),
          setUnread: (id, unread) =>
            TurboModuleRegistry.getEnforcing<PrivateInboxModule>(
              'UnwiredPrivateInbox',
            ).setUnread(id, unread),
        },
        loadInitialMessages,
      ),
      'preview',
    )
  : gmailMailboxes;
