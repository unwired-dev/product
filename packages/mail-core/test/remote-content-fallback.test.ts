import type { MessageBodyState } from '../src/gmail-inbox.ts';

import { createBodyLoads, createGmailInbox } from '../src/gmail-inbox.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';
import { open, png, remote, waitForFetches } from './remote-content-fixture.ts';

const readyBody = (state: MessageBodyState | undefined) => {
  if (state?.kind !== 'ready') {
    throw new Error(`Expected a ready body, received ${state?.kind}`);
  }
  return state;
};

describe('remote content after rich rendering fails', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves fallback ownership and recovery end to end. */
  it('lets healthy and new readers load after a legacy rich view fails', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const photo = 'https://images.example/healthy.png';
    const later = 'https://images.example/new.png';
    for (const url of [photo, later]) {
      gmail.serveRemote(url, { data: png(2, 2) });
    }
    const id = gmail.deliver({
      content: { html: `<img src="${photo}"><img src="${later}">` },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const release = inbox.retainMessage(id);
    const healthy = await open(inbox, id);
    let releaseNew: () => void = () => undefined;
    try {
      inbox.discardRichMessage(
        id,
        readyBody(inbox.messageBody(id)).presentation,
      );
      await inbox.loadRemoteImages(id, [photo], {
        network: true,
        reader: healthy.reader,
      });
      expect(healthy.shown().remote.pending).toStrictEqual([later]);
      expect(
        readyBody(inbox.messageBody(id)).presentation.rich,
      ).toBeUndefined();
      releaseNew = inbox.retainMessage(id);
      await inbox.loadRemoteImages(id, [later], true);
      expect(remote(inbox.messageBody(id)).remote.pending).toStrictEqual([]);
      expect(gmail.remoteFetches).toStrictEqual([photo, later]);
    } finally {
      releaseNew();
      release();
      healthy.release();
    }
  });

  it('releases remote budget after rich failure while preserving another window', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const photo = 'https://images.example/shared.png';
    const later = 'https://images.example/later.png';
    const last = 'https://images.example/last.png';
    const data = png(4096, 4096);
    for (const url of [photo, later, last]) {
      gmail.serveRemote(url, { data });
    }
    const first = gmail.deliver({ content: { html: `<img src="${photo}">` } });
    const second = gmail.deliver({
      content: { html: `<img src="${later}"><img src="${last}">` },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const failed = await open(inbox, first);
    const healthy = await open(inbox, first);
    const other = await open(inbox, second);
    try {
      await inbox.loadRemoteImages(first, [photo], {
        network: true,
        reader: healthy.reader,
      });
      inbox.discardRichMessage(
        first,
        readyBody(inbox.messageBody(first, failed.reader)).presentation,
        failed.reader,
      );
      await inbox.loadRemoteImages(second, [later, last], {
        network: true,
        reader: other.reader,
      });
      expect(healthy.shown().remote.pending).toStrictEqual([]);
      expect(other.shown().remote.pending).toStrictEqual([last]);
      inbox.discardRichMessage(
        first,
        readyBody(inbox.messageBody(first, healthy.reader)).presentation,
        healthy.reader,
      );
      // The fallback windows stay open; only their unused image budget returns.
      await inbox.loadRemoteImages(second, [last], {
        network: true,
        reader: other.reader,
      });
      expect(other.shown().remote.pending).toStrictEqual([]);
      expect(gmail.remoteCached(second, last)).toBe(true);
      expect(gmail.remoteCommits.at(-1)).toStrictEqual([
        ['', second, later],
        ['', second, last],
      ]);
      expect(
        readyBody(inbox.messageBody(first, failed.reader)).presentation.rich,
      ).toBeUndefined();
    } finally {
      failed.release();
      healthy.release();
      other.release();
    }
  });

  it('keeps unsettled images owned by a healthy reader when another rich view fails', async () => {
    expect.hasAssertions();
    const shared = createBodyLoads();
    const gmail = createSyntheticGmail();
    const photo = 'https://images.example/restored.png';
    const later = 'https://images.example/paused.png';
    for (const url of [photo, later]) {
      gmail.serveRemote(url, { data: png(2, 2) });
    }
    const id = gmail.deliver({
      content: { html: `<img src="${photo}"><img src="${later}">` },
    });
    const inbox = createGmailInbox(gmail.native, { shared });
    await inbox.load();
    const seed = await open(inbox, id);
    try {
      await inbox.loadRemoteImages(id, [photo], {
        network: true,
        reader: seed.reader,
      });
    } finally {
      seed.release();
    }
    const failed = await open(inbox, id);
    const healthy = await open(inbox, id);
    gmail.pauseRemote();
    const loading = inbox.loadRemoteImages(id, [photo, later], {
      network: true,
      reader: healthy.reader,
    });
    try {
      // The public account coordinator has retained the cache hit while the batch waits.
      await vi.waitFor(() => {
        expect([...shared.remoteImages.values()][0]?.size).toBe(1);
      });
      await waitForFetches(gmail.remoteInFlight, 1);
      inbox.discardRichMessage(
        id,
        readyBody(inbox.messageBody(id, failed.reader)).presentation,
        failed.reader,
      );
      gmail.resumeRemote();
      await loading;
      expect(healthy.shown().remote.pending).toStrictEqual([]);
      expect(gmail.remoteCommits.at(-1)).toStrictEqual([
        ['', id, photo],
        ['', id, later],
      ]);
    } finally {
      gmail.resumeRemote();
      failed.release();
      healthy.release();
      await loading;
    }
  });

  const viewReader = Symbol('reader');

  it.each([
    {
      kind: 'view',
      reader: viewReader,
      authorization: { network: true, reader: viewReader },
    },
    { kind: 'legacy', reader: undefined, authorization: true },
  ])(
    'ends remote requests when rich rendering fails ($kind reader)',
    async ({ reader, authorization }) => {
      expect.hasAssertions();
      const gmail = createSyntheticGmail();
      const photo = 'https://images.example/failing-view.png';
      gmail.serveRemote(photo, { data: png(2, 2) });
      const id = gmail.deliver({
        content: { html: `<p>Hello</p><img src="${photo}" alt="Photo">` },
      });
      const inbox = createGmailInbox(gmail.native);
      await inbox.load();
      const release = inbox.retainMessage(id, reader);
      await inbox.readMessage(id);
      gmail.pauseRemote();
      const loading = inbox.loadRemoteImages(id, [photo], authorization);
      try {
        await waitForFetches(gmail.remoteInFlight, 1);
        // WebKit reports the rich view failed while the image is in flight.
        const failed = readyBody(inbox.messageBody(id, reader));
        inbox.discardRichMessage(id, failed.presentation, reader);
        await waitForFetches(gmail.remoteInFlight, 0);
        gmail.resumeRemote();
        await loading;
        expect(
          readyBody(inbox.messageBody(id, reader)).presentation.rich,
        ).toBeUndefined();
        expect(gmail.remoteCommits).toStrictEqual([]);
        expect(gmail.remoteTouches).toStrictEqual([]);
        // The fallback reader cannot register new interest either.
        await inbox.loadRemoteImages(id, [photo], authorization);
        expect(gmail.remoteFetches).toStrictEqual([photo]);
        // A fresh body lets this reader try rich rendering again.
        await inbox.readMessage(id, { refresh: true });
        await inbox.loadRemoteImages(id, [photo], authorization);
        expect(
          remote(inbox.messageBody(id, reader)).remote.pending,
        ).toStrictEqual([]);
      } finally {
        gmail.resumeRemote();
        release();
        await loading;
      }
    },
  );

  /* oxlint-enable vitest/max-expects */
});
