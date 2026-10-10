import { deflateSync } from 'node:zlib';

import type { GmailInbox, MessageBodyState } from '../src/gmail-inbox.ts';

import { createBodyLoads, createGmailInbox } from '../src/gmail-inbox.ts';
import {
  createRemoteContentSettings,
  remoteContentPolicy,
} from '../src/remote-content.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';

const ascii = (text: string) => [...Buffer.from(text, 'latin1')];
const u32 = (value: number) => {
  const bytes = Buffer.alloc(4);
  bytes.writeUInt32BE(value);
  return [...bytes];
};
/* oxlint-disable no-bitwise -- PNG fixtures require their binary CRC. */
const crc32 = (bytes: readonly number[]) => {
  let crc = 4_294_967_295;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ ((crc & 1) === 0 ? 0 : 3_988_292_384);
    }
  }
  return (crc ^ 4_294_967_295) >>> 0;
};
/* oxlint-enable no-bitwise */
const chunk = (type: string, data: readonly number[]) => {
  const content = [...ascii(type), ...data];
  return [...u32(data.length), ...content, ...u32(crc32(content))];
};
const png = (width: number, height: number) =>
  Buffer.from([
    ...ascii('\u0089PNG\r\n\u001A\n'),
    ...chunk('IHDR', [...u32(width), ...u32(height), 8, 6, 0, 0, 0]),
    ...chunk('IDAT', [...deflateSync(Buffer.alloc((width * 4 + 1) * height))]),
    ...chunk('IEND', []),
  ]).toString('base64');

const remote = (state: MessageBodyState | undefined) => {
  if (state?.kind !== 'ready' || state.presentation.rich === undefined) {
    throw new Error(`Expected a rich body, received ${state?.kind}`);
  }
  return state.presentation.rich;
};

// Opens a message in one reader, as the reader view does.
const open = async (inbox: GmailInbox, id: string) => {
  const reader = Symbol('reader');
  const release = inbox.retainMessage(id, reader);
  await inbox.readMessage(id);
  return {
    reader,
    release,
    shown: () => remote(inbox.messageBody(id, reader)),
  };
};

// Synchronize with observable paused transfers, independent of scheduler turn counts.
const waitForFetches = (active: () => number, count: number) =>
  vi.waitFor(() => {
    expect(active()).toBe(count);
  });

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
    expect(settings.getSnapshot().policy).toBe('ask');

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
