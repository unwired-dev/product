import PostalMime from 'postal-mime';

import type { RegistrationSnapshot } from '../src/registration.ts';

import { createDrafts, sendingMailboxes } from '../src/drafts.ts';
import { createMailboxes } from '../src/mailboxes.ts';
import { createOutbox, undoSendWindow } from '../src/outbox.ts';
import { defaultProfile, mailboxesOf } from '../src/registration.ts';
import { insertImage } from '../src/semantic-document.ts';
import { createSyntheticProductSync } from '../src/testing/drafts.ts';
import { syntheticConnections } from '../src/testing/gmail-mailbox.ts';
import { createSyntheticGraph } from '../src/testing/graph-mailbox.ts';
import { device, present } from './draft-sync-fixture.ts';
import { account, write } from './outbox-fixture.ts';

// One Microsoft Mailbox Connection, sending through Graph.
const outlook = {
  id: 'connection-outlook',
  address: 'casey@contoso.example.invalid',
};
const snapshot = (state = 'connected'): RegistrationSnapshot => ({
  kind: 'connected',
  productAccountId: account,
  signInProvider: 'apple',
  mailboxes: JSON.stringify([
    { ...outlook, provider: 'microsoft-graph', state },
  ]),
});

const clock = { now: 0 };
const later = (milliseconds: number) => {
  clock.now += milliseconds;
  vi.setSystemTime(clock.now);
};

