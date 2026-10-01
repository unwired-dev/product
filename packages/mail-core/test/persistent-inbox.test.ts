import { inspect } from 'node:util';

import { fixtureMessages } from '../src/index.ts';
import { makeMockInboxStorage } from '../src/mock-storage.ts';
import { createPersistentInbox } from '../src/persistent-inbox.ts';

describe('mock Mail Session persistence boundary', () => {
  it('recovers committed read state in a new session without losing competing changes', async () => {
    expect.hasAssertions();
    const storage = makeMockInboxStorage();
    const first = createPersistentInbox(storage);
    const second = createPersistentInbox(storage);
    await Promise.all([first.load(), second.load()]);
    await Promise.all([
      first.setUnread('studio-review', false),
      second.setUnread('weekend-walk', false),
    ]);
    const reopened = createPersistentInbox(storage);
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
  });

  it('fails closed on malformed data and failing providers without logging mail or account data', async () => {
    expect.hasAssertions();
    const logged: unknown[] = [];
    for (const method of ['log', 'info', 'warn', 'error'] as const) {
      vi.spyOn(console, method).mockImplementation((...values) => {
        logged.push(...values);
      });
    }
    const message = { ...fixtureMessages[0], body: 'sealed-body-7f3a' };
    const inbox = createPersistentInbox({
      open: () =>
        Promise.resolve(
          JSON.stringify({
            version: 1,
            revision: 0,
            messages: [{ ...message, unread: 'sealed-flag-7f3a' }],
          }),
        ),
      setUnread: () => Promise.reject(new Error('unavailable')),
    });
    await inbox.load();
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'failed' });
    // Seed providers and native hosts may reject with account data in any field.
    const seeded = createPersistentInbox(
      {
        open: () => Promise.reject(new Error('unavailable')),
        setUnread: () => Promise.reject(new Error('unavailable')),
      },
      () => Promise.reject(new Error('sealed-seed alex@example.com')),
    );
    await seeded.load();
    expect(seeded.getSnapshot()).toStrictEqual({ kind: 'failed' });
    for (const rejection of [
      Object.assign(new Error('sealed-store alex@example.com'), {
        code: 'unavailable',
      }),
      Object.assign(new Error('unavailable'), {
        code: 'sealed-code alex@example.com',
      }),
      Object.assign(new Error('unavailable'), {
        name: 'sealed-name alex@example.com',
      }),
    ]) {
      const failing = createPersistentInbox({
        open: () => Promise.reject(rejection),
        setUnread: () => Promise.reject(new Error('unavailable')),
      });
      await failing.load();
      expect(failing.getSnapshot()).toStrictEqual({ kind: 'failed' });
    }
    expect(
      logged.filter((value) => value === 'Private Inbox storage failed:'),
    ).toHaveLength(5);
    expect(logged).toStrictEqual(
      expect.arrayContaining([
        'invalid at messages.0.unread',
        'Error',
        'code unavailable',
        'unrecognized code',
        'unrecognized error',
      ]),
    );
    expect(inspect(logged, { depth: 10 })).not.toMatch(/sealed-|alex@/u);
  });
});
