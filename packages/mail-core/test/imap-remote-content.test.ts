import type { ImapInbox } from '../src/imap-inbox.ts';

import { createBodyLoads, createGmailInbox } from '../src/gmail-inbox.ts';
import { createImapInbox } from '../src/imap-inbox.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';
import { createSyntheticImap } from '../src/testing/imap-mailbox.ts';
import { open, png, waitForFetches } from './remote-content-fixture.ts';

const html = (urls: readonly string[]) =>
  urls.map((url) => `<img src="${url}" alt="Photo">`).join('');

// An HTML message with the headers its envelope reports.
const raw = (subject: string, body: string) =>
  [
    'From: Synthetic Sender <sender@example.invalid>',
    'To: alex@example.invalid',
    `Subject: ${subject}`,
    'MIME-Version: 1.0',
    'Content-Type: text/html; charset=utf-8',
    '',
    body,
  ].join('\r\n');

const sources = (name: string, count: number) =>
  Array.from(
    { length: count },
    (_, index) => `https://images.example/${name}/${index}.png`,
  );

const idOf = (inbox: ImapInbox, subject: string) => {
  const state = inbox.getSnapshot();
  const found =
    state.kind === 'ready'
      ? state.messages.find((message) => message.subject === subject)
      : undefined;
  if (found === undefined) {
    throw new Error(`No listed message ${subject}`);
  }
  return found.id;
};

// Opens a message in one reader, as the IMAP reader view does.
const read = async (inbox: ImapInbox, id: string) => {
  const reader = Symbol('reader');
  const release = inbox.retainMessage(id, reader);
  await inbox.readMessage(id);
  return {
    release,
    shown: () => {
      const state = inbox.messageBody(id, reader);
      if (state?.kind !== 'ready' || state.presentation.rich === undefined) {
        throw new Error(`Expected a rich body, received ${state?.kind}`);
      }
      return state.presentation.rich;
    },
  };
};

