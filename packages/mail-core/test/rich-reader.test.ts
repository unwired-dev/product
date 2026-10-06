import { setImmediate } from 'node:timers/promises';
import { deflateSync } from 'node:zlib';

import type { GmailInbox, MessageBodyState } from '../src/gmail-inbox.ts';

import { createGmailInbox } from '../src/gmail-inbox.ts';
import { inspectImage } from '../src/inline-images.ts';
import { inspectLink, linkWarnings } from '../src/link-inspection.ts';
import { imageTally, singleReadablePart } from '../src/message-body.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';

const read = async (inbox: GmailInbox, id: string, reader?: symbol) => {
  await inbox.readMessage(id);
  return inbox.messageBody(id, reader);
};

const ready = (state: MessageBodyState | undefined) => {
  if (state?.kind !== 'ready') {
    throw new Error('Expected a ready body');
  }
  return state;
};

const rich = (state: MessageBodyState | undefined) => {
  if (state?.kind !== 'ready' || state.presentation.rich === undefined) {
    throw new Error(`Expected a rich body, received ${state?.kind}`);
  }
  return state.presentation.rich;
};

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
const png = (width: number, height: number) => [
  ...ascii('\u0089PNG\r\n\u001A\n'),
  ...chunk('IHDR', [...u32(width), ...u32(height), 8, 6, 0, 0, 0]),
  ...chunk('IDAT', [...deflateSync(Buffer.alloc((width * 4 + 1) * height))]),
  ...chunk('IEND', []),
];
// Two image descriptors (44) between the header and the trailer (59) make an animation.
const frame = [44, 0, 0, 0, 0, 2, 0, 2, 0, 0, 2, 2, 68, 1, 0];
const animatedGif = [
  ...ascii('GIF89a'),
  2,
  0,
  2,
  0,
  0,
  0,
  0,
  ...frame,
  ...frame,
  59,
];

// The listed message IDs, or none before the Inbox is ready.
const listedIds = (inbox: GmailInbox) => {
  const state = inbox.getSnapshot();
  return state.kind === 'ready' ? state.messages.map(({ id }) => id) : [];
};

const readable = (state: MessageBodyState | undefined) => {
  if (state?.kind !== 'ready') {
    throw new Error(`Expected a ready body, received ${state?.kind}`);
  }
  return state.presentation.readable;
};

// Holds one already-completed provider reply so another store can commit before it is applied.
const holdNextHistory = (
  gmail: ReturnType<typeof createSyntheticGmail>,
  replacement?: { readonly status: number; readonly body: string },
) => {
  const captured = Promise.withResolvers<undefined>();
  const release = Promise.withResolvers<undefined>();
  const request = gmail.native.gmailRequest;
  let waiting = true;
  gmail.native.gmailRequest = async (path, query, scope) => {
    const reply = await request(path, query, scope);
    if (path === 'history' && waiting) {
      waiting = false;
      captured.resolve(undefined);
      await release.promise;
      return replacement ?? reply;
    }
    return reply;
  };
  return {
    captured: captured.promise,
    release: () => release.resolve(undefined),
  };
};

// Wraps Gmail reads to count concurrent body loads, and refuses the prefetch preflight once
// `refuse` is set, as Gmail does after a revoked grant.
function observeBodyLoads(gmail: ReturnType<typeof createSyntheticGmail>) {
  const { gmailRequest } = gmail.native;
  const observed = { active: 0, most: 0, refuse: false };
  const bodyLoad = (query: ReadonlyArray<readonly [string, string]>) =>
    query.some(([, value]) => value === 'full' || value === 'Content-Type');
  gmail.native.gmailRequest = async (path, query, owner) => {
    if (
      observed.refuse &&
      query.some(([, value]) => value === 'Content-Type')
    ) {
      return { status: 401, body: '{}' };
    }
    if (!bodyLoad(query)) {
      return gmailRequest(path, query, owner);
    }
    observed.active += 1;
    observed.most = Math.max(observed.most, observed.active);
    await setImmediate();
    observed.active -= 1;
    return gmailRequest(path, query, owner);
  };
  return observed;
}

const day = 86_400_000;

// Holds the first prefetch preflight until released, as a slow Gmail reply would.
function holdFirstPreflight(gmail: ReturnType<typeof createSyntheticGmail>) {
  const { gmailRequest } = gmail.native;
  const reached = Promise.withResolvers<undefined>();
  const release = Promise.withResolvers<undefined>();
  let held = false;
  gmail.native.gmailRequest = async (path, query, owner) => {
    if (!held && query.some(([, value]) => value === 'Content-Type')) {
      held = true;
      reached.resolve(undefined);
      await release.promise;
    }
    return gmailRequest(path, query, owner);
  };
  return {
    reached: reached.promise,
    release: () => release.resolve(undefined),
  };
}

// Holds the listing page that resumes at `pageToken` until released.
function holdListPage(
  gmail: ReturnType<typeof createSyntheticGmail>,
  pageToken: string,
) {
  const { gmailRequest } = gmail.native;
  const reached = Promise.withResolvers<undefined>();
  const release = Promise.withResolvers<undefined>();
  gmail.native.gmailRequest = async (path, query, owner) => {
    if (
      path === 'messages' &&
      query.some(([name, value]) => name === 'pageToken' && value === pageToken)
    ) {
      reached.resolve(undefined);
      await release.promise;
    }
    return gmailRequest(path, query, owner);
  };
  return {
    reached: reached.promise,
    release: () => release.resolve(undefined),
  };
}

// Holds every Gmail request except message reads, as a provider that has not answered yet.
function holdProvider(gmail: ReturnType<typeof createSyntheticGmail>) {
  const { gmailRequest } = gmail.native;
  const provider = Promise.withResolvers<undefined>();
  gmail.native.gmailRequest = async (path, query, owner) => {
    if (!path.startsWith('messages/')) {
      await provider.promise;
    }
    return gmailRequest(path, query, owner);
  };
  return () => {
    provider.resolve(undefined);
  };
}

// Answers these messages' full-format body reads with fixed Gmail replies.
function answerBodies(
  gmail: ReturnType<typeof createSyntheticGmail>,
  replies: ReadonlyMap<string, { status: number; body: string }>,
) {
  const { gmailRequest } = gmail.native;
  gmail.native.gmailRequest = async (path, query, owner) => {
    const reply = replies.get(path.slice('messages/'.length));
    const full = query.some(
      ([name, value]) => name === 'format' && value === 'full',
    );
    return full && reply !== undefined
      ? reply
      : gmailRequest(path, query, owner);
  };
}

// Refuses Gmail's grant for full-format reads or attachment downloads while switched on.
function refuseGrant(gmail: ReturnType<typeof createSyntheticGmail>) {
  const { gmailRequest } = gmail.native;
  const refusing = { full: false, attachments: false };
  gmail.native.gmailRequest = async (path, query, owner) => {
    const full = query.some(
      ([name, value]) => name === 'format' && value === 'full',
    );
    const refused =
      (refusing.full && full) ||
      (refusing.attachments && path.includes('/attachments/'));
    return refused
      ? { status: 401, body: '{}' }
      : gmailRequest(path, query, owner);
  };
  return refusing;
}

// Answers inline-image downloads with a fixed status, 503 until a test changes it.
function answerImages(gmail: ReturnType<typeof createSyntheticGmail>) {
  const { gmailRequest } = gmail.native;
  const reply = { status: 503, body: '{}' };
  gmail.native.gmailRequest = async (path, query, owner) =>
    path.includes('/attachments/image-')
      ? { status: reply.status, body: reply.body }
      : gmailRequest(path, query, owner);
  return reply;
}

// Holds image replies while a reader closes during its authorization refresh.
function holdImages(gmail: ReturnType<typeof createSyntheticGmail>) {
  const { gmailRequest } = gmail.native;
  const reached = Promise.withResolvers<undefined>();
  const release = Promise.withResolvers<undefined>();
  gmail.native.gmailRequest = async (path, query, owner) => {
    if (path.includes('/attachments/')) {
      reached.resolve(undefined);
      await release.promise;
    }
    return gmailRequest(path, query, owner);
  };
  return {
    reached: reached.promise,
    release: () => release.resolve(undefined),
  };
}

