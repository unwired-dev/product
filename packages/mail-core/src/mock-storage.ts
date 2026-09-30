import type { NativeInboxStorage } from './persistent-inbox.ts';

import { fixtureMessages } from './index.ts';

export function makeMockInboxStorage(): NativeInboxStorage {
  let messages = fixtureMessages;
  let revision = 0;
  const snapshot = () => JSON.stringify({ version: 1, revision, messages });
  return {
    open: () => Promise.resolve(snapshot()),
    setUnread: (id, unread) => {
      messages = messages.map((message) =>
        message.id === id ? { ...message, unread } : message,
      );
      revision += 1;
      return Promise.resolve(snapshot());
    },
  };
}