describe('imap remote message content', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one consent and ownership contract end to end. */
  it('loads remote images only once a presentation authorizes them, then restores them from the cache', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    const photo = 'https://images.example/photo.png';
    const refused = 'https://internal.example/secret.png';
    imap.serveRemote(photo, { data: png(4, 3) });
    imap.serveRemote(refused, { code: 'refused' });
    imap.deliver('INBOX', {
      subject: 'Newsletter',
      raw: raw(
        'Newsletter',
        [
          '<p>Newsletter</p>',
          html([photo, refused]),
          '<img src="https://tracker.example/open.gif" width="1" height="1">',
        ].join(''),
      ),
    });
    const inbox = createImapInbox(imap.native, { connection: 'imap-1' });
    await inbox.load();
    const id = idOf(inbox, 'Newsletter');

    const first = await read(inbox, id);
    // Known tracking pixels never become loadable references.
    expect(first.shown().remote.pending).toStrictEqual([photo, refused]);
    // Without authorization only the empty cache is consulted.
    await inbox.loadRemoteImages(id, first.shown().remote.pending, false);
    expect(imap.remoteFetches).toStrictEqual([]);

    await inbox.loadRemoteImages(id, first.shown().remote.pending, true);
    expect(imap.remoteFetches.toSorted()).toStrictEqual(
      [photo, refused].toSorted(),
    );
    expect(first.shown().document).toContain('data:image/png;base64,');
    expect(first.shown().document).not.toContain('images.example');
    expect(first.shown().remote.pending).toStrictEqual([refused]);
    // The cache entry belongs to this connection and protects what it displays.
    expect(imap.remoteCommits).toStrictEqual([[['imap-1', id, photo]]]);
    first.release();

    // A later presentation restores the image without contacting the server; Never hides it.
    const second = await read(inbox, id);
    await inbox.loadRemoteImages(id, [photo], false);
    expect(second.shown().document).toContain('data:image/png;base64,');
    expect(imap.remoteFetches).toHaveLength(2);
    inbox.forgetRemoteImages(id);
    expect(second.shown().document).not.toContain('data:image/png');
    expect(imap.remoteCached(id, photo)).toBe(true);
    second.release();
  });

  it('ends remote loads when the reader or the Inbox closes, and keeps a new UIDVALIDITY apart', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    const closing = sources('closing', 2);
    const renumbered = sources('renumbered', 2);
    const forgotten = sources('forgotten', 2);
    for (const url of [...closing, ...renumbered, ...forgotten]) {
      imap.serveRemote(url, { data: png(2, 2) });
    }
    imap.deliver('INBOX', {
      subject: 'Closing',
      raw: raw('Closing', html(closing)),
    });
    imap.deliver('INBOX', {
      subject: 'Renumbered',
      raw: raw('Renumbered', html(renumbered)),
    });
    const inbox = createImapInbox(imap.native, { connection: 'imap-1' });
    await inbox.load();
    const loads: Array<Promise<void>> = [];
    try {
      // The last reader closing cancels its requests; nothing they return is kept.
      const closingId = idOf(inbox, 'Closing');
      const reader = await read(inbox, closingId);
      imap.pauseRemote();
      loads.push(inbox.loadRemoteImages(closingId, closing, true));
      await waitForFetches(imap.remoteInFlight, 2);
      reader.release();
      await waitForFetches(imap.remoteInFlight, 0);
      imap.resumeRemote();
      await Promise.all(loads);
      expect(imap.remoteCommits).toStrictEqual([]);

      // A new UIDVALIDITY gives the message a new identity, which restores nothing cached for
      // the old one without its own authorization.
      const before = idOf(inbox, 'Renumbered');
      const stale = await read(inbox, before);
      await inbox.loadRemoteImages(before, renumbered, true);
      expect(
        imap.remoteCached(before, 'https://images.example/renumbered/0.png'),
      ).toBe(true);
      stale.release();
      imap.renumber('INBOX');
      await inbox.load();
      const after = idOf(inbox, 'Renumbered');
      expect(after).not.toBe(before);
      const fresh = await read(inbox, after);
      await inbox.loadRemoteImages(after, renumbered, false);
      expect(fresh.shown().remote.pending).toStrictEqual(renumbered);
      expect(imap.remoteFetches).toHaveLength(4);
      fresh.release();

      // Closing the Inbox ends every load.
      imap.deliver('INBOX', {
        subject: 'Forgotten',
        raw: raw('Forgotten', html(forgotten)),
      });
      await inbox.load();
      const forgottenId = idOf(inbox, 'Forgotten');
      const last = await read(inbox, forgottenId);
      imap.pauseRemote();
      loads.push(inbox.loadRemoteImages(forgottenId, forgotten, true));
      await waitForFetches(imap.remoteInFlight, 2);
      inbox.forget();
      await waitForFetches(imap.remoteInFlight, 0);
      imap.resumeRemote();
      await Promise.all(loads);
      last.release();
      expect(imap.remoteCommits).toHaveLength(2);
    } finally {
      inbox.forget();
      imap.resumeRemote();
      await Promise.allSettled(loads);
    }
  });

  it('shares the display budget with Gmail readers and the message inline images', async () => {
    expect.hasAssertions();
    const shared = createBodyLoads();
    const gmail = createSyntheticGmail();
    const imap = createSyntheticImap();
    const large = 'https://images.example/gmail/large.png';
    const pair = sources('imap', 2);
    gmail.serveRemote(large, { data: png(4096, 4096) });
    for (const url of pair) {
      imap.serveRemote(url, { data: png(4096, 4096) });
    }
    const gmailId = gmail.deliver({ content: { html: html([large]) } });
    imap.deliver('INBOX', { subject: 'Pair', raw: raw('Pair', html(pair)) });
    const gmailInbox = createGmailInbox(gmail.native, { shared });
    const imapInbox = createImapInbox(imap.native, {
      shared,
      connection: 'imap-1',
    });
    await Promise.all([gmailInbox.load(), imapInbox.load()]);
    const id = idOf(imapInbox, 'Pair');

    // A Gmail reader holding a 16-Mi-pixel image leaves room for one of the pair.
    const gmailReader = await open(gmailInbox, gmailId);
    await gmailInbox.loadRemoteImages(gmailId, [large], true);
    expect(gmailReader.shown().remote.pending).toStrictEqual([]);
    const reader = await read(imapInbox, id);
    await imapInbox.loadRemoteImages(id, pair, true);
    expect(reader.shown().remote.pending).toHaveLength(1);

    // Once the Gmail reader closes, the IMAP reader admits both.
    gmailReader.release();
    await imapInbox.loadRemoteImages(id, pair, true);
    expect(reader.shown().remote.pending).toStrictEqual([]);
    reader.release();
  });
  /* oxlint-enable vitest/max-expects */
});
