import PostalMime from 'postal-mime';

import type { Draft } from '../src/drafts.ts';
import type { SyntheticProductSync } from '../src/testing/drafts.ts';

import { createDrafts } from '../src/drafts.ts';
import { createMailboxes } from '../src/mailboxes.ts';
import { createOutbox, undoSendWindow } from '../src/outbox.ts';
import {
  applyText,
  insertImage,
  plainText,
  toggleMark,
} from '../src/semantic-document.ts';
import { createSyntheticProductSync } from '../src/testing/drafts.ts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '../src/testing/gmail-mailbox.ts';
import { alex, device, present } from './draft-sync-fixture.ts';

type Device = Awaited<ReturnType<typeof device>>;

const account = 'account-a';

// A Trusted Device that sends through `gmail`, the mailbox every device of the account connects.
async function sender(
  server: Readonly<SyntheticProductSync>,
  gmail: ReturnType<typeof createSyntheticGmail>,
  name: string,
) {
  const phone = await device(server, account, name);
  const mailboxes = createMailboxes(
    syntheticConnections({ [alex.id]: gmail }),
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
  return {
    ...phone,
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

// Synthetic Gmail and Product Sync shared by the account's devices. Gmail reads each sent file's
// bytes from whichever device's Draft storage holds them, as that device's native code would.
function sharedAccount(...devices: Array<() => Device | undefined>) {
  const server = createSyntheticProductSync();
  const gmail = createSyntheticGmail({
    assets: (id, digest) =>
      devices
        .map((each) => each()?.storage.bytesOf(account, id, digest))
        .find((bytes) => bytes !== undefined),
  });
  return { server, gmail };
}

const write = (draft: Draft, text: string): Draft => ({
  ...draft,
  body: applyText(draft.body, text).document,
});

// A Draft with recipients and a subject, ready to send.
async function addressed(phone: Device, text = 'See you there') {
  const id = present(await phone.drafts.create(alex), 'a new Draft');
  const created = phone.draft(id);
  await phone.drafts.update(
    {
      ...write(created, text),
      to: [{ name: 'Sam Lee', address: 'sam@example.invalid' }],
      subject: 'Lunch',
    },
    created,
  );
  return id;
}

// The controlled clock every journey runs on.
const clock = { now: 0 };
const later = (milliseconds: number) => {
  clock.now += milliseconds;
  vi.setSystemTime(clock.now);
};

describe('sending a Draft through the Outbox', () => {
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

  /* oxlint-disable vitest/max-expects -- Each journey proves one delivery path end to end. */
  it('sends a formatted reply with its files once after the Undo Send Window, claimed by this device', async () => {
    expect.hasAssertions();
    let phone: Device | undefined = undefined;
    let mac: Device | undefined = undefined;
    const { server, gmail } = sharedAccount(
      () => phone,
      () => mac,
    );
    const sending = await sender(server, gmail, 'phone');
    phone = sending;
    mac = await device(server, account, 'mac');
    const id = present(await sending.drafts.create(alex), 'a new Draft');
    const created = sending.draft(id);
    sending.storage.addFile('file:///plan.pdf', 'quarterly plan bytes');
    sending.storage.addFile('file:///chart.png', 'chart bytes');
    const plan = sending.drafts.prepare({
      name: 'plán.pdf',
      type: 'application/pdf',
    });
    const chart = sending.drafts.prepare({
      name: 'chart.png',
      type: 'image/png',
    });
    const written = write(created, 'Numbers attached');
    const body = toggleMark(
      insertImage(written.body, { start: 16, end: 16 }, chart).document,
      { start: 0, end: 7 },
      'bold',
    );
    await sending.drafts.update(
      {
        ...written,
        to: [{ name: 'Sam Lee', address: 'sam@example.invalid' }],
        cc: [{ name: 'Žofie', address: 'zofie@example.invalid' }],
        bcc: [{ address: 'audit@example.invalid' }],
        subject: 'Re: Plán na říjen',
        body,
        attachments: [plan],
        response: {
          kind: 'reply',
          message: 'm-1',
          thread: { connection: alex.id, id: 'thread-7' },
          inReplyTo: '<m-1@example.invalid>',
          references: ['<m-0@example.invalid>', '<m-1@example.invalid>'],
        },
        quoted: [
          { kind: 'paragraph', spans: [{ text: 'On Monday Sam wrote:' }] },
          { kind: 'quote', spans: [{ text: 'Can you send the numbers?' }] },
        ],
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
    await sending.drafts.sync();
    await mac.drafts.sync();
    expect(mac.list().map((draft) => draft.id)).toStrictEqual([id]);
    const shown = sending.draft(id);

    await expect(
      sending.outbox.send(() => sending.draft(id)),
    ).resolves.toBeUndefined();

    // Admission removes the Draft and keeps the exact message in the Outbox, cancellable.
    expect(sending.list()).toStrictEqual([]);
    expect(sending.drafts.getOutbox()).toStrictEqual([
      {
        id,
        draft: shown,
        message: expect.objectContaining({
          segments: expect.any(Array),
          size: expect.any(Number),
          threadId: 'thread-7',
        }),
        sendAt: clock.now + undoSendWindow,
        state: 'waiting',
      },
    ]);
    expect(
      JSON.parse(present(sending.storage.stored(), 'stored Drafts').document)
        .outbox,
    ).toStrictEqual(sending.drafts.getOutbox());
    later(undoSendWindow - 1);
    await sending.outbox.process();
    expect(gmail.sends).toStrictEqual([]);
    expect(server.claimsOf(account).size).toBe(0);

    later(1);
    await sending.outbox.process();

    // One send, claimed by this device under an identifier that names no content.
    expect(gmail.sends).toHaveLength(1);
    expect([...server.claimsOf(account)]).toStrictEqual([
      [`draft-delivery.${id}`, 'phone'],
    ]);
    const [sent] = gmail.sends;
    expect(sent?.threadId).toBe('thread-7');
    expect(sent?.raw).toContain('Date: Fri, 09 Oct 2026 12:00:00 +0000');
    expect(sending.drafts.getOutbox()).toStrictEqual([]);
    expect(
      JSON.parse(present(sending.storage.stored(), 'stored Drafts').document),
    ).toMatchObject({ sent: [{ id, message: sent?.id, sentAt: clock.now }] });
    expect(sending.storage.stored()?.document).not.toContain('"outbox"');
    expect(sending.storage.assets()).toStrictEqual([]);

    const message = await PostalMime.parse(present(sent, 'a send').raw, {
      attachmentEncoding: 'utf8',
    });
    expect(message.from).toStrictEqual({ address: alex.address, name: '' });
    expect(message.to).toStrictEqual([
      { address: 'sam@example.invalid', name: 'Sam Lee' },
    ]);
    expect(message.cc).toStrictEqual([
      { address: 'zofie@example.invalid', name: 'Žofie' },
    ]);
    expect(message.bcc).toStrictEqual([
      { address: 'audit@example.invalid', name: '' },
    ]);
    expect(message.subject).toBe('Re: Plán na říjen');
    expect(message.inReplyTo).toBe('<m-1@example.invalid>');
    expect(message.references).toBe(
      '<m-0@example.invalid> <m-1@example.invalid>',
    );
    expect(message.html).toContain('<strong>Numbers</strong>');
    expect(message.html).toContain(
      `<img src="cid:${chart.id}@unwired.invalid" alt="chart.png">`,
    );
    expect(message.html).toContain(
      '<blockquote><p>Can you send the numbers?</p></blockquote>',
    );
    expect(message.text).toBe(
      'Numbers attached[chart.png]\nOn Monday Sam wrote:\n> Can you send the numbers?',
    );
    const files = message.attachments.map((file) => ({
      filename: file.filename,
      mimeType: file.mimeType,
      disposition: file.disposition,
      contentId: file.contentId,
      content: file.content,
    }));
    expect(files).toStrictEqual([
      {
        filename: 'chart.png',
        mimeType: 'image/png',
        disposition: 'inline',
        contentId: `<${chart.id}@unwired.invalid>`,
        content: 'chart bytes',
      },
      {
        filename: 'plán.pdf',
        mimeType: 'application/pdf',
        disposition: 'attachment',
        contentId: undefined,
        content: 'quarterly plan bytes',
      },
    ]);

    // The sent Draft is gone on every device, and a later pass sends nothing again.
    await sending.drafts.sync();
    await mac.drafts.sync();
    expect(mac.list()).toStrictEqual([]);
    await sending.outbox.process();
    expect(gmail.sends).toHaveLength(1);
    sending.outbox.dispose();
  });

  it('returns the same usable Draft with Undo before anything is claimed or sent', async () => {
    expect.hasAssertions();
    let phone: Device | undefined = undefined;
    let mac: Device | undefined = undefined;
    const { server, gmail } = sharedAccount(
      () => phone,
      () => mac,
    );
    const sending = await sender(server, gmail, 'phone');
    phone = sending;
    mac = await device(server, account, 'mac');
    const id = await addressed(sending);
    await sending.drafts.sync();
    const shown = sending.draft(id);
    await sending.outbox.send(() => sending.draft(id));
    // Another device stops listing the Draft once this one synchronizes.
    await sending.drafts.sync();
    await mac.drafts.sync();
    expect(mac.list()).toStrictEqual([]);

    later(undoSendWindow - 1);
    await expect(sending.outbox.undo(id)).resolves.toBe(id);
    later(undoSendWindow);
    await sending.outbox.process();

    expect(gmail.sends).toStrictEqual([]);
    expect(server.claimsOf(account).size).toBe(0);
    expect(sending.drafts.getOutbox()).toStrictEqual([]);
    expect(sending.draft(id)).toStrictEqual({
      ...shown,
      updatedAt: clock.now - undoSendWindow,
    });
    // The returned Draft continues everywhere and can be edited and sent again.
    await sending.drafts.sync();
    await mac.drafts.sync();
    expect(mac.list().map((draft) => draft.id)).toStrictEqual([id]);
    await sending.relaunch();
    expect(sending.draft(id).subject).toBe('Lunch');
    await expect(
      sending.outbox.send(() => sending.draft(id)),
    ).resolves.toBeUndefined();
    later(undoSendWindow);
    await sending.outbox.process();
    expect(gmail.sends).toHaveLength(1);
    sending.outbox.dispose();
  });

  it('lets only one of two devices sending the same Draft submit it', async () => {
    expect.hasAssertions();
    let phone: Device | undefined = undefined;
    let mac: Device | undefined = undefined;
    const { server, gmail } = sharedAccount(
      () => phone,
      () => mac,
    );
    const first = await sender(server, gmail, 'phone');
    const second = await sender(server, gmail, 'mac');
    phone = first;
    mac = second;
    const id = await addressed(first);
    await first.drafts.sync();
    await second.drafts.sync();
    // Each device sends before learning of the other's Send.
    await first.outbox.send(() => first.draft(id));
    await second.outbox.send(() => second.draft(id));
    later(undoSendWindow);

    await Promise.all([first.outbox.process(), second.outbox.process()]);

    expect(gmail.sends).toHaveLength(1);
    const outboxes = [first.drafts.getOutbox(), second.drafts.getOutbox()];
    const refused = present(
      outboxes.find((outbox) => outbox.length > 0),
      'the refused device',
    );
    expect(outboxes.filter((outbox) => outbox.length === 0)).toHaveLength(1);
    expect(refused).toMatchObject([
      { id, state: 'failed', problem: 'claimed' },
    ]);
    // Its content returns as a new Draft, apart from the claimed identity.
    const loser = present(
      [first, second].find((each) => each.drafts.getOutbox().length > 0),
      'the refused device',
    );
    const restored = await loser.outbox.undo(id);
    expect(restored).not.toBe(id);
    expect(loser.draft(String(restored)).subject).toBe('Lunch');
    await loser.outbox.process();
    expect(gmail.sends).toHaveLength(1);
    first.outbox.dispose();
    second.outbox.dispose();
  });

  it('admits the editor conflict copy when synchronization rebinds it during asset verification', async () => {
    expect.hasAssertions();
    const { server, gmail } = sharedAccount();
    const sending = await sender(server, gmail, 'phone');
    const checked = Promise.withResolvers<undefined>();
    const resume = Promise.withResolvers<undefined>();
    try {
      const mac = await device(server, account, 'mac');
      const id = await addressed(sending);
      const created = sending.draft(id);
      sending.storage.addFile('file:///notes.txt', 'notes');
      const notes = sending.drafts.prepare({
        name: 'notes.txt',
        type: 'text/plain',
      });
      await sending.drafts.update(
        { ...created, attachments: [notes] },
        created,
      );
      await sending.drafts.importAsset(notes, {
        kind: 'file',
        uri: 'file:///notes.txt',
      });
      await sending.drafts.sync();
      await mac.drafts.sync();
      const original = sending.draft(id);
      let shown = { ...original, subject: 'Phone version' };
      await sending.drafts.update(shown, original, (moved) => {
        shown = { ...shown, id: moved, conflict: true };
      });
      await mac.drafts.update(
        { ...mac.draft(id), subject: 'Mac version' },
        mac.draft(id),
      );
      await mac.drafts.sync();
      const read = sending.storage.native.readDraftAsset;
      vi.spyOn(sending.storage.native, 'readDraftAsset').mockImplementationOnce(
        async (...args) => {
          checked.resolve(undefined);
          await resume.promise;
          return read(...args);
        },
      );
      const pending = sending.outbox.send(() => shown);
      await checked.promise;
      await sending.drafts.sync();
      expect(shown.id).not.toBe(id);
      resume.resolve(undefined);

      await expect(pending).resolves.toBeUndefined();

      expect(sending.list()).toMatchObject([{ id, subject: 'Mac version' }]);
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id: shown.id, draft: { id: shown.id, subject: 'Phone version' } },
      ]);
      expect(sending.drafts.getOutbox()[0]?.message.segments).toContainEqual(
        expect.objectContaining({
          text: expect.stringContaining('Subject: Phone version'),
        }),
      );
      await sending.relaunch();
      expect(sending.list()).toMatchObject([{ id, subject: 'Mac version' }]);
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id: shown.id, draft: { subject: 'Phone version' } },
      ]);
      expect(gmail.sends).toStrictEqual([]);
    } finally {
      resume.resolve(undefined);
      sending.outbox.dispose();
    }
  });

  it('keeps Undo retryable when its cancellation cannot be saved', async () => {
    expect.hasAssertions();
    const { server, gmail } = sharedAccount();
    const sending = await sender(server, gmail, 'phone');
    const id = await addressed(sending);
    await sending.outbox.send(() => sending.draft(id));
    sending.storage.failNextCommit('locked');

    await expect(sending.outbox.undo(id)).resolves.toBe(false);
    expect(sending.drafts.getOutbox()).toMatchObject([
      { id, state: 'waiting' },
    ]);
    expect(sending.list()).toStrictEqual([]);
    await expect(sending.outbox.undo(id)).resolves.toBe(id);
    await sending.relaunch();
    later(undoSendWindow);
    await sending.outbox.process();
    expect(gmail.sends).toStrictEqual([]);
    expect(sending.draft(id).subject).toBe('Lunch');
    sending.outbox.dispose();
  });

  it('timestamps Undo after rebasing onto a competing local writer', async () => {
    expect.hasAssertions();
    const { server, gmail } = sharedAccount();
    const sending = await sender(server, gmail, 'phone');
    try {
      const id = await addressed(sending);
      await sending.outbox.send(() => sending.draft(id));
      const other = createDrafts(sending.storage.native, sending.registration);
      await other.load();
      later(1000);
      const independent = present(await other.create(alex), 'another Draft');
      const open = sending.storage.native.openDrafts;
      vi.spyOn(sending.storage.native, 'openDrafts').mockImplementationOnce(
        () => {
          later(1000);
          return open();
        },
      );

      await expect(sending.outbox.undo(id)).resolves.toBe(id);

      expect(sending.draft(id).updatedAt).toBe(clock.now);
      expect(sending.list().map((draft) => draft.id)).toContain(independent);
      await sending.relaunch();
      expect(sending.draft(id).updatedAt).toBe(clock.now);
      expect(sending.drafts.getOutbox()).toStrictEqual([]);
      expect(gmail.sends).toStrictEqual([]);
    } finally {
      sending.outbox.dispose();
    }
  });

  it('lets only one local storage writer hand the same claimed message to Gmail', async () => {
    expect.hasAssertions();
    const { server, gmail } = sharedAccount();
    const sending = await sender(server, gmail, 'phone');
    const id = await addressed(sending);
    await sending.outbox.send(() => sending.draft(id));
    const drafts = createDrafts(sending.storage.native, sending.registration);
    await drafts.load();
    const mailboxes = createMailboxes(
      syntheticConnections({ [alex.id]: gmail }),
      sending.registration,
    );
    await mailboxes.load();
    const other = createOutbox({
      drafts,
      mailboxes,
      registration: sending.registration,
      claims: sending.storage.delivery,
    });
    later(undoSendWindow);

    await Promise.all([sending.outbox.process(), other.process()]);

    expect(gmail.sends).toHaveLength(1);
    await sending.relaunch();
    expect(sending.drafts.getOutbox()).toStrictEqual([]);
    sending.outbox.dispose();
    other.dispose();
  });

  it('keeps a message queued while its claim is unreachable or uncertain, then sends it once', async () => {
    expect.hasAssertions();
    let phone: Device | undefined = undefined;
    const { server, gmail } = sharedAccount(() => phone);
    const submit = vi.spyOn(gmail.native, 'gmailSend');
    const sending = await sender(server, gmail, 'phone');
    phone = sending;
    const id = await addressed(sending);
    await sending.outbox.send(() => sending.draft(id));
    const admitted = present(
      sending.drafts.getOutbox()[0],
      'the admitted message',
    ).message;
    server.setReachable(false);
    later(undoSendWindow);

    await sending.outbox.process();
    expect(sending.drafts.getOutbox()).toMatchObject([
      { id, state: 'queued', claim: 'requested', problem: 'offline' },
    ]);
    expect(gmail.sends).toStrictEqual([]);

    server.setReachable(true);
    server.loseNextClaimReply();
    await sending.outbox.process();
    // Convex took the claim but the reply was lost: nothing is sent without a confirmed claim.
    expect(gmail.sends).toStrictEqual([]);
    expect(sending.drafts.getOutbox()).toMatchObject([{ id, state: 'queued' }]);

    await sending.outbox.process();
    expect(gmail.sends).toHaveLength(1);
    expect(submit).toHaveBeenCalledWith(admitted, expect.anything());
    expect(sending.drafts.getOutbox()).toStrictEqual([]);
    sending.outbox.dispose();
  });

  it('does not resurrect a confirmed send when a stale recovery writer saves', async () => {
    expect.hasAssertions();
    const { server, gmail } = sharedAccount();
    const sending = await sender(server, gmail, 'phone');
    const id = await addressed(sending);
    await sending.outbox.send(() => sending.draft(id));
    const reply = Promise.withResolvers<undefined>();
    const submit = gmail.native.gmailSend;
    gmail.native.gmailSend = async (...args) => {
      await reply.promise;
      return submit(...args);
    };
    later(undoSendWindow);
    const processing = sending.outbox.process();
    await vi.waitFor(() => {
      expect(sending.drafts.getOutbox()).toMatchObject([{ state: 'sending' }]);
    });
    const recovering = createDrafts(
      sending.storage.native,
      sending.registration,
    );
    await recovering.load();
    expect(recovering.getOutbox()).toMatchObject([{ state: 'unknown' }]);
    reply.resolve(undefined);
    await processing;

    await expect(recovering.save()).resolves.toBe(true);
    expect(recovering.getOutbox()).toStrictEqual([]);
    await sending.relaunch();
    await sending.outbox.process();
    expect(sending.drafts.getOutbox()).toStrictEqual([]);
    expect(gmail.sends).toHaveLength(1);
    sending.outbox.dispose();
  });

  it('processes the Undo Send deadline automatically and stops scheduled work on disposal', async () => {
    expect.hasAssertions();
    vi.useFakeTimers();
    const { server, gmail } = sharedAccount();
    const sending = await sender(server, gmail, 'phone');
    const first = await addressed(sending);
    await sending.outbox.send(() => sending.draft(first));
    await vi.advanceTimersByTimeAsync(undoSendWindow - 1);
    expect(gmail.sends).toStrictEqual([]);
    await vi.advanceTimersByTimeAsync(1);
    expect(gmail.sends).toHaveLength(1);
    const second = await addressed(sending);
    await sending.outbox.send(() => sending.draft(second));
    sending.outbox.dispose();
    await vi.advanceTimersByTimeAsync(undoSendWindow);
    expect(gmail.sends).toHaveLength(1);
    expect(sending.drafts.getOutbox()).toMatchObject([
      { id: second, state: 'waiting' },
    ]);
  });

  it('delays retries when storage cannot record a deadline or claim refusal', async () => {
    expect.hasAssertions();
    vi.useFakeTimers();
    const { server, gmail } = sharedAccount();
    const sending = await sender(server, gmail, 'phone');
    const id = await addressed(sending);
    await sending.outbox.send(() => sending.draft(id));
    let writes = 0;
    const commit = sending.storage.native.commitDrafts;
    vi.spyOn(sending.storage.native, 'commitDrafts').mockImplementation(
      (...args) => {
        writes += 1;
        return commit(...args);
      },
    );
    sending.storage.setLocked(true);

    await vi.advanceTimersByTimeAsync(undoSendWindow + 10);

    expect(writes).toBe(1);
    expect(sending.drafts.getOutbox()).toMatchObject([
      { id, state: 'waiting' },
    ]);
    expect(gmail.sends).toStrictEqual([]);
    sending.storage.setLocked(false);
    await vi.advanceTimersByTimeAsync(29_989);
    expect(writes).toBe(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(gmail.sends).toHaveLength(1);
    expect(sending.drafts.getOutbox()).toStrictEqual([]);

    // A refused claim also remains queued if storage cannot record its final state.
    const second = await addressed(sending);
    await sending.outbox.send(() => sending.draft(second));
    server.claim(account, `draft-delivery.${second}`, 'mac');
    const delivery = present(sending.storage.delivery, 'delivery claims');
    const claim = delivery.claimDraftDelivery;
    let requests = 0;
    const claims = vi
      .spyOn(delivery, 'claimDraftDelivery')
      .mockImplementation(async (...args) => {
        requests += 1;
        const reply = await claim(...args);
        sending.storage.setLocked(true);
        return reply;
      });
    await vi.advanceTimersByTimeAsync(undoSendWindow + 10);
    expect(requests).toBe(1);
    expect(sending.drafts.getOutbox()).toMatchObject([
      { id: second, state: 'queued', claim: 'requested' },
    ]);
    claims.mockRestore();
    sending.storage.setLocked(false);
    await vi.advanceTimersByTimeAsync(29_990);
    expect(sending.drafts.getOutbox()).toMatchObject([
      { id: second, state: 'failed', problem: 'claimed' },
    ]);
    expect(gmail.sends).toHaveLength(1);
    sending.outbox.dispose();
  });

  it('records a definite refusal and an unknown outcome apart, and never sends an unknown one again', async () => {
    expect.hasAssertions();
    let phone: Device | undefined = undefined;
    const { server, gmail } = sharedAccount(() => phone);
    const sending = await sender(server, gmail, 'phone');
    phone = sending;
    const refusedId = await addressed(sending, 'First');
    const unknownId = await addressed(sending, 'Second');
    gmail.failSend({ status: 400, body: '{}' }, { lost: true });
    await sending.outbox.send(() => sending.draft(refusedId));
    await sending.outbox.send(() => sending.draft(unknownId));
    later(undoSendWindow);

    await sending.outbox.process();

    expect(sending.drafts.getOutbox()).toMatchObject([
      { id: refusedId, state: 'failed', problem: 'refused' },
      { id: unknownId, state: 'unknown' },
    ]);
    expect(sending.drafts.getOutbox()[1]).not.toHaveProperty('problem');
    // Gmail accepted the second message although its reply was lost.
    expect(gmail.sends).toHaveLength(1);
    await expect(sending.outbox.undo(unknownId)).resolves.toBe(false);
    await sending.relaunch();
    await sending.outbox.process();
    expect(gmail.sends).toHaveLength(1);
    expect(sending.drafts.getOutbox()).toMatchObject([
      { id: refusedId, state: 'failed' },
      { id: unknownId, state: 'unknown' },
    ]);
    // A refused message returns to the Drafts to correct, apart from its claimed identity.
    const restored = await sending.outbox.undo(refusedId);
    expect(restored).not.toBe(refusedId);
    expect(plainText(sending.draft(String(restored)).body)).toBe('First');
    sending.outbox.dispose();
  });

  it('reads a message as unknown after the app stops while Gmail has it', async () => {
    expect.hasAssertions();
    let phone: Device | undefined = undefined;
    const { server, gmail } = sharedAccount(() => phone);
    const sending = await sender(server, gmail, 'phone');
    phone = sending;
    const id = await addressed(sending);
    await sending.outbox.send(() => sending.draft(id));
    later(undoSendWindow);
    // The handoff never answers, as when the app is stopped meanwhile.
    gmail.native.gmailSend = () =>
      // oxlint-disable-next-line promise/avoid-new -- A request that never settles.
      new Promise(() => {
        // Never settles.
      });
    void sending.outbox.process();
    await vi.waitFor(() => {
      expect(sending.storage.stored()?.document).toContain('"state":"sending"');
    });

    await sending.relaunch();

    expect(sending.drafts.getOutbox()).toMatchObject([
      { id, state: 'unknown' },
    ]);
    await sending.outbox.process();
    expect(gmail.sends).toStrictEqual([]);
    sending.outbox.dispose();
  });

  it('refuses to send without recipients, with unfinished recipient text or files, or from a sender that cannot send', async () => {
    expect.hasAssertions();
    let phone: Device | undefined = undefined;
    const { server, gmail } = sharedAccount(() => phone);
    const sending = await sender(server, gmail, 'phone');
    phone = sending;
    const id = await addressed(sending);
    const draft = sending.draft(id);
    sending.storage.addFile('file:///notes.txt', 'notes');
    const notes = sending.drafts.prepare({
      name: 'notes.txt',
      type: 'text/plain',
    });

    const send = (next: Draft) => sending.outbox.send(() => next);
    await expect(send({ ...draft, to: [] })).resolves.toBe('recipients');
    await expect(send({ ...draft, entries: { to: 'sam@' } })).resolves.toBe(
      'entries',
    );
    // Native code sends ASCII only; such an address would otherwise wait forever.
    await expect(
      send({ ...draft, to: [{ address: 'žofie@example.invalid' }] }),
    ).resolves.toBe('addresses');
    await expect(
      send({ ...draft, connection: 'connection-gone' }),
    ).resolves.toBe('sender');
    // A connection renamed since the Draft chose it must be chosen again.
    await expect(
      send({ ...draft, from: 'old-name@example.invalid' }),
    ).resolves.toBe('sender');
    await expect(send({ ...draft, attachments: [notes] })).resolves.toBe(
      'assets',
    );
    await sending.drafts.update({ ...draft, attachments: [notes] }, draft);
    await sending.drafts.importAsset(notes, {
      kind: 'file',
      uri: 'file:///notes.txt',
    });
    sending.storage.damage(notes.id);
    await expect(sending.outbox.send(() => sending.draft(id))).resolves.toBe(
      'assets',
    );
    // A version another editor changed since is not sent.
    await expect(send({ ...draft, subject: 'Stale' })).resolves.toBe('changed');
    expect(sending.drafts.getOutbox()).toStrictEqual([]);
    expect(sending.list().map((each) => each.id)).toStrictEqual([id]);
    sending.outbox.dispose();
  });
});
