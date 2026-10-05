import type { GmailInbox } from '@private-email/mail-core/gmail-inbox';
import type {
  NativeInboxStorage,
  PersistentInbox,
} from '@private-email/mail-core/persistent-inbox';
import type { TurboModule } from 'react-native';

import { loadInitialMessages } from '@private-email/mail-core/inbox-seed';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import { TurboModuleRegistry } from 'react-native';

import { gmailInbox } from './registration.ts';

interface PrivateInboxModule extends TurboModule, NativeInboxStorage {}

export type InboxStore = PersistentInbox | GmailInbox;

// Preview builds show the synthetic fixture; others show the connected Gmail mailbox.
export const inbox: InboxStore = previewInbox
  ? createPersistentInbox(
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
    )
  : gmailInbox;
