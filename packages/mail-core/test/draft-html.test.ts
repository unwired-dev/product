import type { Draft } from '@private-email/mail-core/drafts';
import type {
  Block,
  SemanticDocument,
} from '@private-email/mail-core/semantic-document';

import { documentFromHtml } from '@private-email/mail-core/draft-html';
import { outgoingMessage } from '@private-email/mail-core/outgoing-message';
import {
  BlockKindSchema,
  MarkSchema,
} from '@private-email/mail-core/semantic-document';
import PostalMime from 'postal-mime';

const sentHtml = async (body: SemanticDocument) => {
  const draft: Draft = {
    id: 'd1',
    connection: 'connection-alex',
    from: 'alex@example.invalid',
    to: [{ address: 'sam@example.invalid' }],
    cc: [],
    bcc: [],
    subject: 'Hello',
    body,
    updatedAt: 0,
  };
  const message = outgoingMessage(draft, { date: 0, boundary: 'b' });
  const raw = message.segments
    .map((segment) => ('text' in segment ? segment.text : ''))
    .join('');
  const parsed = await PostalMime.parse(raw);
  return parsed.html ?? '';
};

const formats = [
  {},
  { link: 'https://example.invalid' },
  { color: '#d1242f' },
  { background: '#fff8c5' },
  { font: '"Times New Roman", serif' },
  { size: 20 },
  {
    link: 'mailto:sam@example.invalid',
    color: '#0969da',
    background: '#fff8c5',
    font: 'Arial',
    size: 14.5,
  },
];
const markSets = Array.from(
  { length: 2 ** MarkSchema.literals.length },
  (_, bits) =>
    MarkSchema.literals.filter(
      (_mark, index) => Math.floor(bits / 2 ** index) % 2 === 1,
    ),
);
// Each span differs from its neighbours, so none merge on the way back.
const spans: Block['spans'] = formats.flatMap((format, index) =>
  markSets.map(([first, ...rest], set) => ({
    text: `f${index}m${set}`,
    ...(first === undefined ? {} : { marks: [first, ...rest] }),
    ...format,
  })),
);
// Code alignment is not sent.
const combinations: readonly SemanticDocument[] = BlockKindSchema.literals.map(
  (kind) => [
    kind === 'code' ? { kind, spans } : { kind, spans, align: 'center' },
  ],
);

