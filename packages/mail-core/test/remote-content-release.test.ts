import { createGmailInbox } from '../src/gmail-inbox.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';
import { open, png, waitForFetches } from './remote-content-fixture.ts';

const sources = (prefix: string, count: number) =>
  Array.from(
    { length: count },
    (_, index) => `https://images.example/${prefix}/${index}.png`,
  );
const html = (urls: readonly string[]) =>
  urls.map((url) => `<img src="${url}" alt="Photo">`).join('');

describe('remote message content ownership', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one ownership contract end to end. */
  it('shows remote images only within what the message inline images leave of the display budget', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const photo = 'https://images.example/beside-inline.png';
    gmail.serveRemote(photo, { data: png(2, 2) });
    // Two 16-Mi-pixel copies of one inline image fill the shared presentation budget.
    const id = gmail.deliver({
      content: {
        html: `<img src="cid:chart" alt="Chart"><img src="cid:chart" alt="Again"><img src="${photo}" alt="Photo">`,
        images: [
          {
            contentId: 'chart',
            mimeType: 'image/png',
            bytes: [...Buffer.from(png(4096, 4096), 'base64')],
          },
        ],
      },
    });
    const small = gmail.deliver({ content: { html: html([photo]) } });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const window = await open(inbox, id);
    try {
      expect(window.shown().document).toContain('data:image/png');
      await inbox.loadRemoteImages(id, [photo], true);
      // Fetched within the retained budget, but neither shown nor cached beside the inline images.
      expect(gmail.remoteFetches).toStrictEqual([photo]);
      expect(window.shown().remote.pending).toStrictEqual([photo]);
      expect(gmail.remoteCommits).toStrictEqual([]);

      // Once that body is no longer shown, the same source fits in another message.
      window.release();
      const other = await open(inbox, small);
      await inbox.loadRemoteImages(small, [photo], true);
      expect(other.shown().remote.pending).toStrictEqual([]);
      expect(gmail.remoteCommits).toHaveLength(1);
      other.release();
    } finally {
      window.release();
    }
  });

  it('cancels requests and returns retained budget when the body leaves memory', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const large = 'https://images.example/removed/large.png';
    const queued = sources('removed', 10);
    gmail.serveRemote(large, { data: png(4096, 4096) });
    for (const url of queued) {
      gmail.serveRemote(url, { data: png(2, 2) });
    }
    const removed = gmail.deliver({
      content: { html: html([large, ...queued]) },
    });
    const pair = sources('kept', 2);
    for (const url of pair) {
      gmail.serveRemote(url, { data: png(4096, 4096) });
    }
    const kept = gmail.deliver({ content: { html: html(pair) } });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const window = await open(inbox, removed);
    const loads: Array<Promise<void>> = [];
    try {
      await inbox.loadRemoteImages(removed, [large], true);
      expect(window.shown().remote.pending).not.toContain(large);
      gmail.pauseRemote();
      loads.push(inbox.loadRemoteImages(removed, queued, true));
      await waitForFetches(gmail.remoteInFlight, 6);

      // Gmail no longer has the message, so synchronization releases its body.
      gmail.remove(removed);
      await inbox.load();
      await waitForFetches(gmail.remoteInFlight, 0);
      gmail.resumeRemote();
      await Promise.all(loads);
      expect(gmail.remoteFetches).toHaveLength(7);
      expect(gmail.remoteCommits).toHaveLength(1);

      // Its 16-Mi-pixel image no longer counts, so both images of another message fit.
      const other = await open(inbox, kept);
      await inbox.loadRemoteImages(kept, pair, true);
      expect(other.shown().remote.pending).toStrictEqual([]);
      other.release();
    } finally {
      window.release();
      gmail.resumeRemote();
      await Promise.allSettled(loads);
    }
  });

  it('drops remote work for a previous mailbox and loads afresh after the Inbox reopens', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const urls = sources('closing', 6);
    for (const url of urls) {
      gmail.serveRemote(url, { data: png(2, 2) });
    }
    const id = gmail.deliver({ content: { html: html(urls) } });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const loads: Array<Promise<void>> = [];
    try {
      // Closing the Inbox ends its loads; reopening loads the same message afresh.
      const closed = await open(inbox, id);
      gmail.pauseRemote();
      loads.push(inbox.loadRemoteImages(id, urls, true));
      await waitForFetches(gmail.remoteInFlight, 6);
      inbox.forget();
      await waitForFetches(gmail.remoteInFlight, 0);
      gmail.resumeRemote();
      await Promise.all(loads);
      closed.release();
      expect(gmail.remoteCommits).toStrictEqual([]);
      await inbox.load();
      const reopened = await open(inbox, id);
      await inbox.loadRemoteImages(id, urls, true);
      expect(reopened.shown().remote.pending).toStrictEqual([]);
      expect(gmail.remoteFetches).toHaveLength(12);
      expect(gmail.remoteCommits).toHaveLength(6);

      // Another mailbox replaces this one: in-flight requests settle into nothing.
      const next = sources('replaced', 6);
      for (const url of next) {
        gmail.serveRemote(url, { data: png(2, 2) });
      }
      const pending = gmail.deliver({ content: { html: html(next) } });
      await inbox.load();
      const replaced = await open(inbox, pending);
      gmail.pauseRemote();
      loads.push(inbox.loadRemoteImages(pending, next, true));
      await waitForFetches(gmail.remoteInFlight, 6);
      gmail.reselect('other@example.invalid');
      await inbox.load();
      gmail.resumeRemote();
      await Promise.all(loads);
      expect(inbox.getSnapshot()).toMatchObject({
        address: 'other@example.invalid',
      });
      expect(gmail.remoteCommits).toHaveLength(6);
      expect(inbox.messageBody(pending, replaced.reader)).toBeUndefined();
      replaced.release();
      reopened.release();
    } finally {
      inbox.forget();
      gmail.resumeRemote();
      await Promise.allSettled(loads);
    }
  });
  /* oxlint-enable vitest/max-expects */
});