// A device whose only mailbox is a Microsoft connection. Graph reads each sent file's bytes from
// this device's Draft storage, as its native code would.
async function microsoftSender() {
  const server = createSyntheticProductSync();
  const phone = await device(server, account, 'phone');
  phone.change(snapshot());
  const graph = createSyntheticGraph({
    address: outlook.address,
    assets: (id, digest) => phone.storage.bytesOf(account, id, digest),
  });
  const mailboxes = createMailboxes(
    syntheticConnections({ [outlook.id]: graph }),
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
  // A Draft to Sam, with Jo in Bcc.
  const addressed = async (text = 'See you there') => {
    const id = present(await phone.drafts.create(outlook), 'a new Draft');
    const created = phone.draft(id);
    await phone.drafts.update(
      {
        ...write(created, text),
        to: [{ name: 'Sam Lee', address: 'sam@example.invalid' }],
        bcc: [{ name: 'Jo', address: 'jo@example.invalid' }],
        subject: 'Lunch',
      },
      created,
    );
    return id;
  };
  return {
    ...phone,
    graph,
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
  };
}

// Larger than Graph's single request, with files of both sizes.
const planSize = 3_500_000;
// A reply to Sam with an inline chart and a plan too large for one sendMail request, admitted to
// the Outbox; resolves its Draft and the chart's Content-ID.
async function large(sending: Awaited<ReturnType<typeof microsoftSender>>) {
  const id = await sending.addressed();
  const created = sending.draft(id);
  sending.storage.addFile('file:///plan.pdf', 'p'.repeat(planSize));
  sending.storage.addFile('file:///chart.png', 'chart bytes');
  const plan = sending.drafts.prepare({
    name: 'plan.pdf',
    type: 'application/pdf',
  });
  const chart = sending.drafts.prepare({
    name: 'chart.png',
    type: 'image/png',
  });
  await sending.drafts.update(
    {
      ...created,
      body: insertImage(created.body, { start: 3, end: 3 }, chart).document,
      attachments: [plan],
      response: {
        kind: 'reply',
        message: 'AAMkAGI2-0001_x=',
        thread: { connection: outlook.id, id: 'conversation-1' },
        inReplyTo: '<m-1@example.invalid>',
        references: ['<m-0@example.invalid>', '<m-1@example.invalid>'],
      },
    },
    created,
  );
  await sending.drafts.importAsset(plan, {
    kind: 'file',
    uri: 'file:///plan.pdf',
  });
  await sending.drafts.importAsset(chart, {
    kind: 'file',
    uri: 'file:///chart.png',
  });
  await expect(
    sending.outbox.send(() => sending.draft(id)),
  ).resolves.toBeUndefined();
  return { id, chart: `${chart.id}@unwired.invalid` };
}
describe('sending Microsoft mail through Graph', () => {
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

  /* oxlint-disable vitest/max-expects -- Each journey proves one delivery path end to end. */
  it('sends a threaded reply with its files once after the Undo Send Window, claimed by this device', async () => {
    expect.hasAssertions();
    const sending = await microsoftSender();
    try {
      expect(
        sendingMailboxes(
          mailboxesOf(sending.registration.getSnapshot().snapshot),
          defaultProfile,
        ).map(({ address }) => address),
      ).toStrictEqual([outlook.address]);
      const id = await sending.addressed();
      const created = sending.draft(id);
      sending.storage.addFile('file:///plan.pdf', 'quarterly plan bytes');
      sending.storage.addFile('file:///chart.png', 'chart bytes');
      const plan = sending.drafts.prepare({
        name: 'plan.pdf',
        type: 'application/pdf',
      });
      const chart = sending.drafts.prepare({
        name: 'chart.png',
        type: 'image/png',
      });
      await sending.drafts.update(
        {
          ...created,
          subject: 'Re: Lunch',
          body: insertImage(created.body, { start: 3, end: 3 }, chart).document,
          attachments: [plan],
          response: {
            kind: 'reply',
            message: 'AAMkAGI2-0001_x=',
            thread: { connection: outlook.id, id: 'conversation-1' },
            inReplyTo: '<m-1@example.invalid>',
            references: ['<m-0@example.invalid>', '<m-1@example.invalid>'],
          },
        },
        created,
      );
      await sending.drafts.importAsset(plan, {
        kind: 'file',
        uri: 'file:///plan.pdf',
      });
      await sending.drafts.importAsset(chart, {
        kind: 'file',
        uri: 'file:///chart.png',
      });
      await expect(
        sending.outbox.send(() => sending.draft(id)),
      ).resolves.toBeUndefined();

      // Nothing reaches Microsoft during the Undo Send Window.
      later(undoSendWindow - 1);
      await sending.outbox.process();
      expect(sending.graph.sends).toStrictEqual([]);
      later(1);
      await sending.outbox.process();

      const [sent, ...others] = sending.graph.sends;
      expect(others).toStrictEqual([]);
      expect(sending.drafts.getOutbox()).toStrictEqual([]);
      const message = await PostalMime.parse(present(sent, 'a send').raw, {
        attachmentEncoding: 'utf8',
      });
      expect({
        from: message.from?.address,
        to: message.to?.map(({ address }) => address),
        bcc: message.bcc?.map(({ address }) => address),
        inReplyTo: message.inReplyTo,
        references: message.references,
        attachments: message.attachments.map(
          ({ filename, disposition, content }) => [
            filename,
            disposition,
            content,
          ],
        ),
      }).toStrictEqual({
        from: outlook.address,
        to: ['sam@example.invalid'],
        // Microsoft delivers to Bcc and removes the header from what others receive.
        bcc: ['jo@example.invalid'],
        inReplyTo: '<m-1@example.invalid>',
        references: '<m-0@example.invalid> <m-1@example.invalid>',
        attachments: [
          ['chart.png', 'inline', 'chart bytes'],
          ['plan.pdf', 'attachment', 'quarterly plan bytes'],
        ],
      });
      // The message names its own Message-ID, which its Sent Items copy keeps.
      expect(message.messageId).toMatch(/@contoso\.example\.invalid>$/u);
      expect(sending.graph.requests.map(({ pathname }) => pathname)).toContain(
        '/v1.0/me/mailFolders/inbox/messages',
      );
    } finally {
      sending.outbox.dispose();
    }
  });

  it('never sends a lost answer again and confirms it only once Sent Items holds its copy', async () => {
    expect.hasAssertions();
    const sending = await microsoftSender();
    try {
      const id = await sending.addressed();
      await sending.outbox.send(() => sending.draft(id));
      later(undoSendWindow);
      // Microsoft accepts the message, files its copy later, and the answer is lost.
      sending.graph.holdSentCopies();
      sending.graph.failSend({ lost: true });
      await sending.outbox.process();
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'unknown' },
      ]);

      // Accepted is not yet visible: without a copy the outcome stays unknown, through relaunch.
      await expect(sending.outbox.check(id)).resolves.toBe(false);
      await sending.relaunch();
      await sending.outbox.process();
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'unknown' },
      ]);
      sending.graph.fileSentCopies();
      await expect(sending.outbox.check(id)).resolves.toBe(true);
      expect(sending.drafts.getOutbox()).toStrictEqual([]);
      expect(sending.graph.sends).toHaveLength(1);
      // Sent Items were asked for the message's own Message-ID.
      const lookup = sending.graph.requests.findLast(({ pathname }) =>
        pathname.endsWith('/sentitems/messages'),
      );
      expect(lookup?.searchParams.get('$filter')).toMatch(
        /^internetMessageId eq '<.+@contoso\.example\.invalid>'$/u,
      );
    } finally {
      sending.outbox.dispose();
    }
  });

  it.each([
    {
      result: 'an incomplete page',
      reply: {
        value: [{ id: 'AAMk-first=' }],
        '@odata.nextLink':
          'https://graph.microsoft.com/v1.0/me/mailFolders/sentitems/messages?$skiptoken=next',
      },
    },
    {
      result: 'two matching copies',
      reply: { value: [{ id: 'AAMk-first=' }, { id: 'AAMk-second=' }] },
    },
  ])(
    'keeps delivery unknown for $result without resubmission',
    async ({ reply }) => {
      expect.hasAssertions();
      const sending = await microsoftSender();
      const graphRead = vi
        .spyOn(sending.graph.native, 'graphRequest')
        .mockResolvedValue({ status: 200, body: JSON.stringify(reply) });
      try {
        const id = await sending.addressed();
        await sending.outbox.send(() => sending.draft(id));
        later(undoSendWindow);
        sending.graph.failSend({ lost: true });
        await sending.outbox.process();
        await expect(sending.outbox.check(id)).resolves.toBe(false);
        expect(sending.drafts.getOutbox()).toMatchObject([
          { id, state: 'unknown' },
        ]);
        await sending.relaunch();
        later(30_000);
        await sending.outbox.process();
        expect(sending.drafts.getOutbox()).toMatchObject([
          { id, state: 'unknown' },
        ]);
        expect(sending.graph.sends).toHaveLength(1);
      } finally {
        graphRead.mockRestore();
        sending.outbox.dispose();
      }
    },
  );

  it.each([
    {
      failure: { status: 403 },
      entry: { state: 'failed', problem: 'authorization' },
      sends: 0,
      sync: 'authentication',
    },
    {
      failure: { code: 'gmail-unavailable' },
      entry: { state: 'failed', problem: 'authorization' },
      sends: 0,
      sync: 'authentication',
    },
    {
      failure: { status: 413 },
      entry: { state: 'failed', problem: 'too-large' },
      sends: 0,
      sync: 'current',
    },
    {
      failure: { status: 400 },
      entry: { state: 'failed', problem: 'refused' },
      sends: 0,
      sync: 'current',
    },
    {
      failure: { status: 429 },
      entry: { state: 'queued', problem: 'rate-limited' },
      sends: 1,
      sync: 'current',
    },
    {
      failure: { code: 'unavailable' },
      entry: { state: 'queued', problem: 'offline' },
      sends: 1,
      sync: 'current',
    },
    {
      failure: { status: 503 },
      entry: { state: 'unknown' },
      sends: 0,
      sync: 'current',
    },
  ])(
    'records $failure as $entry.state without changing the connection',
    async ({ failure, entry, sends, sync }) => {
      expect.hasAssertions();
      const sending = await microsoftSender();
      try {
        const id = await sending.addressed();
        await sending.outbox.send(() => sending.draft(id));
        later(undoSendWindow);
        sending.graph.failSend(failure);
        await sending.outbox.process();
        // The message keeps its connection, and this device stays its Delivery Owner.
        expect(sending.drafts.getOutbox()).toMatchObject([
          { id, ...entry, draft: { connection: outlook.id } },
        ]);
        // Only a definite refusal before acceptance is sent again, once, after the retry delay.
        later(30_000);
        await sending.outbox.process();
        expect(sending.graph.sends).toHaveLength(sends);
        // A refused grant asks for Microsoft again, as a refused read does.
        expect(sending.mailboxes.getSnapshot()[0]?.state).toMatchObject({
          kind: 'ready',
          sync,
        });
      } finally {
        sending.outbox.dispose();
      }
    },
  );

  it('sends a message over Graph’s request limit once, as an Outlook draft its files are attached to', async () => {
    expect.hasAssertions();
    const sending = await microsoftSender();
    try {
      const { chart } = await large(sending);
      later(undoSendWindow);
      await sending.outbox.process();

      const [sent, ...others] = sending.graph.sends;
      expect(others).toStrictEqual([]);
      expect(sending.drafts.getOutbox()).toStrictEqual([]);
      expect(sending.graph.drafts.size).toBe(0);
      // The draft's MIME carries the envelope and threading headers; its files are attached.
      const message = await PostalMime.parse(present(sent, 'a send').raw);
      expect({
        to: message.to?.map(({ address }) => address),
        bcc: message.bcc?.map(({ address }) => address),
        inReplyTo: message.inReplyTo,
        references: message.references,
        files: message.attachments.length,
        html: message.html?.includes(`cid:${chart}`),
      }).toStrictEqual({
        to: ['sam@example.invalid'],
        bcc: ['jo@example.invalid'],
        inReplyTo: '<m-1@example.invalid>',
        references: '<m-0@example.invalid> <m-1@example.invalid>',
        files: 0,
        html: true,
      });
      expect(message.messageId).toMatch(/@contoso\.example\.invalid>$/u);
      expect(
        sent?.attachments.map(
          ({ name, contentType, isInline, contentId, bytes }) => [
            name,
            contentType,
            isInline,
            contentId,
            bytes.length,
          ],
        ),
      ).toStrictEqual([
        ['chart.png', 'image/png', true, chart, 11],
        ['plan.pdf', 'application/pdf', undefined, undefined, planSize],
      ]);
    } finally {
      sending.outbox.dispose();
    }
  });

  it.each([
    { step: 'the draft was created', after: 0 },
    { step: 'part of its files were attached', after: 1 },
    { step: 'every file was attached', after: 2 },
  ])(
    'recovers a send interrupted after $step without a second delivery or a leftover draft',
    async ({ after }) => {
      expect.hasAssertions();
      const sending = await microsoftSender();
      try {
        const { id } = await large(sending);
        later(undoSendWindow);
        sending.graph.failPrepare({ after, interrupted: true });
        await sending.outbox.process();
        // Nothing was handed off: the message waits with its claim, and the draft stays behind.
        expect(sending.drafts.getOutbox()).toMatchObject([
          { id, state: 'queued', claim: 'held' },
        ]);
        expect(sending.graph.drafts.size).toBe(1);
        expect(sending.graph.sends).toStrictEqual([]);

        await sending.relaunch();
        await sending.outbox.process();
        expect(sending.drafts.getOutbox()).toStrictEqual([]);
        expect(sending.graph.sends).toHaveLength(1);
        expect(sending.graph.drafts.size).toBe(0);
      } finally {
        sending.outbox.dispose();
      }
    },
  );

  it('never sends a draft again after a lost answer and confirms it from Sent Items', async () => {
    expect.hasAssertions();
    const sending = await microsoftSender();
    try {
      const { id } = await large(sending);
      later(undoSendWindow);
      sending.graph.holdSentCopies();
      sending.graph.failSend({ lost: true });
      await sending.outbox.process();
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'unknown' },
      ]);
      await sending.relaunch();
      await sending.outbox.process();
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'unknown' },
      ]);
      sending.graph.fileSentCopies();
      await expect(sending.outbox.check(id)).resolves.toBe(true);
      expect(sending.graph.sends).toHaveLength(1);
    } finally {
      sending.outbox.dispose();
    }
  });

  it('keeps interrupted preparation cleanup through offline Edit and relaunch', async () => {
    expect.hasAssertions();
    const sending = await microsoftSender();
    try {
      const { id } = await large(sending);
      later(undoSendWindow);
      sending.graph.failPrepare({ after: 1, interrupted: true });
      await sending.outbox.process();
      expect(sending.graph.drafts.size).toBe(1);
      sending.graph.failDiscard({ status: 503 });
      const edited = await sending.outbox.undo(id);
      expect(edited).not.toBe(false);
      await sending.outbox.process();
      expect(sending.graph.drafts.size).toBe(1);
      await sending.relaunch();
      await sending.outbox.process();
      expect(sending.graph.drafts.size).toBe(0);
      expect(sending.graph.sends).toStrictEqual([]);
      expect(sending.drafts.getSnapshot()).toMatchObject({
        drafts: [{ id: edited }],
      });
    } finally {
      sending.outbox.dispose();
    }
  });

  it('cleans a preparation edited while native code was attaching its files', async () => {
    expect.hasAssertions();
    const sending = await microsoftSender();
    const original = sending.graph.native.graphPrepare;
    const prepared = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    sending.graph.native.graphPrepare = async (...args) => {
      const result = await original(...args);
      prepared.resolve(undefined);
      await release.promise;
      return result;
    };
    try {
      const { id } = await large(sending);
      later(undoSendWindow);
      const delivering = sending.outbox.process();
      await prepared.promise;
      const edited = await sending.outbox.undo(id);
      expect(edited).not.toBe(false);
      release.resolve(undefined);
      await delivering;
      expect(sending.graph.drafts.size).toBe(0);
      expect(sending.graph.sends).toStrictEqual([]);
      expect(sending.drafts.getSnapshot()).toMatchObject({
        drafts: [{ id: edited }],
      });
    } finally {
      release.resolve(undefined);
      sending.outbox.dispose();
    }
  });

  it('sends a large message once when two local Outboxes compete for the same device claim', async () => {
    expect.hasAssertions();
    const sending = await microsoftSender();
    let other: ReturnType<typeof createOutbox> | undefined = undefined;
    try {
      await large(sending);
      const drafts = createDrafts(sending.storage.native, sending.registration);
      await drafts.load();
      other = createOutbox({
        drafts,
        mailboxes: sending.mailboxes,
        registration: sending.registration,
        claims: sending.storage.delivery,
      });
      later(undoSendWindow);
      await Promise.all([sending.outbox.process(), other.process()]);
      await sending.relaunch();
      await sending.outbox.process();
      expect(sending.graph.sends).toHaveLength(1);
      expect(sending.graph.drafts.size).toBe(0);
      expect(sending.drafts.getOutbox()).toStrictEqual([]);
    } finally {
      sending.outbox.dispose();
      other?.dispose();
    }
  });

  it.each([
    {
      failure: { status: 413 },
      entry: { state: 'failed', problem: 'too-large' },
      sends: 0,
    },
    {
      failure: { status: 403 },
      entry: { state: 'failed', problem: 'authorization' },
      sends: 0,
    },
    {
      failure: { status: 429 },
      entry: { state: 'queued', problem: 'rate-limited' },
      sends: 1,
    },
    // Nothing was sent, so even a server error only tries again.
    {
      failure: { status: 503 },
      entry: { state: 'queued', problem: 'offline' },
      sends: 1,
    },
  ])(
    'records a refused draft as $entry.state, deleting it, and tries only a retry again',
    async ({ failure, entry, sends }) => {
      expect.hasAssertions();
      const sending = await microsoftSender();
      try {
        const { id } = await large(sending);
        later(undoSendWindow);
        sending.graph.failPrepare({ after: 1, ...failure });
        await sending.outbox.process();
        expect(sending.drafts.getOutbox()).toMatchObject([{ id, ...entry }]);
        expect(sending.graph.drafts.size).toBe(0);
        later(30_000);
        await sending.outbox.process();
        expect(sending.graph.sends).toHaveLength(sends);
      } finally {
        sending.outbox.dispose();
      }
    },
  );

  it('refuses a message whose text alone is over Graph’s request limit at Send', async () => {
    expect.hasAssertions();
    const sending = await microsoftSender();
    try {
      const id = await sending.addressed('x'.repeat(1_600_000));
      await expect(sending.outbox.send(() => sending.draft(id))).resolves.toBe(
        'too-large',
      );
      expect(sending.drafts.getOutbox()).toStrictEqual([]);
      expect(sending.draft(id).id).toBe(id);
    } finally {
      sending.outbox.dispose();
    }
  });
  /* oxlint-enable vitest/max-expects */
});
