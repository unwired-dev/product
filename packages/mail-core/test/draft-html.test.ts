import PostalMime from 'postal-mime';

import type { Draft } from '../src/drafts.ts';
import type { SemanticDocument } from '../src/semantic-document.ts';

import { documentFromHtml } from '../src/draft-html.ts';
import { outgoingMessage } from '../src/outgoing-message.ts';

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
        { kind: 'paragraph', spans: [] },
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
