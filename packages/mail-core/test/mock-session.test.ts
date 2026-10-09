import { makeMockInboxStorage } from '../src/mock-storage.ts';
import { createPersistentInbox } from '../src/persistent-inbox.ts';
import {
  createMockMailSession,
  syntheticSummary,
} from '../src/testing/mock-session.ts';

describe('isolated synthetic providers', () => {
  it('replays open, mark-read and relaunch without changing another session or reseeding committed state', async () => {
    expect.hasAssertions();
    const session = createMockMailSession('open-read-relaunch');
    const boundary = makeMockInboxStorage();
    const first = createPersistentInbox(boundary, session.mail.list);
    await first.load();
    expect(first.getSnapshot()).toMatchObject({
      kind: 'ready',
      messages: expect.arrayContaining([
        expect.objectContaining({ id: 'studio-review', unread: true }),
      ]),
    });
    await first.setUnread('studio-review', false);
    const relaunched = createPersistentInbox(boundary, session.mail.list);
    const isolated = createPersistentInbox(
      makeMockInboxStorage(),
      session.mail.list,
    );
    await Promise.all([relaunched.load(), isolated.load()]);
    expect(relaunched.getSnapshot()).toMatchObject({
      kind: 'ready',
      messages: expect.arrayContaining([
        expect.objectContaining({ id: 'studio-review', unread: false }),
      ]),
    });
    expect(isolated.getSnapshot()).toMatchObject({
      kind: 'ready',
      messages: expect.arrayContaining([
        expect.objectContaining({ id: 'studio-review', unread: true }),
      ]),
    });
    await expect(session.identity.signIn()).resolves.toStrictEqual({
      kind: 'synthetic',
      account: 'mock-product-account',
      address: 'alex@example.invalid',
    });
    await expect(session.assistance.summarize()).resolves.toBe(
      syntheticSummary,
    );
  });

  it.each(['identity-unavailable', 'mail-unavailable'])(
    'fails closed for %s without presenting fallback mail',
    async (scenario) => {
      expect.hasAssertions();
      const session = createMockMailSession(scenario);
      const inbox = createPersistentInbox(
        makeMockInboxStorage(),
        session.mail.list,
      );
      await inbox.load();
      expect(inbox.getSnapshot()).toStrictEqual({ kind: 'failed' });
    },
  );

  it('controls assistance failure without affecting the synthetic mailbox', async () => {
    expect.hasAssertions();
    const session = createMockMailSession('assistance-unavailable');
    await expect(session.assistance.availability()).resolves.toBe(
      'model-not-ready',
    );
    await expect(session.assistance.summarize()).rejects.toThrow(
      'Synthetic provider unavailable',
    );
    await expect(session.mail.list()).resolves.toStrictEqual(
      expect.arrayContaining([
        expect.objectContaining({ id: 'studio-review', unread: true }),
      ]),
    );
  });

  it.each([
    'production',
    { scenario: 'open-read-relaunch', credentials: 'real-token' },
    {
      scenario: 'open-read-relaunch',
      account: 'real-account',
      mailbox: 'person@gmail.com',
    },
    { scenario: 'open-read-relaunch', endpoint: 'https://production.invalid' },
  ])(
    'rejects configuration that could introduce external authority: %j',
    (selection) => {
      expect.hasAssertions();
      expect(() => createMockMailSession(selection)).toThrow(/Expected/u);
    },
  );
});
