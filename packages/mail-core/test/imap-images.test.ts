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
const photo = 'https://images.example/photo.png';
const remoteBody = (id: string) => ({
  document: JSON.stringify({
    version: 2,
    id,
    html: `<p>Photo</p>${`<img src="${photo}">`.repeat(2)}`,
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
    const saves = shared.cache.getSnapshot();
    const close = inbox.retainMessage(id);
    await inbox.readMessage(id);
    expect(rich(inbox, id).document).not.toContain('data:image/png');
    // The downloaded body is saved once.
    expect(shared.cache.getSnapshot()).toBe(saves + 1);
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

  /* oxlint-disable vitest/max-expects -- One journey proves release across stores in both directions and across Gmail messages. */
  it('shows waiting readers their images when another store or message releases the budget', async () => {
    expect.hasAssertions();
    const shared = createBodyLoads();
    const gmail = createSyntheticGmail();
    const older = gmail.deliver({ at: Date.UTC(2020, 0, 1) });
    const newer = gmail.deliver({ at: Date.UTC(2020, 0, 2) });
    gmail.native.openMessageBody = (_scope, id) =>
      Promise.resolve(cached(id, 1));
    const gmailInbox = createGmailInbox(gmail.native, { shared });
    await gmailInbox.load();
    const gmailRich = (id: string, reader?: symbol) => {
      const state = gmailInbox.messageBody(id, reader);
      assert.equal(state?.kind, 'ready');
      assert.ok(state.presentation.rich);
      return state.presentation.rich;
    };
    const closeOlder = gmailInbox.retainMessage(older);
    await gmailInbox.readMessage(older);

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
    const established = rich(inbox, id, first);
    const closeSecond = inbox.retainMessage(id, second);
    await inbox.readMessage(id);
    expect(rich(inbox, id, second).document).not.toContain('data:image/png');
    let imapChanges = 0;
    const unsubscribeImap = inbox.subscribe(() => {
      imapChanges += 1;
    });
    // Closing the Gmail reader shows the waiting IMAP window its images without reopening it.
    closeOlder();
    expect(rich(inbox, id, second).document).toContain('data:image/png');
    expect(rich(inbox, id, first)).toBe(established);
    expect(imapChanges).toBe(1);
    unsubscribeImap();

    // The reverse: a Gmail window waits until an IMAP window closes.
    const window = Symbol('Gmail window');
    const closeNewer = gmailInbox.retainMessage(newer, window);
    await gmailInbox.readMessage(newer);
    expect(gmailRich(newer, window).document).not.toContain('data:image/png');
    const shown = rich(inbox, id, second);
    let gmailChanges = 0;
    const unsubscribeGmail = gmailInbox.subscribe(() => {
      gmailChanges += 1;
    });
    closeFirst();
    expect(gmailRich(newer, window).document).toContain('data:image/png');
    expect(rich(inbox, id, second)).toBe(shown);
    expect(gmailChanges).toBe(1);
    unsubscribeGmail();

    // Within Gmail, a reader of another message takes the budget a closing reader held.
    const reopenOlder = gmailInbox.retainMessage(older);
    await gmailInbox.readMessage(older);
    expect(gmailRich(older).document).not.toContain('data:image/png');
    closeNewer();
    expect(gmailRich(older).document).toContain('data:image/png');
    expect(rich(inbox, id, second)).toBe(shown);
    reopenOlder();
    closeSecond();
    expect(
      [...shared.images.values()].flatMap((ledger) => [...ledger.values()]),
    ).toStrictEqual([]);
  });
  /* oxlint-enable vitest/max-expects */

  it.each(['synchronization removal', 'body refresh'] as const)(
    'shows waiting IMAP images after Gmail %s',
    async (release) => {
      expect.hasAssertions();
      const shared = createBodyLoads();
      const gmail = createSyntheticGmail();
      const first = gmail.deliver({});
      const second = gmail.deliver({});
      gmail.native.openMessageBody = (_scope, id) =>
        Promise.resolve(cached(id, 1));
      const gmailInbox = createGmailInbox(gmail.native, { shared });
      await gmailInbox.load();
      const closeFirst = gmailInbox.retainMessage(first);
      const closeSecond = gmailInbox.retainMessage(second);
      await gmailInbox.readMessage(first);
      await gmailInbox.readMessage(second);

      const imap = createSyntheticImap();
      imap.deliver('INBOX', { subject: 'Photo' });
      vi.spyOn(imap.native, 'openMessageBody').mockImplementation(
        (_scope, id) => Promise.resolve(cached(id, 1)),
      );
      const inbox = createImapInbox(imap.native, { shared });
      await inbox.load();
      const id = firstId(inbox);
      const closeImap = inbox.retainMessage(id);
      await inbox.readMessage(id);
      expect(rich(inbox, id).document).not.toContain('data:image/png');

      const releaseBody = {
        'synchronization removal': () => {
          gmail.remove(first);
          return gmailInbox.load();
        },
        'body refresh': () => {
          gmail.native.openMessageBody = (_scope, message) =>
            Promise.resolve(cached(message, 0));
          return gmailInbox.readMessage(first, { refresh: true });
        },
      };
      await releaseBody[release]();
      expect(rich(inbox, id).document).toContain('data:image/png');
      closeFirst();
      closeSecond();
      closeImap();
    },
  );

  it.each([
    {
      provider: 'Gmail',
      other: 'IMAP',
      gmailBody: remoteBody,
      imapBody: (id: string) => cached(id, 1),
    },
    {
      provider: 'IMAP',
      other: 'Gmail',
      gmailBody: (id: string) => cached(id, 1),
      imapBody: remoteBody,
    },
  ] as const)(
    'shows waiting inline images when $provider hides remote content',
    async ({ provider, other, gmailBody, imapBody }) => {
      expect.hasAssertions();
      const shared = createBodyLoads();
      const gmail = createSyntheticGmail();
      const gmailId = gmail.deliver({});
      gmail.serveRemote(photo, { data: image });
      gmail.native.openMessageBody = (_scope, id) =>
        Promise.resolve(gmailBody(id));
      const gmailInbox = createGmailInbox(gmail.native, { shared });
      await gmailInbox.load();
      const imap = createSyntheticImap();
      imap.deliver('INBOX', { subject: 'Photo' });
      imap.serveRemote(photo, { data: image });
      vi.spyOn(imap.native, 'openMessageBody').mockImplementation(
        (_scope, id) => Promise.resolve(imapBody(id)),
      );
      const inbox = createImapInbox(imap.native, { shared });
      await inbox.load();
      const imapId = firstId(inbox);
      const stores = {
        Gmail: { inbox: gmailInbox, id: gmailId },
        IMAP: { inbox, id: imapId },
      };
      const holder = stores[provider];
      const waiting = stores[other];
      const closeHolder = holder.inbox.retainMessage(holder.id);
      await holder.inbox.readMessage(holder.id);
      await holder.inbox.loadRemoteImages(holder.id, [photo], true);
      const closeWaiting = waiting.inbox.retainMessage(waiting.id);
      await waiting.inbox.readMessage(waiting.id);
      const before = waiting.inbox.messageBody(waiting.id);
      assert.equal(before?.kind, 'ready');
      expect(before.presentation.rich?.document).not.toContain(
        'data:image/png',
      );

      holder.inbox.forgetRemoteImages(holder.id);
      const after = waiting.inbox.messageBody(waiting.id);
      assert.equal(after?.kind, 'ready');
      expect(after.presentation.rich?.document).toContain('data:image/png');
      closeHolder();
      closeWaiting();
    },
  );

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

  it('downloads at most two IMAP bodies at once for one connection', async () => {
    expect.hasAssertions();
    const shared = createBodyLoads();
    const imap = createSyntheticImap();
    for (const subject of ['First', 'Second', 'Third']) {
      imap.deliver('INBOX', { subject });
    }
    const { imapMessage } = imap.native;
    const gates: Array<() => void> = [];
    let running = 0;
    let most = 0;
    vi.spyOn(imap.native, 'imapMessage').mockImplementation(
      async (mailbox, request) => {
        running += 1;
        most = Math.max(most, running);
        const gate = Promise.withResolvers<undefined>();
        gates.push(() => {
          gate.resolve(undefined);
        });
        await gate.promise;
        running -= 1;
        return imapMessage(mailbox, request);
      },
    );
    const inbox = createImapInbox(imap.native, { shared });
    await inbox.load();
    const state = inbox.getSnapshot();
    assert.equal(state.kind, 'ready');
    const ids = state.messages.map(({ id }) => id);
    const releases = ids.map((id) => inbox.retainMessage(id));
    const reads = Promise.all(ids.map(async (id) => inbox.readMessage(id)));
    await vi.waitFor(() => {
      expect(gates).toHaveLength(2);
    });
    // The third download waits for a permit until one of the first two finishes.
    gates.shift()?.();
    await vi.waitFor(() => {
      expect(gates).toHaveLength(2);
    });
    for (const open of gates.splice(0)) {
      open();
    }
    await reads;
    expect(most).toBe(2);
    expect(ids.map((id) => inbox.messageBody(id)?.kind)).toStrictEqual([
      'ready',
      'ready',
      'ready',
    ]);
    for (const release of releases) {
      release();
    }
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
