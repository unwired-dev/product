import type { GmailPart } from '../src/message-body.ts';

import { createGmailInbox } from '../src/gmail-inbox.ts';
import { sanitizeHtml } from '../src/html-sanitizer.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';

const textPart = (mimeType: string, content: string): GmailPart => ({
  mimeType,
  body: {
    data: Buffer.from(content).toString('base64url'),
    size: Buffer.byteLength(content),
  },
});
const imagePart = (
  id: string,
  contentId: string,
  {
    filename = '',
    disposition,
  }: { readonly filename?: string; readonly disposition?: string } = {},
): GmailPart => ({
  mimeType: 'image/png',
  filename,
  headers: [
    { name: 'Content-ID', value: contentId },
    ...(disposition === undefined
      ? []
      : [{ name: 'Content-Disposition', value: disposition }]),
  ],
  body: { size: 1, attachmentId: id },
});

const substitutePayload = (
  gmail: ReturnType<typeof createSyntheticGmail>,
  id: string,
  payload: GmailPart,
) => {
  const request = gmail.native.gmailRequest;
  const observed = { images: [] as string[], full: 0 };
  gmail.native.gmailRequest = (...args) => {
    const preflight = args[1].some(
      ([name, value]) => name === 'metadataHeaders' && value === 'Content-Type',
    );
    const full = args[1].some(
      ([name, value]) => name === 'format' && value === 'full',
    );
    if (full) {
      observed.full += 1;
    }
    if (preflight || full) {
      return Promise.resolve({
        status: 200,
        body: JSON.stringify({ id, payload }),
      });
    }
    if (args[0].includes('/attachments/')) {
      observed.images.push(args[0].split('/').at(-1) ?? '');
      return Promise.resolve({
        status: 200,
        body: JSON.stringify({ data: 'AA', size: 1 }),
      });
    }
    return request(...args);
  };
  return observed;
};