// Answers every attachment download with the same reported size and data.
function answerAttachments(
  gmail: ReturnType<typeof createSyntheticGmail>,
  attachment: Readonly<{ size: number; data: string }>,
) {
  const { gmailRequest } = gmail.native;
  const answered: string[] = [];
  gmail.native.gmailRequest = async (path, query, owner) => {
    if (!path.includes('/attachments/')) {
      return gmailRequest(path, query, owner);
    }
    answered.push(path);
    return { status: 200, body: JSON.stringify(attachment) };
  };
  return answered;
}

// Answers one message's full-format read with a crafted MIME payload.
function replaceFullPayload(
  gmail: ReturnType<typeof createSyntheticGmail>,
  id: string,
  payload: unknown,
) {
  const { gmailRequest } = gmail.native;
  gmail.native.gmailRequest = async (path, query, owner) =>
    path === `messages/${id}` &&
    query.some(([name, value]) => name === 'format' && value === 'full')
      ? { status: 200, body: JSON.stringify({ id, payload }) }
      : gmailRequest(path, query, owner);
}

describe('the isolated rich reader', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one reader contract end to end. */
  it('admits only passive markup, app colors, vetted links and non-loading placeholders', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      content: {
        html: [
          '<html><head><base href="https://sender.invalid/"><meta http-equiv="refresh" content="0;url=https://sender.invalid">',
          '<link rel="stylesheet" href="https://sender.invalid/a.css"><style>@import url(https://sender.invalid/b.css);</style></head>',
          '<body bgcolor="#000" style="background:#000">',
          '<div style="display:none">Hidden preheader</div>',
          '<table bgcolor="#123" width="600" onload="x()"><tr><td style="color:#fff;background-image:url(https://sender.invalid/bg.png);padding:4px;font-weight:bold" align="center">Cell text</td></tr></table>',
          '<p><font color="red">Red words</font> and <a href="tel:+15551234" target="_blank">call us</a>.</p>',
          '<form action="https://sender.invalid/post"><input name="q" value="secret"><button>Send</button>Form note</form>',
          '<svg><a href="https://sender.invalid/svg"><text>SVG</text></a></svg>',
          '<img src="https://sender.invalid/photo.jpg" alt="Team photo">',
          '<img src="https://sender.invalid/open.gif" width="1" height="1">',
          '<img src="data:image/png;base64,AAAA" alt="Inline data">',
          '<img src="http://sender.invalid/plain.png">',
          '</body></html>',
        ].join(''),
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const opened = await read(inbox, id);
    const { document, links } = rich(opened);
    expect(document.slice(document.indexOf('<body>'))).not.toMatch(
      /sender\.invalid|<base|refresh|<link|@import|bgcolor|onload|#fff|background-image|<font|<form|<input|<button|secret|<svg|target=|data:image\/png;base64,AAAA|Hidden preheader/u,
    );
    expect(document).toContain(
      '<td align="center" style="padding: 4px; font-weight: bold">Cell text</td>',
    );
    expect(document).toContain('<span>Red words</span>');
    expect(document).toContain(
      '<a href="about:blank#unwired-link-0" rel="noreferrer noopener">call us</a>',
    );
    expect(document).toContain('<div>Form note</div>');
    // The remote image keeps its description as a placeholder; the declared 1×1 pixel is gone.
    expect(document).toContain(
      '<span class="blocked-image" role="img" aria-label="Team photo">Team photo</span>',
    );
    expect(document.match(/blocked-image" role="img"/gu)).toHaveLength(3);
    expect(links).toStrictEqual([{ href: 'tel:+15551234', text: 'call us' }]);
    expect(readable(opened)).toMatchObject({ hidesImages: true });
  });

  it('inspects image-only links by their description and keeps images CSS enlarges', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      content: {
        html: [
          '<p><a href="https://phish.invalid/login"><img src="https://phish.invalid/logo.png" alt="https://bank.invalid"></a></p>',
          '<img src="https://sender.invalid/banner.png" width="1" height="1" style="width:100%;height:auto" alt="Banner">',
          '<img src="https://sender.invalid/logo.png" width="1" height="1" style="width:.5em;height:+.5em" alt="Enlarged logo">',
          '<img src="https://sender.invalid/photo.png" width="100" height="100" style="max-width:+1;max-height:1e0" alt="Photo">',
        ].join(''),
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const { document, links } = rich(await read(inbox, id));
    expect(links).toStrictEqual([
      { href: 'https://phish.invalid/login', text: 'https://bank.invalid' },
    ]);
    // CSS overrides the one-pixel attributes, so this is a visible image, not a tracker.
    expect(document).toContain('aria-label="Banner"');
    expect(document).toContain('aria-label="Enlarged logo"');
    expect(document).toContain('aria-label="Photo"');
  });

  it('keeps CID tracking pixels excluded when CSS dimensions are discarded or zero', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const styles = [
      'width:;height:',
      'width:bogus;height:bogus',
      'width:var(--missing);height:var(--missing)',
      'width:url(https://sender.invalid);height:url(https://sender.invalid)',
      'width:expression(x);height:expression(x)',
      'width:calc(bogus);height:calc(bogus)',
      'width:+100;height:+100',
      'width:1e2;height:1e2',
      'width:.0em;height:+.0%',
      'width:+0px;height:auto',
      'width:+1px;height:1e0px',
    ];
    const id = gmail.deliver({
      at: Date.UTC(2020, 0, 1),
      content: {
        html: `<p>Body</p>${styles
          .map(
            (style, index) =>
              `<img src="cid:pixel-${index}" width="1" height="1" style="${style}" alt="Pixel">`,
          )
          .join('')}`,
        images: styles.map((_, index) => ({
          contentId: `pixel-${index}`,
          mimeType: 'image/png',
          bytes: png(40, 30),
        })),
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const opened = await read(inbox, id);
    expect(rich(opened).document).not.toContain('Pixel');
    expect(readable(opened)).toStrictEqual({
      paragraphs: [[{ text: 'Body' }]],
      hidesImages: false,
    });
    expect(
      gmail.requests.filter(({ path }) => path.includes('/attachments/')),
    ).toHaveLength(0);
  });

  it('keeps attachment-like parts out of the body and shows image-only remote mail', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const now = Date.now();
    const excluded = [
      '',
      ' \t',
      'attachment (unterminated',
      'x-file',
      // A repeated header counts every occurrence, never only the first.
      ['inline', 'attachment'],
      ['attachment', 'inline'],
      ['inline', ''],
      ['inline', ' \t'],
      ['inline', 'inline (unterminated'],
    ].map((disposition) =>
      gmail.deliver({
        at: now - 60_000,
        content: { text: 'Attached notes', single: true, disposition },
      }),
    );
    const allowed = [
      undefined,
      'InLiNe; filename="notes.txt"',
      ['inline', 'INLINE'],
      ['inline', '(nested (comment)) InLiNe; filename="(notes).txt"'],
    ].map((disposition) =>
      gmail.deliver({
        at: now - 60_000,
        content: { text: 'Readable notes', single: true, disposition },
      }),
    );
    const imageOnly = gmail.deliver({
      content: {
        html: '<p><img src="https://sender.invalid/poster.png" alt="" width="400"></p>',
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    // Prefetch records an exclusion marker instead of caching the attachment-like part.
    await vi.waitFor(() => {
      expect(gmail.bodyCommits).toHaveLength(excluded.length + allowed.length);
    });
    for (const id of excluded) {
      expect(JSON.parse(String(gmail.cachedBodies().get(id)))).toMatchObject({
        excluded: true,
      });
      expect(
        gmail.requests
          .filter(({ path }) => path === `messages/${id}`)
          .filter(({ query }) => query.get('format') === 'full'),
      ).toHaveLength(0);
      expect(readable(await read(inbox, id)).paragraphs).toStrictEqual([]);
    }
    for (const id of allowed) {
      expect(readable(await read(inbox, id)).paragraphs).not.toStrictEqual([]);
    }
    // The placeholder alone is visible content, with the blocked-image notice.
    const shown = await read(inbox, imageOnly);
    expect(rich(shown).document).toContain('class="blocked-image"');
    expect(readable(shown)).toMatchObject({
      paragraphs: [],
      hidesImages: true,
    });
    inbox.discardRichMessage(imageOnly, ready(shown).presentation);
    expect(
      ready(inbox.messageBody(imageOnly)).presentation.rich,
    ).toBeUndefined();
    expect(readable(inbox.messageBody(imageOnly))).toMatchObject({
      paragraphs: [],
      hidesImages: true,
    });
  });

  it('prunes bodies after a failed prune even when the next synchronization commits nothing', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const archived = gmail.deliver({ subject: 'Archived' });
    const kept = gmail.deliver({ subject: 'Kept' });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await read(inbox, archived);
    await read(inbox, kept);
    gmail.archive(archived);
    gmail.failRetain('unavailable');
    gmail.failRetain('unavailable');
    await inbox.load();
    expect(gmail.cachedBodies().has(archived)).toBe(true);
    const commits = gmail.commits.length;
    const open = gmail.native.openMailbox;
    gmail.native.openMailbox = async () => ({
      ...(await open()),
      availability: 'retry',
    });
    const relaunched = createGmailInbox(gmail.native);
    await relaunched.load();
    expect(gmail.cachedBodies().has(archived)).toBe(true);
    gmail.native.openMailbox = open;
    // A verified synchronization after relaunch commits nothing but still retries pruning.
    await relaunched.load();
    expect(gmail.commits).toHaveLength(commits);
    expect([...gmail.cachedBodies().keys()]).toStrictEqual([kept]);
  });

  it('keeps a newer listed body when another store finishes an older no-change synchronization', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const at = Date.now() - 31 * 24 * 60 * 60 * 1000;
    gmail.deliver({ at });
    const earlier = createGmailInbox(gmail.native);
    const newer = createGmailInbox(gmail.native);
    await earlier.load();
    await newer.load();
    const history = holdNextHistory(gmail);
    const loading = earlier.load();
    await history.captured;
    const added = gmail.deliver({ at, subject: 'Newer listed message' });
    await newer.load();
    await read(newer, added);
    expect(gmail.cachedBodies().has(added)).toBe(true);
    history.release();
    await loading;
    expect(gmail.cachedBodies().has(added)).toBe(true);
    expect(listedIds(earlier)).toContain(added);
  });

  it('classifies images and text by the CSS WebKit actually receives', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const logo = png(40, 30);
    const id = gmail.deliver({
      content: {
        html: [
          // Unparseable maxima are dropped, so WebKit draws the image at its own size.
          '<p><img src="cid:shown@example" style="max-width:calc(1px);max-height:calc(1px)" alt="Shown"></p>',
          // Valid one-pixel maxima reach WebKit, so this stays a tracking pixel.
          '<p><img src="cid:pixel@example" style="max-width:1px;max-height:1px"></p>',
          // Retained minima win over one-pixel attributes, so WebKit paints this one.
          '<p><img src="cid:minimum@example" width="1" height="1" style="max-width:1px;max-height:1px;min-width:100px;min-height:100px" alt="Minimum"></p>',
          // Minima alone do not shrink the image's intrinsic size to a tracking pixel.
          '<p><img src="cid:intrinsic@example" style="min-width:1px;min-height:1px" alt="Intrinsic"></p>',
          '<p><img src="cid:zero-minimum@example" style="min-width:0;min-height:0" alt="Zero minimum"></p>',
          // Relative and auto dimensions remain unknown, including minimum constraints.
          '<p><img src="cid:relative-size@example" style="width:50%;height:auto;min-width:1px;min-height:1px" alt="Relative size"></p>',
          '<p><img src="cid:relative-minimum@example" width="1" height="1" style="max-width:1px;max-height:1px;min-width:100%;min-height:100%" alt="Relative minimum"></p>',
          '<p><img src="cid:auto-minimum@example" width="1" height="1" style="min-width:auto;min-height:auto" alt="Auto minimum"></p>',
          // A known maximum still bounds unknown intrinsic sizes when minima are also known.
          '<p><img src="cid:bounded@example" style="max-width:1px;max-height:1px;min-width:0;min-height:0"></p>',
          // Clipping is discarded, so this text paints and stays readable and inspectable.
          '<div style="width:0;height:0;overflow:hidden;white-space:nowrap">Read <a href="https://phish.invalid/">https://bank.invalid</a></div>',
        ].join(''),
        images: [
          { contentId: 'shown@example', mimeType: 'image/png', bytes: logo },
          { contentId: 'pixel@example', mimeType: 'image/png', bytes: logo },
          { contentId: 'minimum@example', mimeType: 'image/png', bytes: logo },
          {
            contentId: 'intrinsic@example',
            mimeType: 'image/png',
            bytes: logo,
          },
          {
            contentId: 'zero-minimum@example',
            mimeType: 'image/png',
            bytes: logo,
          },
          {
            contentId: 'relative-size@example',
            mimeType: 'image/png',
            bytes: logo,
          },
          {
            contentId: 'relative-minimum@example',
            mimeType: 'image/png',
            bytes: logo,
          },
          {
            contentId: 'auto-minimum@example',
            mimeType: 'image/png',
            bytes: logo,
          },
          { contentId: 'bounded@example', mimeType: 'image/png', bytes: logo },
        ],
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const opened = await read(inbox, id);
    const { document, links } = rich(opened);
    expect(document).not.toContain('calc(');
    expect(document).toContain('src="data:image/png;base64,');
    expect(
      gmail.requests
        .map(({ path }) => path)
        .filter((path) => path.includes('/attachments/image-')),
    ).toStrictEqual([
      `messages/${id}/attachments/image-0`,
      `messages/${id}/attachments/image-2`,
      `messages/${id}/attachments/image-3`,
      `messages/${id}/attachments/image-4`,
      `messages/${id}/attachments/image-5`,
      `messages/${id}/attachments/image-6`,
      `messages/${id}/attachments/image-7`,
    ]);
    expect(links).toStrictEqual([
      { href: 'https://phish.invalid/', text: 'https://bank.invalid' },
    ]);
    expect(
      readable(opened)
        .paragraphs.flat()
        .map(({ text }) => text)
        .join(''),
    ).toContain('https://bank.invalid');
  });

  it('never resolves images from a discarded alternative, whatever its container', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const logo = png(40, 30);
    const ids = ['mixed', 'signed', 'leaf', 'selected', 'outer'];
    const id = gmail.deliver({
      content: {
        images: ids.map((contentId) => ({
          contentId,
          mimeType: 'image/png',
          bytes: logo,
        })),
      },
    });
    const html = [
      '<p>Chosen</p>',
      ...ids.map(
        (contentId) => `<img src="cid:${contentId}" alt="${contentId}">`,
      ),
    ].join('');
    const image = (index: number) => ({
      mimeType: 'image/png',
      headers: [
        { name: 'Content-ID', value: `<${ids[index]}>` },
        { name: 'Content-Disposition', value: 'inline' },
      ],
      body: { size: logo.length, attachmentId: `image-${index}` },
    });
    replaceFullPayload(gmail, id, {
      mimeType: 'multipart/mixed',
      parts: [
        {
          mimeType: 'multipart/alternative',
          parts: [
            {
              mimeType: 'multipart/related',
              parts: [
                {
                  mimeType: 'text/html',
                  body: {
                    size: Buffer.byteLength(html),
                    data: Buffer.from(html).toString('base64url'),
                  },
                },
                image(3),
              ],
            },
            { mimeType: 'multipart/mixed', parts: [image(0)] },
            { mimeType: 'multipart/signed', parts: [image(1)] },
            image(2),
          ],
        },
        image(4),
      ],
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const { document } = rich(await read(inbox, id));
    expect(document).toContain('aria-label="mixed"');
    expect(document).toContain('aria-label="signed"');
    expect(document).toContain('aria-label="leaf"');
    expect(document.match(/src="data:image\/png/gu)).toHaveLength(2);
    expect(
      gmail.requests
        .map(({ path }) => path)
        .filter((path) => path.includes('/attachments/')),
    ).toStrictEqual([
      `messages/${id}/attachments/image-3`,
      `messages/${id}/attachments/image-4`,
    ]);
  });

  it('reads only the first part of signed and report containers', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const logo = png(40, 30);
    const ids = ['body', 'signature'];
    const signed = gmail.deliver({
      content: {
        images: ids.map((contentId) => ({
          contentId,
          mimeType: 'image/png',
          bytes: logo,
        })),
      },
    });
    const report = gmail.deliver({ content: { text: 'Report' } });
    const leaf = (mimeType: string, content: string) => ({
      mimeType,
      body: {
        size: Buffer.byteLength(content),
        data: Buffer.from(content).toString('base64url'),
      },
    });
    const image = (index: number) => ({
      mimeType: 'image/png',
      headers: [
        { name: 'Content-ID', value: `<${ids[index]}>` },
        { name: 'Content-Disposition', value: 'inline' },
      ],
      body: { size: logo.length, attachmentId: `image-${index}` },
    });
    replaceFullPayload(gmail, signed, {
      mimeType: 'multipart/mixed',
      parts: [
        {
          mimeType: 'multipart/signed',
          parts: [
            {
              mimeType: 'multipart/related',
              parts: [
                leaf(
                  'text/html',
                  '<p>Signed</p><img src="cid:body" alt="body"><img src="cid:signature" alt="signature">',
                ),
                image(0),
              ],
            },
            image(1),
          ],
        },
      ],
    });
    replaceFullPayload(gmail, report, {
      mimeType: 'multipart/report',
      parts: [
        {
          mimeType: 'multipart/mixed',
          parts: [leaf('text/plain', 'Delivery failed')],
        },
        leaf('text/html', '<p>Report payload</p>'),
      ],
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const { document } = rich(await read(inbox, signed));
    expect(document).toContain('aria-label="signature"');
    expect(document.match(/src="data:image\/png/gu)).toHaveLength(1);
    expect(
      gmail.requests
        .map(({ path }) => path)
        .filter((path) => path.includes('/attachments/')),
    ).toStrictEqual([`messages/${signed}/attachments/image-0`]);
    const opened = ready(await read(inbox, report));
    expect(opened.presentation.rich).toBeUndefined();
    expect(readable(opened).paragraphs).toStrictEqual([
      [{ text: 'Delivery failed' }],
    ]);
  });

  it('keeps link labels with invalid offsets readable and inspectable', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const styles = [
      'margin-left:-10000garbage;text-indent:-9999nonsense',
      'margin:-10000px inherit',
      'margin:initial -10000px',
      'margin:-10000px 0 0 0 0',
      'margin-left:-10000px 0',
      'text-indent:-10000px auto',
      'text-indent:auto',
      'font-size:0garbage;line-height:0nonsense',
      'font-size:0px initial;line-height:0px initial',
      'text-indent:-10000px hanging each-line',
    ];
    const id = gmail.deliver({
      content: {
        html: [
          ...styles.map(
            (style, index) =>
              `<p><a href="https://phish.invalid/${index}"><span style="${style}">https://bank.invalid/${index}</span></a></p>`,
          ),
          '<p style="margin:1px auto;text-indent:1em">Control</p><p style="margin:inherit">Keyword control</p>',
        ].join(''),
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const opened = await read(inbox, id);
    const { document, links } = rich(opened);
    // Invalid or unsupported offsets are not painted and cannot suppress inspected labels.
    expect(document).not.toMatch(
      /style="[^"]*(?:-10000|-9999|text-indent: auto)/u,
    );
    expect(document).toContain('style="margin: 1px auto; text-indent: 1em"');
    expect(document).toContain('style="margin: inherit"');
    expect(links).toStrictEqual(
      styles.map((_, index) => ({
        href: `https://phish.invalid/${index}`,
        text: `https://bank.invalid/${index}`,
      })),
    );
    expect(
      readable(opened)
        .paragraphs.flat()
        .map(({ text }) => text)
        .join(''),
    ).toContain('https://bank.invalid/1');
  });

  it('resolves visible inline images within bounds and keeps them for provider-free opens', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const logo = png(40, 30);
    const id = gmail.deliver({
      content: {
        text: 'Logo alternative.',
        html: [
          '<p>Logo <img src="cid:logo%40example" alt="Logo"></p>',
          '<p><img src="cid:anim@example" alt="Animation"></p>',
          '<img src="cid:big@example" alt="Big"><img src="cid:short@example" alt="Short">',
          '<div hidden><img src="cid:hidden@example"></div>',
        ].join(''),
        images: [
          { contentId: 'logo@example', mimeType: 'image/png', bytes: logo },
          {
            contentId: 'anim@example',
            mimeType: 'image/gif',
            bytes: animatedGif,
          },
          {
            contentId: 'big@example',
            mimeType: 'image/png',
            bytes: logo,
            size: 6 * 1024 * 1024,
          },
          {
            contentId: 'short@example',
            mimeType: 'image/png',
            bytes: logo.slice(0, 20),
            size: logo.length,
          },
          { contentId: 'hidden@example', mimeType: 'image/png', bytes: logo },
          { contentId: 'unused@example', mimeType: 'image/png', bytes: logo },
        ],
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const { document } = rich(await read(inbox, id));
    expect(document.match(/src="data:image\/png;base64,/gu)).toHaveLength(1);
    expect(document).toContain('aria-label="Animation"');
    expect(document).toContain('aria-label="Big"');
    expect(document).toContain('aria-label="Short"');
    // Oversized, hidden and unreferenced parts were never requested.
    const imageRequests = () =>
      gmail.requests
        .map(({ path }) => path)
        .filter((path) => path.includes('/attachments/image-'));
    expect(imageRequests()).toStrictEqual([
      `messages/${id}/attachments/image-0`,
      `messages/${id}/attachments/image-1`,
      `messages/${id}/attachments/image-3`,
    ]);

    // A relaunch without Gmail shows the admitted image from the encrypted cache.
    const relaunched = createGmailInbox(gmail.native);
    gmail.fail({ code: 'unavailable' });
    await relaunched.load();
    expect(rich(await read(relaunched, id)).document).toBe(document);
    expect(imageRequests()).toHaveLength(3);

    // A body cached before its images were resolved resolves them on the next online open.
    await gmail.native.commitMessageBody(
      { address: 'alex@example.invalid', generation: '0' },
      id,
      {
        document: JSON.stringify({
          version: 2,
          id,
          html: '<p><img src="cid:logo@example" alt="Logo"></p>',
        }),
        tier: 'opened',
        protectedIds: [],
      },
    );
    const online = createGmailInbox(gmail.native);
    await online.load();
    expect(rich(await read(online, id)).document).toContain(
      'src="data:image/png;base64,',
    );
    expect(JSON.parse(String(gmail.cachedBodies().get(id)))).toMatchObject({
      images: { refused: [] },
    });
  });

  it.each(['MIME', 'image'] as const)(
    'asks for Gmail again when completing cached images rejects %s authorization',
    async (resource) => {
      expect.hasAssertions();
      const gmail = createSyntheticGmail();
      const id = gmail.deliver({
        at: Date.UTC(2020, 0, 1),
        content: {
          html: '<p>Cached mail</p><img src="cid:logo" alt="Logo">',
          images: [
            { contentId: 'logo', mimeType: 'image/png', bytes: png(40, 30) },
          ],
        },
      });
      const request = gmail.native.gmailRequest;
      const imageReply = answerImages(gmail);
      const first = createGmailInbox(gmail.native);
      await first.load();
      expect(rich(await read(first, id)).document).toContain('Cached mail');
      const cached = gmail.cachedBodies().get(id);
      expect(JSON.parse(String(cached)).images).toBeUndefined();

      const reopened = createGmailInbox(gmail.native);
      await reopened.load();
      imageReply.status = 401;
      const refuse = {
        MIME: () => {
          answerBodies(gmail, new Map([[id, { status: 401, body: '{}' }]]));
        },
        image: () => undefined,
      };
      refuse[resource]();
      // The cached text stays readable while the Inbox asks for Gmail.
      expect(rich(await read(reopened, id)).document).toContain('Cached mail');
      expect(reopened.getSnapshot()).toMatchObject({
        kind: 'ready',
        sync: 'authentication',
      });
      expect(gmail.cachedBodies().get(id)).toBe(cached);

      gmail.native.gmailRequest = request;
      await reopened.load();
      await vi.waitFor(() => {
        expect(rich(reopened.messageBody(id)).document).toContain(
          'data:image/png;base64,',
        );
      });
      expect(reopened.getSnapshot()).toMatchObject({ sync: 'current' });
    },
  );

  it('reserves declared bytes for rejected image downloads', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const imageBytes = 5 * 1024 * 1024;
    const contentIds = Array.from(
      { length: 5 },
      (_, index) => `invalid-${index}`,
    );
    const html = `<p>Readable mail</p>${contentIds
      .map((contentId) => `<img src="cid:${contentId}" alt="Invalid">`)
      .join('')}`;
    const id = gmail.deliver({
      at: Date.UTC(2020, 0, 1),
      content: { html },
    });
    // Each image declares 5 MiB, but its downloaded data decodes to fewer bytes.
    // Rejection for that size mismatch must still consume the declared request budget.
    replaceFullPayload(gmail, id, {
      mimeType: 'multipart/related',
      parts: [
        {
          mimeType: 'text/html',
          body: {
            size: Buffer.byteLength(html),
            data: Buffer.from(html).toString('base64url'),
          },
        },
        ...contentIds.map((contentId, index) => ({
          mimeType: 'image/png',
          headers: [
            { name: 'Content-ID', value: `<${contentId}>` },
            { name: 'Content-Disposition', value: 'inline' },
          ],
          body: { size: imageBytes, attachmentId: `image-${index}` },
        })),
      ],
    });
    const downloaded = answerAttachments(gmail, {
      size: imageBytes,
      data: 'AAAA',
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const opened = await read(inbox, id);
    expect(rich(opened).document).not.toContain('data:image');
    expect(readable(opened).paragraphs.flat()).toContainEqual({
      text: 'Readable mail',
    });
    expect(downloaded).toHaveLength(4);
    const saved = JSON.parse(String(gmail.cachedBodies().get(id)));
    expect(saved.images).toStrictEqual({
      admitted: [],
      refused: contentIds,
    });
  });

  it.each(
    (['MIME', 'image'] as const).flatMap((resource) =>
      [
        { status: 503, body: '{}' },
        {
          status: 403,
          body: '{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}',
        },
      ].map((reply) => ({ resource, reply })),
    ),
  )(
    'keeps image failures retryable without reauthorization: %j',
    async ({ resource, reply }) => {
      expect.hasAssertions();
      const gmail = createSyntheticGmail();
      const id = gmail.deliver({
        at: Date.UTC(2020, 0, 1),
        content: {
          html: '<p>Cached text</p><img src="cid:photo" alt="Photo">',
          images: [
            { contentId: 'photo', mimeType: 'image/png', bytes: png(4, 4) },
          ],
        },
      });
      const imageReply = answerImages(gmail);
      Object.assign(imageReply, reply);
      const first = createGmailInbox(gmail.native);
      await first.load();
      expect(rich(await read(first, id)).document).toContain('Cached text');
      expect(first.getSnapshot()).toMatchObject({ sync: 'current' });
      const cached = gmail.cachedBodies().get(id);

      const reopened = createGmailInbox(gmail.native);
      await reopened.load();
      const setup = {
        MIME: () => answerBodies(gmail, new Map([[id, reply]])),
        image: () => undefined,
      };
      setup[resource]();
      expect(rich(await read(reopened, id)).document).toContain('Cached text');
      expect(reopened.getSnapshot()).toMatchObject({ sync: 'current' });
      expect(gmail.cachedBodies().get(id)).toBe(cached);
    },
  );

  it.each([undefined, Symbol('window')])(
    'does not restore a closed reader or its image reservation after authorization refresh: %s',
    async (reader) => {
      expect.hasAssertions();
      const gmail = createSyntheticGmail();
      const content = {
        html: '<p>Shown text</p><img src="cid:photo" alt="Photo">',
        images: [
          { contentId: 'photo', mimeType: 'image/png', bytes: png(4096, 4096) },
        ],
      };
      const closed = gmail.deliver({ content });
      const second = gmail.deliver({ content });
      const third = gmail.deliver({ content });
      const refusing = refuseGrant(gmail);
      const inbox = createGmailInbox(gmail.native);
      await inbox.load();
      const close = inbox.retainMessage(closed, reader);
      refusing.attachments = true;
      expect(rich(await read(inbox, closed, reader)).document).toContain(
        'Shown text',
      );
      expect(inbox.getSnapshot()).toMatchObject({ sync: 'authentication' });

      refusing.attachments = false;
      const held = holdImages(gmail);
      await inbox.load();
      await held.reached;
      const refresh = inbox.readMessage(closed);
      expect(rich(inbox.messageBody(closed, reader)).document).toContain(
        'Shown text',
      );
      close();
      held.release();
      await refresh;
      expect(inbox.messageBody(closed)).toBeUndefined();
      expect(inbox.messageBody(closed, reader)).toBeUndefined();

      // Closing during refresh returns its budget: two other 16 Mi-pixel images fit.
      const closeSecond = inbox.retainMessage(second);
      const closeThird = inbox.retainMessage(third);
      expect(rich(await read(inbox, second)).document).toContain(
        'data:image/png',
      );
      expect(rich(await read(inbox, third)).document).toContain(
        'data:image/png',
      );
      closeSecond();
      closeThird();
    },
  );

  it('shares one image budget across displayed bodies and returns it when a reader closes', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const ids = [1, 2, 3].map(() =>
      gmail.deliver({
        content: {
          html: '<p>Photo <img src="cid:photo@example" alt="Photo"></p>',
          images: [
            {
              contentId: 'photo@example',
              mimeType: 'image/png',
              bytes: png(4096, 4096),
            },
          ],
        },
      }),
    );
    const [first = '', second = '', third = ''] = ids;
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const releaseFirst = inbox.retainMessage(first);
    inbox.retainMessage(second);
    expect(rich(await read(inbox, first)).document).toContain('data:image/png');
    expect(rich(await read(inbox, second)).document).toContain(
      'data:image/png',
    );
    // Two 16 Mi-pixel images fill the shared 32 Mi-pixel budget.
    const releaseThird = inbox.retainMessage(third);
    expect(rich(await read(inbox, third)).document).not.toContain('data:image');
    releaseFirst();
    releaseThird();
    inbox.retainMessage(third);
    expect(rich(await read(inbox, third)).document).toContain('data:image/png');
  });

  it('charges every window showing the same message and releases a closing reader independently', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const content = {
      html: '<p>Photo <img src="cid:photo@example" alt="Photo"></p>',
      images: [
        {
          contentId: 'photo@example',
          mimeType: 'image/png',
          bytes: png(4096, 4096),
        },
      ],
    };
    const first = gmail.deliver({ content });
    const second = gmail.deliver({ content });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const firstReader = Symbol('first');
    const duplicateReader = Symbol('duplicate');
    const secondReader = Symbol('second message');
    const thirdReader = Symbol('third');
    const closeFirst = inbox.retainMessage(first, firstReader);
    const closeDuplicate = inbox.retainMessage(first, duplicateReader);
    const original = rich(await read(inbox, first, firstReader));
    expect(original.document).toContain('data:image/png');
    expect(rich(inbox.messageBody(first, duplicateReader)).document).toContain(
      'data:image/png',
    );
    const closeSecond = inbox.retainMessage(second, secondReader);
    expect(
      rich(await read(inbox, second, secondReader)).document,
    ).not.toContain('data:image');
    closeDuplicate();
    closeSecond();
    inbox.retainMessage(second, secondReader);
    expect(rich(await read(inbox, second, secondReader)).document).toContain(
      'data:image/png',
    );
    // Joining a ready body must also account for every independent WebView.
    const closeThirdReader = inbox.retainMessage(first, thirdReader);
    expect(rich(inbox.messageBody(first, thirdReader)).document).not.toContain(
      'data:image',
    );
    // An established WebView receives exactly the same source and keeps its position.
    expect(rich(inbox.messageBody(first, firstReader))).toBe(original);
    expect(rich(inbox.messageBody(second, secondReader)).document).toContain(
      'data:image/png',
    );
    closeThirdReader();
    closeFirst();
    inbox.retainMessage(first, firstReader);
    expect(rich(await read(inbox, first, firstReader)).document).toContain(
      'data:image/png',
    );
  });

  it('keeps current reservations when an earlier owner generation finishes or closes its reader', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const first = gmail.deliver({ at: Date.UTC(2020, 0, 1) });
    const second = gmail.deliver({ at: Date.UTC(2020, 0, 1) });
    const bytes = Buffer.from(png(4096, 4096)).toString('base64');
    const entered = Promise.withResolvers<undefined>();
    const delayed = Promise.withResolvers<{ document: string | null }>();
    vi.spyOn(gmail.native, 'openMessageBody')
      .mockImplementation((_scope, id) => {
        const body = {
          document: JSON.stringify({
            version: 2,
            id,
            html: '<p>Photo</p><img src="cid:photo"><img src="cid:photo">',
            images: {
              admitted: [
                {
                  contentId: 'photo',
                  mimeType: 'image/png',
                  data: bytes,
                  width: 4096,
                  height: 4096,
                },
              ],
              refused: [],
            },
          }),
        };
        return Promise.resolve(body);
      })
      .mockImplementationOnce(() => {
        entered.resolve(undefined);
        return delayed.promise;
      });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const closeOldReader = inbox.retainMessage(first);
    const oldRead = inbox.readMessage(first);
    await entered.promise;
    inbox.forget();
    await inbox.load();
    inbox.retainMessage(first);
    const current = rich(await read(inbox, first));
    expect(current.document.split('data:image/png')).toHaveLength(3);
    closeOldReader();
    // Even a valid old cache reply must not mutate the newer owner's ledger.
    delayed.resolve(
      await gmail.native.openMessageBody(
        { address: '', generation: '' },
        first,
      ),
    );
    await oldRead;
    expect(rich(inbox.messageBody(first))).toBe(current);
    inbox.retainMessage(second);
    expect(rich(await read(inbox, second)).document).not.toContain(
      'data:image',
    );
  });

  it('prefetches recent single-part bodies after the Inbox is available, and only those', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const now = Date.now();
    const recentHtml = gmail.deliver({
      at: now - 60_000,
      content: { html: '<p>Recent HTML</p>', single: true },
    });
    const recentText = gmail.deliver({
      at: now - 120_000,
      content: { text: 'Recent text', single: true },
    });
    const multipart = gmail.deliver({
      at: now - day,
      content: { text: 'Has parts', html: '<p>Has parts</p>' },
    });
    const old = gmail.deliver({
      at: now - 31 * day,
      content: { text: 'Old', single: true },
    });
    const trashed = gmail.deliver({
      at: now - 180_000,
      content: { text: 'Trashed', single: true },
    });
    gmail.label(trashed, 'TRASH');
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await vi.waitFor(() => {
      expect(gmail.bodyCommits).toHaveLength(3);
    });
    expect(listedIds(inbox)).not.toContain(trashed);
    expect(gmail.bodyCommits).toStrictEqual(
      [recentHtml, recentText, multipart].map((id) => ({
        id,
        tier: 'prefetched',
        protectedIds: [recentHtml, recentText, multipart],
      })),
    );
    // Pruning an over-budget cache keeps the same recent working set.
    expect(gmail.bodyRetains.at(-1)).toStrictEqual([
      recentHtml,
      recentText,
      multipart,
    ]);
    const requested = (id: string) =>
      gmail.requests.filter(({ path }) => path.startsWith(`messages/${id}`));
    // A multipart message gets an exclusion marker after the body-free preflight only.
    expect(
      requested(multipart).map(({ query }) => query.getAll('metadataHeaders')),
    ).toStrictEqual([
      ['From', 'Subject'],
      ['Content-Type', 'Content-Disposition'],
    ]);
    expect(
      JSON.parse(String(gmail.cachedBodies().get(multipart))),
    ).toMatchObject({
      excluded: true,
    });
    expect(
      requested(old).every(({ query }) => query.get('format') === 'metadata'),
    ).toBe(true);

    // Prefetched bodies open from the device; the excluded one downloads when opened.
    const before = gmail.requests.length;
    expect(rich(await read(inbox, recentHtml)).document).toContain(
      'Recent HTML',
    );
    expect(gmail.requests).toHaveLength(before);
    expect(rich(await read(inbox, multipart)).document).toContain('Has parts');
    expect(gmail.bodyCommits.at(-1)).toMatchObject({
      id: multipart,
      tier: 'prefetched',
    });

    // Later synchronizations neither repeat the preflight nor download stored bodies again.
    const preflights = gmail.requests.filter(({ query }) =>
      query.getAll('metadataHeaders').includes('Content-Type'),
    ).length;
    await inbox.load();
    await vi.waitFor(() => {
      expect(
        gmail.requests.filter(({ query }) =>
          query.getAll('metadataHeaders').includes('Content-Type'),
        ),
      ).toHaveLength(preflights);
    });
  });

  it('protects the recent working set when a body is opened before prefetch starts', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const now = Date.now();
    const recent = [1, 2].map((index) =>
      gmail.deliver({
        at: now - index * 60_000,
        content: { text: `Recent ${index}`, single: true },
      }),
    );
    const older = gmail.deliver({
      at: now - 40 * day,
      content: { text: 'Older', single: true },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await vi.waitFor(() => {
      expect(gmail.bodyCommits).toHaveLength(2);
    });
    // A fresh Inbox shows the cached list while Gmail has not answered yet.
    inbox.forget();
    const answer = holdProvider(gmail);
    const loading = inbox.load();
    await vi.waitFor(() => {
      expect(listedIds(inbox)).toContain(older);
    });
    expect(readable(await read(inbox, older)).paragraphs).toStrictEqual([
      [{ text: 'Older' }],
    ]);
    expect(gmail.bodyCommits.at(-1)).toStrictEqual({
      id: older,
      tier: 'opened',
      protectedIds: recent,
    });
    answer();
    await loading;
  });

  it('asks for Gmail again when an opened body is refused authorization, but not for quota', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const quota = gmail.deliver({
      at: Date.UTC(2020, 0, 2),
      content: { text: 'Quota' },
    });
    const refused = gmail.deliver({
      at: Date.UTC(2020, 0, 1),
      content: { text: 'Refused' },
    });
    answerBodies(
      gmail,
      new Map([
        [
          quota,
          {
            status: 403,
            body: JSON.stringify({
              error: { errors: [{ reason: 'userRateLimitExceeded' }] },
            }),
          },
        ],
        [refused, { status: 401, body: '{}' }],
      ]),
    );
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'current' });
    await expect(read(inbox, quota)).resolves.toMatchObject({
      kind: 'unavailable',
    });
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'current' });
    await expect(read(inbox, refused)).resolves.toStrictEqual({
      kind: 'unavailable',
      reason: 'authentication',
    });
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'authentication' });
  });

  it.each([
    { status: 200, reply: undefined },
    { status: 500, reply: { status: 500, body: '{}' } },
  ])(
    'keeps a body authorization notice through an overlapping sync ($status) and recovers on the next load',
    async ({ reply }) => {
      expect.hasAssertions();
      const gmail = createSyntheticGmail();
      const id = gmail.deliver({
        at: Date.UTC(2020, 0, 1),
        content: { text: 'Refused' },
      });
      const inbox = createGmailInbox(gmail.native);
      await inbox.load();
      const history = holdNextHistory(gmail, reply);
      const syncing = inbox.load();
      await history.captured;
      const replies = new Map([[id, { status: 401, body: '{}' }]]);
      answerBodies(gmail, replies);
      await inbox.readMessage(id);
      const refused = inbox.getSnapshot();
      expect(refused).toMatchObject({ sync: 'authentication' });
      history.release();
      await syncing;
      // Older metadata results cannot dismiss the notice or retry without renewed permission.
      expect(inbox.getSnapshot()).toStrictEqual(refused);
      expect(inbox.messageBody(id)).toStrictEqual({
        kind: 'unavailable',
        reason: 'authentication',
      });
      replies.clear();
      await inbox.load();
      await inbox.readMessage(id);
      expect(inbox.messageBody(id)).toMatchObject({ kind: 'ready' });
      expect(inbox.getSnapshot()).toStrictEqual({
        ...refused,
        sync: 'current',
      });
    },
  );

  it('keeps bodies with malformed MIME headers on demand instead of prefetching them', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const malformed = [
      'inline garbage',
      'inline; filename="unterminated',
      'inline; filename',
    ].map((disposition) =>
      gmail.deliver({
        at: Date.now() - 60_000,
        content: { text: 'On demand', single: true, disposition },
      }),
    );
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await vi.waitFor(() => {
      expect(gmail.bodyCommits).toHaveLength(malformed.length);
    });
    for (const id of malformed) {
      expect(JSON.parse(String(gmail.cachedBodies().get(id)))).toMatchObject({
        excluded: true,
      });
      expect(
        gmail.requests
          .filter(({ path }) => path === `messages/${id}`)
          .filter(({ query }) => query.get('format') === 'full'),
      ).toHaveLength(0);
      // Opening still reads the body.
      expect(readable(await read(inbox, id)).paragraphs).toStrictEqual([
        [{ text: 'On demand' }],
      ]);
    }
    const part = (contentType: string) => ({
      mimeType: 'text/html',
      headers: [{ name: 'Content-Type', value: contentType }],
      body: { size: 1, data: 'eA' },
    });
    expect(
      [
        'text/html garbage',
        'text/html; charset',
        'text/html; charset="utf-8',
        'text/html (unterminated',
        'text/html; charset="utf-8"; format=flowed',
        "text/html; charset*=UTF-8''utf-8",
        '(comment) text/html; name="a; b.html"',
        'text/html;\r\n\tcharset="utf-8"',
      ].map((contentType) => singleReadablePart(part(contentType))),
    ).toStrictEqual([false, false, false, false, true, true, true, true]);
  });

  it.each(['Content-Type', 'Content-Disposition'] as const)(
    'checks malformed %s again in the full prefetch response',
    async (name) => {
      expect.hasAssertions();
      const gmail = createSyntheticGmail();
      const id = gmail.deliver({
        at: Date.now() - 60_000,
        content: { text: 'On demand', single: true },
      });
      const values = {
        'Content-Type': 'text/plain; charset="unterminated',
        'Content-Disposition': 'inline; filename="unterminated',
      };
      replaceFullPayload(gmail, id, {
        mimeType: 'text/plain',
        headers: [{ name, value: values[name] }],
        body: { size: 9, data: Buffer.from('On demand').toString('base64url') },
      });
      const inbox = createGmailInbox(gmail.native);
      await inbox.load();
      await vi.waitFor(() => {
        expect(JSON.parse(String(gmail.cachedBodies().get(id)))).toStrictEqual({
          version: 2,
          id,
          excluded: true,
        });
      });
      expect(readable(await read(inbox, id)).paragraphs).toStrictEqual([
        [{ text: 'On demand' }],
      ]);
    },
  );

  it('charges every requested image download to the aggregate byte bound', () => {
    expect.hasAssertions();
    const tally = imageTally();
    const part = { mimeType: 'image/png', body: { size: 5 * 1024 * 1024 } };
    const requested = Array.from({ length: 20 }, (_, attempt) => {
      const allowed = tally.request(part, attempt);
      // Malformed bytes are refused, but their transfer still counts.
      tally.receive(`image-${attempt}`, part, 'AAAA');
      return allowed;
    });
    expect(requested.filter(Boolean)).toHaveLength(4);
  });

  it('asks for Gmail when a cached or opened body meets a rejected grant while resolving images', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      at: Date.UTC(2020, 0, 1),
      content: {
        html: '<p>Shown text</p><img src="cid:photo" alt="Photo">',
        images: [
          { contentId: 'photo', mimeType: 'image/png', bytes: png(4, 4) },
        ],
      },
    });
    const refusing = refuseGrant(gmail);
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    // An opened body keeps its text while its image download meets the rejection.
    refusing.attachments = true;
    const opened = rich(await read(inbox, id));
    expect(opened.document).toContain('Shown text');
    expect(opened.document).not.toContain('data:image');
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'authentication' });
    // Once Gmail answers again, the next synchronization resolves the image in place.
    refusing.attachments = false;
    await inbox.load();
    await vi.waitFor(() => {
      expect(rich(inbox.messageBody(id)).document).toContain('data:image/png');
    });
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'current' });

    // A cached body whose images were never resolved keeps its text when Gmail rejects the
    // grant for the message's structure, and the Inbox asks for Gmail.
    const unresolved = gmail.deliver({
      at: Date.UTC(2020, 0, 2),
      content: {
        html: '<p>Cached text</p><img src="cid:pending" alt="Pending">',
        images: [
          { contentId: 'pending', mimeType: 'image/png', bytes: png(4, 4) },
        ],
      },
    });
    refusing.attachments = true;
    await inbox.load();
    await read(inbox, unresolved);
    refusing.attachments = false;
    const fresh = createGmailInbox(gmail.native);
    await fresh.load();
    refusing.full = true;
    const cached = rich(await read(fresh, unresolved));
    expect(cached.document).toContain('Cached text');
    expect(fresh.getSnapshot()).toMatchObject({ sync: 'authentication' });
  });

  it('stops prefetch when Gmail needs permission again and limits loads to two', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const now = Date.now();
    const ids = [1, 2, 3, 4].map((index) =>
      gmail.deliver({
        at: now - index * 60_000,
        content: { text: `Recent ${index}`, single: true },
      }),
    );
    const observed = observeBodyLoads(gmail);
    const inbox = createGmailInbox(gmail.native);
    const opening = inbox.load();
    await Promise.all([opening, inbox.readMessage(String(ids[3]))]);
    await vi.waitFor(() => {
      expect(gmail.bodyCommits).toHaveLength(4);
    });
    expect(observed.most).toBeLessThanOrEqual(2);

    observed.refuse = true;
    gmail.deliver({
      at: now - 1000,
      content: { text: 'Newest', single: true },
    });
    await inbox.load();
    await vi.waitFor(() => {
      expect(inbox.getSnapshot()).toMatchObject({ sync: 'authentication' });
    });
  });

  it('charges repeated image occurrences and releases rich reservations after render failure', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const first = gmail.deliver({
      content: {
        html: `<p>Repeated</p>${'<img src="cid:photo">'.repeat(3)}`,
        images: [
          { contentId: 'photo', mimeType: 'image/png', bytes: png(4096, 4096) },
        ],
      },
    });
    const second = gmail.deliver({
      content: {
        html: '<p>Second</p><img src="cid:photo">',
        images: [
          { contentId: 'photo', mimeType: 'image/png', bytes: png(4096, 4096) },
        ],
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    inbox.retainMessage(first);
    inbox.retainMessage(second);
    const body = await read(inbox, first);
    // Three occurrences would decode to 48 Mi pixels, so this CID remains a placeholder.
    expect(rich(body).document).not.toContain('src="data:');
    expect(rich(await read(inbox, second)).document).toContain('src="data:');
    const current = ready(inbox.messageBody(second));
    inbox.discardRichMessage(second, current.presentation);
    expect(inbox.messageBody(second)).toMatchObject({
      kind: 'ready',
      presentation: { readable: { paragraphs: [[{ text: 'Second' }]] } },
    });
    expect(inbox.messageBody(second)).not.toHaveProperty('presentation.rich');
  });

  it('joins an in-flight recent prefetch and drops a presentation closed before completion', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      at: Date.now() - 1000,
      content: { text: 'Shared body', single: true },
    });
    const request = gmail.native.gmailRequest;
    const start = Promise.withResolvers<undefined>();
    const gate = Promise.withResolvers<undefined>();
    let fulls = 0;
    // oxlint-disable vitest/no-conditional-in-test -- Route only the full-body transport through the deterministic gate.
    const holdFullRead: typeof request = async (...args) => {
      if (
        args[0] === `messages/${id}` &&
        args[1].some(([name, value]) => name === 'format' && value === 'full')
      ) {
        fulls += 1;
        start.resolve(undefined);
        await gate.promise;
      }
      return request(...args);
    };
    // oxlint-enable vitest/no-conditional-in-test
    gmail.native.gmailRequest = holdFullRead;
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await start.promise;
    const release = inbox.retainMessage(id);
    const opening = inbox.readMessage(id);
    gate.resolve(undefined);
    await opening;
    expect(readable(inbox.messageBody(id))).toMatchObject({
      paragraphs: [[{ text: 'Shared body' }]],
    });
    expect(fulls).toBe(1);
    release();
    // A later cached read closed before its queued completion retains no hidden presentation.
    const end = inbox.retainMessage(id);
    const pending = inbox.readMessage(id);
    end();
    await pending;
    expect(inbox.messageBody(id)).toBeUndefined();
  });

  it('does not restore a reader closed by the initial loading notification', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      at: Date.UTC(2020, 0, 1),
      content: { text: 'Closed mail', single: true },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const close = inbox.retainMessage(id);
    // Synchronous publication precedes registration of the pending read's promise.
    const unsubscribe = inbox.subscribe(() => {
      unsubscribe();
      close();
    });
    await inbox.readMessage(id);
    unsubscribe();
    expect(inbox.messageBody(id)).toBeUndefined();
  });

  it('rejects incomplete image containers before local data reaches WebKit', () => {
    expect.hasAssertions();
    const valid = png(20, 20);
    const missingData = [
      ...ascii('\u0089PNG\r\n\u001A\n'),
      ...chunk('IHDR', [...u32(20), ...u32(20), 8, 6, 0, 0, 0]),
      ...chunk('IEND', []),
    ];
    const badSignature = [...valid];
    badSignature[4] = 0;
    const badCrc = [...valid];
    badCrc[29] = 1;
    expect(inspectImage(Uint8Array.from(valid))).toMatchObject({
      mimeType: 'image/png',
      width: 20,
      height: 20,
    });
    for (const bytes of [
      missingData,
      badSignature,
      badCrc,
      valid.slice(0, -1),
      [
        ...ascii('RIFF'),
        22,
        0,
        0,
        0,
        ...ascii('WEBPVP8X'),
        10,
        0,
        0,
        0,
        ...Array.from({ length: 10 }, () => 0),
      ],
    ]) {
      expect(inspectImage(Uint8Array.from(bytes))).toBeUndefined();
    }
  });

  it('prefetches for a newly opened mailbox while the previous mailbox is still prefetching', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const now = Date.now();
    gmail.deliver({
      at: now - 60_000,
      content: { text: 'Previous mailbox', single: true },
    });
    const preflight = holdFirstPreflight(gmail);
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await preflight.reached;

    inbox.forget();
    gmail.reselect('sam@example.invalid');
    const next = gmail.deliver({
      at: now - 60_000,
      content: { text: 'Selected mailbox', single: true },
    });
    await inbox.load();
    preflight.release();
    await vi.waitFor(() => {
      expect(gmail.cachedBodies().has(next)).toBe(true);
    });
  });

  it('saves and shows an opened body while a long synchronization is still listing', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 60 });
    const page = holdListPage(gmail, '50');
    const inbox = createGmailInbox(gmail.native);
    const synchronizing = inbox.load();
    await page.reached;
    const [first = ''] = listedIds(inbox);
    await inbox.readMessage(first);
    expect(inbox.messageBody(first)?.kind).toBe('ready');
    expect(gmail.cachedBodies().has(first)).toBe(true);
    page.release();
    await synchronizing;
  });
  /* oxlint-enable vitest/max-expects */
});

