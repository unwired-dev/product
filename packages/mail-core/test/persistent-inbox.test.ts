import { makeMockInboxStorage } from '../src/mock-storage.ts';
import { createPersistentInbox } from '../src/persistent-inbox.ts';

describe('mock Mail Session persistence boundary', () => {
  it('recovers committed read state in a new session without losing competing changes', async () => {
    expect.hasAssertions();
    const storage = makeMockInboxStorage();
    const first = createPersistentInbox(storage);
    const second = createPersistentInbox(storage);
    try {
      await Promise.all([first.load(), second.load()]);
      await Promise.all([
        first.setUnread('studio-review', false),
        second.setUnread('weekend-walk', false),
      ]);
      const reopened = createPersistentInbox(storage);
      try {
        await reopened.load();
        expect(reopened.getSnapshot()).toMatchObject({
          kind: 'ready',
          messages: [
            { id: 'studio-review', unread: false },
            { id: 'weekend-walk', unread: false },
            { id: 'reading-list', unread: false },
            { id: 'reservation', unread: false },
          ],
        });
      } finally {
        await reopened.dispose();
      }
    } finally {
      await Promise.all([first.dispose(), second.dispose()]);
    }
  });

  it('hides stale mail on failed writes and retries the preserved store after unlock', async () => {
    expect.hasAssertions();
    const storage = makeMockInboxStorage();
    let current = storage;
    const locked = {
      open: () =>
        Promise.reject(Object.assign(new Error('locked'), { code: 'locked' })),
      setUnread: () =>
        Promise.reject(Object.assign(new Error('locked'), { code: 'locked' })),
    };
    const inbox = createPersistentInbox({
      open: (seed) => current.open(seed),
      setUnread: (id, unread) => current.setUnread(id, unread),
    });
    try {
      await inbox.load();
      await inbox.setUnread('studio-review', false);
      current = locked;
      await inbox.setUnread('weekend-walk', false);
      expect(inbox.getSnapshot()).toStrictEqual({ kind: 'locked' });
      await inbox.load();
      expect(inbox.getSnapshot()).toStrictEqual({ kind: 'locked' });
      current = storage;
      await inbox.load();
      expect(inbox.getSnapshot()).toMatchObject({
        kind: 'ready',
        messages: [
          { id: 'studio-review', unread: false },
          { id: 'weekend-walk', unread: true },
          { id: 'reading-list', unread: false },
          { id: 'reservation', unread: false },
        ],
      });
    } finally {
      await inbox.dispose();
    }
  });

  it('rejects malformed native data without falling back to an in-memory Inbox', async () => {
    expect.hasAssertions();
    const inbox = createPersistentInbox({
      open: () => Promise.resolve('{"version":2,"messages":[]}'),
      setUnread: () => Promise.reject(new Error('unavailable')),
    });
    try {
      await inbox.load();
      expect(inbox.getSnapshot()).toStrictEqual({ kind: 'failed' });
    } finally {
      await inbox.dispose();
    }
  });
});
