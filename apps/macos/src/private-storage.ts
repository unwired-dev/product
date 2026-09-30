import type { NativeInboxStorage } from '@private-email/mail-core/persistent-inbox';
import type { TurboModule } from 'react-native';

import { loadInitialMessages } from '@private-email/mail-core/inbox-seed';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { TurboModuleRegistry } from 'react-native';

interface PrivateInboxModule extends TurboModule, NativeInboxStorage {}

export const inbox = createPersistentInbox(
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
);
