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
    expect(result.document).toContain('<hr style="visibility: hidden">');
    expect(result.document).toContain(
      '<div style="visibility: hidden"><hr style="visibility: visible"><br style="visibility: visible"></div>',
    );
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

  it('suppresses text only for margins that move its own box off canvas', () => {
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
        text: '',
      })),
    ]);
    for (const { href, text } of result.links.slice(0, visible.length)) {
      expect(inspectLink(href, text)).toContain(linkWarnings.text);
    }
    const texts = result.readable.paragraphs.flat().map(({ text }) => text);
    expect(texts).toContain('Inline top margin');
    expect(texts).not.toContain('Block top margin');
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
        { href: 'https://phish.invalid', text: '' },
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
    expect(masked.links[0]?.text).toBe('https://bank.invalid');
    expect(
      masked.links.flatMap(({ href, text }) => inspectLink(href, text)),
    ).toContain(linkWarnings.text);
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
        { href: 'https://phish.invalid', text: '' },
      ]);
    }
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
