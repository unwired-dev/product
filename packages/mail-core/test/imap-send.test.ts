import * as Schema from 'effect/Schema';
import PostalMime from 'postal-mime';

import type { RegistrationSnapshot } from '../src/registration.ts';
import type { SyntheticProductSync } from '../src/testing/drafts.ts';

import {
  createDrafts,
  sendingMailboxes,
  sendingStateOf,
} from '../src/drafts.ts';
import { createMailboxes } from '../src/mailboxes.ts';
import { createOutbox, undoSendWindow } from '../src/outbox.ts';
import { mailboxesOf } from '../src/registration.ts';
import { createSyntheticProductSync } from '../src/testing/drafts.ts';
import { syntheticConnections } from '../src/testing/gmail-mailbox.ts';
import { createSyntheticImap } from '../src/testing/imap-mailbox.ts';
import { device, present } from './draft-sync-fixture.ts';
import { account, write } from './outbox-fixture.ts';

// Two Standards-Based Mailbox Connections; each has its own IMAP and SMTP server.
const work = { id: 'connection-work', address: 'alex@work.example.invalid' };
const home = { id: 'connection-home', address: 'alex@home.example.invalid' };

const connection = (
  mailbox: Readonly<{ id: string; address: string }>,
  smtp: boolean,
) => ({
  ...mailbox,
  provider: 'imap',
  state: 'connected',
  imap: { host: 'imap.example.invalid', port: 993, username: mailbox.address },
  ...(smtp
    ? {
        smtp: {
          host: 'smtp.example.invalid',
          port: 465,
          security: 'tls',
          username: mailbox.address,
        },
      }
    : {}),
});
const snapshot = (smtp = true): RegistrationSnapshot => ({
  kind: 'connected',
  productAccountId: account,
  signInProvider: 'google',
  mailboxes: JSON.stringify([connection(work, smtp), connection(home, smtp)]),
});

const decodeRaw = Schema.decodeUnknownSync(
  Schema.Struct({ data: Schema.String }),
);

const clock = { now: 0 };
const later = (milliseconds: number) => {
  clock.now += milliseconds;
  vi.setSystemTime(clock.now);
};

// A device sending from both IMAP connections, each with a Sent folder its server declares.
async function imapSender(
  server: Readonly<SyntheticProductSync> = createSyntheticProductSync(),
) {
  const servers = {
    work: createSyntheticImap({ address: work.address }),
    home: createSyntheticImap({ address: home.address }),
  };
  servers.work.addFolder('Sent', ['sent']);
  servers.home.addFolder('Sent Items', ['sent']);
  const phone = await device(server, account, 'phone');
  phone.change(snapshot());
  const mailboxes = createMailboxes(
    syntheticConnections(
      {},
      { [work.id]: servers.work.native, [home.id]: servers.home.native },
    ),
    phone.registration,
  );
  await mailboxes.load();
  const open = () =>
    createOutbox({
      drafts: phone.drafts,
      mailboxes,
      registration: phone.registration,
      claims: phone.storage.delivery,
    });
  let outbox = open();
  // A Draft from `mailbox` to Sam, with Jo and Avery in a Bcc field long enough to fold.
  const addressed = async (mailbox = work) => {
    const id = present(await phone.drafts.create(mailbox), 'a new Draft');
    const created = phone.draft(id);
    await phone.drafts.update(
      {
        ...write(created, 'See you there'),
        to: [{ name: 'Sam Lee', address: 'sam@example.invalid' }],
        bcc: [
          { name: 'Jo', address: 'jo@example.invalid' },
          {
            name: 'Avery Quinn',
            address: 'avery.quinn@long-department.example.invalid',
          },
        ],
        subject: 'Lunch',
      },
      created,
    );
    return id;
  };
  return {
    ...phone,
    servers,
    mailboxes,
    addressed,
    get drafts() {
      return phone.drafts;
    },
    get outbox() {
      return outbox;
    },
    // A relaunch reopens storage and starts a new Outbox over it.
    relaunch: async () => {
      outbox.dispose();
      await phone.relaunch();
      outbox = open();
    },
    // The only message a server holds in its Sent folder, as raw text.
    copy: async (name: keyof typeof servers, folder: string) => {
      const reply = await servers[name].native.imapMessage(
        { address: '', generation: '' },
        { folder, uidValidity: 3, uid: 1 },
      );
      return Buffer.from(decodeRaw(reply).data, 'base64').toString();
    },
  };
}