describe('link inspection', () => {
  it.each([
    ['https://example.invalid/a', 'Example', []],
    ['https://example.invalid/a', 'www.example.invalid', []],
    ['https://phish.invalid/a', 'https://bank.invalid', [linkWarnings.text]],
    ['https://phish.invalid/a', 'https://192.0.2.7/login', [linkWarnings.text]],
    ['https://phish.invalid/a', '192.0.2.7', [linkWarnings.text]],
    ['https://phish.invalid/a', '[2001:db8::1]', [linkWarnings.text]],
    ['https://phish.invalid/a', 'https://0x7f.1/', [linkWarnings.text]],
    ['https://192.0.2.7/login', '192.0.2.7', [linkWarnings.numeric]],
    ['https://example.invalid/a', 'Version 1.2', []],
    ['https://example.invalid/a', '1.2.3', []],
    ['https://example.invalid/a', '12:30', []],
    ['https://example.invalid/a', '2026-10-06', []],
    ['https://example.invalid/a', 'https://', []],
    ['https://example.invalid/a', 'https://?query', []],
    ['https://example.invalid/a', 'https://#fragment', []],
    ['https://example.invalid/a', 'https://%65xample.invalid/', []],
    ['https://a+b.invalid/', 'https://a%2Bb.invalid/', []],
    ['https://0.0.0.0/', 'https://0x/', [linkWarnings.numeric]],
    ['https://0.0.0.1/', 'https://0x.1/', [linkWarnings.numeric]],
    ['https://127.0.0.1/', 'https://0x7f.1/', [linkWarnings.numeric]],
    ['https://127.0.0.1/', 'https://0177.1/', [linkWarnings.numeric]],
    ['https://127.0.0.1/', 'https://2130706433/', [linkWarnings.numeric]],
    ['https://127.0.0.1/', 'https://127.1/', [linkWarnings.numeric]],
    [
      'https://[2001:db8::1]/',
      '[2001:0db8:0:0:0:0:0:1]:443/path?query#fragment',
      [linkWarnings.numeric],
    ],
    [
      'https://[::ffff:c000:207]/',
      'https://[::ffff:192.0.2.7]/',
      [linkWarnings.numeric],
    ],
    [
      'https://127.0.0.1/',
      'https://0x7f.2/',
      [linkWarnings.text, linkWarnings.numeric],
    ],
    [
      'https://[2001:db8::1]/',
      '[2001:db8::2]',
      [linkWarnings.text, linkWarnings.numeric],
    ],
    [
      'https://[2001:db8::1]/',
      '[2001::db8::1]',
      [linkWarnings.text, linkWarnings.numeric],
    ],
    ['http://bank.invalid/', 'https://bank.invalid', [linkWarnings.insecure]],
    ['https://xn--bnk-sna.invalid/', 'Bank', [linkWarnings.international]],
    ['https://192.0.2.7/login', 'Login', [linkWarnings.numeric]],
    ['https://127.1/login', 'Login', [linkWarnings.numeric]],
    ['https://0x7f.1/login', 'Login', [linkWarnings.numeric]],
    ['https://%C3%A9.invalid/', 'Login', [linkWarnings.international]],
    [
      'https://example.invalid/%E2%80%AEgnp.exe',
      'File',
      [linkWarnings.direction],
    ],
    ['https://bank.invalid@phish.invalid/', 'Bank', [linkWarnings.credentials]],
    ['https://example.invalid/‮gnp.exe', 'File', [linkWarnings.direction]],
    [
      'https://tracker.invalid/r?u=https%3A%2F%2Fother.invalid%2F',
      'Read more',
      [linkWarnings.forwards],
    ],
    [
      'https://0x7f000001/r?next=https%3A%2F%2F127.0.0.1%2F',
      'Continue',
      [linkWarnings.numeric],
    ],
    [
      'https://example.invalid/r?next=https%3A%2F%2F%2565xample.invalid%2F',
      'Continue',
      [],
    ],
    [
      'https://[2001:db8::1]/r?next=https%3A%2F%2F%5B2001%3Adb8%3A0%3A0%3A0%3A0%3A0%3A1%5D%2F',
      'Continue',
      [linkWarnings.numeric],
    ],
    ['https://phish.invalid/', 'bank.xn--p1ai', [linkWarnings.text]],
    ['https://bank.xn--p1ai/', 'bank.xn--p1ai', [linkWarnings.international]],
    ['https://phish.invalid/', 'Version 1.2', []],
    [
      'https://phish.invalid/',
      'BANK.XN--P1AI/login?next=1',
      [linkWarnings.text],
    ],
    ['https://phish.invalid/', 'bank.xn--', []],
    ['https://phish.invalid/', '2026.10.06', []],
  ] as const)('inspects %s shown as %s', (href, text, reasons) => {
    expect.hasAssertions();
    expect(inspectLink(href, text)).toStrictEqual(reasons);
  });
});
