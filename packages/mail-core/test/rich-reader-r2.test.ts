import type { GmailPart } from '../src/message-body.ts';

import { createGmailInbox } from '../src/gmail-inbox.ts';
import { sanitizeHtml } from '../src/html-sanitizer.ts';
import { inspectLink, linkWarnings } from '../src/link-inspection.ts';
import { contentIdsOf, presentation } from '../src/message-body.ts';
import { messageLinkLimit, readableText } from '../src/readable-text.ts';
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
    ...[
      ['Content-Type', 'text/html garbage'],
      ['Content-Type', 'text/html; charset="unterminated'],
      ['Content-Type', 'text/html; charset='],
      ['Content-Type', 'text/html; charset=utf8 garbage'],
      ['Content-Type', 'text/html;'],
      ['Content-Type', 'text/html;\ncharset=utf-8'],
      ['Content-Type', 'text/html\n'],
      ['Content-Type', 'text/html;\u00A0charset=utf-8'],
      ['Content-Disposition', 'inline garbage'],
      ['Content-Disposition', 'inline; filename="unterminated'],
      ['Content-Disposition', 'inline; filename='],
      ['Content-Disposition', 'inline; filename="mail.html" garbage'],
      ['Content-Disposition', 'inline; filename="dangling\\'],
      ['Content-Disposition', 'inline;\rfilename="mail.html"'],
      ['Content-Disposition', 'inline;\u00A0filename="mail.html"'],
    ].map(([name = '', value = '']) => ({
      ...textPart('text/html', '<p>Must remain on demand</p>'),
      headers: [{ name, value }],
    })),
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
    'refuses speculative full downloads of malformed, multipart or attachment metadata: %j',
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
      { href: 'https://phish.invalid', text: 'Off canvas' },
      { href: 'https://phish.invalid', text: 'Sibling visible' },
    ]);
  });

  it('shows and resolves descendants that make hidden visibility visible again', () => {
    expect.hasAssertions();
    const result = sanitizeHtml(
      [
        '<div style="visibility:hidden">Hidden text<img src="cid:hidden"><span style="visibility:visible">Shown text<img src="cid:shown"></span></div>',
        '<p style="visibility:hidden"><a href="https://phish.invalid/a">Hidden label <span style="visibility:visible">https://bank.invalid</span></a></p>',
        '<div style="visibility:collapse"><img src="cid:collapsed"><span style="visibility:inherit"><img src="cid:inherited"></span></div>',
        '<table><tr style="visibility:collapse"><td style="visibility:visible"><img src="cid:row"></td></tr></table>',
      ].join(''),
    );
    expect(result.contentIds).toStrictEqual(['shown']);
    expect(result.links).toStrictEqual([
      { href: 'https://phish.invalid/a', text: 'https://bank.invalid' },
    ]);
    expect(
      result.readable.paragraphs.flat().map(({ text }) => text),
    ).toStrictEqual(['Shown text', 'https://bank.invalid']);
    expect(result.document).toContain('style="visibility: hidden"');
    expect(result.document).toContain('style="visibility: visible"');
  });

  it('keeps descendants that restore inherited visibility without inspecting hidden peers', () => {
    expect.hasAssertions();
    const result = sanitizeHtml(
      [
        '<div style="visibility:hidden">Hidden preheader',
        '<a style="visibility:visible" href="https://phish.invalid">https://bank.invalid<span style="visibility:hidden"> masked</span></a>',
        '<img src="cid:hidden"><img style="visibility:visible" src="cid:shown">',
        '<span style="visibility:inherit">Hidden inherited</span>',
        '<span style="visibility:unset">Hidden unset</span>',
        '<span style="visibility:revert">Hidden revert</span>',
        '<span style="visibility:collapse"><b style="visibility:visible">Restored collapse</b></span>',
        '<a href="https://phish.invalid/image"><img style="visibility:visible" src="cid:label" alt="https://bank.invalid"></a>',
        '</div><p>Visible sibling</p>',
      ].join(''),
    );
    expect(result.links).toStrictEqual([
      { href: 'https://phish.invalid', text: 'https://bank.invalid' },
      { href: 'https://phish.invalid/image', text: 'https://bank.invalid' },
    ]);
    for (const { href, text } of result.links) {
      expect(inspectLink(href, text)).toContain(linkWarnings.text);
    }
    expect(result).toMatchObject({
      contentIds: ['shown', 'label'],
      contentIdOccurrences: ['shown', 'label'],
    });
    const readable = result.readable.paragraphs
      .flat()
      .map(({ text }) => text)
      .join('');
    expect(readable).toMatch(
      /^https:\/\/bank.invalidRestored collapse\s*https:\/\/bank.invalidVisible sibling$/u,
    );
    expect(result.document).toContain('visibility: visible');
  });

  it('does not restore visibility through excluded boxes or collapsed table tracks', () => {
    expect.hasAssertions();
    for (const blocker of ['display:none', 'opacity:0']) {
      const blocked = sanitizeHtml(
        `<div style="${blocker}"><a style="visibility:visible" href="https://phish.invalid">Visible?</a><img style="visibility:visible" src="cid:blocked"></div>`,
      );
      expect(blocked).toMatchObject({
        renderable: false,
        contentIds: [],
        links: [],
      });
    }
    const collapsed = sanitizeHtml(
      '<table><tr style="visibility:collapse"><td style="visibility:visible"><img src="cid:collapsed-row"></td></tr></table>',
    );
    expect(collapsed.contentIds).toStrictEqual([]);
    const hiddenImage = sanitizeHtml(
      '<div style="visibility:hidden"><img src="cid:hidden"></div>',
    );
    expect(hiddenImage).toMatchObject({
      contentIds: [],
      renderable: false,
      readable: { hidesImages: false },
    });
  });

  it.each(['cid:missing', 'https://images.example.invalid/photo.png'])(
    'preserves restored visibility when %s becomes a placeholder',
    (source) => {
      expect.hasAssertions();
      const result = sanitizeHtml(
        `<div style="visibility:hidden"><img style="visibility:visible" src="${source}" alt="Restored image"></div>`,
      );
      expect(result.document).toContain(
        '<span class="blocked-image" style="visibility: visible" role="img" aria-label="Restored image">Restored image</span>',
      );
      expect(result.readable).toStrictEqual({
        paragraphs: [[{ text: 'Restored image' }]],
        hidesImages: true,
      });
    },
  );

  it('preserves visibility styling on rules and line breaks', () => {
    expect.hasAssertions();
    const result = sanitizeHtml(
      '<p>Visible</p><hr style="visibility:hidden"><div style="visibility:hidden"><hr style="visibility:visible"><br style="visibility:visible"></div>',
    );
    expect(result.document).toContain('<hr style="visibility: hidden;');
    expect(result.document).toContain(
      '<div style="visibility: hidden"><hr style="visibility: visible;',
    );
    expect(result.document).toContain('<br style="visibility: visible"></div>');
  });

  it('retains visibility geometry and resets while omitting hidden link controls', () => {
    expect.hasAssertions();
    const result = sanitizeHtml(
      '<div style="visibility:hidden"><img width="200" height="100" src="cid:hidden"><a href="https://hidden.invalid">Hidden</a><a href="https://shown.invalid"><img style="visibility:initial" src="cid:initial" alt="Initial visible"></a></div><div style="visibility:collapse"><table><tr><td style="visibility:visible"><img src="cid:inherited-row"></td></tr></table></div>',
    );
    expect(result).toMatchObject({
      contentIds: ['initial'],
      links: [{ href: 'https://shown.invalid', text: 'Initial visible' }],
    });
    expect(result.document).toContain('<img width="200" height="100">');
    expect(result.document.match(/<a /gu)).toHaveLength(1);
  });

  it('omits links and image notices from an entirely hidden fallback', () => {
    expect.hasAssertions();
    const hiddenOnly = sanitizeHtml(
      '<div style="visibility:hidden"><a href="https://hidden.invalid">Hidden</a><img src="cid:hidden" alt="Hidden alt"></div>',
    );
    expect(hiddenOnly).toMatchObject({
      renderable: false,
      contentIds: [],
      links: [],
      readable: { paragraphs: [], hidesImages: false },
    });
  });

  it('keeps hidden column tracks while excluding collapsed column cells', () => {
    expect.hasAssertions();
    const columns = sanitizeHtml(
      '<table><colgroup><col style="visibility:hidden"><col style="visibility:collapse"></colgroup><tr><td><img src="cid:kept-column"></td><td><img src="cid:collapsed-column"></td></tr></table>',
    );
    expect(columns.contentIds).toStrictEqual(['kept-column']);
    expect(columns.document).toContain('<col style="visibility: hidden">');
  });

  it('excludes inherited collapsed columns when a row group restores visibility', () => {
    expect.hasAssertions();
    const result = sanitizeHtml(
      '<div style="visibility:collapse"><table><colgroup><col><col style="visibility:initial"></colgroup><tbody style="visibility:visible"><tr><td><img src="cid:inherited-column"></td><td><img src="cid:restored-column"></td></tr></tbody></table></div>',
    );
    expect(result.contentIds).toStrictEqual(['restored-column']);
    expect(result.contentIdOccurrences).toStrictEqual(['restored-column']);
  });

  it('fetches only CID descendants whose visibility is restored on an explicit open', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({ at: Date.UTC(2020, 0, 1) });
    const observed = substitutePayload(gmail, id, {
      mimeType: 'multipart/related',
      parts: [
        textPart(
          'text/html',
          '<div style="visibility:hidden"><img src="cid:hidden"><span style="visibility:visible">Visible descendant<img src="cid:shown"></span></div>',
        ),
        imagePart('hidden-part', 'hidden'),
        imagePart('shown-part', 'shown'),
      ],
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await inbox.readMessage(id);
    expect(observed.images).toStrictEqual(['shown-part']);
    expect(inbox.messageBody(id)).toMatchObject({ kind: 'ready' });
  });

  it('normalizes large leading offsets without suppressing painted labels', () => {
    expect.hasAssertions();
    const visible = [
      'margin:0',
      'margin:0 0',
      'margin:0 0 -10000px',
      'margin:0 0 -10000px 0',
      'margin:0 -10000px 0 0',
      'margin-bottom:-10000px',
      'margin-right:-10000px',
      'margin:0 -10000px -10000px 0',
      'margin:-10000px 0 0;margin-top:0',
      'margin-top:-10000px;margin:0',
      'margin-left:-10000px;margin:0',
      'margin:0;margin-left:-10000px;margin:0 0 0',
      'margin-left:0;margin:-10000px 0;margin-top:0',
      'margin:-0000px',
      'margin:-10000e-9px',
      'margin-left:-10000px;margin:initial',
      'margin-top:-10000px;margin:unset',
      'margin:0 auto -10000px auto',
    ];
    const hidden = [
      'margin:0 0 0 -10000px',
      'margin:-10000px 0',
      'margin:0 -10000px',
      'margin-top:-10000px',
      'margin-left:-10000px',
      'margin:0;margin-top:-10000px',
      'margin-left:0;margin:0;margin-left:-10000px',
      'margin:0 0 0 -001000px',
    ];
    const anchor = (style: string, index: number) =>
      `<div style="${style}"><a href="https://phish.invalid/${index}">https://bank.invalid/${index}</a></div>`;
    const result = sanitizeHtml(
      [
        ...visible.map(anchor),
        ...hidden.map((style, index) => anchor(style, visible.length + index)),
        '<p><span style="margin-top:-10000px">Inline top margin</span></p>',
        '<p><span style="display:block;margin-top:-10000px">Block top margin</span></p>',
      ].join(''),
    );
    expect(result.links).toStrictEqual([
      ...visible.map((_, index) => ({
        href: `https://phish.invalid/${index}`,
        text: `https://bank.invalid/${index}`,
      })),
      ...hidden.map((_, index) => ({
        href: `https://phish.invalid/${visible.length + index}`,
        text: `https://bank.invalid/${visible.length + index}`,
      })),
    ]);
    for (const { href, text } of result.links) {
      expect(inspectLink(href, text)).toContain(linkWarnings.text);
    }
    const texts = result.readable.paragraphs.flat().map(({ text }) => text);
    expect(texts).toContain('Inline top margin');
    expect(texts).toContain('Block top margin');
  });

  it('inspects painted labels in directional and margin-inapplicable layouts', () => {
    expect.hasAssertions();
    const anchor = '<a href="https://phish.invalid">https://bank.invalid</a>';
    const visible = [
      `<div dir="rtl" style="margin-left:-10000px">${anchor}</div>`,
      `<div dir="rtl"><div style="margin-left:-10000px">${anchor}</div></div>`,
      `<div dir="rtl"><div dir="invalid" style="margin-left:-10000px">${anchor}</div></div>`,
      `<p><span style="margin-top:-10000px">${anchor}</span></p>`,
      `<div style="display:inline;margin-top:-10000px">${anchor}</div>`,
      `<table><tr style="margin-top:-10000px"><td style="margin-left:-10000px">${anchor}</td></tr></table>`,
      `<div style="display:table-cell;margin:-10000px">${anchor}</div>`,
      `<div dir="rtl" style="width:100px;margin-right:-10000px">${anchor}</div>`,
      `<div dir="rtl" style="width:100px;margin-left:-10000px">${anchor}</div>`,
      `<div dir="rtl"><span style="margin-left:-10000px">${anchor}</span></div>`,
      `<div dir="rtl" style="margin-right:-10000px">${anchor}</div>`,
      `<div dir="rtl"><div style="margin-right:-10000px">${anchor}</div></div>`,
      `<div style="margin:0 -10000px 0 0" dir="rtl">${anchor}</div>`,
    ];
    for (const html of visible) {
      const result = presentation({ version: 2, id: 'margin-label', html });
      expect(result.rich?.links).toStrictEqual([
        { href: 'https://phish.invalid', text: 'https://bank.invalid' },
      ]);
      expect(
        result.rich?.links.flatMap(({ href, text }) => inspectLink(href, text)),
      ).toContain(linkWarnings.text);
      expect(
        result.readable.paragraphs
          .flat()
          .map(({ text }) => text)
          .join(''),
      ).toContain('https://bank.invalid');
    }
    for (const html of [
      `<span style="display:block;margin-top:-10000px">${anchor}</span>`,
      `<div dir="auto" style="margin-left:-10000px">${anchor}</div>`,
    ]) {
      expect(sanitizeHtml(html).links).toStrictEqual([
        { href: 'https://phish.invalid', text: 'https://bank.invalid' },
      ]);
    }
    const reset = sanitizeHtml(
      `<div dir="rtl" style="margin-right:-10000px">Hidden</div><div style="margin-right:-10000px">${anchor}</div>`,
    );
    expect(reset.links[0]?.text).toBe('https://bank.invalid');
    const masked = sanitizeHtml(
      '<a href="https://phish.invalid">https://bank.invalid<span dir="auto" style="margin-left:-10000px"> masking text</span></a>',
    );
    expect(masked.document).not.toContain('dir="auto"');
    expect(masked.links[0]?.text).toBe('https://bank.invalid masking text');
    expect(masked.document).toContain('margin-left: 0');
  });

  it('inspects labels according to their block indent and inline baseline layout', () => {
    expect.hasAssertions();
    const anchor = '<a href="https://phish.invalid">https://bank.invalid</a>';
    for (const html of [
      `<span style="text-indent:-10000px">${anchor}</span>`,
      `<span style="display:inline-block;margin-top:-10000px">${anchor}</span>`,
      `<span style="display:inline-block;margin-top:-10000px;margin-bottom:-10000px">${anchor}</span>`,
      `<custom style="display:contents;margin-top:-10000px">${anchor}</custom>`,
      `<div style="text-indent:-10000px"><div style="text-indent:0">${anchor}</div></div>`,
      '<a href="https://phish.invalid"><img src="https://image.invalid" alt="https://bank.invalid" style="margin:-10000px;text-indent:-10000px"></a>',
    ]) {
      const result = presentation({ version: 2, id: 'layout-label', html });
      expect(result.rich?.links).toStrictEqual([
        { href: 'https://phish.invalid', text: 'https://bank.invalid' },
      ]);
      expect(
        result.rich?.links.flatMap(({ href, text }) => inspectLink(href, text)),
      ).toContain(linkWarnings.text);
      expect(
        result.readable.paragraphs
          .flat()
          .map(({ text }) => text)
          .join(''),
      ).toContain('https://bank.invalid');
    }
    for (const html of [
      `<span style="display:inline-block;text-indent:-10000px">${anchor}</span>`,
      `<span style="text-indent:-10000px"><div>${anchor}</div></span>`,
      `<div style="text-indent:-10000px"><span style="text-indent:0">${anchor}</span></div>`,
    ]) {
      expect(sanitizeHtml(html).links).toStrictEqual([
        { href: 'https://phish.invalid', text: 'https://bank.invalid' },
      ]);
    }
  });

  it('keeps illegibly small text out of link labels and resolves offsets by unit', () => {
    expect.hasAssertions();
    const nested = (depth: number, inner: string) =>
      `${'<small>'.repeat(depth)}${inner}${'</small>'.repeat(depth)}`;
    const masked = [
      '<span style="font-size:0.01px"> masking text</span>',
      '<span style="font-size:0.001em"> masking text</span>',
      '<span style="font-size:0.1rem"> masking text</span>',
      nested(9, ' masking text'),
      '<span style="font-size:25%"> masking text</span>',
      '<span style="font-size:4px"><img src="https://image.invalid" alt=" masking text"></span>',
    ];
    const labelled = [
      '<span style="font-size:1000px"><span style="font-size:0.1em">https://bank.invalid</span></span>',
      '<span style="font-size:4px">https://bank.invalid</span>',
      '<span style="font-size:1vw">https://bank.invalid</span>',
      '<span style="font-size:.5ex">https://bank.invalid</span>',
      '<span style="font-size:8px"><span style="font-size:50%">https://bank.invalid</span></span>',
      '<img src="https://image.invalid" style="font-size:.01px" alt="https://bank.invalid">',
    ];
    const offCanvas = ['text-indent:-999px', 'text-indent:-100em'];
    const result = sanitizeHtml(
      [
        ...masked.map(
          (mask, index) =>
            `<p><a href="https://phish.invalid/${index}">https://bank.invalid${mask}</a></p>`,
        ),
        ...labelled.map(
          (label, index) =>
            `<p><a href="https://phish.invalid/${masked.length + index}">${label}</a></p>`,
        ),
        ...offCanvas.map(
          (style) =>
            `<div style="${style}"><a href="https://phish.invalid/indent">https://bank.invalid</a></div>`,
        ),
        '<p style="text-indent:-2em"><a href="https://phish.invalid/hanging">https://bank.invalid</a></p>',
      ].join(''),
    );
    expect(result.links.map(({ text }) => text)).toStrictEqual([
      ...masked.map(() => 'https://bank.invalid'),
      ...labelled.map(() => 'https://bank.invalid'),
      ...offCanvas.map(() => 'https://bank.invalid'),
      'https://bank.invalid',
    ]);
    expect(
      result.links
        .filter(({ text }) => text !== '')
        .map(({ href, text }) => inspectLink(href, text)),
    ).toStrictEqual(
      [...masked, ...labelled, ...offCanvas, 'hanging'].map(() => [
        linkWarnings.text,
      ]),
    );
  });

  it('inspects normalized fonts, placeholders and compensated or wrapped offsets', () => {
    expect.hasAssertions();
    const address = 'https://bank.invalid';
    const anchor = `<a href="https://phish.invalid">${address}</a>`;
    const variants = [
      `<div style="font-size:3px"><h1 style="font-size:revert">${anchor}</h1></div>`,
      `<div style="padding-left:400px"><div style="text-indent:-320px">${anchor}</div></div>`,
      `<div style="padding-left:400px"><div style="margin-left:-320px">${anchor}</div></div>`,
      `<div style="width:600px;text-indent:-60%">${anchor}</div>`,
      `<div style="width:80px;text-indent:-320px">${anchor}</div>`,
      `<div dir="rtl" style="margin-left:-320px">${anchor}</div>`,
      `<div style="font-size:0"><a href="https://phish.invalid">Hidden<img src="https://image.invalid" style="font-size:16px" alt="${address}"></a></div>`,
    ];
    for (const html of variants.slice(0, -1)) {
      const result = sanitizeHtml(html);
      expect(result.links).toStrictEqual([
        { href: 'https://phish.invalid', text: address },
      ]);
      expect(
        inspectLink(result.links[0]!.href, result.links[0]!.text),
      ).toContain(linkWarnings.text);
    }
    expect(sanitizeHtml(variants.at(-1)!).links[0]?.text).toBe('');
    const dynamic = sanitizeHtml(
      `<span style="font-size:.31em">${anchor}</span>`,
    );
    expect(dynamic.document).toContain('font-size: max(4px, .31em)');
    expect(dynamic.links[0]?.text).toBe(address);
  });

  it('splits inline styles as WebKit does around quoted semicolons', () => {
    expect.hasAssertions();
    const styles = [
      'font-family:"foo; font-size:16px"; font-size:0',
      "font-family:'foo; font-size:16px'; font-size:0",
      'font-family:"foo; font-size:0',
      'font-family:"foo\n; font-size:0',
      'font-family:"foo\r; font-size:0',
      'font-family:"foo\f; font-size:0',
      'font-family:[foo); font-size:0',
      'font-family:(foo]; font-size:0',
      'font-family:[foo)]; font-size:0',
      'font-family:(foo]); font-size:0',
    ];
    const result = sanitizeHtml(
      styles
        .map(
          (style, index) =>
            `<p><a href="https://phish.invalid/${index}"><span style="${style.replaceAll('"', '&quot;')}">https://bank.invalid</span></a></p>`,
        )
        .join(''),
    );
    // A closed string keeps its semicolon and the zero size after it applies; an unterminated
    // string swallows the rest, and a broken one drops only its own declaration.
    expect(result.links.map(({ text }) => text)).toStrictEqual([
      '',
      '',
      'https://bank.invalid',
      '',
      '',
      '',
      'https://bank.invalid',
      'https://bank.invalid',
      '',
      '',
    ]);
    expect(
      result.links.map(({ href, text }) => inspectLink(href, text)),
    ).toStrictEqual([
      [],
      [],
      [linkWarnings.text],
      [],
      [],
      [],
      [linkWarnings.text],
      [linkWarnings.text],
      [],
      [],
    ]);
    expect(result.document).not.toMatch(
      /font-family: (?:&quot;|')foo; font-size: 0/u,
    );
  });

  it('normalizes tall spacers so text after them renders beside the link label', () => {
    expect.hasAssertions();
    const spacers = [
      'display:block;height:10000px',
      'display:block;min-height:10000px',
      'display:block;margin-bottom:10000px',
      'display:inline-block;height:625em',
      'display:block;height:320px',
      'display:block;min-height:100%',
      'display:block;margin-bottom:-10000px',
    ];
    const cells = ['td', 'th'].map(
      (tag) =>
        `<a href="https://phish.invalid/cell">https://bank.invalid<table><tr><${tag} height="10000" style="height:320px"></${tag}></tr></table> masking</a>`,
    );
    const result = sanitizeHtml(
      [
        ...spacers.map(
          (style, index) =>
            `<p><a href="https://phish.invalid/${index}">https://bank.invalid<span style="${style}"></span> masking</a></p>`,
        ),
        ...cells,
        '<p style="height:200px;min-height:120px;margin-bottom:40px">Sized control</p>',
        '<table><tr><td height="200">Cell control</td></tr></table>',
      ].join(''),
    );
    expect(result.links.map(({ text }) => text)).toStrictEqual(
      [...spacers, ...cells].map(() => 'https://bank.invalid masking'),
    );
    expect(result.document).not.toMatch(/10000px|625em/u);
    expect(result.document).not.toContain('height="10000"');
    expect(result.document).toContain('<td height="200">Cell control</td>');
    expect(result.document).toContain(
      'height: 200px; min-height: 120px; margin-bottom: 40px',
    );
  });

  it('normalizes large spacing so masking text stays visible and inspected', () => {
    expect.hasAssertions();
    const masks = [
      'display:inline-block;margin-left:10000px',
      'display:inline-block;margin:0 0 0 100%',
      'display:inline-block;padding-left:10000px',
      'display:inline-block;padding:0 0 0 625em',
      'display:block;padding-top:10000px',
      'display:inline-block;padding-bottom:10000px',
      'display:inline-block;border-left:10000px solid',
      'display:block;border-top:10000px solid',
      'display:inline-block;border-bottom:10000px solid',
      'display:block;border-top-style:solid;border-top-width:10000px',
      'display:inline-block;border-bottom-style:solid;border-bottom-width:10000px',
      'display:table;border-spacing:10000px',
      'display:inline-block;vertical-align:-10000px',
      'display:block;line-height:10000px',
      'display:block;line-height:1000',
      'display:inline-block;letter-spacing:10000px;white-space:nowrap',
      'display:block;text-indent:10000px',
      'display:block;margin-top:10000px',
    ];
    const result = sanitizeHtml(
      [
        ...masks.map(
          (style, index) =>
            `<p><a href="https://phish.invalid/${index}">https://bank.invalid<span style="${style}"> masking text</span></a></p>`,
        ),
        '<p style="margin-left:40px;padding-left:20px;text-indent:2em">Indented control</p>',
      ].join(''),
    );
    expect(result.links.map(({ text }) => text)).toStrictEqual(
      masks.map(() => 'https://bank.invalid masking text'),
    );
    expect(result.document).not.toMatch(/10000px|625em/u);
    // A later longhand overrides the shorthand's large leading margin.
    expect(result.document).toContain('margin: 0 0 0 100%; margin-left: 0');
    expect(result.document).toContain(
      'margin-left: 40px; padding-left: 20px; text-indent: 2em',
    );
    expect(
      sanitizeHtml(
        '<span style="letter-spacing:-.1em;vertical-align:-20%;line-height:1.5;width:200px">Small spacing</span>',
      ).document,
    ).toContain(
      'letter-spacing: -.1em; vertical-align: -20%; line-height: 1.5; width: 200px',
    );
  });

  it('bounds oversized aligned text boxes without discarding desktop email widths', () => {
    expect.hasAssertions();
    const result = sanitizeHtml(
      '<a href="https://phish.invalid">https://bank.invalid<span style="display:inline-block;width:10000px;text-align:right"> masking text</span></a>' +
        '<span style="display:inline-block;min-width:10000px;text-align:center">Centered</span>' +
        '<div style="width:600px">Desktop width</div>',
    );
    expect(result.links[0]?.text).toBe('https://bank.invalid masking text');
    expect(result.document).toContain('width: min(100%, 10000px)');
    expect(result.document).toContain('min-width: min(100%, 10000px)');
    expect(result.document).toContain('width: min(100%, 600px)');
  });

  it('collects only the unique Content-IDs resolution may attempt, counting every occurrence', () => {
    expect.hasAssertions();
    const ids = Array.from({ length: 5000 }, (_, index) => `image-${index}`);
    const result = sanitizeHtml(
      [...ids, 'image-0']
        .map((contentId) => `<img src="cid:${contentId}" alt="">`)
        .join(''),
    );
    expect(result.contentIds).toStrictEqual(ids.slice(0, 20));
    expect(result.contentIdOccurrences).toHaveLength(5001);
    expect(result.document.match(/class="blocked-image"/gu)).toHaveLength(5001);
  });

  it('offers at most the message link limit as links, keeping later ones as text', () => {
    expect.hasAssertions();
    const anchors = Array.from(
      { length: messageLinkLimit + 50 },
      (_, index) =>
        `<p><a href="https://example.invalid/${index}">Link ${index}</a></p>`,
    );
    const result = sanitizeHtml(anchors.join(''));
    expect(result.document.match(/about:blank#unwired-link-/gu)).toHaveLength(
      messageLinkLimit,
    );
    const spans = result.readable.paragraphs.flat();
    const plain = readableText(
      Array.from(
        { length: messageLinkLimit + 50 },
        (_, index) => `https://example.invalid/${index}`,
      ).join('\n\n'),
    );
    const offered = presentation({
      version: 2,
      id: 'bounded-links',
      html: anchors.join(''),
    });
    expect({
      richLinks: result.links.length,
      readableLinks: spans.filter(({ href }) => href !== undefined).length,
      lastSpan: spans.at(-1),
      plainLinks: plain.paragraphs
        .flat()
        .filter(({ href }) => href !== undefined).length,
      offeredLinks: offered.rich?.links.length,
      offeredReadableLinks: offered.readable.paragraphs
        .flat()
        .filter(({ href }) => href !== undefined).length,
      offeredLastSpan: offered.readable.paragraphs.flat().at(-1),
    }).toStrictEqual({
      richLinks: messageLinkLimit,
      readableLinks: messageLinkLimit,
      lastSpan: { text: 'Link 249' },
      plainLinks: messageLinkLimit,
      offeredLinks: messageLinkLimit,
      offeredReadableLinks: messageLinkLimit,
      offeredLastSpan: { text: 'Link 249' },
    });
  });

  it('caps fallback link controls even when one anchor crosses many paragraphs', () => {
    expect.hasAssertions();
    const offered = presentation({
      version: 2,
      id: 'split-link',
      html: `<a href="https://example.invalid">${'<p>Label</p>'.repeat(500)}</a>`,
    });
    expect(offered.rich?.links).toHaveLength(1);
    const spans = offered.readable.paragraphs.flat();
    expect(spans.filter(({ href }) => href !== undefined)).toHaveLength(
      messageLinkLimit,
    );
    expect(spans).toHaveLength(500);
    expect(spans.at(-1)).toStrictEqual({ text: 'Label' });
  });

  it('counts only visible anchors and readable spans at the link limit', () => {
    expect.hasAssertions();
    const result = sanitizeHtml(
      [
        '<a href="https://hidden.invalid" style="visibility:hidden">Hidden</a>'.repeat(
          250,
        ),
        '<a href="https://visible.invalid" style="visibility:hidden"><span style="visibility:visible">Restored</span></a>',
        Array.from(
          { length: 200 },
          (_, index) =>
            `<a href="https://example.invalid/${index}">Visible ${index}</a>`,
        ).join(''),
      ].join(''),
    );
    expect(result.links).toHaveLength(messageLinkLimit);
    expect(result.links.at(0)).toStrictEqual({
      href: 'https://visible.invalid',
      text: 'Restored',
    });
    expect(result.links.at(-1)?.text).toBe('Visible 198');
    expect(
      result.readable.paragraphs
        .flat()
        .filter(({ href }) => href !== undefined),
    ).toHaveLength(messageLinkLimit);
    expect(result.readable.paragraphs.flat().at(-1)).toStrictEqual({
      text: 'Visible 199',
    });
  });

  it('keeps only a few consecutive breaks so text after them stays beside the link label', () => {
    expect.hasAssertions();
    const result = sanitizeHtml(
      [
        `<div><a href="https://phish.invalid/0">https://bank.invalid${'<br>'.repeat(300)}not a URL</a></div>`,
        `<div><a href="https://phish.invalid/1">https://bank.invalid${'<br><hr>'.repeat(150)}not a URL</a></div>`,
        '<p>One<br><br>Two</p>',
      ].join(''),
    );
    expect(result.document.match(/<br\b|<hr\b/gu)).toHaveLength(4 + 4 + 2);
    expect(result.links.map(({ text }) => text)).toStrictEqual([
      'https://bank.invalidnot a URL',
      'https://bank.invalidnot a URL',
    ]);
  });

  it('bounds linked spacer runs across hidden text, Unicode and preformatted newlines', () => {
    expect.hasAssertions();
    for (const gap of [
      '<br>\u200B'.repeat(300),
      '<br><span style="visibility:hidden">Hidden</span>'.repeat(300),
      `<pre>${'\n'.repeat(300)}</pre>`,
      `<span style="white-space:pre">${'\n'.repeat(300)}</span>`,
    ]) {
      const result = sanitizeHtml(
        `<a href="https://phish.invalid">https://bank.invalid${gap}not a URL</a>`,
      );
      const body = result.document.slice(
        result.document.indexOf('<body>') + 6,
        result.document.lastIndexOf('</body>'),
      );
      expect(body.match(/<br\b|<hr\b|\n/gu)).toHaveLength(4);
      expect(result.links).toHaveLength(1);
      expect(result.links[0]?.href).toBe('https://phish.invalid');
      expect(result.links[0]?.text.replaceAll(/[\s\p{Cf}]/gu, '')).toBe(
        'https://bank.invalidnotaURL',
      );
      expect(
        result.readable.paragraphs
          .flat()
          .map(({ text }) => text)
          .join(''),
      ).toContain('not a URL');
    }
    const ordinary = sanitizeHtml(
      '<pre>One\n\nTwo</pre><span style="white-space:pre">Three\n\nFour</span>',
    );
    expect(ordinary.document).toContain('One\n\nTwo');
    expect(ordinary.document).toContain('Three\n\nFour');
    const meaningful = sanitizeHtml(
      `<a href="https://example.invalid">One${'<br>'.repeat(4)}Two${'<br>'.repeat(4)}Three</a>`,
    );
    expect(meaningful.document.match(/<br>/gu)).toHaveLength(8);
  });

  it('removes empty linked spacer boxes while retaining styled visible descendants', () => {
    expect.hasAssertions();
    for (const gap of [
      '<p></p>'.repeat(300),
      '<div style="padding:20px"></div>'.repeat(100),
      '<div style="height:200px"></div>'.repeat(100),
      '<div style="margin:200px 0"></div>'.repeat(100),
    ]) {
      const result = sanitizeHtml(
        `<a href="https://phish.invalid">https://bank.invalid${gap}not a URL</a>`,
      );
      expect(
        result.document.match(/display: contents/gu)?.length,
      ).toBeGreaterThanOrEqual(100);
      expect(result.links).toStrictEqual([
        {
          href: 'https://phish.invalid',
          text: 'https://bank.invalidnot a URL',
        },
      ]);
    }
    const restored = sanitizeHtml(
      '<a href="https://phish.invalid"><div style="visibility:hidden;padding:20px">Hidden<span style="visibility:visible">Visible</span></div></a>',
    );
    expect(restored.links).toStrictEqual([
      { href: 'https://phish.invalid', text: 'Visible' },
    ]);
    expect(restored.document).toContain('visibility: hidden; padding: 20px');
    expect(restored.document).toContain('visibility: visible');
    const ordinary = sanitizeHtml(
      '<div style="padding:20px">Ordinary content</div>',
    );
    expect(ordinary.document).toContain(
      '<div style="padding: 20px">Ordinary content</div>',
    );
  });

  it('removes hidden linked image boxes without fetching them or changing ordinary hidden geometry', () => {
    expect.hasAssertions();
    const image =
      '<img style="visibility:hidden;width:20px;height:200px" src="cid:hidden">';
    const result = sanitizeHtml(
      `<a href="https://phish.invalid">https://bank.invalid${image.repeat(100)}not a URL</a>`,
    );
    expect(result.document.match(/display: none/gu)).toHaveLength(100);
    expect({
      links: result.links,
      contentIds: result.contentIds,
      hidesImages: result.readable.hidesImages,
    }).toStrictEqual({
      links: [
        {
          href: 'https://phish.invalid',
          text: 'https://bank.invalidnot a URL',
        },
      ],
      contentIds: [],
      hidesImages: false,
    });
    const ordinary = sanitizeHtml(`${image}<p>Visible text</p>`);
    expect(ordinary.document).toContain(
      '<img style="visibility: hidden; width: 20px; height: 200px">',
    );
    const visible = sanitizeHtml(
      '<a href="https://example.invalid"><div style="padding:20px"><img src="cid:missing" alt="Photo"></div></a>',
    );
    expect(visible.document).toContain(
      '<div style="padding: 20px"><span class="blocked-image"',
    );
    expect(visible.readable.hidesImages).toBe(true);
  });

  it('bounds a break run by the height its lines add, not only by its count', () => {
    expect.hasAssertions();
    const breaks = (style: string, gap = '<br>'.repeat(10)) => {
      const { document } = sanitizeHtml(
        `<div style="${style}"><a href="https://phish.invalid">https://bank.invalid${gap}not a URL</a></div>`,
      );
      const body = document.slice(
        document.indexOf('<body>') + 6,
        document.lastIndexOf('</body>'),
      );
      return body.split(/<br\b|\n/gu).length - 1;
    };
    // A 200-pixel line already exceeds the run's height, a 60-pixel font's lines leave room
    // for one break, and ordinary text keeps the four-break count.
    expect(
      ['line-height:200px', 'font-size:60px', 'line-height:normal'].map(
        (style) => breaks(style),
      ),
    ).toStrictEqual([0, 1, 4]);
    // A short child still occupies the tall ancestor's line boxes, including when an empty
    // wrapper loses its own box. It cannot make the spacer charge artificially cheap.
    expect([
      breaks('line-height:200px', '<br style="line-height:0">'.repeat(10)),
      breaks('font-size:60px', '<br style="font-size:4px">'.repeat(10)),
      breaks(
        'line-height:200px',
        `<span style="line-height:0;white-space:pre">${'\n'.repeat(10)}</span>`,
      ),
    ]).toStrictEqual([0, 1, 0]);
    // Rules retain a divider but use ordinary vertical geometry. Put longhands before
    // shorthands too, so reserialization cannot reactivate the sender's taller box.
    const rules = sanitizeHtml(
      `<a href="https://phish.invalid">https://bank.invalid${'<hr style="height:200px;min-height:200px;padding-top:100px;padding:100px;margin-top:200px;margin:200px;border-top-width:200px;border-width:200px">'.repeat(10)}not a URL</a>`,
    );
    expect(rules.document.match(/<hr\b/gu)).toHaveLength(4);
    expect(rules.document).toContain(
      'height: 0; min-height: 0; max-height: 0; padding-top: 0; padding-bottom: 0; margin-top: .5em; margin-bottom: .5em; border-top-width: 1px; border-bottom-width: 1px',
    );
    expect(rules.links[0]?.text).toBe('https://bank.invalidnot a URL');
  });

  it('keeps emitted line heights within the break model, including sender normal font metrics', () => {
    expect.hasAssertions();
    // A CSS expression can paint tall lines while the model substitutes the parent.
    for (const value of ['calc(100px + 100px)', '25vw', '20ch']) {
      expect(
        sanitizeHtml(`<div style="line-height:${value}">One<br>Two</div>`)
          .document,
      ).not.toContain(`line-height: ${value}`);
    }
    // Normal is not a known multiplier for arbitrary retained fonts. Explicit factors
    // still work, and the font and text remain even when spacer breaks are omitted.
    const document = (style: string) =>
      sanitizeHtml(
        `<a href="https://phish.invalid" style="${style}">bank.invalid${'<br>'.repeat(10)}not a URL</a>`,
      ).document;
    const unknown = document(
      'font-size:44px;font-family:Zapfino;line-height:normal',
    );
    expect(unknown).not.toContain('<br');
    expect(unknown).toContain('font-family: Zapfino');
    expect(
      document('font-size:44px;font-family:Zapfino;line-height:1.2').match(
        /<br\b/gu,
      ),
    ).toHaveLength(3);
  });

  it('resolves duplicate declarations by importance and validity, as the cascade does', () => {
    expect.hasAssertions();
    const result = sanitizeHtml(
      [
        '<img src="cid:important" style="display:none!important;display:block">',
        '<img src="cid:rejected" style="display:none;display:bogus">',
        '<img src="cid:later-important" style="display:none!important;display:block !important">',
        '<img src="cid:later" style="display:none;display:block">',
        '<img src="cid:kept" style="display:block!important;display:none">',
        '<img src="cid:faded" style="opacity:0!important;opacity:1">',
        '<img src="cid:veiled" style="visibility:hidden!important;visibility:visible">',
        '<img src="cid:flex" style="display:none;display:flex">',
        '<img src="cid:two-keyword" style="display:none;display:inline flow-root">',
        '<img src="cid:invalid-pair" style="display:none;display:block block">',
        '<img src="cid:invalid-inside" style="display:none;display:flex grid!important">',
        '<img src="cid:unsupported-run-in" style="display:none;display:run-in">',
        '<img src="cid:webkit-flex" style="display:none;display:-webkit-flex">',
        '<img src="cid:exponent" style="opacity:0;opacity:1e0">',
        '<img src="cid:calculated" style="opacity:0;opacity:calc(1)">',
        '<img src="cid:minimum" style="opacity:0;opacity:min(1, .5)">',
        '<img src="cid:invalid-calculation" style="opacity:0;opacity:calc(bogus)!important">',
        '<img src="cid:calculated-zero" style="opacity:1;opacity:calc(1 - 1)">',
        '<img src="cid:invalid-important-size" style="width:bogus!important;width:0">',
        '<img src="cid:percentage-reset" style="opacity:0%;opacity:100%">',
        '<img src="cid:opacity-reset" style="opacity:0!important;opacity:initial!important">',
        '<img src="cid:non-css-keyword" style="display:none;display:li\u017Ft-item">',
        '<img src="cid:non-css-reset" style="opacity:0;opacity:un\u017Fet">',
        '<img src="cid:non-css-space" style="display:none;display:inline\u00A0flex">',
        '<img src="cid:non-css-trailing" style="display:none;display:block\u00A0">',
        '<img src="cid:non-css-important" style="display:none;display:block!\u00A0important">',
        '<img src="cid:invalid-math-space" style="opacity:0;opacity:calc(0\u00A0+\u00A01)">',
        '<img src="cid:invalid-math-type" style="opacity:0;opacity:calc(50% + .5)">',
        '<img src="cid:invalid-max" width="100" height="100" style="max-width:auto!important;max-width:0">',
        '<img src="cid:max-reset" width="100" height="100" style="max-width:0;max-width:none">',
        '<img src="cid:typed-product" style="opacity:0;opacity:calc(50% * 50% / 100%)">',
        '<img src="cid:clamped" style="opacity:0;opacity:clamp(none,.5,1)">',
        '<img src="cid:math-zero" style="opacity:1;opacity:calc(min(1, .5) - .5)">',
        '<a href="https://phish.invalid"><span style="font-size:0 !important;font-size:16px">https://bank.invalid</span></a>',
      ].join(''),
    );
    expect(result.contentIds).toStrictEqual([
      'later-important',
      'later',
      'kept',
      'flex',
      'two-keyword',
      'webkit-flex',
      'exponent',
      'calculated',
      'minimum',
      'percentage-reset',
      'opacity-reset',
      'max-reset',
      'typed-product',
      'clamped',
    ]);
    expect(result.links).toStrictEqual([
      { href: 'https://phish.invalid', text: '' },
    ]);
    const sizes = sanitizeHtml(
      [
        '<a href="https://phish.invalid"><span style="font-size:bogus!important;font-size:0">https://bank.invalid</span></a>',
        '<a href="https://phish.invalid"><span style="font-size:-1px!important;font-size:0">https://bank.invalid</span></a>',
        '<a href="https://phish.invalid"><span style="font-size:0;font-size:1vw">https://bank.invalid</span></a>',
        '<a href="https://phish.invalid"><span style="font-size:0;font-size:1cap">https://bank.invalid</span></a>',
        '<a href="https://phish.invalid"><span style="font-size:0;font-size:1svw">https://bank.invalid</span></a>',
      ].join(''),
    );
    expect(sizes.links.map((link) => link.text)).toStrictEqual([
      '',
      '',
      'https://bank.invalid',
      'https://bank.invalid',
      'https://bank.invalid',
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
