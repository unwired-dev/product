import assert from 'node:assert/strict';
import { deflateSync } from 'node:zlib';

import type { ImapInbox } from '../src/imap-inbox.ts';

import { createBodyLoads, createGmailInbox } from '../src/gmail-inbox.ts';
import { createImapInbox } from '../src/imap-inbox.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';
import { createSyntheticImap } from '../src/testing/imap-mailbox.ts';

// A complete 16 Mi-pixel PNG, small on the wire but large when a reader decodes it.
const u32 = (value: number) => {
  const bytes = Buffer.alloc(4);
  bytes.writeUInt32BE(value);
  return bytes;
};
/* oxlint-disable no-bitwise -- PNG fixtures require their binary CRC. */
const chunk = (type: string, data: Buffer) => {
  const content = Buffer.concat([Buffer.from(type), data]);
  let crc = 4_294_967_295;
  for (const byte of content) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ ((crc & 1) === 0 ? 0 : 3_988_292_384);
    }
  }
  return Buffer.concat([
    u32(data.length),
    content,
    u32((crc ^ 4_294_967_295) >>> 0),
  ]);
};
/* oxlint-enable no-bitwise */
const image = Buffer.concat([
  Buffer.from('\u0089PNG\r\n\u001A\n', 'latin1'),
  chunk(
    'IHDR',
    Buffer.concat([u32(4096), u32(4096), Buffer.from([8, 6, 0, 0, 0])]),
  ),
  chunk('IDAT', deflateSync(Buffer.alloc((4096 * 4 + 1) * 4096))),
  chunk('IEND', Buffer.alloc(0)),
]).toString('base64');

const cached = (id: string, copies: number) => ({
  document: JSON.stringify({
    version: 2,
    id,
    html: `<p>Photo</p>${'<img src="cid:photo">'.repeat(copies)}`,
    images: {
      admitted: [
        {
          contentId: 'photo',
          mimeType: 'image/png',
          data: image,
          width: 4096,
          height: 4096,
        },
      ],
      refused: [],
    },
  }),
});
const firstId = (inbox: ImapInbox) => {
  const state = inbox.getSnapshot();
  assert.equal(state.kind, 'ready');
  const [message] = state.messages;
  assert.ok(message);
  return message.id;
};
const rich = (inbox: ImapInbox, id: string, reader?: symbol) => {
  const state = inbox.messageBody(id, reader);
  assert.equal(state?.kind, 'ready');
  assert.ok(state.presentation.rich);
  return state.presentation.rich;
};

