import { readFileSync } from 'node:fs';

import { presentation } from '@private-email/mail-core/message-body';

// The rich reader's document, links and readable text for an HTML-only body.
const sanitizeHtml = (html: string) => {
  const { rich, readable } = presentation({ version: 2, id: 'mail', html });
  return {
    document: rich?.document ?? '',
    links: rich?.links ?? [],
    readable,
  };
};

const fixture = (name: string) =>
  readFileSync(
    new URL(`responsive-mail/${name}.html`, import.meta.url),
    'utf8',
  );

const mediaOf = (document: string) =>
  /<style>.*?(?<media>@media \(max-width.*)\.link-cell\{/su.exec(
    document,
  )?.[1] ?? '';

// The rule a breakpoint gives the element whose emitted start tag precedes `text`.
const ruleBefore = (
  document: string,
  text: string,
  media = mediaOf(document),
) => {
  const tag = document.slice(0, document.indexOf(text));
  const name = [
    ...tag.matchAll(/class="(?:link-cell )?(?<name>responsive-\d+)"/gu),
  ].at(-1)?.[1];
  return (
    new RegExp(`\\.${name}\\{(?<rule>[^}]*)\\}`, 'u').exec(media)?.[1] ?? ''
  );
};

describe('responsive sender layouts', () => {
  const steam = fixture('steam-purchase-error');

  it('lays the Steam purchase message out for a phone and keeps the desktop layout wider', () => {
    expect.hasAssertions();
    const { document } = sanitizeHtml(steam);
    expect(mediaOf(document)).toMatch(/^@media \(max-width:600px\)\{/u);
    expect(document).toContain('font-size: 36px; line-height: 44px');
    const greeting = ruleBefore(document, 'Hello example');
    expect(greeting).toContain('padding:0 72px!important');
    expect(greeting).toMatch(
      /padding-left:12px!important;padding-right:12px!important;font-size:22px!important;line-height:28px!important$/u,
    );
  });

  it('keeps the Steam purchase button and its unbroken label readable', () => {
    expect.hasAssertions();
    const { document } = sanitizeHtml(steam);
    // The button cell keeps its background, and the label takes the ink that contrasts more.
    expect(document).toContain(
      '<td align="center" class="link-cell responsive-10" style="padding: 18px 80px; background-color: #2d73ff; color: #000000">',
    );
    expect(ruleBefore(document, 'Retry your purchase')).toBe(
      'padding:12px 24px!important;background-color:#2d73ff!important;color:#000000!important',
    );
    expect(document).toContain('.link-cell a{color:inherit}');
    // Long words wrap only when they must, so the label never splits mid-word.
    expect(document).toContain('overflow-wrap:break-word');
  });

  it('shows and inspects the same Steam content with or without its responsive rules', () => {
    expect.hasAssertions();
    const { links, readable } = sanitizeHtml(steam);
    const withoutStyle = sanitizeHtml(
      steam.replace(/<style[^]*<\/style>/u, ''),
    );
    expect(mediaOf(withoutStyle.document)).toBe('');
    expect(readable).toStrictEqual(withoutStyle.readable);
    expect(links).toStrictEqual([
      {
        href: 'https://store.example.com/cart/',
        text: 'Retry your purchase ›',
      },
    ]);
    expect(withoutStyle.links).toStrictEqual(links);
  });

  it('restates each breakpoint, narrowest last, and leaves fixed-width mail unchanged', () => {
    expect.hasAssertions();
    const { document } = sanitizeHtml(fixture('responsive-newsletter'));
    const media = mediaOf(document);
    const [wide = '', narrow = ''] = media.split('@media (max-width:400px)');
    expect(wide).toMatch(/^@media \(max-width:620px\)\{/u);
    expect(ruleBefore(document, 'Three jobs', wide)).toContain(
      'font-size:18px!important',
    );
    expect(ruleBefore(document, 'Three jobs', narrow)).toContain(
      'font-size:15px!important',
    );
    expect(ruleBefore(document, 'This week', narrow)).toContain(
      'font-size:24px!important',
    );
    expect(mediaOf(sanitizeHtml(fixture('fixed-width')).document)).toBe('');
  });

  it('lets a long URL wrap inside a fixed-width table while words stay whole', () => {
    expect.hasAssertions();
    const { document } = sanitizeHtml(fixture('fixed-width'));
    expect(document).toContain(
      'https:/<wbr>/<wbr>library.<wbr>example.<wbr>org/<wbr>account/<wbr>loans/<wbr>renew?<wbr>item=<wbr>9780393635522&amp;<wbr>branch=<wbr>central',
    );
    expect(document).toContain('Thank you for reading with us.');
  });

  it('admits only geometry and type from max-width rules with element or class selectors', () => {
    expect.hasAssertions();
    const { document } = sanitizeHtml(
      [
        '<style>@media screen and (max-width: 480px) {',
        '.a { display: none !important; visibility: hidden; opacity: 0; color: red; background: #000;',
        'position: absolute; top: 0; font-size: 18px; width: url(x); height: calc(1px) }',
        '#b, .a span, p[title], p:first-child, * { font-size: 30px } }',
        '@media (min-width: 600px) { .a { padding: 40px } }',
        '@media print { .a { padding: 41px } }',
        '.a { padding: 42px }</style>',
        '<p class="a" id="b" title="t">Text</p>',
      ].join(''),
    );
    expect(mediaOf(document)).toBe(
      '@media (max-width:480px){.responsive-0{font-size:18px!important}}',
    );
    expect(document).toContain('<p title="t" class="responsive-0">Text</p>');
  });

  it('keeps the base layout everywhere when a narrow style would change what a link shows', () => {
    expect.hasAssertions();
    for (const [rule, inline] of [
      // Narrow readers would hide the inspected suffix…
      ['font-size: 1px !important', ''],
      // …or show a suffix wide readers hide and inspection leaves out.
      ['font-size: 16px !important', ' style="font-size:1px"'],
    ]) {
      const { document, links } = sanitizeHtml(
        `<style>@media (max-width:600px){.mask{${rule}}}</style>` +
          `<p style="font-size:20px">Pay at <a href="https://pay.example.com.evil.example/"><span>pay.example.com</span><span class="mask"${inline}>.evil.example</span></a></p>`,
      );
      expect(mediaOf(document)).toBe('');
      expect(document).not.toContain('responsive-');
      expect(links).toHaveLength(1);
    }
  });

  it('keeps a sender background only on a link-only cell with an opaque color', () => {
    expect.hasAssertions();
    const cells = [
      '<td bgcolor="#fff"> <a href="https://a.example/">Light</a> </td>',
      '<td style="background:#123"><a href="https://a.example/">Dark</a></td>',
      '<td style="background-color:#2d73ff;background:linear-gradient(#000,#fff)" bgcolor="#ffffff"><a href="https://a.example/">Fallback</a></td>',
      '<td bgcolor="#000">Text <a href="https://a.example/">and link</a></td>',
      '<td bgcolor="#000"><a href="https://a.example/"><img alt="Icon" src="https://a.example/i.png"> Icon</a></td>',
      '<td style="background:rgba(0,0,0,.5)"><a href="https://a.example/">Translucent</a></td>',
    ];
    const { document } = sanitizeHtml(
      `<table><tr>${cells.join('')}</tr></table>`,
    );
    expect(document.match(/<td[^>]*>/gu)).toStrictEqual([
      '<td class="link-cell" style="background-color: #ffffff; color: #000000">',
      '<td class="link-cell" style="background-color: #112233; color: #FFFFFF">',
      '<td class="link-cell" style="background-color: #ffffff; color: #000000">',
      '<td>',
      '<td>',
      '<td>',
    ]);
  });

  it('keeps a button label inside its cell at every width', () => {
    expect.hasAssertions();
    const { document } = sanitizeHtml(
      [
        '<style>@media (max-width:600px){.p{font-size:14px}.lift{margin-top:-90px;line-height:0}}</style>',
        '<p class="p">Text</p><table><tr><td bgcolor="#000" style="line-height:0">',
        '<a href="https://pay.example.com.evil.example/x"><span>pay.example.com</span>',
        '<span class="lift" style="display:block;text-indent:-200px">.evil.example</span></a></td></tr></table>',
      ].join(''),
    );
    expect(document).toContain(
      '<td class="link-cell" style="line-height: 0; background-color: #000000; color: #FFFFFF">',
    );
    // The phone layout still applies, and the app's containment follows it, so it outranks every
    // sender declaration: inline, inherited or narrow.
    expect(mediaOf(document)).toContain('font-size:14px!important');
    expect(document).toContain(
      '}}.link-cell{text-indent:0!important;letter-spacing:normal!important;line-height:normal!important}' +
        '.link-cell *{margin:0!important;text-indent:0!important;vertical-align:baseline!important;' +
        'letter-spacing:normal!important;line-height:normal!important;width:auto!important;' +
        'height:auto!important;max-width:none!important;max-height:none!important}',
    );
  });

  it('restates narrow styles as the cascade orders them, without sender link decoration', () => {
    expect.hasAssertions();
    const { document } = sanitizeHtml(
      [
        '<style>@media (max-width:600px){',
        'a{font-size:15px;text-decoration:underline wavy}',
        '.list{padding-left:400px !important}',
        '.p{padding:12px !important}}</style>',
        '<p><a href="https://a.example/" style="text-decoration:underline wavy #ff0000 6px">Link</a></p>',
        '<ul class="list" style="padding-left:20px"><li>Item</li></ul>',
        '<p class="p" style="padding-left:72px !important">Text</p>',
      ].join(''),
    );
    // The reader's own underline keeps its color and thickness at every width.
    expect(ruleBefore(document, 'Link')).toBe('font-size:15px!important');
    // A bounded-out value returns to the browser's list indent, not zero.
    expect(ruleBefore(document, 'Item')).toBe('padding-left:revert!important');
    // An important inline longhand outranks an important rule's shorthand.
    expect(ruleBefore(document, 'Text')).toBe(
      'padding:12px!important;padding-left:72px!important',
    );
  });

  it('ignores media rules past the selector budget', () => {
    expect.hasAssertions();
    const selectors = Array.from({ length: 600 }, () => '.a').join(',');
    const { document } = sanitizeHtml(
      `<style>@media (max-width:600px){${selectors}{font-size:18px}}</style><p class="a">Text</p>`,
    );
    expect(mediaOf(document)).toBe('');
  });
});
