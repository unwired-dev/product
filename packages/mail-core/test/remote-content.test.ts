import { createBodyLoads, createGmailInbox } from '../src/gmail-inbox.ts';
import {
  createRemoteContentSettings,
  remoteContentPolicy,
} from '../src/remote-content.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';
import { open, png, waitForFetches } from './remote-content-fixture.ts';

describe('remote message content', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one consent and cache contract end to end. */
  it('loads nothing until a presentation authorizes it, then shows validated bytes from the cache', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const photo = 'https://images.example/photo.png';
    const broken = 'https://images.example/broken.png';
    const refused = 'https://internal.example/secret.png';
    gmail.serveRemote(photo, { data: png(4, 3) });
    gmail.serveRemote(broken, {
      data: Buffer.from('not an image').toString('base64'),
    });
    gmail.serveRemote(refused, { code: 'refused' });
    const html = [
      '<p>Newsletter</p>',
      `<img src="${photo}" alt="Photo"><img src="${photo}" alt="Again">`,
      `<img src="${broken}" alt="Broken"><img src="${refused}" alt="Refused">`,
      '<img src="https://tracker.example/open.gif" width="1" height="1">',
      '<img src="http://images.example/plain.png" alt="Plain">',
    ].join('');
    const id = gmail.deliver({ content: { html } });
    const other = gmail.deliver({
      content: { html: `<img src="${photo}" alt="Shared">` },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();

    const first = await open(inbox, id);
    // Known tracking pixels and plain HTTP sources never become loadable references.
    expect(first.shown().remote).toMatchObject({
      images: [photo, photo, broken, refused],
      pending: [photo, broken, refused],
    });
    // Without authorization only the cache is consulted, and it is empty.
    await inbox.loadRemoteImages(id, first.shown().remote.pending, false);
    expect(gmail.remoteFetches).toStrictEqual([]);
    expect(first.shown().document).not.toContain('data:image/png');

    // An authorized presentation fetches each source once, admits only a valid image, and
    // keeps the reader's isolation.
    await inbox.loadRemoteImages(id, first.shown().remote.pending, true);
    expect(gmail.remoteFetches.toSorted()).toStrictEqual(
      [broken, photo, refused].toSorted(),
    );
    const loaded = first.shown();
    expect(
      loaded.document.match(/src="data:image\/png;base64,/gu),
    ).toHaveLength(2);
    expect(loaded.document).toContain('img-src data:;');
    expect(loaded.document).not.toContain('images.example');
    expect(loaded.remote.pending).toStrictEqual([broken, refused]);
    expect(gmail.remoteCached(id, photo)).toBe(true);
    expect(gmail.remoteCached(id, broken)).toBe(false);
    // Each commit protects what is currently displayed.
    expect(gmail.remoteCommits).toStrictEqual([[['', id, photo]]]);
    first.release();

    // A later presentation restores the cached image without contacting the server.
    const second = await open(inbox, id);
    expect(second.shown().remote.pending).toStrictEqual([
      photo,
      broken,
      refused,
    ]);
    await inbox.loadRemoteImages(id, [photo], false);
    expect(second.shown().document).toContain('data:image/png;base64,');
    expect(gmail.remoteFetches).toHaveLength(3);
    // A policy change to Never hides what is loaded; the cache keeps it.
    inbox.forgetRemoteImages(id);
    expect(second.shown().document).not.toContain('data:image/png');
    expect(gmail.remoteCached(id, photo)).toBe(true);
    second.release();

    // Cached content belongs to its message: the same source in another message is not shared.
    const third = await open(inbox, other);
    await inbox.loadRemoteImages(other, [photo], false);
    expect(third.shown().remote.pending).toStrictEqual([photo]);
    expect(gmail.remoteFetches).toHaveLength(3);
    third.release();
  });

  it('preserves the network budget after twenty Ask cache misses', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const urls = Array.from(
      { length: 20 },
      (_, index) => `https://images.example/consent/${index}.png`,
    );
    for (const url of urls) {
      gmail.serveRemote(url, { data: png(2, 2) });
    }
    const id = gmail.deliver({
      content: {
        html: urls.map((url) => `<img src="${url}" alt="Photo">`).join(''),
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const reader = await open(inbox, id);
    try {
      await inbox.loadRemoteImages(id, urls, false);
      expect(gmail.remoteFetches).toStrictEqual([]);
      await inbox.loadRemoteImages(id, urls, true);
      expect(gmail.remoteFetches).toHaveLength(20);
      expect(reader.shown().remote.pending).toStrictEqual([]);
      inbox.forgetRemoteImages(id);
      await inbox.loadRemoteImages(id, urls, false);
      expect(reader.shown().remote.pending).toStrictEqual([]);
      expect(gmail.remoteFetches).toHaveLength(20);
    } finally {
      reader.release();
    }
  });

  it('keeps restoring cached images nearby after a full batch of cache misses', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const cachedUrl = 'https://images.example/later/20.png';
    const urls = [
      ...Array.from(
        { length: 20 },
        (_, index) => `https://images.example/later/${index}.png`,
      ),
      cachedUrl,
    ];
    gmail.serveRemote(cachedUrl, { data: png(2, 2) });
    const id = gmail.deliver({
      content: {
        html: urls.map((url) => `<img src="${url}" alt="Photo">`).join(''),
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const reader = await open(inbox, id);
    try {
      // An earlier authorized presentation cached only the last source.
      await inbox.loadRemoteImages(id, [cachedUrl], true);
      inbox.forgetRemoteImages(id);
      expect(reader.shown().remote.pending).toContain(cachedUrl);
      // The first twenty nearby sources miss the cache; the twenty-first is still restored.
      await inbox.loadRemoteImages(id, urls, false);
      expect(reader.shown().remote.pending).not.toContain(cachedUrl);
      expect(gmail.remoteFetches).toStrictEqual([cachedUrl]);
    } finally {
      reader.release();
    }
  });

  it('does not restore the old viewport when a held cache-only batch continues', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const urls = Array.from(
      { length: 21 },
      (_, index) => `https://images.example/withdrawn/${index}.png`,
    );
    const cachedUrl = urls[20]!;
    gmail.serveRemote(cachedUrl, { data: png(2, 2) });
    const id = gmail.deliver({
      content: { html: urls.map((url) => `<img src="${url}">`).join('') },
    });
    let releaseCache: () => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Hold cache reads until the viewport withdraws them.
    const heldCache = new Promise<void>((resolve) => {
      releaseCache = resolve;
    });
    let readCache = gmail.native.openRemoteContent;
    const probes: string[] = [];
    const inbox = createGmailInbox({
      ...gmail.native,
      openRemoteContent: (scope, resource) => readCache(scope, resource),
    });
    await inbox.load();
    const reader = await open(inbox, id);
    let loading: Promise<void> | undefined = undefined;
    try {
      await inbox.loadRemoteImages(id, [cachedUrl], true);
      inbox.forgetRemoteImages(id);
      readCache = async (scope, resource) => {
        probes.push(resource.url);
        await heldCache;
        return gmail.native.openRemoteContent(scope, resource);
      };
      loading = inbox.loadRemoteImages(id, urls, {
        network: false,
        reader: reader.reader,
      });
      await vi.waitFor(() => {
        expect(probes).toHaveLength(6);
      });
      await inbox.loadRemoteImages(id, [], {
        network: false,
        reader: reader.reader,
      });
      releaseCache();
      await loading;
      expect(probes).toHaveLength(6);
      expect(reader.shown().remote.pending).toContain(cachedUrl);
      expect(reader.shown().document).not.toContain('data:image/png');
      expect(gmail.remoteFetches).toStrictEqual([cachedUrl]);
    } finally {
      reader.release();
      releaseCache();
      await loading;
    }
  });

  it('retries a source that failed transiently, keeps refusals final, and marks only shown cache entries', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const flaky = 'https://images.example/flaky.png';
    const refused = 'https://internal.example/secret.png';
    gmail.serveRemote(flaky, { code: 'unavailable' });
    gmail.serveRemote(refused, { code: 'refused' });
    const id = gmail.deliver({
      content: {
        html: `<img src="${flaky}" alt="Flaky"><img src="${refused}" alt="Refused">`,
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const reader = await open(inbox, id);
    try {
      await inbox.loadRemoteImages(id, [flaky, refused], true);
      expect(reader.shown().remote.pending).toStrictEqual([flaky, refused]);
      // The server recovers while the reader stays open; a later request retries only the
      // transient failure.
      gmail.serveRemote(flaky, { data: png(2, 2) });
      // Leaving and returning to the viewport does not make a definite refusal retryable.
      await inbox.loadRemoteImages(id, [], true);
      await inbox.loadRemoteImages(id, [flaky, refused], true);
      expect(reader.shown().remote.pending).toStrictEqual([refused]);
      expect(gmail.remoteFetches).toStrictEqual([flaky, refused, flaky]);
      // A fetched image is cached, not marked as shown from the cache.
      expect(gmail.remoteTouches).toStrictEqual([]);
    } finally {
      reader.release();
    }
    // Restoring it in a later presentation marks the shown entry as recently used.
    const later = await open(inbox, id);
    try {
      await inbox.loadRemoteImages(id, [flaky], false);
      expect(later.shown().remote.pending).toStrictEqual([refused]);
      expect(gmail.remoteTouches).toHaveLength(1);
    } finally {
      later.release();
    }
  });

  it('retries deferred images in the same reader after another connection releases its budget', async () => {
    expect.hasAssertions();
    const shared = createBodyLoads();
    const first = createSyntheticGmail();
    const second = createSyntheticGmail({ address: 'sam@example.invalid' });
    const photo = 'https://images.example/held.png';
    const later = 'https://images.example/deferred.png';
    const data = png(4096, 4096);
    first.serveRemote(photo, { data });
    second.serveRemote(photo, { data });
    second.serveRemote(later, { data });
    const aId = first.deliver({ content: { html: `<img src="${photo}">` } });
    const bId = second.deliver({
      content: { html: `<img src="${photo}"><img src="${later}">` },
    });
    const a = createGmailInbox(first.native, { shared, connection: 'a' });
    const b = createGmailInbox(second.native, { shared, connection: 'b' });
    await Promise.all([a.load(), b.load()]);
    const aReader = await open(a, aId);
    const bReader = await open(b, bId);
    try {
      await a.loadRemoteImages(aId, [photo], true);
      await b.loadRemoteImages(bId, [photo, later], true);
      expect(bReader.shown().remote.pending).toStrictEqual([later]);
      expect(second.remoteCached(bId, later)).toBe(false);
      aReader.release();
      await b.loadRemoteImages(bId, [later], true);
      expect(bReader.shown().remote.pending).toStrictEqual([]);
      expect(second.remoteCached(bId, later)).toBe(true);
      expect(second.remoteFetches).toStrictEqual([photo, later, later]);
    } finally {
      aReader.release();
      bReader.release();
    }
  });

  it('does not touch or cache an image that repeated display occurrences cannot admit', async () => {
    expect.hasAssertions();
    const shared = createBodyLoads();
    const gmail = createSyntheticGmail();
    const urls = Array.from(
      { length: 20 },
      (_, index) => `https://images.example/repeated/${index}.png`,
    );
    const photo = urls[0]!;
    const data = png(3000, 3000);
    gmail.serveRemote(photo, { data });
    const id = gmail.deliver({
      content: {
        html: urls.map((url) => `<img src="${url}">`.repeat(4)).join(''),
      },
    });
    const inbox = createGmailInbox(gmail.native, { shared, connection: 'a' });
    await inbox.load();
    const reader = await open(inbox, id);
    let withdrawal: Promise<void> | undefined = undefined;
    let unsubscribe: () => void = () => undefined;
    gmail.pauseRemote();
    const pending = inbox.loadRemoteImages(id, [photo], true);
    try {
      await waitForFetches(gmail.remoteInFlight, 1);
      unsubscribe = inbox.subscribe(() => {
        unsubscribe();
        // A host can change viewport interest synchronously while consuming publication.
        withdrawal = inbox.loadRemoteImages(id, [], true);
      });
      gmail.resumeRemote();
      await pending;
      await withdrawal;
      expect(reader.shown().remote.pending).toStrictEqual(urls);
      expect(reader.shown().document).not.toContain('data:image/png');
      expect(gmail.remoteCached(id, photo)).toBe(false);
      // Interest replacement must not inherit an undisplayed image as already loaded.
      await inbox.loadRemoteImages(id, [photo], true);
      expect(gmail.remoteFetches).toStrictEqual([photo, photo]);
      // Undisplayed retention must not consume another connection's display budget.
      const other = createSyntheticGmail({ address: 'sam@example.invalid' });
      const otherUrls = [
        'https://images.example/a.png',
        'https://images.example/b.png',
      ];
      const large = png(4096, 4096);
      for (const url of otherUrls) {
        other.serveRemote(url, { data: large });
      }
      const otherId = other.deliver({
        content: {
          html: otherUrls.map((url) => `<img src="${url}">`).join(''),
        },
      });
      const otherInbox = createGmailInbox(other.native, {
        shared,
        connection: 'b',
      });
      await otherInbox.load();
      const otherReader = await open(otherInbox, otherId);
      try {
        await otherInbox.loadRemoteImages(otherId, otherUrls, true);
        expect(otherReader.shown().remote.pending).toStrictEqual([]);
      } finally {
        otherReader.release();
      }
      // A previously cached copy is equally undisplayable; reading it must not refresh LRU.
      const scope = await gmail.native.openMailbox();
      for (const url of urls) {
        await gmail.native.commitRemoteContent(
          scope,
          { id, url },
          { data, protected: [] },
        );
      }
      // A full deferred cache batch settles without repeatedly probing the same sources.
      await inbox.loadRemoteImages(id, urls, false);
      expect(reader.shown().remote.pending).toStrictEqual(urls);
      expect(gmail.remoteTouches).toStrictEqual([]);
    } finally {
      unsubscribe();
      reader.release();
      gmail.resumeRemote();
      await pending;
      await withdrawal;
    }
  });

  it('lets a surviving window show an image the closed window held in the shared budget', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const photo = 'https://images.example/shared-budget.png';
    gmail.serveRemote(photo, { data: png(4096, 4096) });
    const id = gmail.deliver({
      content: { html: `<p>Hello</p><img src="${photo}" alt="Photo">` },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const windows = [
      await open(inbox, id),
      await open(inbox, id),
      await open(inbox, id),
    ] as const;
    try {
      for (const window of windows) {
        await inbox.loadRemoteImages(id, [photo], {
          network: true,
          reader: window.reader,
        });
      }
      // Two 16-megapixel copies fill the shared budget, so the third window keeps a placeholder.
      expect(
        windows.map((window) => window.shown().remote.pending),
      ).toStrictEqual([[], [], [photo]]);
      windows[0].release();
      expect(windows[2].shown().remote.pending).toStrictEqual([]);
      expect(gmail.remoteFetches).toStrictEqual([photo]);
    } finally {
      windows[1].release();
      windows[2].release();
    }
  });

  it('does not publish an undisplayable cache hit and lets a later request retry it', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const photo = 'https://images.example/repeated-budget.png';
    gmail.serveRemote(photo, { data: png(4096, 4096) });
    const image = `<img src="${photo}" alt="Photo">`;
    const id = gmail.deliver({
      content: { html: `<p>Target</p>${image}${image}` },
    });
    const other = gmail.deliver({ content: { html: `<p>Other</p>${image}` } });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const seed = await open(inbox, id);
    try {
      await inbox.loadRemoteImages(id, [photo], {
        network: true,
        reader: seed.reader,
      });
      expect(gmail.remoteCached(id, photo)).toBe(true);
    } finally {
      seed.release();
    }
    const holder = await open(inbox, other);
    try {
      await inbox.loadRemoteImages(other, [photo], {
        network: true,
        reader: holder.reader,
      });
      const reader = await open(inbox, id);
      let notifications = 0;
      const unsubscribe = inbox.subscribe(() => {
        notifications += 1;
      });
      try {
        const previous = inbox.messageBody(id, reader.reader);
        // The cache's one copy fits retention, but two displayed copies cannot fit beside Other.
        await inbox.loadRemoteImages(id, [photo], {
          network: false,
          reader: reader.reader,
        });
        expect(reader.shown().remote.pending).toStrictEqual([photo]);
        expect(inbox.messageBody(id, reader.reader)).toBe(previous);
        expect(notifications).toBe(0);
        // Hiding the other view's images returns its budget for a later cache-only request.
        inbox.forgetRemoteImages(other);
        await inbox.loadRemoteImages(id, [photo], {
          network: false,
          reader: reader.reader,
        });
        expect(reader.shown().remote.pending).toStrictEqual([]);
        expect(gmail.remoteFetches).toStrictEqual([photo, photo]);
      } finally {
        unsubscribe();
        reader.release();
      }
    } finally {
      holder.release();
    }
  });

  it('cancels withdrawn window requests while another window authorizes different images', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const urls = [
      'https://images.example/window-a.png',
      'https://images.example/window-b.png',
    ];
    for (const url of urls) {
      gmail.serveRemote(url, { data: png(2, 2) });
    }
    const id = gmail.deliver({
      content: {
        html: urls.map((url) => `<img src="${url}" alt="Photo">`).join(''),
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const a = await open(inbox, id);
    const b = await open(inbox, id);
    let releaseA = a.release;
    try {
      gmail.pauseRemote();
      const first = inbox.loadRemoteImages(id, urls.slice(0, 1), {
        network: true,
        reader: a.reader,
      });
      const second = inbox.loadRemoteImages(id, urls.slice(1), {
        network: true,
        reader: b.reader,
      });
      await waitForFetches(gmail.remoteInFlight, 2);
      expect(gmail.remoteInFlight()).toBe(2);
      releaseA();
      releaseA = () => undefined;
      await Promise.all([first, second]);
      expect(gmail.remoteInFlight()).toBe(0);
      expect(gmail.remoteCommits).toStrictEqual([]);
      gmail.resumeRemote();
      await inbox.loadRemoteImages(id, urls.slice(1), {
        network: true,
        reader: b.reader,
      });
      expect(b.shown().document).toContain('data:image/png');
      expect(gmail.remoteFetches).toStrictEqual([...urls, urls[1]]);
    } finally {
      releaseA();
      b.release();
      gmail.resumeRemote();
    }
  });

  it('runs six requests per message and twelve across the account', async () => {
    expect.hasAssertions();
    const shared = createBodyLoads();
    const first = createSyntheticGmail();
    const second = createSyntheticGmail({ address: 'sam@example.invalid' });
    const images = (prefix: string) =>
      Array.from(
        { length: 10 },
        (_, index) => `https://images.example/${prefix}/${index}.png`,
      );
    const deliver = (gmail: typeof first, prefix: string) => {
      for (const url of images(prefix)) {
        gmail.serveRemote(url, { data: png(2, 2) });
      }
      return gmail.deliver({
        content: {
          html: images(prefix)
            .map((url) => `<img src="${url}" alt="x">`)
            .join(''),
        },
      });
    };
    const a1 = deliver(first, 'a1');
    const a2 = deliver(first, 'a2');
    const b1 = deliver(second, 'b1');
    const inboxA = createGmailInbox(first.native, { shared });
    const inboxB = createGmailInbox(second.native, { shared });
    await Promise.all([inboxA.load(), inboxB.load()]);
    await Promise.all([open(inboxA, a1), open(inboxA, a2), open(inboxB, b1)]);

    const loads: Array<Promise<void>> = [];
    try {
      first.pauseRemote();
      second.pauseRemote();
      loads.push(inboxA.loadRemoteImages(a1, images('a1'), true));
      await waitForFetches(first.remoteInFlight, 6);
      expect(first.remoteInFlight()).toBe(6);
      loads.push(
        inboxA.loadRemoteImages(a2, images('a2'), true),
        inboxB.loadRemoteImages(b1, images('b1'), true),
      );
      await waitForFetches(
        () => first.remoteInFlight() + second.remoteInFlight(),
        12,
      );
      expect(first.remoteInFlight() + second.remoteInFlight()).toBe(12);
      first.resumeRemote();
      second.resumeRemote();
      await Promise.all(loads);
      expect(first.remoteFetches).toHaveLength(20);
      expect(second.remoteFetches).toHaveLength(10);
      expect(first.mostRemoteInFlight()).toBeLessThanOrEqual(12);
    } finally {
      inboxA.forget();
      inboxB.forget();
      first.resumeRemote();
      second.resumeRemote();
      await Promise.allSettled(loads);
    }
  });

  it('retires active and queued requests on Never and last-reader close, including immediate reopening', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const urls = Array.from(
      { length: 10 },
      (_, index) => `https://images.example/cancel/${index}.png`,
    );
    for (const url of urls) {
      gmail.serveRemote(url, { data: png(2, 2) });
    }
    const id = gmail.deliver({
      content: {
        html: urls.map((url) => `<img src="${url}" alt="Photo">`).join(''),
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const first = await open(inbox, id);
    const loads: Array<Promise<void>> = [];
    try {
      gmail.pauseRemote();
      const pending = inbox.loadRemoteImages(id, urls, true);
      loads.push(pending);
      await waitForFetches(gmail.remoteInFlight, 6);
      expect(gmail.remoteInFlight()).toBe(6);
      inbox.forgetRemoteImages(id);
      await pending;
      expect(gmail.remoteFetches).toHaveLength(6);
      expect(first.shown().document).not.toContain('data:image/png');
      expect(gmail.remoteCommits).toStrictEqual([]);

      const reopened = inbox.loadRemoteImages(id, urls, true);
      loads.push(reopened);
      await waitForFetches(gmail.remoteInFlight, 6);
      first.release();
      const second = await open(inbox, id);
      const replacement = inbox.loadRemoteImages(id, urls, true);
      loads.push(replacement);
      await waitForFetches(gmail.remoteInFlight, 6);
      expect(gmail.remoteInFlight()).toBe(6);
      expect(gmail.mostRemoteInFlight()).toBe(6);
      second.release();
      await Promise.all([reopened, replacement]);
      expect(gmail.remoteCommits).toStrictEqual([]);
    } finally {
      inbox.forget();
      gmail.resumeRemote();
      await Promise.allSettled(loads);
    }
  });

  it('rechecks the viewport and preserves loaded content and limits across Ask and Never', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const shared = createBodyLoads();
    const urls = Array.from(
      { length: 11 },
      (_, index) => `https://images.example/viewport/${index}.png`,
    );
    for (const url of urls) {
      gmail.serveRemote(url, { data: png(2, 2) });
    }
    const id = gmail.deliver({
      content: {
        html: urls.map((url) => `<img src="${url}" alt="Photo">`).join(''),
      },
    });
    const fetch = vi.spyOn(gmail.native, 'fetchRemoteContent');
    const cancel = vi.spyOn(gmail.native, 'cancelRemoteContent');
    const inbox = createGmailInbox(gmail.native, { shared });
    await inbox.load();
    const reader = await open(inbox, id);
    try {
      await inbox.loadRemoteImages(id, urls.slice(0, 1), true);
      gmail.pauseRemote();
      const scrolling = inbox.loadRemoteImages(id, urls.slice(1), true);
      await waitForFetches(gmail.remoteInFlight, 6);
      await inbox.loadRemoteImages(id, [], true);
      gmail.resumeRemote();
      await scrolling;
      // Work queued behind the six active transfers is no longer near the viewport.
      expect(gmail.remoteFetches).toHaveLength(7);
      expect(gmail.remoteCommits).toHaveLength(1);

      gmail.pauseRemote();
      const loading = inbox.loadRemoteImages(id, urls.slice(1), true);
      await waitForFetches(gmail.remoteInFlight, 6);
      await inbox.loadRemoteImages(id, [], false);
      await loading;
      expect(gmail.remoteFetches).toHaveLength(13);
      expect(reader.shown().document).toContain('data:image/png');
      expect([...shared.remoteImages.values()][0]?.size).toBe(1);
      // Revocation retains one native budget, and every dispatch has its own identity.
      expect(
        new Set(fetch.mock.calls.map((call) => call[2].session)).size,
      ).toBe(1);
      expect(
        new Set(fetch.mock.calls.map((call) => call[2].request)).size,
      ).toBe(13);
      expect(cancel.mock.calls.every((call) => !call[2])).toBe(true);

      inbox.forgetRemoteImages(id);
      expect(reader.shown().document).not.toContain('data:image/png');
      await inbox.loadRemoteImages(id, urls, true);
      // The twenty-source limit is already spent and policy changes do not replenish it.
      expect(gmail.remoteFetches).toHaveLength(13);
    } finally {
      reader.release();
      gmail.resumeRemote();
    }
    expect(cancel.mock.calls.at(-1)?.[2]).toBe(true);
  });

  it('combines independent readers without allowing an offscreen or unconsented window to revoke another', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const urls = Array.from(
      { length: 10 },
      (_, index) => `https://images.example/windows/${index}.png`,
    );
    for (const url of urls) {
      gmail.serveRemote(url, { data: png(2, 2) });
    }
    const id = gmail.deliver({
      content: {
        html: urls.map((url) => `<img src="${url}" alt="Photo">`).join(''),
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const a = await open(inbox, id);
    const b = await open(inbox, id);
    const loads: Array<Promise<void>> = [];
    try {
      gmail.pauseRemote();
      const loading = inbox.loadRemoteImages(id, urls, {
        network: true,
        reader: a.reader,
      });
      loads.push(loading);
      await waitForFetches(gmail.remoteInFlight, 6);
      await inbox.loadRemoteImages(id, [], {
        network: false,
        reader: b.reader,
      });
      expect(gmail.remoteInFlight()).toBe(6);
      await inbox.loadRemoteImages(id, urls, {
        network: false,
        reader: b.reader,
      });
      expect(gmail.remoteInFlight()).toBe(6);
      a.release();
      await loading;
      // The surviving unconsented reader may read the cache, but queued fetches cannot start.
      await inbox.loadRemoteImages(id, urls, {
        network: false,
        reader: b.reader,
      });
      expect(gmail.remoteFetches).toHaveLength(6);
      expect(gmail.remoteCommits).toStrictEqual([]);
      expect(b.shown().document).not.toContain('data:image/png');
      b.release();
    } finally {
      inbox.forget();
      gmail.resumeRemote();
      await Promise.allSettled(loads);
    }
  });

  it('bounds attempted sources and shares retained pixels and cache protection across connections', async () => {
    expect.hasAssertions();
    const shared = createBodyLoads();
    const first = createSyntheticGmail();
    const second = createSyntheticGmail({ address: 'sam@example.invalid' });
    const photo = 'https://images.example/large.png';
    const large = png(4096, 4096);
    first.serveRemote(photo, { data: large });
    const firstId = first.deliver({
      content: { html: `<img src="${photo}" alt="Photo">` },
    });
    const inboxA = createGmailInbox(first.native, {
      shared,
      connection: 'connection-a',
    });
    const inboxB = createGmailInbox(second.native, {
      shared,
      connection: 'connection-b',
    });
    const urls = Array.from(
      { length: 30 },
      (_, index) => `https://images.example/bounded/${index}.png`,
    );
    for (const url of urls) {
      second.serveRemote(url, { data: large });
    }
    const secondId = second.deliver({
      content: {
        html: urls.map((url) => `<img src="${url}" alt="Photo">`).join(''),
      },
    });
    await Promise.all([inboxA.load(), inboxB.load()]);
    const a = await open(inboxA, firstId);
    const b = await open(inboxB, secondId);
    try {
      await inboxA.loadRemoteImages(firstId, [photo], true);
      await inboxB.loadRemoteImages(secondId, urls, true);
      expect(second.remoteFetches).toHaveLength(20);
      // Two 16-Mi-pixel images fill the retained budget, even though many sources are valid.
      expect(second.remoteCommits).toHaveLength(1);
      expect(second.remoteCommits[0]).toContainEqual([
        'connection-a',
        firstId,
        photo,
      ]);
      expect(b.shown().remote.pending).toHaveLength(29);
      inboxA.forget();
      expect(shared.remoteImages.size).toBe(1);
      // A released connection's image is no longer charged to the shared retained budget.
      b.release();
      const reopened = await open(inboxB, secondId);
      await inboxB.loadRemoteImages(secondId, urls.slice(20, 22), true);
      reopened.release();
      expect(second.remoteCommits).toHaveLength(3);
      expect(second.remoteCommits.at(-1)).not.toContainEqual([
        'connection-a',
        firstId,
        photo,
      ]);
    } finally {
      a.release();
      b.release();
    }
  });

  it('keeps remote content hidden until the saved policy is read, and asks after a failed read', async () => {
    expect.hasAssertions();
    let read: (reply: unknown) => void = () => undefined;
    const settings = createRemoteContentSettings({
      remoteContentSettings: () =>
        // oxlint-disable-next-line promise/avoid-new -- The saved policy arrives when the test releases it.
        new Promise((resolve) => {
          read = resolve;
        }),
      setRemoteContentSettings: () => Promise.resolve(null),
      clearRemoteContent: () => Promise.resolve(null),
    });
    const loading = settings.load();
    // A cold launch has not read the saved Never yet; nothing is restored or offered meanwhile.
    expect(remoteContentPolicy(settings.getSnapshot(), 'connection-a')).toBe(
      'never',
    );
    read({ settings: '{"policy":"never","overrides":{}}' });
    await loading;
    expect(remoteContentPolicy(settings.getSnapshot(), 'connection-a')).toBe(
      'never',
    );

    const failing = createRemoteContentSettings({
      remoteContentSettings: () =>
        Promise.reject(
          Object.assign(new Error('Synthetic failure'), {
            code: 'unavailable',
          }),
        ),
      setRemoteContentSettings: () => Promise.resolve(null),
      clearRemoteContent: () => Promise.resolve(null),
    });
    await failing.load();
    expect(remoteContentPolicy(failing.getSnapshot(), 'connection-a')).toBe(
      'ask',
    );
  });

  it('keeps device-local policies, per-connection overrides and Clear Remote Content', async () => {
    expect.hasAssertions();
    const saved: string[] = [];
    let stored: string | null = null;
    let clearing: Promise<unknown> = Promise.resolve(null);
    const settings = createRemoteContentSettings({
      remoteContentSettings: () => Promise.resolve({ settings: stored }),
      setRemoteContentSettings: (text) => {
        saved.push(text);
        return Promise.resolve(null);
      },
      clearRemoteContent: () => clearing,
    });
    // Missing and unreadable settings ask, which loads nothing without consent.
    await settings.load();
    expect(settings.getSnapshot()).toStrictEqual({
      policy: 'ask',
      overrides: {},
    });
    stored = '{"policy":"sometimes","overrides":{}}';
    await settings.load();
    expect(settings.getSnapshot()?.policy).toBe('ask');

    await settings.setPolicy('always');
    await settings.setOverride('connection-a', 'never');
    expect(remoteContentPolicy(settings.getSnapshot(), 'connection-a')).toBe(
      'never',
    );
    expect(remoteContentPolicy(settings.getSnapshot(), 'connection-b')).toBe(
      'always',
    );
    await settings.setOverride('connection-a');
    expect(remoteContentPolicy(settings.getSnapshot(), 'connection-a')).toBe(
      'always',
    );
    expect(saved.at(-1)).toBe('{"policy":"always","overrides":{}}');

    // Stored settings are restored by a fresh store.
    stored = '{"policy":"never","overrides":{"connection-b":"always"}}';
    const restored = createRemoteContentSettings({
      remoteContentSettings: () => Promise.resolve({ settings: stored }),
      setRemoteContentSettings: () => Promise.resolve(null),
      clearRemoteContent: () => clearing,
    });
    await restored.load();
    expect(remoteContentPolicy(restored.getSnapshot(), 'connection-b')).toBe(
      'always',
    );
    expect(remoteContentPolicy(restored.getSnapshot(), 'connection-c')).toBe(
      'never',
    );

    await expect(settings.clear()).resolves.toBe(true);
    clearing = Promise.reject(
      Object.assign(new Error('Synthetic failure'), { code: 'locked' }),
    );
    await expect(settings.clear()).resolves.toBe(false);
  });

  it('publishes durable policy transitions and keeps concurrent choices after a rejected save', async () => {
    expect.hasAssertions();
    const held = Promise.withResolvers<undefined>();
    let stored = '{"policy":"always","overrides":{}}';
    const write = vi
      .fn<(text: string) => Promise<void>>(async (text) => {
        stored = text;
      })
      .mockImplementationOnce(async () => {
        await held.promise;
        throw Object.assign(new Error('Synthetic failure'), { code: 'locked' });
      });
    const settings = createRemoteContentSettings({
      remoteContentSettings: () => Promise.resolve({ settings: stored }),
      setRemoteContentSettings: write,
      clearRemoteContent: () => Promise.resolve({}),
    });
    await settings.load();
    const previous = settings.getSnapshot();
    const never = settings.setPolicy('never');
    const override = settings.setOverride('connection-a', 'ask');
    const ask = settings.setPolicy('ask');
    try {
      await vi.waitFor(() => {
        expect(write).toHaveBeenCalledWith('{"policy":"never","overrides":{}}');
      });
      expect(settings.getSnapshot()).toBe(previous);
    } finally {
      held.resolve(undefined);
      await Promise.all([never, override, ask]);
    }
    expect(write.mock.calls.map(([text]) => text)).toStrictEqual([
      '{"policy":"never","overrides":{}}',
      '{"policy":"always","overrides":{"connection-a":"ask"}}',
      '{"policy":"ask","overrides":{"connection-a":"ask"}}',
    ]);
    expect(settings.getSnapshot()).toStrictEqual({
      policy: 'ask',
      overrides: { 'connection-a': 'ask' },
    });
    await settings.load();
    expect(settings.getSnapshot()).toStrictEqual({
      policy: 'ask',
      overrides: { 'connection-a': 'ask' },
    });
  });
});