describe('imap reader image and lifetime boundaries', () => {
  it.each([
    { code: 'locked', expected: { kind: 'locked' }, removedCalls: 0 },
    {
      code: 'mailbox-revoked',
      expected: { kind: 'failed' },
      removedCalls: 1,
    },
    {
      code: 'gmail-unavailable',
      expected: { kind: 'ready', status: 'authentication' },
      removedCalls: 0,
    },
  ])(
    'updates the owning Inbox after a body read reports $code',
    async ({ code, expected, removedCalls }) => {
      expect.hasAssertions();
      const imap = createSyntheticImap();
      imap.deliver('INBOX', { subject: 'Private mail' });
      const removed = vi.fn<() => void>();
      const inbox = createImapInbox(imap.native, { removed });
      await inbox.load();
      const id = firstId(inbox);
      vi.spyOn(imap.native, 'openMessageBody').mockRejectedValue({ code });
      const close = inbox.retainMessage(id);
      await inbox.readMessage(id);
      expect(inbox.getSnapshot()).toMatchObject(expected);
      expect(removed).toHaveBeenCalledTimes(removedCalls);
      close();
    },
  );

  it('charges repeated CID occurrences before rendering a downloaded body', async () => {
    expect.hasAssertions();
    const shared = createBodyLoads();
    const imap = createSyntheticImap();
    imap.deliver('INBOX', {
      subject: 'Photo',
      raw: [
        'Content-Type: multipart/related; boundary=b',
        '',
        '--b',
        'Content-Type: text/html',
        '',
        `<p>Photo</p>${'<img src="cid:photo">'.repeat(3)}`,
        '--b',
        'Content-Type: image/png',
        'Content-ID: <photo>',
        'Content-Transfer-Encoding: base64',
        '',
        image,
        '--b--',
        '',
      ].join('\r\n'),
    });
    const inbox = createImapInbox(imap.native, { shared });
    await inbox.load();
    const id = firstId(inbox);
    const close = inbox.retainMessage(id);
    await inbox.readMessage(id);
    expect(rich(inbox, id).document).not.toContain('data:image/png');
    expect(shared.cache.getSnapshot()).toBe(1);
    close();
  });

  /* oxlint-disable vitest/max-expects -- One multi-window journey proves budget sharing, stability and release. */
  it('shares the Gmail budget and admits each IMAP window without replacing an established source', async () => {
    expect.hasAssertions();
    const shared = createBodyLoads();
    const gmail = createSyntheticGmail();
    const gmailId = gmail.deliver({ at: Date.UTC(2020, 0, 1) });
    gmail.native.openMessageBody = (_scope, id) =>
      Promise.resolve(cached(id, 1));
    const gmailInbox = createGmailInbox(gmail.native, { shared });
    await gmailInbox.load();
    const closeGmail = gmailInbox.retainMessage(gmailId);
    await gmailInbox.readMessage(gmailId);

    const imap = createSyntheticImap();
    imap.deliver('INBOX', { subject: 'Photo' });
    vi.spyOn(imap.native, 'openMessageBody').mockImplementation((_scope, id) =>
      Promise.resolve(cached(id, 1)),
    );
    const inbox = createImapInbox(imap.native, { shared });
    await inbox.load();
    const id = firstId(inbox);
    const first = Symbol('first window');
    const second = Symbol('second window');
    const closeFirst = inbox.retainMessage(id, first);
    await inbox.readMessage(id);
    const original = rich(inbox, id, first);
    expect(original.document).toContain('data:image/png');
    const closeSecond = inbox.retainMessage(id, second);
    await inbox.readMessage(id);
    expect(rich(inbox, id, second).document).not.toContain('data:image/png');
    expect(rich(inbox, id, first)).toBe(original);
    closeSecond();
    closeGmail();
    const reopenSecond = inbox.retainMessage(id, second);
    expect(rich(inbox, id, second).document).toContain('data:image/png');
    const secondSource = rich(inbox, id, second);
    const firstBody = inbox.messageBody(id, first);
    assert.equal(firstBody?.kind, 'ready');
    inbox.discardRichMessage(id, firstBody.presentation, first);
    expect(rich(inbox, id, second)).toBe(secondSource);
    closeFirst();
    reopenSecond();
    expect(
      [...shared.images.values()].flatMap((ledger) => [...ledger.values()]),
    ).toStrictEqual([]);
  });
  /* oxlint-enable vitest/max-expects */

  it('shows a waiting window its images once another window releases the budget', async () => {
    expect.hasAssertions();
    const shared = createBodyLoads();
    const gmail = createSyntheticGmail();
    const gmailId = gmail.deliver({ at: Date.UTC(2020, 0, 1) });
    gmail.native.openMessageBody = (_scope, id) =>
      Promise.resolve(cached(id, 1));
    const gmailInbox = createGmailInbox(gmail.native, { shared });
    await gmailInbox.load();
    const closeGmail = gmailInbox.retainMessage(gmailId);
    await gmailInbox.readMessage(gmailId);

    const imap = createSyntheticImap();
    imap.deliver('INBOX', { subject: 'Photo' });
    vi.spyOn(imap.native, 'openMessageBody').mockImplementation((_scope, id) =>
      Promise.resolve(cached(id, 1)),
    );
    const inbox = createImapInbox(imap.native, { shared });
    await inbox.load();
    const id = firstId(inbox);
    const first = Symbol('first window');
    const second = Symbol('second window');
    const closeFirst = inbox.retainMessage(id, first);
    await inbox.readMessage(id);
    const closeSecond = inbox.retainMessage(id, second);
    await inbox.readMessage(id);
    // Gmail and the first window hold the whole budget; the second waits with placeholders.
    expect(rich(inbox, id, second).document).not.toContain('data:image/png');
    closeFirst();
    expect(rich(inbox, id, second).document).toContain('data:image/png');
    closeSecond();
    closeGmail();
  });

  it('retries the surviving legacy readers with their reduced image cost', async () => {
    expect.hasAssertions();
    const shared = createBodyLoads();
    const gmail = createSyntheticGmail();
    const gmailId = gmail.deliver({ at: Date.UTC(2020, 0, 1) });
    gmail.native.openMessageBody = (_scope, id) =>
      Promise.resolve(cached(id, 1));
    const gmailInbox = createGmailInbox(gmail.native, { shared });
    await gmailInbox.load();
    const closeGmail = gmailInbox.retainMessage(gmailId);
    await gmailInbox.readMessage(gmailId);

    const imap = createSyntheticImap();
    imap.deliver('INBOX', { subject: 'Photo' });
    vi.spyOn(imap.native, 'openMessageBody').mockImplementation((_scope, id) =>
      Promise.resolve(cached(id, 1)),
    );
    const inbox = createImapInbox(imap.native, { shared });
    await inbox.load();
    const id = firstId(inbox);
    const closeFirst = inbox.retainMessage(id);
    const closeSecond = inbox.retainMessage(id);
    await inbox.readMessage(id);
    expect(rich(inbox, id).document).not.toContain('data:image/png');
    closeFirst();
    expect(rich(inbox, id).document).toContain('data:image/png');
    closeSecond();
    closeGmail();
  });

  /* oxlint-disable vitest/max-expects -- One waiting-reader journey proves identity, notification and admission order. */
  it('keeps unchanged waiting presentations while admitting windows in order', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.deliver('INBOX', { subject: 'Photo' });
    vi.spyOn(imap.native, 'openMessageBody').mockImplementation((_scope, id) =>
      Promise.resolve(cached(id, 1)),
    );
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const id = firstId(inbox);
    const first = Symbol('first');
    const second = Symbol('second');
    const third = Symbol('third');
    const fourth = Symbol('fourth');
    const closeFirst = inbox.retainMessage(id, first);
    const closeSecond = inbox.retainMessage(id, second);
    const closeThird = inbox.retainMessage(id, third);
    const closeFourth = inbox.retainMessage(id, fourth);
    await inbox.readMessage(id);
    const waiting = inbox.messageBody(id, third);
    let changes = 0;
    const unsubscribe = inbox.subscribe(() => {
      changes += 1;
    });
    closeFourth();
    expect(inbox.messageBody(id, third)).toBe(waiting);
    expect(changes).toBe(0);
    const closeLast = inbox.retainMessage(id, fourth);
    const lastWaiting = inbox.messageBody(id, fourth);
    const established = inbox.messageBody(id, second);
    changes = 0;
    closeFirst();
    expect(rich(inbox, id, third).document).toContain('data:image/png');
    expect(inbox.messageBody(id, fourth)).toBe(lastWaiting);
    expect(inbox.messageBody(id, second)).toBe(established);
    expect(changes).toBe(1);
    closeSecond();
    expect(rich(inbox, id, fourth).document).toContain('data:image/png');
    unsubscribe();
    closeThird();
    closeLast();
  });
  /* oxlint-enable vitest/max-expects */

  it('gives a waiting reader the reservation released by a rich-view failure', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.deliver('INBOX', { subject: 'Photo' });
    vi.spyOn(imap.native, 'openMessageBody').mockImplementation((_scope, id) =>
      Promise.resolve(cached(id, 1)),
    );
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const id = firstId(inbox);
    const first = Symbol('first');
    const second = Symbol('second');
    const third = Symbol('third');
    const closeFirst = inbox.retainMessage(id, first);
    const closeSecond = inbox.retainMessage(id, second);
    const closeThird = inbox.retainMessage(id, third);
    await inbox.readMessage(id);
    const failed = inbox.messageBody(id, first);
    assert.equal(failed?.kind, 'ready');
    expect(rich(inbox, id, third).document).not.toContain('data:image/png');
    let changes = 0;
    const unsubscribe = inbox.subscribe(() => {
      changes += 1;
    });
    inbox.discardRichMessage(id, failed.presentation, first);
    expect(rich(inbox, id, third).document).toContain('data:image/png');
    expect(changes).toBe(1);
    closeSecond();
    const fallback = inbox.messageBody(id, first);
    assert.equal(fallback?.kind, 'ready');
    expect(fallback.presentation.rich).toBeUndefined();
    unsubscribe();
    closeFirst();
    closeThird();
  });

  it('drops a late cache callback after its connection is forgotten', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.deliver('INBOX', { subject: 'Private mail' });
    const reply = await imap.native.openMailbox();
    const pending = Promise.withResolvers<unknown>();
    const entered = Promise.withResolvers<undefined>();
    vi.spyOn(imap.native, 'openMailbox').mockImplementation(() => {
      entered.resolve(undefined);
      return pending.promise;
    });
    const inbox = createImapInbox(imap.native);
    const loading = inbox.load();
    await entered.promise;
    inbox.forget();
    pending.resolve(reply);
    await loading;
    await inbox.openFolder('Archive');
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'loading' });
    expect(imap.server.reads).toStrictEqual([]);
  });
});