describe('sending through SMTP and filing Sent copies', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'] });
    clock.now = Date.UTC(2026, 9, 12, 12);
    vi.setSystemTime(clock.now);
  });
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  afterEach(() => {
    vi.useRealTimers();
  });

  it('submits once from its own connection and files one Sent copy that keeps Bcc', async () => {
    expect.hasAssertions();
    const sending = await imapSender();
    try {
      const id = await sending.addressed(home);
      await expect(
        sending.outbox.send(() => sending.draft(id)),
      ).resolves.toBeUndefined();
      // Nothing reaches the server during the Undo Send Window.
      await sending.outbox.process();
      expect(sending.servers.home.smtp.accepted).toStrictEqual([]);
      later(undoSendWindow);
      await sending.outbox.process();

      const [submitted, ...others] = sending.servers.home.smtp.accepted;
      const { raw } = present(submitted, 'a submission');
      const delivered = await PostalMime.parse(raw);
      // The copy goes to the folder this server declares Sent, with Bcc and the same identity.
      const copy = await PostalMime.parse(
        await sending.copy('home', 'Sent Items'),
      );
      expect({
        others,
        work: sending.servers.work.smtp.accepted,
        recipients: submitted?.recipients,
        delivered: {
          from: delivered.from?.address,
          to: delivered.to?.map(({ address }) => address),
          bcc: delivered.bcc,
          // No line of the folded Bcc field reaches recipients.
          bccLines: /jo@|avery\.quinn@/u.test(raw),
        },
        filed: [
          sending.servers.home.server.changes,
          sending.servers.work.server.changes,
        ],
        copy: {
          bcc: copy.bcc?.map(({ address }) => address),
          messageId: copy.messageId,
          text: copy.text?.trim(),
        },
        outbox: sending.drafts.getOutbox(),
      }).toStrictEqual({
        others: [],
        work: [],
        recipients: [
          'sam@example.invalid',
          'jo@example.invalid',
          'avery.quinn@long-department.example.invalid',
        ],
        delivered: {
          from: home.address,
          to: ['sam@example.invalid'],
          bcc: undefined,
          bccLines: false,
        },
        filed: [['append Sent Items'], []],
        copy: {
          bcc: [
            'jo@example.invalid',
            'avery.quinn@long-department.example.invalid',
          ],
          messageId: delivered.messageId,
          text: 'See you there',
        },
        outbox: [],
      });
      expect(delivered.messageId).toMatch(/@home\.example\.invalid>$/u);
      expect(sending.storage.stored()?.document).toContain(`"id":"${id}"`);
    } finally {
      sending.outbox.dispose();
    }
  });

  it('files the copy again after a lost answer or a relaunch, without a second copy or submission', async () => {
    expect.hasAssertions();
    const sending = await imapSender();
    try {
      const id = await sending.addressed();
      await sending.outbox.send(() => sending.draft(id));
      later(undoSendWindow);
      // The server stores the copy, then the answer is lost.
      sending.servers.work.server.loseReply = true;
      await sending.outbox.process();
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'filing', problem: 'offline' },
      ]);
      // A relaunch while the server cannot be reached keeps the message being filed.
      sending.servers.work.server.failure = 'offline';
      await sending.relaunch();
      await sending.outbox.process();
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'filing' },
      ]);
      // Edit never returns an accepted message to the Drafts.
      await expect(sending.outbox.undo(id)).resolves.toBe(false);
      sending.servers.work.server.failure = undefined;
      await sending.outbox.process();
      expect({
        outbox: sending.drafts.getOutbox(),
        submissions: sending.servers.work.smtp.accepted.length,
        changes: sending.servers.work.server.changes,
      }).toStrictEqual({
        outbox: [],
        submissions: 1,
        changes: ['append Sent'],
      });
    } finally {
      sending.outbox.dispose();
    }
  });

  it('recovers a durable Sent copy with a fresh unopened mailbox without resubmitting', async () => {
    expect.hasAssertions();
    const sending = await imapSender();
    try {
      const id = await sending.addressed();
      await sending.outbox.send(() => sending.draft(id));
      later(undoSendWindow);
      sending.servers.work.server.loseReply = true;
      await sending.outbox.process();
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'filing' },
      ]);
      sending.outbox.dispose();
      sending.storage.relaunch();
      const drafts = createDrafts(sending.storage.native, sending.registration);
      await drafts.load();
      const mailboxes = createMailboxes(
        syntheticConnections({}, { [work.id]: sending.servers.work.native }),
        sending.registration,
      );
      const recovered = createOutbox({
        drafts,
        mailboxes,
        registration: sending.registration,
        claims: sending.storage.delivery,
      });
      try {
        await recovered.process();
        expect({
          outbox: drafts.getOutbox(),
          submissions: sending.servers.work.smtp.accepted.length,
          changes: sending.servers.work.server.changes,
        }).toStrictEqual({
          outbox: [],
          submissions: 1,
          changes: ['append Sent'],
        });
      } finally {
        recovered.dispose();
      }
    } finally {
      sending.outbox.dispose();
    }
  });

  it.each([
    {
      failure: 'smtp-refused',
      state: 'failed',
      problem: 'authorization',
      retried: 0,
    },
    {
      failure: 'smtp-rejected',
      state: 'failed',
      problem: 'refused',
      retried: 0,
    },
    { failure: 'too-large', state: 'failed', problem: 'too-large', retried: 0 },
    {
      failure: 'smtp-insecure',
      state: 'queued',
      problem: 'offline',
      retried: 1,
    },
    { failure: 'offline', state: 'queued', problem: 'offline', retried: 1 },
  ])(
    'keeps $failure before SMTP acceptance as $state $problem',
    async ({ failure, state, problem, retried }) => {
      expect.hasAssertions();
      const sending = await imapSender();
      try {
        const id = await sending.addressed();
        await sending.outbox.send(() => sending.draft(id));
        later(undoSendWindow);
        sending.servers.work.smtp.failure = failure;
        await sending.outbox.process();
        expect(sending.drafts.getOutbox()).toMatchObject([
          { id, state, problem },
        ]);
        expect(sending.servers.work.server.changes).toStrictEqual([]);
        // Only a message that never reached the server is tried again, once.
        await sending.outbox.process();
        expect(sending.servers.work.smtp.accepted).toHaveLength(retried);
      } finally {
        sending.outbox.dispose();
      }
    },
  );

  it('never submits an ambiguous acceptance again and confirms it only from one Sent copy', async () => {
    expect.hasAssertions();
    const sending = await imapSender();
    try {
      const id = await sending.addressed();
      await sending.outbox.send(() => sending.draft(id));
      later(undoSendWindow);
      // The server takes the message's end, then the connection drops.
      sending.servers.work.smtp.lost = true;
      await sending.outbox.process();
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'unknown' },
      ]);
      await sending.relaunch();
      await sending.outbox.process();
      await expect(sending.outbox.check(id)).resolves.toBe(false);
      expect({
        submissions: sending.servers.work.smtp.accepted.length,
        changes: sending.servers.work.server.changes,
      }).toStrictEqual({ submissions: 1, changes: [] });
      // The server filed its own copy; one copy confirms it.
      sending.servers.work.deliver('Sent', {
        subject: 'Lunch',
        raw: present(sending.servers.work.smtp.accepted[0], 'submission').raw,
      });
      await expect(sending.outbox.check(id)).resolves.toBe(true);
      expect(sending.servers.work.smtp.accepted).toHaveLength(1);
    } finally {
      sending.outbox.dispose();
    }
  });

  it('reads a stop after SMTP accepted but before its answer was saved as unknown', async () => {
    expect.hasAssertions();
    const sending = await imapSender();
    try {
      const id = await sending.addressed();
      await sending.outbox.send(() => sending.draft(id));
      sending.servers.work.smtp.stopped = true;
      later(undoSendWindow);
      void sending.outbox.process();
      await vi.waitFor(() => {
        expect(sending.servers.work.smtp.accepted).toHaveLength(1);
      });
      sending.servers.work.smtp.stopped = false;
      await sending.relaunch();
      await sending.outbox.process();
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'unknown' },
      ]);
      expect(sending.servers.work.smtp.accepted).toHaveLength(1);
    } finally {
      sending.outbox.dispose();
    }
  });

  it('keeps malformed native answers pending without a second submission', async () => {
    expect.hasAssertions();
    const sending = await imapSender();
    const { native } = sending.servers.work;
    const submit = vi.spyOn(native, 'imapSend');
    const file = vi.spyOn(native, 'imapFileSent');
    try {
      const unknown = await sending.addressed();
      submit.mockResolvedValueOnce({ accepted: false });
      await sending.outbox.send(() => sending.draft(unknown));
      later(undoSendWindow);
      await sending.outbox.process();
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id: unknown, state: 'unknown' },
      ]);
      await sending.outbox.process();
      const accepted = await sending.addressed();
      file.mockResolvedValueOnce(null);
      await sending.outbox.send(() => sending.draft(accepted));
      later(undoSendWindow);
      await sending.outbox.process();
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id: unknown, state: 'unknown' },
        { id: accepted, state: 'filing' },
      ]);
      await sending.outbox.process();
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id: unknown, state: 'unknown' },
      ]);
      expect({
        submissions: sending.servers.work.smtp.accepted.length,
        changes: sending.servers.work.server.changes,
      }).toStrictEqual({ submissions: 1, changes: ['append Sent'] });
    } finally {
      submit.mockRestore();
      file.mockRestore();
      sending.outbox.dispose();
    }
  });

  it('rechecks the Sent folder after claim admission before SMTP submission', async () => {
    expect.hasAssertions();
    const sending = await imapSender();
    const delivery = present(sending.storage.delivery, 'delivery claims');
    const claim = delivery.claimDraftDelivery;
    const held = vi
      .spyOn(delivery, 'claimDraftDelivery')
      .mockImplementation(async (...args) => {
        const reply = await claim(...args);
        sending.servers.work.removeFolder('Sent');
        await sending.mailboxes.load();
        return reply;
      });
    try {
      const id = await sending.addressed();
      await sending.outbox.send(() => sending.draft(id));
      later(undoSendWindow);
      await sending.outbox.process();
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'failed', problem: 'sent-folder' },
      ]);
      expect(sending.servers.work.smtp.accepted).toStrictEqual([]);
    } finally {
      held.mockRestore();
      sending.outbox.dispose();
    }
  });

  it.each([
    {
      failure: 'gmail-unavailable',
      expected: { kind: 'ready', status: 'authentication' },
    },
    { failure: 'locked', expected: { kind: 'locked' } },
    { failure: 'mailbox-revoked', expected: { kind: 'failed' } },
  ])(
    'applies $failure during Sent filing to the owning mailbox',
    async ({ failure, expected }) => {
      expect.hasAssertions();
      const sending = await imapSender();
      try {
        const id = await sending.addressed();
        await sending.outbox.send(() => sending.draft(id));
        later(undoSendWindow);
        sending.servers.work.server.failure = failure;
        await sending.outbox.process();
        const mailbox = sending.mailboxes
          .getConnections()
          .find(({ id: connection }) => connection === work.id);
        expect(mailbox?.inbox.getSnapshot()).toMatchObject(expected);
        expect(sending.servers.work.smtp.accepted).toHaveLength(1);
        expect(sending.servers.work.server.changes).toStrictEqual([]);
        expect(sending.drafts.getOutbox()).toMatchObject([
          { id, state: 'filing' },
        ]);
      } finally {
        sending.outbox.dispose();
      }
    },
  );

  it.each([
    { failure: 'locked', state: 'locked', outcome: 'queued' },
    { failure: 'mailbox-revoked', state: 'failed', outcome: 'failed' },
  ])(
    'closes stale mail presentation after SMTP reports $failure',
    async ({ failure, state, outcome }) => {
      expect.hasAssertions();
      const sending = await imapSender();
      try {
        const id = await sending.addressed();
        await sending.outbox.send(() => sending.draft(id));
        later(undoSendWindow);
        sending.servers.work.smtp.failure = failure;
        await sending.outbox.process();
        const mailbox = sending.mailboxes
          .getConnections()
          .find(({ id: connection }) => connection === work.id);
        expect(mailbox?.inbox.getSnapshot()).toMatchObject({ kind: state });
        expect(sending.drafts.getOutbox()).toMatchObject([
          { id, state: outcome },
        ]);
        expect(sending.servers.work.smtp.accepted).toStrictEqual([]);
      } finally {
        sending.outbox.dispose();
      }
    },
  );

  it('keeps an interrupted Sent lookup unknown and discards its stale reply', async () => {
    expect.hasAssertions();
    const sending = await imapSender();
    const { native } = sending.servers.work;
    const find = vi.spyOn(native, 'imapFindSent');
    try {
      const id = await sending.addressed();
      await sending.outbox.send(() => sending.draft(id));
      sending.servers.work.smtp.lost = true;
      later(undoSendWindow);
      await sending.outbox.process();
      sending.servers.work.server.failure = 'locked';
      await expect(sending.outbox.check(id)).resolves.toBe(false);
      const mailbox = present(
        sending.mailboxes
          .getConnections()
          .find(({ id: connection }) => connection === work.id),
        'mailbox',
      );
      expect(mailbox.inbox.getSnapshot()).toStrictEqual({ kind: 'locked' });
      sending.servers.work.server.failure = undefined;
      await sending.mailboxes.load();
      const pending = Promise.withResolvers<unknown>();
      const calls = find.mock.calls.length;
      find.mockReturnValueOnce(pending.promise);
      const checked = sending.outbox.check(id);
      await vi.waitFor(() => {
        expect(find).toHaveBeenCalledTimes(calls + 1);
      });
      mailbox.inbox.forget();
      pending.resolve({ count: 1 });
      await expect(checked).resolves.toBe(false);
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'unknown' },
      ]);
      expect(sending.servers.work.smtp.accepted).toHaveLength(1);
    } finally {
      find.mockRestore();
      sending.outbox.dispose();
    }
  });

  it('sends only from connections with verified SMTP and a declared Sent folder', async () => {
    expect.hasAssertions();
    const sending = await imapSender();
    try {
      const id = await sending.addressed();
      sending.servers.work.removeFolder('Sent');
      await sending.mailboxes.load();
      await expect(sending.outbox.send(() => sending.draft(id))).resolves.toBe(
        'sent-folder',
      );
      // A connection saved before SMTP receives only: it is no sender and its Drafts wait.
      sending.change(snapshot(false));
      const listed = mailboxesOf(sending.registration.getSnapshot().snapshot);
      expect(sendingMailboxes(listed, 'default')).toStrictEqual([]);
      expect(sendingStateOf(sending.draft(id), listed)).toBe('password');
      await expect(sending.outbox.send(() => sending.draft(id))).resolves.toBe(
        'sender',
      );
      expect(sending.servers.work.smtp.accepted).toStrictEqual([]);
    } finally {
      sending.outbox.dispose();
    }
  });
});
