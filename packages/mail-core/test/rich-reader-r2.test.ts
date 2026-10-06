import type { GmailPart } from '../src/message-body.ts';

import { createGmailInbox } from '../src/gmail-inbox.ts';
import { sanitizeHtml } from '../src/html-sanitizer.ts';
import { inspectLink, linkWarnings } from '../src/link-inspection.ts';
import { contentIdsOf, presentation } from '../src/message-body.ts';
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
  contentId: string | readonly string[],
  {
    filename = '',
    disposition,
  }: {
    readonly filename?: string;
    readonly disposition?: string | readonly string[];
  } = {},
): GmailPart => ({
  mimeType: 'image/png',
  filename,
  headers: [
    ...[contentId].flat().map((value) => ({ name: 'cOnTeNt-ID', value })),
    ...[disposition ?? []]
      .flat()
      .map((value) => ({ name: 'cOnTeNt-Disposition', value })),
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
      headers: [
        { name: 'Content-Type', value: 'text/html; charset=UTF-8' },
        { name: 'cOnTeNt-TyPe', value: '(comment) TEXT/HTML; charset=UTF-8' },
      ],
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
    const references = [
      'shared',
      'optional',
      'explicit',
      'filename',
      'attached',
      'conflict',
      'blank',
      'same',
      'ambiguous',
      'normalized',
      'container',
      'descendant',
      'related-conflict',
      'empty-id',
      'masked',
    ]
      .map((id) => `<img src="cid:${id}">`)
      .join('');
    const html = `<p>Body</p>${references}`;
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
                imagePart('related-conflict', '<related-conflict>', {
                  filename: 'attachment.png',
                  disposition: ['inline', 'attachment'],
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
        imagePart('conflict', '<conflict>', {
          filename: 'attachment.png',
          disposition: ['inline', 'attachment'],
        }),
        imagePart('blank', '<blank>', {
          filename: 'attachment.png',
          disposition: ['inline', ' \t'],
        }),
        imagePart('same', '<same>', {
          filename: 'inline.png',
          disposition: [
            'inline',
            '(nested (comment)) INLINE; filename="(logo).png"',
          ],
        }),
        imagePart('ambiguous', ['<ambiguous>', '<another>']),
        imagePart('normalized', ['<normalized>', '(comment)\r\n <normalized>']),
        imagePart('empty-id', ['<empty-id>', ' \t']),
        {
          ...imagePart('container', '<container>'),
          parts: [imagePart('descendant', '<descendant>')],
        },
        {
          mimeType: 'multipart/mixed',
          headers: [
            { name: 'Content-Type', value: 'multipart/mixed' },
            { name: 'cOnTeNt-TyPe', value: 'message/rfc822' },
          ],
          parts: [imagePart('masked', '<masked>')],
        },
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
    expect(observed.images).toStrictEqual([
      'chosen',
      'optional',
      'explicit',
      'same',
      'normalized',
    ]);
  });

  it.each([
    ...['multipart/related', 'message/rfc822', '', ' \t'].map((value) => ({
      ...textPart('text/plain', 'Excluded ambiguous body'),
      headers: [
        { name: 'Content-Type', value: 'text/plain' },
        { name: 'cOnTeNt-TyPe', value },
      ],
    })),
    {
      ...textPart('text/plain', 'Excluded reversed conflict'),
      headers: [
        { name: 'Content-Type', value: 'multipart/related' },
        { name: 'cOnTeNt-TyPe', value: 'text/plain' },
      ],
    },
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

  it('reads text a descendant size makes visible again and inspects its link', () => {
    expect.hasAssertions();
    const result = sanitizeHtml(
      [
        '<div style="font-size:0"><a style="font-size:16px" href="https://phish.invalid/a">https://bank.invalid</a></div>',
        '<div style="font-size:0"><a style="font-size:2em" href="https://phish.invalid/b">https://hidden.invalid</a></div>',
        '<div style="font-size:0"><span style="font-size:larger">Hidden larger</span></div>',
        '<div style="line-height:0"><span style="line-height:normal">Visible line</span></div>',
        '<div style="max-height:0"><span style="font-size:16px">Boxed</span></div>',
        '<div style="line-height:0"><a href="https://phish.invalid/c">https://line.invalid</a></div>',
        '<div style="text-indent:-9999px"><div style="text-indent:0"><a href="https://phish.invalid/d">https://indent.invalid</a></div></div>',
        '<a href="https://phish.invalid/e">https://bank.invalid<span style="font-size:0"><span style="font-size:calc(0px)"> masking text</span></span></a>',
        '<a href="https://phish.invalid/revert">https://bank.invalid<span style="font-size:0"><span style="font-size:revert-layer"> masking text</span></span></a>',
        '<div style="max-width:0"><a href="https://phish.invalid/f">https://width.invalid</a></div>',
      ].join(''),
    );
    expect(result.links).toStrictEqual([
      { href: 'https://phish.invalid/a', text: 'https://bank.invalid' },
      { href: 'https://phish.invalid/b', text: '' },
      { href: 'https://phish.invalid/c', text: 'https://line.invalid' },
      { href: 'https://phish.invalid/d', text: 'https://indent.invalid' },
      { href: 'https://phish.invalid/e', text: 'https://bank.invalid' },
      { href: 'https://phish.invalid/revert', text: 'https://bank.invalid' },
      { href: 'https://phish.invalid/f', text: 'https://width.invalid' },
    ]);
    for (const { href, text } of result.links.filter(
      ({ text }) => text !== '',
    )) {
      expect(inspectLink(href, text)).toContain(linkWarnings.text);
    }
    expect(
      result.readable.paragraphs.flat().map(({ text }) => text),
    ).toStrictEqual([
      'https://bank.invalid',
      'Visible line',
      'Boxed',
      'https://line.invalid',
      'https://indent.invalid',
      'https://bank.invalid',
      'https://bank.invalid',
      'https://width.invalid',
    ]);
    expect(result.document).not.toContain('calc(0px)');
    for (const fontSize of [
      'bogus',
      'calc(0px)',
      '-1px',
      '2',
      'revert',
      'revert-layer',
    ]) {
      const masked = sanitizeHtml(
        `<a href="https://phish.invalid">https://bank.invalid<span style="font-size:0"><span style="font-size:${fontSize}"> masking text</span></span></a>`,
      );
      expect(masked.links).toStrictEqual([
        { href: 'https://phish.invalid', text: 'https://bank.invalid' },
      ]);
    }
    const indented = sanitizeHtml(
      '<div style="text-indent:-9999px"><div style="text-indent:revert"><a href="https://phish.invalid">Off canvas</a></div></div><a href="https://phish.invalid">Sibling visible</a>',
    );
    expect(indented.links).toStrictEqual([
      { href: 'https://phish.invalid', text: '' },
      { href: 'https://phish.invalid', text: 'Sibling visible' },
    ]);
  });

  it('never resolves images in cells of collapsed table columns', () => {
    expect.hasAssertions();
    const result = sanitizeHtml(
      [
        '<table>',
        '<colgroup><col><col style="visibility:collapse"></colgroup>',
        '<colgroup span="2" style="visibility:collapse"></colgroup>',
        '<colgroup style="visibility:collapse"><col style="visibility:visible"></colgroup>',
        '<tr><td><img src="cid:shown"></td><td><img src="cid:collapsed"></td>',
        '<td colspan="2"><img src="cid:group"></td><td><img src="cid:override"></td></tr>',
        '<tr><td rowspan="2"><img src="cid:tall"></td><td colspan="4"><img src="cid:partial"></td></tr>',
        '<tr><td><img src="cid:shifted"></td></tr>',
        '</table>',
      ].join(''),
    );
    expect(result.contentIds).toStrictEqual([
      'shown',
      'override',
      'tall',
      'partial',
    ]);
    expect(result.document.match(/class="blocked-image"/gu)).toHaveLength(4);
  });

  it('uses emitted table slots and spans for collapse admission across row groups', () => {
    expect.hasAssertions();
    const result = sanitizeHtml(
      [
        '<table style="display:block"><col style="display:none"><col><col style="visibility:collapse">',
        '<tfoot><tr><td><img src="cid:footer"></td><td><img src="cid:no-footer"></td></tr></tfoot>',
        '<thead><tr><th><img src="cid:header"></th><th><img src="cid:no-header"></th></tr></thead>',
        '<tbody><tr style="visibility:collapse"><td rowspan="0"><img src="cid:no-row"></td></tr>',
        '<tr><td style="display:none"></td><td style="display:block" rowspan="+2suffix"><img src="cid:rowspan"></td>',
        '<td><img src="cid:no-first"></td></tr><tr><td><img src="cid:no-shifted"></td></tr></tbody>',
        '<tbody><tr><td><table><col style="visibility:collapse"><col>',
        '<tr><td><img src="cid:no-nested"></td><td><img src="cid:nested"></td></tr></table></td>',
        '<td><img src="cid:no-outer"></td></tr></tbody></table>',
        '<table><colgroup><col style="display:none"></colgroup><col style="visibility:collapse">',
        '<tr><td><img src="cid:no-empty-group"></td></tr></table>',
      ].join(''),
    );
    expect(result.contentIds).toStrictEqual([
      'footer',
      'header',
      'rowspan',
      'nested',
    ]);
    expect(result.document).toContain('rowspan="2"');
    expect(result.document).not.toContain('suffix');
    expect(result.document).not.toContain('display: block');
    expect(result.document).not.toContain('<colgroup></colgroup>');
  });

  it('falls back without CID requests when table spans exhaust bounded layout work', () => {
    expect.hasAssertions();
    const document = {
      version: 2 as const,
      id: 'bounded-table',
      html: `<table><col style="visibility:collapse">${'<tr><td colspan="1000" rowspan="0"><img src="cid:excluded"></td></tr>'.repeat(1000)}</table>`,
      text: 'Retained fallback',
    };
    expect(contentIdsOf(document)).toStrictEqual([]);
    expect(presentation(document)).toStrictEqual({
      readable: {
        paragraphs: [[{ text: 'Retained fallback' }]],
        hidesImages: false,
      },
    });
  });
});