describe('a Semantic Message Document from Draft HTML', () => {
  it('reads back every block kind, mark, link, alignment, color and font that outgoing mail writes', async () => {
    expect.hasAssertions();
    const document: SemanticDocument = [
      { kind: 'heading1', spans: [{ text: 'Menu' }], align: 'center' },
      { kind: 'heading2', spans: [{ text: 'Starters' }] },
      { kind: 'heading3', spans: [], align: 'right' },
      {
        kind: 'paragraph',
        spans: [
          { text: 'Plain, ' },
          {
            text: 'all marks',
            marks: ['bold', 'italic', 'underline', 'strikethrough', 'code'],
            font: 'Arial',
          },
          { text: ' and ' },
          {
            text: 'a & b < c',
            link: 'https://example.invalid/plan?a=1&b=2',
            marks: ['bold'],
            color: '#d1242f',
          },
          { text: ' then ' },
          {
            text: 'painted',
            color: '#0969da',
            background: '#fff8c5',
            font: '"Times New Roman", serif',
            size: 14.5,
          },
          { text: 'named', font: '"Family,Inc.", serif' },
        ],
        align: 'justify',
      },
      { kind: 'paragraph', spans: [] },
      { kind: 'bulleted', spans: [{ text: 'One' }] },
      { kind: 'bulleted', spans: [], align: 'center' },
      {
        kind: 'numbered',
        spans: [{ text: 'First', link: 'mailto:sam@example.invalid' }],
      },
      { kind: 'numbered', spans: [{ text: 'Second', marks: ['italic'] }] },
      {
        kind: 'quote',
        spans: [{ text: 'Quoted', font: 'Menlo' }],
        align: 'right',
      },
      { kind: 'quote', spans: [] },
      { kind: 'code', spans: [{ text: '  indented  code' }] },
      { kind: 'code', spans: [] },
      { kind: 'code', spans: [{ text: 'tel', link: 'tel:+420123456789' }] },
      { kind: 'paragraph', spans: [{ text: 'Last' }] },
    ];

    expect(documentFromHtml(await sentHtml(document))).toStrictEqual({
      document,
    });
  });

  it('reads back every combination of marks, link, colors and font in every block kind', async () => {
    expect.hasAssertions();
    for (const document of combinations) {
      expect(documentFromHtml(await sentHtml(document))).toStrictEqual({
        document,
      });
    }
  });

  it('reads a Gmail Draft', () => {
    expect.hasAssertions();

    const html =
      '<div dir="ltr"><div>Hi <b>Sam</b>,</div><div><br></div>' +
      '<div style="text-align:center"><font color="#ff0000" face="arial, sans-serif" size="4">Big red</font></div>' +
      '<div><span style="background-color:rgb(255,255,0)">marked</span> <i>and</i> <u>more</u> <strike>gone</strike></div>' +
      '<ul><li style="margin-left:15px">Item</li></ul>' +
      '<blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex">Quote</blockquote>' +
      '<div><font face="monospace">code</font> <a href="https://example.invalid">link</a></div></div>';

    expect(documentFromHtml(html)).toStrictEqual({
      document: [
        {
          kind: 'paragraph',
          spans: [
            { text: 'Hi ' },
            { text: 'Sam', marks: ['bold'] },
            { text: ',' },
          ],
        },
        { kind: 'paragraph', spans: [] },
        {
          kind: 'paragraph',
          spans: [
            {
              text: 'Big red',
              color: '#ff0000',
              font: 'arial, sans-serif',
              size: 18,
            },
          ],
          align: 'center',
        },
        {
          kind: 'paragraph',
          spans: [
            { text: 'marked', background: '#ffff00' },
            { text: ' ' },
            { text: 'and', marks: ['italic'] },
            { text: ' ' },
            { text: 'more', marks: ['underline'] },
            { text: ' ' },
            { text: 'gone', marks: ['strikethrough'] },
          ],
        },
        { kind: 'bulleted', spans: [{ text: 'Item' }] },
        { kind: 'quote', spans: [{ text: 'Quote' }] },
        {
          kind: 'paragraph',
          spans: [
            { text: 'code', font: 'monospace' },
            { text: ' ' },
            { text: 'link', link: 'https://example.invalid' },
          ],
        },
      ],
    });
  });

  it('keeps noncollapsing whitespace, empty code blocks and exponential font sizes through outgoing mail', async () => {
    expect.hasAssertions();
    const document: SemanticDocument = [
      { kind: 'paragraph', spans: [{ text: '\u00A0\u2003' }] },
      { kind: 'code', spans: [] },
      { kind: 'paragraph', spans: [{ text: 'small', size: 1e-7 }] },
    ];
    expect(documentFromHtml(await sentHtml(document))).toStrictEqual({
      document,
    });
  });

  it('reports rendering attributes and styles on line breaks instead of silently changing them', () => {
    expect.hasAssertions();
    for (const [html, unsupported] of [
      ['<ol reversed><li>one</li><li>two</li></ol>', ['reversed']],
      ['<ul><li>one<br>continuation</li></ul>', ['li']],
      ['<ol><li><p>one</p><p>continuation</p></li></ol>', ['li']],
      ['<body bgcolor="#000000"><p>dark</p></body>', ['bgcolor']],
      ['<p>a<br style="display:none">b</p>', ['display']],
      ['<p>a<br clear="all">b</p>', ['clear']],
      ['<p popover>hidden</p>', ['popover']],
      ['<font size="+1">relative</font>', ['size']],
      ['<p style="font-weight:500">medium</p>', ['font-weight']],
      ['<p style="font-weight:800">heavy</p>', ['font-weight']],
      ['<p style="font-weight:0x190">invalid</p>', ['font-weight']],
      ['<p style="color:rgb(1\u00A0 2 3)">invalid</p>', ['color']],
      ['<p style="color:rgb(1,2 3)">invalid</p>', ['color']],
      ['<p style="color:rgb(1,2,3 / 1)">invalid</p>', ['color']],
      ['<p style="font-style:oblique">slanted</p>', ['font-style']],
      [
        '<p style="text-decoration:none underline">invalid</p>',
        ['text-decoration'],
      ],
      [
        '<p style="text-decoration:underline\u00A0line-through">invalid</p>',
        ['text-decoration'],
      ],
      [
        '<span style="background-color:#123456;background-color:none">text</span>',
        ['background-color'],
      ],
      ['<font color="rgb(1,2,3)">text</font>', ['color']],
      ['<body text="rgb(1,2,3)">text</body>', ['text']],
      [
        '<body link="rgb(1,2,3)"><a href="https://example.invalid">text</a></body>',
        ['link'],
      ],
      [String.raw`<p style="font-family:foo\ bar">font</p>`, ['style']],
    ] as const) {
      expect(documentFromHtml(html)).toStrictEqual({ unsupported });
    }
  });

  it('refuses styles the declaration parser cannot inspect within its nesting budget', () => {
    expect.hasAssertions();
    const nested = `${'calc('.repeat(513)}1${')'.repeat(513)}`;
    expect(
      documentFromHtml(`<p style="font-size:${nested}">text</p>`),
    ).toStrictEqual({ unsupported: ['style'] });
  });

  it('ignores HTML hidden content and traverses deeply nested wrappers without throwing', () => {
    expect.hasAssertions();
    const document: SemanticDocument = [
      { kind: 'paragraph', spans: [{ text: 'visible' }] },
    ];
    expect(
      documentFromHtml('<p hidden>hidden</p><p>visible</p>'),
    ).toStrictEqual({ document });
    expect(
      documentFromHtml('<p hidden style="display:block">visible</p>'),
    ).toStrictEqual({ unsupported: ['hidden', 'display'] });
    expect(
      documentFromHtml(
        `${'<span>'.repeat(4000)}visible${'</span>'.repeat(4000)}`,
      ),
    ).toStrictEqual({ document });
  });

  it('keeps body text and unvisited-link colors while allowing inline overrides', () => {
    expect.hasAssertions();
    expect(
      documentFromHtml(
        '<body text="#123456" link="#abcdef"><p>plain <a href="https://example.invalid">link</a> <a href="https://example.invalid" style="color:#000000">overridden</a></p></body>',
      ),
    ).toStrictEqual({
      document: [
        {
          kind: 'paragraph',
          spans: [
            { text: 'plain ', color: '#123456' },
            { text: 'link', link: 'https://example.invalid', color: '#abcdef' },
            { text: ' ', color: '#123456' },
            {
              text: 'overridden',
              link: 'https://example.invalid',
              color: '#000000',
            },
          ],
        },
      ],
    });
  });

  it('takes inherited styles from the parent rather than the element default or attribute', () => {
    expect.hasAssertions();
    expect(
      documentFromHtml(
        '<p><b style="font-weight:inherit">plain</b> <font color="#ff0000" style="color:inherit">default</font></p>',
      ),
    ).toStrictEqual({
      document: [{ kind: 'paragraph', spans: [{ text: 'plain default' }] }],
    });
    expect(
      documentFromHtml(
        '<div align="right"><p align="center" style="text-align:inherit">right</p></div>',
      ),
    ).toStrictEqual({
      document: [
        { kind: 'paragraph', spans: [{ text: 'right' }], align: 'right' },
      ],
    });
  });

  it('keeps quoted font-family commas in styles and font attributes', () => {
    expect.hasAssertions();

    for (const html of [
      '<p style="font-family:\'Family,Inc.\', serif">named</p>',
      '<font face="\'Family,Inc.\', serif">named</font>',
    ]) {
      expect(documentFromHtml(html)).toStrictEqual({
        document: [
          {
            kind: 'paragraph',
            spans: [{ text: 'named', font: '"Family,Inc.", serif' }],
          },
        ],
      });
    }
  });

  it('refuses bare numeric and non-CSS whitespace font names instead of changing inherited fonts', () => {
    expect.hasAssertions();
    for (const family of [
      '123',
      '1abc',
      '-1abc',
      'Arial\u00A0',
      'inherit\u00A0',
      'Arial inherit',
      'serif Foo',
    ]) {
      expect(
        documentFromHtml(
          `<div style="font-family:Arial"><span style="font-family:${family}">text</span></div>`,
        ),
      ).toStrictEqual({ unsupported: ['font-family'] });
    }
    expect(
      documentFromHtml('<p style="font-family:&quot;123&quot;">text</p>'),
    ).toStrictEqual({
      document: [
        { kind: 'paragraph', spans: [{ text: 'text', font: '"123"' }] },
      ],
    });
  });

  it('reads formatting when the host transform omits named capture groups', () => {
    expect.hasAssertions();

    const original = RegExp.prototype.exec;
    const exec = vi
      .spyOn(RegExp.prototype, 'exec')
      .mockImplementation(function (this: RegExp, value: string) {
        const match = original.call(this, value);
        delete match?.groups;
        return match;
      });
    try {
      expect(
        documentFromHtml(
          '<p style="color:#abc;font-size:12pt"><span style="background:rgb(1,2,3);font-family:\'Family,Inc.\'">named</span></p>',
        ),
      ).toStrictEqual({
        document: [
          {
            kind: 'paragraph',
            spans: [
              {
                text: 'named',
                color: '#aabbcc',
                background: '#010203',
                font: '"Family,Inc."',
                size: 16,
              },
            ],
          },
        ],
      });
    } finally {
      exec.mockRestore();
    }
  });

  it('reads an Apple Mail Draft', () => {
    expect.hasAssertions();

    const html = `<html><head><meta http-equiv="content-type" content="text/html; charset=utf-8"></head>
<body style="overflow-wrap: break-word; -webkit-nbsp-mode: space; line-break: after-white-space;">
<div>Hello</div>
<div><br></div>
<div><span style="caret-color: rgb(255, 38, 0); color: rgb(255, 38, 0);">Red</span>
  <font face="Menlo" size="3">mono</font></div>
<div style="text-align: right;"><span style="font-size: 18px; font-weight: 700;">Right</span></div>
<blockquote type="cite"><div>Earlier</div></blockquote>
<div><ol><li>Step</li></ol></div>
</body></html>`;

    expect(documentFromHtml(html)).toStrictEqual({
      document: [
        { kind: 'paragraph', spans: [{ text: 'Hello' }] },
        { kind: 'paragraph', spans: [] },
        {
          kind: 'paragraph',
          spans: [
            { text: 'Red', color: '#ff2600' },
            { text: ' ' },
            { text: 'mono', font: 'Menlo', size: 16 },
          ],
        },
        {
          kind: 'paragraph',
          spans: [{ text: 'Right', marks: ['bold'], size: 18 }],
          align: 'right',
        },
        { kind: 'quote', spans: [{ text: 'Earlier' }] },
        { kind: 'numbered', spans: [{ text: 'Step' }] },
      ],
    });
  });

  it('reads an Outlook Draft', () => {
    expect.hasAssertions();

    const html = `<html xmlns:o="urn:schemas-microsoft-com:office:office"><head>
<style><!-- p.MsoNormal {margin:0in; font-size:11.0pt; font-family:"Calibri",sans-serif;} --></style></head>
<body lang=EN-US link="#0563C1" vlink="#954F72" style='word-wrap:break-word'>
<div class=WordSection1>
<p class=MsoNormal><span style='font-size:12.0pt;font-family:"Calibri",sans-serif;color:#1F497D;mso-fareast-font-family:Calibri'>Dear Sam,<o:p></o:p></span></p>
<p class=MsoNormal><o:p>&nbsp;</o:p></p>
<p class=MsoNormal align=center style='text-align:center'><b><span style='font-family:"Times New Roman",serif'>Agenda<o:p></o:p></span></b></p>
</div></body></html>`;

    expect(documentFromHtml(html)).toStrictEqual({
      document: [
        {
          kind: 'paragraph',
          spans: [
            {
              text: 'Dear Sam,',
              color: '#1f497d',
              font: '"Calibri", sans-serif',
              size: 16,
            },
          ],
        },
        { kind: 'paragraph', spans: [{ text: '\u00A0' }] },
        {
          kind: 'paragraph',
          spans: [
            {
              text: 'Agenda',
              marks: ['bold'],
              font: '"Times New Roman", serif',
            },
          ],
          align: 'center',
        },
      ],
    });
  });

  it('reads Outlook on the web formatting set on a block', () => {
    expect.hasAssertions();

    expect(
      documentFromHtml(
        '<div style="font-family: Aptos, Aptos_EmbeddedFont, Calibri, sans-serif; font-size: 12pt; color: rgb(0, 0, 0);">Hi<br>there</div>',
      ),
    ).toStrictEqual({
      document: ['Hi', 'there'].map((text) => ({
        kind: 'paragraph',
        spans: [
          {
            text,
            color: '#000000',
            font: 'Aptos, Aptos_EmbeddedFont, Calibri, sans-serif',
            size: 16,
          },
        ],
      })),
    });
  });

  it('names what the document cannot hold instead of approximating it', () => {
    expect.hasAssertions();

    expect(
      documentFromHtml(
        '<table><tr><td>Cell</td></tr></table><p><img src="cid:x"></p><h4>Small</h4><hr>',
      ),
    ).toStrictEqual({ unsupported: ['table', 'img', 'h4', 'hr'] });
    expect(
      documentFromHtml(
        '<ul><li>One<ul><li>Nested</li></ul></li></ul><blockquote><h1>Title</h1></blockquote>' +
          '<ol start="3"><li>Three</li></ol><p dir="rtl">x</p>',
      ),
    ).toStrictEqual({ unsupported: ['ul', 'h1', 'start', 'dir'] });
    expect(
      documentFromHtml(
        '<p style="color:red;font-size:1.2em;background:#fff;text-indent:1em;text-align:end">x</p>',
      ),
    ).toStrictEqual({
      unsupported: [
        'color',
        'font-size',
        'background',
        'text-indent',
        'text-align',
      ],
    });
    expect(
      documentFromHtml(
        '<a href="javascript:alert(1)">x</a><font size="9" color="rgba(0,0,0,0.5)">y</font>' +
          '<blockquote style="margin:0 0 0 40px;border:none;padding:0px">indent</blockquote>' +
          '<span style="font-family:var(--font)">z</span>￼',
      ),
    ).toStrictEqual({
      unsupported: ['href', 'size', 'color', 'border', 'font-family', 'U+FFFC'],
    });
    expect(
      documentFromHtml('<p style="text-decoration:overline">x</p>'),
    ).toStrictEqual({ unsupported: ['text-decoration'] });
  });

  it('refuses CSS-wide keywords other than inherit instead of reading them as values', () => {
    expect.hasAssertions();

    expect(
      documentFromHtml(
        '<div style="font-family:Arial"><span style="font-family:unset">a</span></div>' +
          '<font face="initial">b</font><font face="Arial, revert">c</font>' +
          '<blockquote style="border:initial">d</blockquote>' +
          '<p style="font-size:revert-layer;margin:unset">e</p>',
      ),
    ).toStrictEqual({
      unsupported: ['font-family', 'face', 'border', 'font-size'],
    });
    expect(
      documentFromHtml(
        '<div style="font-family:Arial"><span style="font-family:inherit">a</span></div>' +
          '<p style="font-family:\'unset\'">b</p>',
      ),
    ).toStrictEqual({
      document: [
        { kind: 'paragraph', spans: [{ text: 'a', font: 'Arial' }] },
        { kind: 'paragraph', spans: [{ text: 'b', font: '"unset"' }] },
      ],
    });
  });

  it('collapses whitespace as a browser shows it', () => {
    expect.hasAssertions();

    expect(documentFromHtml('')).toStrictEqual({
      document: [{ kind: 'paragraph', spans: [] }],
    });
    expect(
      documentFromHtml(
        '\n<p>  Two \n spaces <b> bold </b> end  </p>\n<pre>  a\n\n b\n</pre>',
      ),
    ).toStrictEqual({
      document: [
        {
          kind: 'paragraph',
          spans: [
            { text: 'Two spaces ' },
            { text: 'bold ', marks: ['bold'] },
            { text: 'end' },
          ],
        },
        { kind: 'code', spans: [{ text: '  a' }] },
        { kind: 'code', spans: [] },
        { kind: 'code', spans: [{ text: ' b' }] },
      ],
    });
  });

  it('replaces an element decoration while retaining decorations from its ancestors', () => {
    expect.hasAssertions();
    for (const [html, span] of [
      ['<u style="text-decoration:none">text</u>', { text: 'text' }],
      [
        '<s style="text-decoration:underline">text</s>',
        { text: 'text', marks: ['underline'] },
      ],
      [
        '<u><s style="text-decoration:none">text</s></u>',
        { text: 'text', marks: ['underline'] },
      ],
      ['<u style="text-decoration-line:none">text</u>', { text: 'text' }],
      [
        '<span style="text-decoration:underline;text-decoration-line:none">text</span>',
        { text: 'text' },
      ],
      [
        '<span style="text-decoration:underline!important;text-decoration-line:none">text</span>',
        { text: 'text', marks: ['underline'] },
      ],
      [
        '<span style="text-decoration-line:line-through!important;text-decoration:underline">text</span>',
        { text: 'text', marks: ['strikethrough'] },
      ],
    ] as const) {
      expect(documentFromHtml(html)).toStrictEqual({
        document: [
          {
            kind: 'paragraph',
            spans: [span],
          },
        ],
      });
    }
  });

  it('resolves background shorthand resets and importance before flattening spans', () => {
    expect.hasAssertions();
    for (const [style, span] of [
      ['background-color:#123456;background:none', { text: 'text' }],
      [
        'background-color:#123456!important;background:#abcdef',
        { text: 'text', background: '#123456' },
      ],
      [
        'background:#123456!important;background-color:#abcdef',
        { text: 'text', background: '#123456' },
      ],
    ] as const) {
      expect(
        documentFromHtml(`<span style="${style}">text</span>`),
      ).toStrictEqual({
        document: [
          {
            kind: 'paragraph',
            spans: [span],
          },
        ],
      });
    }
    expect(
      documentFromHtml(
        '<span style="background:#123456"><span style="background-color:#abcdef;background:none">text</span></span>',
      ),
    ).toStrictEqual({
      document: [
        { kind: 'paragraph', spans: [{ text: 'text', background: '#123456' }] },
      ],
    });
  });

  it('refuses adjacent ordered-list restarts that the document would renumber', () => {
    expect.hasAssertions();
    expect(
      documentFromHtml(
        '<ol><li>one</li></ol><div><ol><li>one again</li></ol></div>',
      ),
    ).toStrictEqual({ unsupported: ['ol'] });
    expect(documentFromHtml('<ol><li>one</li></ol><ol></ol>')).toStrictEqual({
      document: [{ kind: 'numbered', spans: [{ text: 'one' }] }],
    });
    expect(
      documentFromHtml(
        '<ol><li>one</li></ol><p><br></p><ol><li>one again</li></ol>',
      ),
    ).toStrictEqual({
      document: [
        { kind: 'numbered', spans: [{ text: 'one' }] },
        { kind: 'paragraph', spans: [] },
        { kind: 'numbered', spans: [{ text: 'one again' }] },
      ],
    });
  });

  it('refuses heading font resets that cannot override the document heading defaults', () => {
    expect.hasAssertions();
    for (const html of [
      '<h1 style="font-weight:normal">text</h1>',
      '<h2><span style="font-weight:400">text</span></h2>',
      '<h3 style="font-weight:inherit">text</h3>',
    ]) {
      expect(documentFromHtml(html)).toStrictEqual({
        unsupported: ['font-weight'],
      });
    }
    expect(
      documentFromHtml('<h1 style="font-size:inherit">text</h1>'),
    ).toStrictEqual({ unsupported: ['font-size'] });
  });

  it('takes the intrinsic presentation of links, code and headings as outgoing mail sends them', async () => {
    expect.hasAssertions();
    const link = 'https://example.invalid';
    const cases: ReadonlyArray<readonly [string, Block]> = [
      // A link shows the link color, not the color it inherits; its own color is its text's.
      [
        `<p style="color:#ff0000"><a href="${link}">x</a></p>`,
        { kind: 'paragraph', spans: [{ text: 'x', link }] },
      ],
      [
        `<p><a href="${link}" style="color:#ff0000">x</a></p>`,
        { kind: 'paragraph', spans: [{ text: 'x', link, color: '#ff0000' }] },
      ],
      // A link is underlined, and its descendants cannot remove that.
      [
        `<p><a href="${link}"><span style="text-decoration:none">x</span></a></p>`,
        { kind: 'paragraph', spans: [{ text: 'x', link }] },
      ],
      [
        `<p><a href="${link}" style="text-decoration:underline line-through">x</a></p>`,
        {
          kind: 'paragraph',
          spans: [{ text: 'x', link, marks: ['underline', 'strikethrough'] }],
        },
      ],
      [
        `<p><a href="${link}" style="text-decoration:none;text-decoration-line:underline">x</a></p>`,
        {
          kind: 'paragraph',
          spans: [{ text: 'x', link, marks: ['underline'] }],
        },
      ],
      [
        `<p style="text-decoration:underline;color:#123456"><a href="${link}" style="text-decoration:none;color:#123456">x</a></p>`,
        {
          kind: 'paragraph',
          spans: [{ text: 'x', link, marks: ['underline'], color: '#123456' }],
        },
      ],
      [
        `<p style="color:#123456"><a href="${link}" style="color:inherit">x</a></p>`,
        { kind: 'paragraph', spans: [{ text: 'x', link, color: '#123456' }] },
      ],
      // <code> shows its own monospace font, which outgoing mail sets inside any font.
      [
        '<p><span style="font-family:Arial"><code>x</code></span></p>',
        { kind: 'paragraph', spans: [{ text: 'x', marks: ['code'] }] },
      ],
      [
        '<p><code style="font-family:Arial">x</code></p>',
        {
          kind: 'paragraph',
          spans: [{ text: 'x', marks: ['code'], font: 'Arial' }],
        },
      ],
      [
        '<p style="font-family:Arial"><code style="font-family:inherit">x</code></p>',
        {
          kind: 'paragraph',
          spans: [{ text: 'x', marks: ['code'], font: 'Arial' }],
        },
      ],
      [
        '<p><code><font face="Arial">x</font></code></p>',
        {
          kind: 'paragraph',
          spans: [{ text: 'x', marks: ['code'], font: 'Arial' }],
        },
      ],
      [
        '<pre style="font-family:Arial"><code>x</code></pre>',
        { kind: 'code', spans: [{ text: 'x' }] },
      ],
      // A code block shows its monospace font unless it sets its own.
      [
        '<div style="font-family:Arial"><pre>x</pre></div>',
        { kind: 'code', spans: [{ text: 'x' }] },
      ],
      [
        '<pre style="font-family:Menlo">x</pre>',
        { kind: 'code', spans: [{ text: 'x', font: 'Menlo' }] },
      ],
      // Only a heading's own size is sent, so a size around it does not apply.
      [
        '<div style="font-size:12px"><h1 style="font-size:20px">x</h1></div>',
        { kind: 'heading1', spans: [{ text: 'x', size: 20 }] },
      ],
      [
        '<h2><span style="font-size:20px">x</span></h2>',
        { kind: 'heading2', spans: [{ text: 'x', size: 20 }] },
      ],
    ];

    for (const [html, block] of cases) {
      const document: SemanticDocument = [block];
      expect(documentFromHtml(html)).toStrictEqual({ document });
      // Outgoing mail sends what the document holds, so it reads back unchanged.
      expect(documentFromHtml(await sentHtml(document))).toStrictEqual({
        document,
      });
    }
  });

  it('refuses presentation that outgoing mail would restore to the element default', () => {
    expect.hasAssertions();
    const link = 'https://example.invalid';
    for (const [html, unsupported] of [
      [
        `<p><a href="${link}" style="text-decoration:none">x</a></p>`,
        'text-decoration',
      ],
      [
        `<p style="text-decoration:none"><a href="${link}" style="text-decoration-line:inherit">x</a></p>`,
        'text-decoration-line',
      ],
      ['<p><code style="font-family:inherit">x</code></p>', 'font-family'],
      [`<p><a href="${link}" style="color:inherit">x</a></p>`, 'color'],
      ['<div style="font-size:12px"><h1>x</h1></div>', 'font-size'],
    ] as const) {
      expect(documentFromHtml(html)).toStrictEqual({
        unsupported: [unsupported],
      });
    }
  });

  it('refuses an ancestor decoration whose color the outgoing marks would change', () => {
    expect.hasAssertions();
    for (const html of [
      '<p><u><span style="color:#ff0000">x</span></u></p>',
      '<p><s style="color:#123456"><font color="#abcdef">x</font></s></p>',
      '<p><u><a href="https://example.invalid">x</a></u></p>',
    ]) {
      expect(documentFromHtml(html)).toStrictEqual({ unsupported: ['color'] });
    }
  });
});