describe('rich-reader review regressions', () => {
  it('prefetches HTML using authoritative Content-Type despite a contradictory payload MIME type', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      at: Date.now() - 1000,
      content: { text: 'Recent', single: true },
    });
    const html = '<p><strong>Prefetched HTML</strong></p>';
    const observed = substitutePayload(gmail, id, {
      ...textPart('text/plain', html),
      headers: [{ name: 'Content-Type', value: 'text/html; charset=UTF-8' }],
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await vi.waitFor(() => {
      expect(gmail.cachedBodies().has(id)).toBe(true);
    });
    expect(JSON.parse(String(gmail.cachedBodies().get(id)))).toMatchObject({
      html,
    });
    await inbox.readMessage(id);
    expect(inbox.messageBody(id)).toMatchObject({
      kind: 'ready',
      presentation: { rich: { document: expect.stringContaining(html) } },
    });
    expect(observed.full).toBe(1);
  });

  it('uses retained plain text after sanitizer stack exhaustion without leaving a loader', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({ at: Date.UTC(2020, 0, 1) });
    substitutePayload(gmail, id, {
      mimeType: 'multipart/alternative',
      parts: [
        textPart('text/plain', 'Retained fallback'),
        textPart(
          'text/html',
          `${'<div>'.repeat(6000)}<img src="cid:never">${'</div>'.repeat(
            6000,
          )}`,
        ),
      ],
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await expect(inbox.readMessage(id)).resolves.toBeUndefined();
    expect(inbox.messageBody(id)).toStrictEqual({
      kind: 'ready',
      presentation: {
        readable: {
          paragraphs: [[{ text: 'Retained fallback' }]],
          hidesImages: false,
        },
      },
    });
  });

  it('keeps the blocked-image notice when rich HTML has a retained plain alternative', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      at: Date.UTC(2020, 0, 1),
      content: {
        text: 'Plain fallback',
        html: '<p>Rich body</p><img src="https://images.example.invalid/photo.png">',
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await inbox.readMessage(id);
    expect(inbox.messageBody(id)).toMatchObject({
      kind: 'ready',
      presentation: {
        rich: { links: [] },
        readable: {
          paragraphs: [[{ text: 'Plain fallback' }]],
          hidesImages: true,
        },
      },
    });
  });

  it('resolves CID images only in the chosen MIME branch and eligible outer siblings', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({ at: Date.UTC(2020, 0, 1) });
    const html =
      '<p>Body</p><img src="cid:shared"><img src="cid:optional"><img src="cid:explicit"><img src="cid:filename"><img src="cid:attached">';
    const payload: GmailPart = {
      mimeType: 'multipart/mixed',
      parts: [
        {
          mimeType: 'multipart/alternative',
          parts: [
            {
              mimeType: 'multipart/related',
              parts: [
                textPart('text/plain', 'Alternative'),
                imagePart('wrong', '<shared>'),
              ],
            },
            {
              mimeType: 'multipart/related',
              parts: [
                textPart('text/html', html),
                imagePart('chosen', '(nested (comment)) <shared>', {
                  filename: 'logo.png',
                }),
              ],
            },
          ],
        },
        imagePart('optional', '<optional>'),
        imagePart('explicit', '<explicit>', {
          filename: 'inline.png',
          disposition: '(leading (comment))\r\n inline; filename="inline.png"',
        }),
        imagePart('filename', '<filename>', { filename: 'attachment.png' }),
        {
          mimeType: 'multipart/related',
          headers: [
            {
              name: 'Content-Disposition',
              value: '(leading)\r\n attachment; filename="forwarded"',
            },
          ],
          parts: [imagePart('attached', '<attached>')],
        },
      ],
    };
    const observed = substitutePayload(gmail, id, payload);
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await inbox.readMessage(id);
    expect(inbox.messageBody(id)).toMatchObject({ kind: 'ready' });
    expect(observed.images).toStrictEqual(['chosen', 'optional', 'explicit']);
  });

  it.each([
    {
      mimeType: 'text/plain',
      headers: [{ name: 'Content-Type', value: 'text/html (unterminated' }],
    },
    {
      mimeType: 'text/plain',
      headers: [{ name: 'Content-Type', value: 'text/html )' }],
    },
    {
      mimeType: 'text/plain',
      headers: [
        {
          name: 'Content-Type',
          value: '(leading) multipart/related; boundary=x',
        },
      ],
    },
    {
      mimeType: 'text/html',
      headers: [
        { name: 'Content-Type', value: 'text/html' },
        {
          name: 'Content-Disposition',
          value: '(leading (nested))\r\n attachment; filename="mail.html"',
        },
      ],
    },
  ])(
    'refuses speculative full downloads of multipart or attachment metadata: %j',
    async (payload) => {
      expect.hasAssertions();
      const gmail = createSyntheticGmail();
      const id = gmail.deliver({
        at: Date.now() - 1000,
        content: { text: 'Recent', single: true },
      });
      const observed = substitutePayload(gmail, id, payload);
      const inbox = createGmailInbox(gmail.native);
      await inbox.load();
      await vi.waitFor(() => {
        expect(gmail.bodyCommits).toHaveLength(1);
      });
      expect(observed.full).toBe(0);
      expect(JSON.parse(String(gmail.cachedBodies().get(id)))).toMatchObject({
        excluded: true,
      });
    },
  );

  it('retains visible CID descendants while excluding unreadable preheaders and non-rendering images', () => {
    expect.hasAssertions();
    const result = sanitizeHtml(
      [
        '<div style="font-size:0;line-height:0;max-height:0">Hidden preheader<img src="cid:visible"></div>',
        '<img src="cid:visible">',
        '<img src="cid:pixel" width="100" height="100" style="width:100px;height:100px;max-width:1px;max-height:1px">',
        '<img src="cid:transparent" style="opacity:0%">',
        '<img src="cid:negative" style="opacity:-.1">',
        '<img src="cid:zero-percent" style="width:0%;height:100px">',
        '<img src="cid:zero-relative" style="max-height:0em">',
        '<img src="cid:contents" style="display:contents">',
        '<div hidden><img src="cid:hidden"></div>',
      ].join(''),
    );
    expect(result.contentIds).toStrictEqual(['visible']);
    expect(result.contentIdOccurrences).toStrictEqual(['visible', 'visible']);
    expect(result.renderable).toBe(true);
    expect(result.readable.paragraphs).toStrictEqual([]);
  });
});
