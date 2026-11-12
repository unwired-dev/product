import { readFileSync } from 'node:fs';

import { sanitizeHtml } from '../src/html-sanitizer.ts';

const fixture = (name: string) =>
  readFileSync(
    new URL(`responsive-mail/${name}.html`, import.meta.url),
    'utf8',
  );

const mediaOf = (document: string) =>
  /<style>.*?(?<media>@media \(max-width.*)<\/style>/su.exec(document)?.[1] ??
  '';

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
});
