import type { Device } from './outbox-fixture.ts';

import { createOutbox, undoSendWindow } from '../src/outbox.ts';
import { alex } from './draft-sync-fixture.ts';
import { account, addressed, sender, sharedAccount } from './outbox-fixture.ts';

// The controlled clock every journey runs on.
const clock = { now: 0 };
const later = (milliseconds: number) => {
  clock.now += milliseconds;
  vi.setSystemTime(clock.now);
};

describe('recovering Outbox outcomes and late Send refusals', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'] });
    clock.now = Date.UTC(2026, 9, 9, 12);
    vi.setSystemTime(clock.now);
  });
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  afterEach(() => {
    vi.useRealTimers();
  });

  it('saves a definite non-delivery again when storage refused it, then sends once', async () => {
    expect.hasAssertions();
    let phone: Device | undefined = undefined;
    const { server, gmail } = sharedAccount(() => phone);
    const sending = await sender(server, gmail, 'phone');
    phone = sending;
    try {
      const id = await addressed(sending);
      await sending.outbox.send(() => sending.draft(id));
      later(undoSendWindow);
      // Gmail refuses for a rate limit, and storage refuses to record that answer.
      gmail.failSend({ status: 429, body: '{}' });
      const { gmailSend } = gmail.native;
      gmail.native.gmailSend = async (...args) => {
        gmail.native.gmailSend = gmailSend;
        const reply = await gmailSend(...args);
        sending.storage.failNextCommit('locked');
        return reply;
      };

      await sending.outbox.process();
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'sending' },
      ]);

      later(30_000);
      await sending.outbox.process();
      // The definite non-delivery is recorded, so the message stays retryable and editable.
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'queued', problem: 'rate-limited' },
      ]);
      later(30_000);
      await sending.outbox.process();
      expect(gmail.sends).toHaveLength(1);
      expect(sending.drafts.getOutbox()).toStrictEqual([]);
    } finally {
      sending.outbox.dispose();
    }
  });

  it.each([
    { outcome: 'sent', status: 200, states: [], editable: false },
    { outcome: 'unknown', status: 503, states: ['unknown'], editable: false },
    { outcome: 'failed', status: 400, states: ['failed'], editable: true },
  ])(
    'saves a refused $outcome outcome again without another Gmail submission',
    async ({ status, states, editable }) => {
      expect.hasAssertions();
      let phone: Device | undefined = undefined;
      const { server, gmail } = sharedAccount(() => phone);
      const sending = await sender(server, gmail, 'phone');
      phone = sending;
      try {
        const id = await addressed(sending);
        await sending.outbox.send(() => sending.draft(id));
        later(undoSendWindow);
        gmail.failSend({ status, body: '{}' });
        const { gmailSend } = gmail.native;
        let submissions = 0;
        gmail.native.gmailSend = async (...args) => {
          submissions += 1;
          const reply = await gmailSend(...args);
          sending.storage.failNextCommit('locked');
          return reply;
        };
        await sending.outbox.process();
        expect(sending.drafts.getOutbox()).toMatchObject([
          { id, state: 'sending' },
        ]);
        // A second refusal retains the same answer for another storage-only retry.
        sending.storage.failNextCommit('locked');
        later(30_000);
        await sending.outbox.process();
        expect(sending.drafts.getOutbox()).toMatchObject([
          { id, state: 'sending' },
        ]);
        later(30_000);
        await sending.outbox.process();
        await sending.relaunch();
        await sending.outbox.process();
        expect(submissions).toBe(1);
        expect(
          sending.drafts
            .getOutbox()
            .map((entry) => ({ id: entry.id, state: entry.state })),
        ).toStrictEqual(states.map((state) => ({ id, state })));
        expect(typeof (await sending.outbox.undo(id)) === 'string').toBe(
          editable,
        );
      } finally {
        sending.outbox.dispose();
      }
    },
  );

  it('refuses Send when the sending mailbox changes while its files are verified', async () => {
    expect.hasAssertions();
    let phone: Device | undefined = undefined;
    const { server, gmail } = sharedAccount(() => phone);
    const sending = await sender(server, gmail, 'phone');
    phone = sending;
    const outbox = createOutbox({
      drafts: {
        ...sending.drafts,
        readAsset: async (asset, options) => {
          sending.change({
            kind: 'connected',
            productAccountId: account,
            signInProvider: 'google',
            mailboxes: JSON.stringify([
              {
                ...alex,
                address: 'renamed@example.invalid',
                state: 'connected',
              },
            ]),
          });
          return sending.drafts.readAsset(asset, options);
        },
      },
      mailboxes: sending.mailboxes,
      registration: sending.registration,
      claims: sending.storage.delivery,
    });
    try {
      const id = await addressed(sending);
      const draft = sending.draft(id);
      sending.storage.addFile('file:///notes.txt', 'notes');
      const notes = sending.drafts.prepare({
        name: 'notes.txt',
        type: 'text/plain',
      });
      await sending.drafts.update({ ...draft, attachments: [notes] }, draft);
      await sending.drafts.importAsset(notes, {
        kind: 'file',
        uri: 'file:///notes.txt',
      });

      await expect(outbox.send(() => sending.draft(id))).resolves.toBe(
        'sender',
      );

      expect(sending.drafts.getOutbox()).toStrictEqual([]);
      expect(sending.list().map((each) => each.id)).toStrictEqual([id]);
    } finally {
      outbox.dispose();
      sending.outbox.dispose();
    }
  });
});
