import type { Draft } from '@private-email/mail-core/drafts';
import type { SemanticDocument } from '@private-email/mail-core/semantic-document';

import { documentFromHtml } from '@private-email/mail-core/draft-html';
import { outgoingMessage } from '@private-email/mail-core/outgoing-message';
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
      ['<font size="+1">relative</font>', ['size']],
      ['<p style="font-weight:500">medium</p>', ['font-weight']],
      ['<p style="font-weight:800">heavy</p>', ['font-weight']],
      ['<p style="font-style:oblique">slanted</p>', ['font-style']],
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
});
