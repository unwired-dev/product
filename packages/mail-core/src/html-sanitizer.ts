/* oxlint-disable typescript/prefer-readonly-parameter-types -- parse5 tree nodes are mutable library types; the sanitizer only reads them. */
import type { DefaultTreeAdapterTypes } from 'parse5';

import { html as htmlSpec, parse } from 'parse5';

import type { ImageFacts } from './inline-images.ts';
import type { ReadableBody } from './readable-text.ts';

import { opacityNumber } from './css-opacity.ts';
import { inlineImageLimits } from './inline-images.ts';
import { messageLinkHref, vettedHref } from './link-inspection.ts';
import {
  hasReadableText,
  hasVisibleText,
  messageLinkLimit,
  paragraphBuilder,
} from './readable-text.ts';

type Node = DefaultTreeAdapterTypes.ChildNode;
type Element = DefaultTreeAdapterTypes.Element;

// An admitted MIME Inline Image, as standard base64 for an app-generated `data:` source.
export interface InlineImage extends ImageFacts {
  readonly contentId: string;
  readonly data: string;
}

export interface BodyLink {
  readonly href: string;
  // The link's visible text, for inspection and keyboard access.
  readonly text: string;
}

export interface SanitizedHtml {
  // A complete app-owned document for the isolated WebKit view.
  readonly document: string;
  // The same content as readable text: the fallback when rich presentation is unavailable.
  readonly readable: ReadableBody;
  // Readable text, a referenced Content-ID image, or a blocked-image placeholder.
  readonly renderable: boolean;
  // Visible `cid:` references, in document order, for MIME resolution.
  readonly contentIds: readonly string[];
  // Every visible occurrence, including duplicates, for the presentation image budget.
  readonly contentIdOccurrences: readonly string[];
  readonly links: readonly BodyLink[];
}

// Scripts, metadata, embedded content, form controls and foreign markup never reach the output.
const removed = new Set([
  'applet',
  'area',
  'audio',
  'base',
  'button',
  'canvas',
  'datalist',
  'dialog',
  'embed',
  'fieldset',
  'frame',
  'frameset',
  'head',
  'iframe',
  'input',
  'link',
  'map',
  'math',
  'meta',
  'meter',
  'noscript',
  'object',
  'optgroup',
  'option',
  'output',
  'picture',
  'portal',
  'progress',
  'script',
  'select',
  'slot',
  'source',
  'style',
  'svg',
  'template',
  'textarea',
  'title',
  'track',
  'video',
]);

// The passive elements the reader admits.
const admitted = new Set([
  'a',
  'b',
  'blockquote',
  'br',
  'caption',
  'center',
  'cite',
  'code',
  'col',
  'colgroup',
  'dd',
  'div',
  'dl',
  'dt',
  'em',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'hr',
  'i',
  'img',
  'li',
  'ol',
  'p',
  'pre',
  'q',
  's',
  'small',
  'span',
  'strike',
  'strong',
  'sub',
  'sup',
  'table',
  'tbody',
  'td',
  'tfoot',
  'th',
  'thead',
  'tr',
  'u',
  'ul',
]);

// Structural elements outside the admitted set keep their content as a block or inline span.
const asBlock = new Set([
  'address',
  'article',
  'aside',
  'details',
  'figcaption',
  'figure',
  'footer',
  'form',
  'header',
  'hgroup',
  'main',
  'nav',
  'section',
  'summary',
]);

// Elements that end a paragraph of the readable fallback.
const paragraphs = new Set([
  ...asBlock,
  'blockquote',
  'caption',
  'center',
  'dd',
  'div',
  'dl',
  'dt',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'hr',
  'li',
  'ol',
  'p',
  'pre',
  'table',
  'tr',
  'ul',
]);

const number = /^\d{1,4}$/u;
const length = /^\d{1,5}(?:%|px)?$/iu;
const text = /^[^<>]{0,1000}$/u;

const attributeRules: Readonly<Record<string, RegExp>> = {
  abbr: text,
  align: /^(?:left|right|center|justify|middle|top|bottom)$/iu,
  alt: text,
  border: number,
  cellpadding: number,
  cellspacing: number,
  colspan: number,
  dir: /^(?:ltr|rtl)$/iu,
  headers: text,
  height: length,
  lang: /^[a-z]{1,8}(?:-[\da-z]{1,8})*$/iu,
  role: /^(?:presentation|none|table|grid)$/iu,
  rowspan: number,
  scope: /^(?:row|col|rowgroup|colgroup)$/iu,
  span: number,
  start: number,
  summary: text,
  title: text,
  valign: /^(?:top|middle|bottom|baseline)$/iu,
  value: number,
  width: length,
};

const elementAttributes: Readonly<Record<string, readonly string[]>> = {
  col: ['align', 'span', 'valign', 'width'],
  colgroup: ['align', 'span', 'valign', 'width'],
  img: ['alt', 'height', 'width'],
  li: ['value'],
  ol: ['start', 'type'],
  table: [
    'align',
    'border',
    'cellpadding',
    'cellspacing',
    'role',
    'summary',
    'width',
  ],
  td: [
    'abbr',
    'align',
    'colspan',
    'headers',
    'height',
    'rowspan',
    'valign',
    'width',
  ],
  th: [
    'abbr',
    'align',
    'colspan',
    'headers',
    'height',
    'rowspan',
    'scope',
    'valign',
    'width',
  ],
  ul: ['type'],
};

const listTypes: Readonly<Record<string, RegExp>> = {
  ol: /^[1aAiI]$/u,
  ul: /^(?:disc|circle|square)$/iu,
};

// CSS properties kept from a sender's inline style; text colors and backgrounds are the app's.
const properties = new Set([
  'border',
  'border-bottom',
  'border-bottom-style',
  'border-bottom-width',
  'border-collapse',
  'border-left',
  'border-left-style',
  'border-left-width',
  'border-right',
  'border-right-style',
  'border-right-width',
  'border-spacing',
  'border-style',
  'border-top',
  'border-top-style',
  'border-top-width',
  'border-width',
  'display',
  'font-family',
  'font-size',
  'font-style',
  'font-weight',
  'height',
  'letter-spacing',
  'line-height',
  'margin',
  'margin-bottom',
  'margin-left',
  'margin-right',
  'margin-top',
  'max-height',
  'max-width',
  'min-height',
  'min-width',
  'overflow-wrap',
  'padding',
  'padding-bottom',
  'padding-left',
  'padding-right',
  'padding-top',
  'text-align',
  'text-decoration',
  'text-indent',
  'text-transform',
  'vertical-align',
  'visibility',
  'white-space',
  'width',
  'word-break',
  'word-wrap',
]);

// Values that could load, execute, reference or escape the declaration.
const unsafeValue =
  /url\s*\(|image-set|expression\s*\(|var\s*\(|attr\s*\(|env\s*\(|javascript:|@|\\|[<>{}]|\/\*/iu;

const displays =
  /^(?:block|inline|inline-block|list-item|table|table-row|table-cell|table-row-group|table-header-group|table-footer-group|table-column|table-column-group|table-caption)$/iu;

// Keep sizing to literal lengths and keywords; unvalidated CSS functions cannot mask pixels.
const dimensionValue =
  /^(?:\+?(?<amount>(?:\d+(?:\.\d+)?|\.\d+)(?:e[+-]?\d+)?)(?<unit>%|px|em|rem|ex|ch|vw|vh|vmin|vmax|cm|mm|in|pt|pc)?|auto|min-content|max-content|fit-content|stretch|inherit|initial|unset|revert(?:-layer)?)$/iu;

const cssDimension = (value: string) => {
  const match = dimensionValue.exec(value);
  return (
    match !== null &&
    (match[1] === undefined || match[2] !== undefined || Number(match[1]) === 0)
  );
};

const pixels = (value: string | undefined) => {
  const match = dimensionValue.exec(value?.trim() ?? '');
  if (match?.[1] === undefined) {
    return undefined;
  }
  const amount = Number(match[1]);
  return amount === 0 || match[2] === undefined || /^px$/iu.test(match[2])
    ? amount
    : undefined;
};

interface FilteredStyle {
  readonly css: string;
  // Content no one sees: hidden preheaders, zero-sized or off-canvas text.
  readonly hidden: boolean;
  readonly declared: ReadonlyMap<string, string>;
  // The declarations WebKit receives; dimensions and readable text use these values.
  readonly retained: ReadonlyMap<string, string>;
}

// Declarations end at semicolons outside quoted strings and brackets, as WebKit reads them. A
// string that a line break or the end of the attribute interrupts would swallow the declarations
// after it once reserialized, so its declaration is dropped.
interface StyleScan {
  quote: string | undefined;
  endings: string[];
  broken: boolean;
}

const scanQuoted = (scan: StyleScan, char: string) => {
  if (char === scan.quote) {
    scan.quote = undefined;
  } else if (/[\n\r\f]/u.test(char)) {
    scan.broken = true;
    scan.quote = undefined;
  }
  return false;
};

// Whether this character ends the declaration.
const scanUnquoted = (scan: StyleScan, char: string) => {
  if (char === '"' || char === "'") {
    scan.quote = char;
  } else if (char === '(' || char === '[') {
    scan.endings.push(char === '(' ? ')' : ']');
  } else if (char === scan.endings.at(-1)) {
    scan.endings.pop();
  }
  return char === ';' && scan.endings.length === 0;
};

const splitDeclarations = (style: string) => {
  const declarations: string[] = [];
  let start = 0;
  let scan: StyleScan = {
    quote: undefined,
    endings: [],
    broken: false,
  };
  const end = (at: number) => {
    if (!scan.broken && scan.quote === undefined) {
      declarations.push(style.slice(start, at));
    }
    start = at + 1;
    scan = { quote: undefined, endings: [], broken: false };
  };
  for (let at = 0; at < style.length; at += 1) {
    const char = style.charAt(at);
    if (char === '\\') {
      // Hex escapes consume up to six digits and one optional whitespace character, including
      // a newline. Other escapes consume one character without changing string/block state.
      at +=
        /^(?:[0-9a-f]{1,6}(?:\r\n|[\t\n\f\r ])?|\r\n|[\s\S])/iu.exec(
          style.slice(at + 1),
        )?.[0].length ?? 0;
    } else if (
      scan.quote === undefined
        ? scanUnquoted(scan, char)
        : scanQuoted(scan, char)
    ) {
      end(at);
    }
  }
  end(style.length);
  return declarations;
};

// Content no one sees: hidden preheaders, zero-sized or off-canvas text.
const hiddenBy: ReadonlyArray<
  (declared: ReadonlyMap<string, string>) => boolean
> = [
  (declared) => /^none$/iu.test(declared.get('display') ?? ''),
  (declared) => {
    const opacity = opacityNumber(declared.get('opacity') ?? '');
    return opacity !== undefined && (Number.isNaN(opacity) || opacity <= 0);
  },
];

// Model only retained literal font sizes and keywords. Unsupported expressions are discarded
// before rendering, so invisible expression text cannot mask a link's visible address.
const sizeValue =
  /^(?<amount>[+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:e[+-]?\d+)?)(?<unit>%|px|em|rem|ex|ch|vw|vh|vmin|vmax|cm|mm|q|in|pt|pc)?$/u;
const fontKeyword =
  /^(?:xx-small|x-small|small|medium|large|x-large|xx-large|xxx-large|larger|smaller|inherit|initial|unset|revert(?:-layer)?)$/u;
const cssFontSize = (raw: string) => {
  const value = raw.toLowerCase();
  const size = sizeValue.exec(value);
  return size === null
    ? fontKeyword.test(value)
    : Number.isFinite(Number(size[1])) &&
        Number(size[1]) >= 0 &&
        /^(?:px|em|rem|%|cm|mm|q|in|pt|pc)?$/u.test(size[2] ?? '') &&
        (size[2] !== undefined || Number(size[1]) === 0);
};

// Line-height budgeting must use the same values WebKit receives. Font-metric and
// viewport lengths, and expressions, have no reliable pixel basis in this traversal.
const cssLineHeight = (raw: string) => {
  const value = raw.toLowerCase();
  if (/^(?:normal|inherit|initial|unset|revert(?:-layer)?)$/u.test(value)) {
    return true;
  }
  const size = sizeValue.exec(value);
  return (
    size !== null &&
    Number.isFinite(Number(size[1])) &&
    Number(size[1]) >= 0 &&
    /^(?:px|em|rem|%|cm|mm|q|in|pt|pc)?$/u.test(size[2] ?? '')
  );
};

// Reader geometry in CSS pixels. The Mac default body is 13px; Dynamic Type remains enabled.
// Emitted font normalization keeps the readability cutoff independent of the actual body size.
const rootFontPixels = 16;
const bodyFontPixels = 13;
const narrowestReaderPixels = 320;
// A conservative legibility cutoff, not a claim that smaller text paints no pixels.
const minimumTextPixels = 4;

const absoluteUnits = new Map([
  ['px', 1],
  ['pt', 96 / 72],
  ['pc', 16],
  ['in', 96],
  ['cm', 96 / 2.54],
  ['mm', 96 / 25.4],
  ['q', 96 / 101.6],
  ['rem', rootFontPixels],
  ['vw', narrowestReaderPixels / 100],
  ['vh', narrowestReaderPixels / 100],
  ['vmin', narrowestReaderPixels / 100],
  ['vmax', narrowestReaderPixels / 100],
]);

// A signed CSS length in pixels, given the font size em units use and the basis of percentages.
const lengthPixels = (
  value: string | undefined,
  { font, percent }: Readonly<{ font: number; percent: number }>,
) => {
  const parsed =
    /^(?<amount>[+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:e[+-]?\d+)?)(?<unit>[a-z%]*)$/u.exec(
      value?.trim().toLowerCase() ?? '',
    );
  if (parsed === null) {
    return undefined;
  }
  const amount = Number(parsed[1]);
  const unit = parsed[2] ?? '';
  const scale =
    new Map([
      ['em', font],
      ['ex', font / 2],
      ['ch', font / 2],
      ['%', percent / 100],
    ]).get(unit) ?? absoluteUnits.get(unit);
  if (amount === 0) {
    return 0;
  }
  return scale === undefined ? undefined : amount * scale;
};

// Font sizes browsers give these elements when the sender sets none.
const defaultFontSizes = new Map([
  ['h1', '2em'],
  ['h2', '1.5em'],
  ['h3', '1.17em'],
  ['h5', '0.83em'],
  ['h6', '0.67em'],
  ['small', 'smaller'],
  ['sub', 'smaller'],
  ['sup', 'smaller'],
]);

const fontKeywordPixels = new Map([
  ['xx-small', 9],
  ['x-small', 10],
  ['small', 13],
  ['medium', 16],
  ['initial', 16],
  ['large', 18],
  ['x-large', 24],
  ['xx-large', 32],
  ['xxx-large', 48],
]);

const fontValueIn = (value: string | undefined, tag: string) =>
  value === undefined || /^(?:revert(?:-layer)?)$/iu.test(value)
    ? defaultFontSizes.get(tag)
    : value;

// The sender cannot choose viewport/font-metric units whose rendered size is unknown here.
// Pin tiny sizes to the model and give retained relative sizes a 4px rendering floor. Ordinary
// body text still uses Dynamic Type, and relative sizes above the cutoff continue to scale.
const normalizeFont = (style: FilteredStyle, tag: string, font: number) => {
  const value = fontValueIn(style.retained.get('font-size'), tag)
    ?.trim()
    .toLowerCase();
  if (value === undefined) {
    return style;
  }
  let relative = value;
  if (value === 'larger') {
    relative = '120%';
  } else if (value === 'smaller') {
    relative = `${100 / 1.2}%`;
  }
  let size = relative;
  if (font < minimumTextPixels) {
    size = `${font}px`;
  } else if (/(?:em|%)$/u.test(relative)) {
    size = `max(4px, ${relative})`;
  }
  return {
    ...style,
    retained: new Map([...style.retained, ['font-size', size]]),
  };
};

// The computed font size an element's text uses: relative sizes scale the parent's, so a chain
// of small factors under a large parent can still paint legible text.
const fontSizeIn = (value: string | undefined, parent: number, tag: string) => {
  const declared = fontValueIn(value, tag)?.trim().toLowerCase();
  if (declared === undefined) {
    return parent;
  }
  const keyword = fontKeywordPixels.get(declared);
  if (keyword !== undefined) {
    return keyword;
  }
  if (declared === 'larger' || declared === 'smaller') {
    return declared === 'larger' ? parent * 1.2 : parent / 1.2;
  }
  const resolved = lengthPixels(declared, { font: parent, percent: parent });
  return resolved === undefined || resolved < 0 ? parent : resolved;
};

// Signed lengths for offsets; a nonzero number needs a unit, as WebKit requires.
const offsetValue =
  /^(?<sign>[+-])?(?<amount>(?:\d+(?:\.\d+)?|\.\d+)(?:e[+-]?\d+)?)(?<unit>%|px|em|rem|ex|ch|vw|vh|vmin|vmax|cm|mm|in|pt|pc)?$/iu;

const cssWideKeyword = /^(?:inherit|initial|unset|revert(?:-layer)?)$/iu;

// Resolve physical margins in emitted declaration order, including shorthand resets.
const marginEdges = (
  declared: ReadonlyMap<string, string>,
  inherited: ReadonlyMap<string, string>,
) => {
  const edges = new Map<string, string>();
  const assign = (edge: string, value: string) => {
    let resolved = value;
    if (/^inherit$/iu.test(value)) {
      resolved = inherited.get(edge) ?? '0';
    } else if (cssWideKeyword.test(value)) {
      resolved = '0';
    }
    edges.set(edge, resolved);
  };
  for (const [name, value] of declared) {
    if (name === 'margin') {
      const [top = '0', right = top, bottom = top, left = right] =
        value.split(/\s+/u);
      assign('top', top);
      assign('right', right);
      assign('bottom', bottom);
      assign('left', left);
    } else if (name.startsWith('margin-')) {
      assign(name.slice(7), value);
    }
  }
  return edges;
};

// Negative offsets whose clipping depends on unknown geometry are normalized in the output.
// Even a large offset can leave compensated or wrapped text visible, so it cannot by itself
// justify omitting a label. Small hanging indents and trailing LTR margins remain intact.
const offCanvas = (value: string | undefined, font: number) =>
  (lengthPixels(value, { font, percent: narrowestReaderPixels }) ?? 0) <=
    -narrowestReaderPixels ||
  /^-(?:\d+(?:\.\d+)?|\.\d+)(?:e[+-]?\d+)?(?:%|ex|ch|vw|vh|vmin|vmax)$/iu.test(
    value ?? '',
  );

// Large positive spacing pushes content past the reader's right edge, or a whole label below
// the viewport; whether glyphs stay visible depends on wrapping, so it is normalized as well.
const farRight = (value: string | undefined, font: number) =>
  (lengthPixels(value, { font, percent: narrowestReaderPixels }) ?? 0) >=
  narrowestReaderPixels;

const displaces = (value: string | undefined, font: number) =>
  offCanvas(value, font) || farRight(value, font);

// Padding and border widths take no negative values; any large token drops the declaration.
const spacingProperties = new Set([
  'padding',
  'padding-top',
  'padding-bottom',
  'padding-left',
  'padding-right',
  'border',
  'border-top',
  'border-bottom',
  'border-left',
  'border-right',
  'border-width',
  'border-top-width',
  'border-bottom-width',
  'border-left-width',
  'border-right-width',
  'border-spacing',
]);

const colorFunctions = /\b(?:rgba?|hsla?)\([^()]*\)/giu;

const normalizeTextSpacing = (retained: Map<string, string>, font: number) => {
  if (displaces(retained.get('text-indent'), font)) {
    retained.set('text-indent', '0');
  }
  for (const name of ['vertical-align', 'letter-spacing']) {
    if (
      Math.abs(
        lengthPixels(retained.get(name), { font, percent: font }) ?? 0,
      ) >= narrowestReaderPixels
    ) {
      retained.set(name, '0');
    }
  }
  const lineHeight = retained.get('line-height');
  if (
    (lengthPixels(lineHeight, { font, percent: font }) ??
      Number(lineHeight) * font) >= narrowestReaderPixels
  ) {
    retained.set('line-height', 'normal');
  }
};

const normalizeSpacing = (
  declarations: ReadonlyMap<string, string>,
  font: number,
) => {
  const retained = new Map(declarations);
  normalizeTextSpacing(retained, font);
  // Keep desktop email widths while preventing aligned text in oversized boxes from
  // escaping their containing block. Unlike spacing, a 600px layout is ordinary mail.
  for (const name of ['width', 'min-width']) {
    const value = retained.get(name);
    if (farRight(value, font)) {
      retained.set(name, `min(100%, ${value})`);
    }
  }
  // A tall box pushes the text after it below the viewport, away from the label it extends;
  // without the height, images keep the reader's automatic height and their aspect ratio.
  for (const name of ['height', 'min-height']) {
    if (farRight(retained.get(name), font)) {
      retained.delete(name);
    }
  }
  for (const [name, value] of retained) {
    if (
      spacingProperties.has(name) &&
      // A closing color parenthesis separates CSS tokens even without whitespace.
      value
        .replaceAll(colorFunctions, ' ')
        .split(/\s+/u)
        .some((token) => farRight(token, font))
    ) {
      retained.delete(name);
    }
  }
  return retained;
};

const normalizeMargins = (
  style: FilteredStyle,
  margins: Map<string, string>,
  {
    display,
    directional,
    font,
  }: Readonly<{ display: string; directional: boolean; font: number }>,
) => {
  const retained = normalizeSpacing(style.retained, font);
  for (const edge of ['left', 'right', 'top', 'bottom']) {
    if (
      displaces(margins.get(edge), font) &&
      (edge === 'right' ? directional : !/^table-(?!caption$)/u.test(display))
    ) {
      margins.set(edge, '0');
      const name = `margin-${edge}`;
      retained.delete(name);
      retained.set(name, '0');
    }
  }
  return {
    ...style,
    retained,
    css: [...retained].map(([name, value]) => `${name}: ${value}`).join('; '),
  };
};

const offsetTokens = new Map([
  ['margin', 4],
  ['margin-top', 1],
  ['margin-right', 1],
  ['margin-bottom', 1],
  ['margin-left', 1],
  ['text-indent', 1],
]);

// CSS-wide keywords stand alone; auto belongs only to margins. Keep text-indent to a single
// length: hanging/each-line require line-sensitive readability that this reader does not model.
const cssOffset = (name: string, value: string) => {
  if (cssWideKeyword.test(value)) {
    return true;
  }
  const tokens = value.trim().split(/\s+/u);
  return (
    tokens.length <= (offsetTokens.get(name) ?? 0) &&
    tokens.every((token) => {
      if (name !== 'text-indent' && /^auto$/iu.test(token)) {
        return true;
      }
      // Positional captures: Hermes leaves `groups` unset on some named-group results.
      const match = offsetValue.exec(token);
      return (
        match !== null && (match[3] !== undefined || Number(match[2]) === 0)
      );
    })
  );
};

// Sizes WebKit applies only when they follow the validated dimension grammar.
const dimensionProperties = new Set([
  'width',
  'height',
  'max-width',
  'max-height',
  'min-width',
  'min-height',
]);

const validSize = (name: string, value: string) => {
  if (name === 'font-size') {
    return cssFontSize(value);
  }
  if (name === 'line-height') {
    return cssLineHeight(value);
  }
  return !dimensionProperties.has(name) || cssDimension(value);
};

// Properties WebKit accepts only as one of these keywords.
const keywordValues = new Map([
  ['display', displays],
  [
    'visibility',
    /^(?:visible|hidden|collapse|inherit|initial|unset|revert(?:-layer)?)$/iu,
  ],
]);

// A CSS function outside quoted strings, such as calc(), whose geometry the sanitizer cannot
// bound, so such a value is never emitted. Plain color functions carry no geometry, so ordinary
// borders such as `1px solid rgb(…)` stay; a function nested inside one still counts.
const cssFunction = (value: string) =>
  value
    .replaceAll(/"[^"]*"|'[^']*'/gu, '')
    .replaceAll(colorFunctions, ' ')
    .includes('(');

const keptDeclaration = ([name, value]: readonly [string, string]) =>
  properties.has(name) &&
  value !== '' &&
  !unsafeValue.test(value) &&
  !cssFunction(value) &&
  validSize(name, value) &&
  (!offsetTokens.has(name) || cssOffset(name, value)) &&
  (keywordValues.get(name)?.test(value) ?? true);

// Retain native table roles: anonymous boxes from sender display overrides would otherwise
// disagree with the span grid used to exclude collapsed cells before CID discovery.
const tableDisplays = new Map([
  ['table', 'table'],
  ['col', 'table-column'],
  ['colgroup', 'table-column-group'],
  ['thead', 'table-header-group'],
  ['tbody', 'table-row-group'],
  ['tfoot', 'table-footer-group'],
  ['tr', 'table-row'],
  ['td', 'table-cell'],
  ['th', 'table-cell'],
]);

// Source validity is separate from retention: flex can override none even though it is omitted
// from the output. These display forms are accepted by the supported WebKit host; run-in, ruby
// and multi-keyword list-item forms are not. Outside/inside keywords occur at most once each.
const displayOutside = '(?:block|inline)';
const displayInside = '(?:flow|flow-root|table|flex|grid)';
const hidingGrammar = new Map([
  [
    'display',
    new RegExp(
      `^(?:none|contents|list-item|inline-(?:block|table|flex|grid)|-webkit-(?:inline-)?(?:box|flex)|table-(?:row-group|header-group|footer-group|row|cell|column-group|column|caption)|${displayOutside}(?:[\\t\\n\\f\\r ]+${displayInside})?|${displayInside}(?:[\\t\\n\\f\\r ]+${displayOutside})?)$`,
      'iu',
    ),
  ],
  ['visibility', /^(?:visible|hidden|collapse)$/iu],
]);

// Validate literal sizes before importance selection, including units the reader does not
// retain. Otherwise an invalid important value blocks a valid normal one, or an unretained
// viewport/font-metric size incorrectly leaves a preceding zero in place.
const sourceLength =
  /^(?<amount>[+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:e[+-]?\d+)?)(?<unit>%|px|cm|mm|q|in|pt|pc|r?(?:em|ex|cap|ch|ic|lh)|[sld]?v(?:w|h|i|b|min|max)|cq(?:w|h|i|b|min|max))?$/iu;
const sourceSizing = new Set([
  ...dimensionProperties,
  'font-size',
  'line-height',
]);
const validSourceLength = (size: readonly string[], unitless: boolean) =>
  Number.isFinite(Number(size[1])) &&
  Number(size[1]) >= 0 &&
  (unitless || size[2] !== undefined || Number(size[1]) === 0);
const sourceSize = (name: string, raw: string) => {
  if (!sourceSizing.has(name)) {
    return true;
  }
  const value = raw.toLowerCase();
  const size = sourceLength.exec(value);
  if (size !== null) {
    return validSourceLength(size, name === 'line-height');
  }
  if (name === 'font-size') {
    return fontKeyword.test(value);
  }
  if (name === 'line-height') {
    return value === 'normal';
  }
  return (
    /^(?:min-content|max-content|fit-content|stretch)$/u.test(value) ||
    value === (name.startsWith('max-') ? 'none' : 'auto')
  );
};

// CSS keywords are ASCII-insensitive; Unicode regex folding must not turn LONG S or Kelvin
// signs into accepted hiding/size/offset keywords. These supported grammars contain no strings.
const sourceGrammarProperties = new Set([
  ...sourceSizing,
  ...offsetTokens.keys(),
  ...hidingGrammar.keys(),
  'opacity',
]);
const acceptedOffset = (name: string, value: string) =>
  !offsetTokens.has(name) ||
  (!/[^\S\t\n\f\r ]/u.test(value) && cssOffset(name, value));
const acceptedDeclaration = (name: string, value: string) =>
  value !== '' &&
  (!sourceGrammarProperties.has(name) || !/[^\p{ASCII}]/u.test(value)) &&
  (cssWideKeyword.test(value) ||
    (name === 'opacity'
      ? opacityNumber(value) !== undefined
      : sourceSize(name, value) &&
        acceptedOffset(name, value) &&
        (hidingGrammar.get(name)?.test(value) ?? true)));

// Duplicates resolve as the cascade does: an important declaration wins over later normal ones,
// and a rejected one changes nothing.
const trimCSS = (value: string) =>
  value.replaceAll(/^[\t\n\f\r ]+|[\t\n\f\r ]+$/gu, '');
// CSS escapes as WebKit decodes them: up to six hex digits and one optional whitespace, or any
// other character taken literally. Invalid code points become U+FFFD.
const cssEscape =
  /\\(?:(?<hex>[\da-f]{1,6})(?:\r\n|[\t\n\f\r ])?|(?<literal>[^\n\f\r\da-f]))/giu;
const unescapeCSS = (source: string) =>
  source.replaceAll(
    cssEscape,
    (_escape: string, hex: string | undefined, literal: string | undefined) => {
      if (hex === undefined) {
        return literal ?? '';
      }
      const code = Number.parseInt(hex, 16);
      // Zero, surrogates and values past U+10FFFF are not characters.
      return code === 0 ||
        code > 1_114_111 ||
        (code >= 55_296 && code <= 57_343)
        ? '\uFFFD'
        : String.fromCodePoint(code);
    },
  );

// The source token may contain escapes; its decoded spelling must also be an identifier
// that can be emitted without escapes. Escaped digits remain identifiers, never numbers.
const plainCSSIdentifier =
  /^(?:--|-?[a-z_\u0080-\u{10FFFF}])[\w\u0080-\u{10FFFF}-]*$/iu;
const identEscape = cssEscape.source.replaceAll(/\(\?<[^>]+>/gu, '(?:');
const identStart = String.raw`(?:[a-z_\u0080-\u{10FFFF}]|${identEscape})`;
const identRest = String.raw`(?:[\w\u0080-\u{10FFFF}-]|${identEscape})`;
const identSource = `(?:--|-?${identStart})${identRest}*`;
const sourceCSSIdentifier = new RegExp(`^${identSource}$`, 'iu');
const importance = new RegExp(
  `![\\t\\n\\f\\r ]*(?<identifier>${identSource})$`,
  'iu',
);

// Preprocess CSS newlines, then recognize strings, identifiers and unquoted URL tokens before
// comments. A comment separates tokens; preserve that trivia for source math validation.
const stringEscape = String.raw`(?:${identEscape}|\\\n)`;
const cssLexeme = new RegExp(
  String.raw`"(?:[^"\\\n]|${stringEscape})*"?|'(?:[^'\\\n]|${stringEscape})*'?|(${identSource})(\()?|\\[\s\S]|\/\*[\s\S]*?(?:\*\/|$)`,
  'giu',
);
// Whether an identifier followed by "(" opens a URL token. A URL spelling inside a dimension, hash
// or at-keyword is not one.
const opensURL = (style: string, match: RegExpExecArray) =>
  match[2] === '(' &&
  !/[\w@#-]/u.test(style.charAt(match.index - 1)) &&
  unescapeCSS(match[1] ?? '').toLowerCase() === 'url';

// Where scanning resumes after a URL token's opening "(": past the closing parenthesis of an
// unquoted URL, where even a bad URL ends and /* is URL text, or unchanged before a quoted one.
const unquotedURLEnd = (style: string, from: number) => {
  let at = from;
  while (/[\t\n ]/u.test(style.charAt(at))) {
    at += 1;
  }
  if (style.charAt(at) === '"' || style.charAt(at) === "'") {
    return from;
  }
  while (at < style.length && style.charAt(at) !== ')') {
    at +=
      style.charAt(at) === '\\'
        ? (/^(?:[0-9a-f]{1,6}[\t\n ]?|[\s\S])/iu.exec(style.slice(at + 1))?.[0]
            .length ?? 0)
        : 0;
    at += 1;
  }
  return Math.min(at + 1, style.length);
};

const withoutCSSComments = (source: string, trivia = '  ') => {
  const style = source
    .replaceAll(/\r\n?|\f/gu, '\n')
    .replaceAll('\0', '\uFFFD');
  const chunks: string[] = [];
  let from = 0;
  cssLexeme.lastIndex = 0;
  for (
    let match = cssLexeme.exec(style);
    match !== null;
    match = cssLexeme.exec(style)
  ) {
    if (match[0].startsWith('/*')) {
      // One space can be consumed by a preceding hex escape and join the next token.
      chunks.push(style.slice(from, match.index), trivia);
      from = cssLexeme.lastIndex;
    } else if (opensURL(style, match)) {
      cssLexeme.lastIndex = unquotedURLEnd(style, cssLexeme.lastIndex);
    }
  }
  chunks.push(style.slice(from));
  return chunks.join('');
};
const commentTrivia = String.raw`(?:[\t\n\f\r ]|\/\*\*\/)*`;
const commentedImportance = new RegExp(
  `!${commentTrivia}${identSource}${commentTrivia}$`,
  'iu',
);

const readValue = (source: string) => {
  const marker = importance.exec(source);
  const important =
    marker !== null &&
    unescapeCSS(marker[1] ?? '').toLowerCase() === 'important';
  const raw = important ? trimCSS(source.slice(0, marker.index)) : source;
  // Trim only source whitespace: escaped whitespace belongs to the identifier.
  const value = unescapeCSS(raw);
  return {
    value,
    important,
    valid:
      !raw.includes('\\') ||
      (sourceCSSIdentifier.test(raw) && plainCSSIdentifier.test(value)),
  };
};

// A declaration that used escapes is emitted only when its decoded value cannot change how the
// emitted style splits or quotes.
const plainEscapedValue = /^[^;:"'\\\n\r\f]*$/u;

// One declaration's decoded name and value, or nothing when WebKit would reject it.
const readDeclaration = (source: string) => {
  const declaration = withoutCSSComments(source);
  const colon = declaration.indexOf(':');
  const name = unescapeCSS(trimCSS(declaration.slice(0, colon))).toLowerCase();
  const { value, important, valid } = readValue(
    trimCSS(declaration.slice(colon + 1)),
  );
  const sourceMath = withoutCSSComments(source, '/**/')
    .slice(source.indexOf(':') + 1)
    .replace(important ? commentedImportance : /$^/u, '')
    .replaceAll(new RegExp(`^${commentTrivia}|${commentTrivia}$`, 'gu'), '');
  const validMath =
    name !== 'opacity' ||
    !/^(?:calc|min|max|clamp)\(/iu.test(value) ||
    opacityNumber(sourceMath) !== undefined;
  return colon > 0 && valid && validMath && acceptedDeclaration(name, value)
    ? {
        name,
        value,
        important,
        unsafe: declaration.includes('\\') && !plainEscapedValue.test(value),
      }
    : undefined;
};

// Names and values are decoded before classification, so an escaped name hides what it names.
const parseDeclarations = (style: string) => {
  const declared = new Map<string, string>();
  const important = new Set<string>();
  const unsafe = new Set<string>();
  for (const declaration of splitDeclarations(
    withoutCSSComments(style, '/**/'),
  ).map(readDeclaration)) {
    if (
      declaration !== undefined &&
      (declaration.important || !important.has(declaration.name))
    ) {
      const { name, value } = declaration;
      if (declaration.important) {
        important.add(name);
      }
      if (declaration.unsafe) {
        unsafe.add(name);
      } else {
        unsafe.delete(name);
      }
      // Keep the last declaration's position as well as its value for shorthand precedence.
      declared.delete(name);
      declared.set(name, value);
    }
  }
  return { declared, unsafe };
};

function filterStyle(style: string, tag = ''): FilteredStyle {
  const { declared, unsafe } = parseDeclarations(style);
  const retained = new Map(
    [...declared].filter(
      (declaration) =>
        !unsafe.has(declaration[0]) && keptDeclaration(declaration),
    ),
  );
  const tableDisplay = tableDisplays.get(tag);
  if (
    tableDisplay !== undefined &&
    retained.get('display')?.toLowerCase() !== tableDisplay
  ) {
    retained.delete('display');
  }
  return {
    css: [...retained].map(([name, value]) => `${name}: ${value}`).join('; '),
    hidden: hiddenBy.some((check) => check(declared)),
    declared,
    retained,
  };
}

const escapeText = (value: string) =>
  value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
const escapeAttribute = (value: string) =>
  escapeText(value).replaceAll('"', '&quot;');

const attributeOf = (element: Element, name: string) =>
  element.attrs.find((attribute) => attribute.name.toLowerCase() === name)
    ?.value;

// A `cid:` reference as MIME resolution compares it: URI-decoded, without angle brackets.
const contentIdReference = (source: string) => {
  const reference = source.trim();
  if (!/^cid:/iu.test(reference)) {
    return undefined;
  }
  try {
    return decodeURIComponent(reference.slice(4)).replaceAll(/^<|>$/gu, '');
  } catch {
    return undefined;
  }
};

const isElement = (node: Node): node is Element => 'tagName' in node;

const visibilityIn = (style: FilteredStyle, parent: string) => {
  const value = style.retained.get('visibility')?.toLowerCase();
  if (
    value === undefined ||
    /^(?:inherit|unset|revert(?:-layer)?)$/u.test(value)
  ) {
    return parent;
  }
  return value === 'initial' ? 'visible' : value;
};

const directionIn = (element: Element, parent: string) => {
  const value = attributeOf(element, 'dir')?.trim().toLowerCase();
  return value !== undefined && /^(?:ltr|rtl)$/u.test(value) ? value : parent;
};

// Omit collapsed tracks and their contents, even if WebKit paints descendant overflow.
const tableTracks = new Set([
  'tr',
  'thead',
  'tbody',
  'tfoot',
  'col',
  'colgroup',
]);

// Elements that never reach the output: removed, foreign, or hidden from readers. Other
// hidden visibility is inherited state, which a descendant can make visible again.
const isDropped = (
  node: Element,
  style: FilteredStyle,
  visibility = 'visible',
) =>
  removed.has(node.tagName) ||
  node.namespaceURI !== htmlSpec.NS.HTML ||
  attributeOf(node, 'hidden') !== undefined ||
  style.hidden ||
  (tableTracks.has(node.tagName) &&
    visibilityIn(style, visibility) === 'collapse');

// Declared 1×1 or zero-sized images are tracking pixels, removed rather than shown as blocked.
const isTrackingPixel = (element: Element, style: FilteredStyle) => {
  const size = (name: 'width' | 'height') => {
    // A retained CSS dimension overrides the HTML attribute, even when it is not in pixels.
    const dimension = pixels(
      style.retained.get(name) ?? attributeOf(element, name),
    );
    const maximum = pixels(style.retained.get(`max-${name}`));
    const minimumValue = style.retained.get(`min-${name}`);
    const minimum = pixels(minimumValue);
    const bounded =
      maximum === undefined
        ? dimension
        : Math.min(dimension ?? maximum, maximum);
    // A minimum cannot establish an unknown size, and a relative minimum may beat any maximum.
    if (
      bounded === undefined ||
      (minimumValue !== undefined && minimum === undefined)
    ) {
      return undefined;
    }
    // CSS lets a retained pixel minimum win over both the size and the maximum.
    return minimum === undefined ? bounded : Math.max(bounded, minimum);
  };
  const width = size('width');
  const height = size('height');
  return (
    width === 0 ||
    height === 0 ||
    (width !== undefined && width <= 1 && height !== undefined && height <= 1)
  );
};

// Leading-digit integer attributes as HTML table layout reads them, within its limits.
const tableSpans = new Set(['span', 'colspan', 'rowspan']);
const span = (raw: string | undefined, name: string) => {
  const value = /^\s*\+?(?<digits>\d+)/u.exec(raw ?? '')?.[1];
  const parsed = value === undefined ? Number.NaN : Number(value);
  return Number.isNaN(parsed) || parsed < (name === 'rowspan' ? 0 : 1)
    ? 1
    : Math.min(parsed, name === 'rowspan' ? 65_534 : 1000);
};

// One admitted attribute with a valid value, or nothing.
const keptAttribute =
  (tag: string, allowed: ReadonlySet<string>) =>
  ({ name: raw, value }: Readonly<{ name: string; value: string }>) => {
    const attribute = raw.toLowerCase();
    const rule =
      attribute === 'type' ? listTypes[tag] : attributeRules[attribute];
    if (allowed.has(attribute) && tableSpans.has(attribute)) {
      return ` ${attribute}="${span(value, attribute)}"`;
    }
    // Removing a CSS height must not reactivate an oversized table-cell height hint.
    if (
      attribute === 'height' &&
      ['td', 'th'].includes(tag) &&
      farRight(value.trim().replace(/^\d+$/u, '$&px'), bodyFontPixels)
    ) {
      return '';
    }
    return allowed.has(attribute) && rule?.test(value.trim()) === true
      ? ` ${attribute}="${escapeAttribute(value.trim())}"`
      : '';
  };

// A quotation's source, kept only as an inert web address.
const citeAttribute = (element: Element) => {
  const cite = attributeOf(element, 'cite')?.trim() ?? '';
  return (element.tagName === 'blockquote' || element.tagName === 'q') &&
    /^https?:\/\/\S+$/iu.test(cite)
    ? ` cite="${escapeAttribute(cite)}"`
    : '';
};

// The element's admitted attributes, each value validated, and its filtered style.
const attributes = (element: Element, style: FilteredStyle) => {
  const allowed = new Set([
    'dir',
    'lang',
    'title',
    ...(elementAttributes[element.tagName] ?? []),
  ]);
  return (
    element.attrs.map(keptAttribute(element.tagName, allowed)).join('') +
    citeAttribute(element) +
    (style.css === '' ? '' : ` style="${escapeAttribute(style.css)}"`)
  );
};

// Admitted elements keep their name; other structural content becomes a block or inline span.
// Elements WebKit lays out inline, whose vertical margins move nothing.
const inlineTags = new Set([
  'a',
  'b',
  'cite',
  'code',
  'em',
  'i',
  'q',
  's',
  'small',
  'span',
  'strike',
  'strong',
  'sub',
  'sup',
  'u',
]);

const outputTag = (name: string) => {
  if (admitted.has(name)) {
    return name;
  }
  return asBlock.has(name) ? 'div' : 'span';
};

const displayOf = (name: string, style: FilteredStyle) =>
  style.retained.get('display')?.toLowerCase() ??
  tableDisplays.get(name) ??
  (inlineTags.has(outputTag(name)) || name === 'br' || name === 'img'
    ? 'inline'
    : 'block');

const childElements = (parent: Element, names: readonly string[]) =>
  parent.childNodes.filter(
    (node): node is Element => isElement(node) && names.includes(node.tagName),
  );

const visibilityOf = (element: Element, parent: string) =>
  visibilityIn(
    filterStyle(attributeOf(element, 'style') ?? '', element.tagName),
    parent,
  );

// Elements the walker removes cannot contribute slots to the emitted table's layout. Collapse
// columns still contribute slots until their hidden cells have been identified.
const tableElements = (
  parent: Element,
  names: readonly string[],
  visibility = 'visible',
) =>
  childElements(parent, names).filter((node) => {
    const style = filterStyle(attributeOf(node, 'style') ?? '', node.tagName);
    return /^(?:col|colgroup)$/u.test(node.tagName)
      ? attributeOf(node, 'hidden') === undefined &&
          !/^none$/iu.test(style.declared.get('display') ?? '')
      : !isDropped(node, style, visibility);
  });

const emptyColumnGroup = (node: Element) =>
  node.tagName === 'colgroup' &&
  childElements(node, ['col']).length > 0 &&
  tableElements(node, ['col']).length === 0;

const droppedColumnGroup = (node: Element) =>
  node.tagName === 'colgroup' &&
  childElements(node, ['col']).length > 0 &&
  childElements(node, ['col']).every((col) =>
    isDropped(col, filterStyle(attributeOf(col, 'style') ?? '', 'col')),
  );

// Column indices a table's colgroup and col elements collapse. A col inherits its group's
// visibility; hidden columns do not hide their cells.
const collapsedColumns = (
  table: Element,
  spend: (slots: number) => void,
  tableVisibility: string,
) => {
  const collapsed = new Set<number>();
  let column = 0;
  for (const group of tableElements(table, ['colgroup']).filter(
    (candidate) => !emptyColumnGroup(candidate),
  )) {
    const groupVisibility = visibilityOf(group, tableVisibility);
    const cols = tableElements(group, ['col']);
    const tracks =
      cols.length === 0
        ? [
            {
              count: span(attributeOf(group, 'span'), 'span'),
              visibility: groupVisibility,
            },
          ]
        : cols.map((col) => ({
            count: span(attributeOf(col, 'span'), 'span'),
            visibility: visibilityOf(col, groupVisibility),
          }));
    for (const { count, visibility } of tracks) {
      spend(count);
      for (let index = 0; index < count; index += 1) {
        if (visibility === 'collapse') {
          collapsed.add(column);
        }
        column += 1;
      }
    }
  }
  return collapsed;
};

const firstFree = (occupied: readonly number[], from: number) => {
  let column = from;
  while ((occupied[column] ?? 0) > 0) {
    column += 1;
  }
  return column;
};

// Places one row's cells after the slots earlier rows still span, recording collapsed ones.
const placeRow = (
  row: Element,
  {
    occupied,
    collapsed,
    cells,
    spend,
  }: Readonly<{
    occupied: number[];
    collapsed: ReadonlySet<number>;
    cells: Set<Element>;
    spend: (slots: number) => void;
  }>,
) => {
  let column = 0;
  for (const cell of tableElements(row, ['td', 'th'])) {
    const width = span(attributeOf(cell, 'colspan'), 'colspan');
    // Account for both free-slot search and the final occupancy sweep before doing either.
    spend((occupied.length + width) * 2);
    const start = firstFree(occupied, column);
    const rows = span(attributeOf(cell, 'rowspan'), 'rowspan');
    const columns = Array.from({ length: width }, (_, index) => start + index);
    if (columns.every((index) => collapsed.has(index))) {
      cells.add(cell);
    }
    for (const index of columns) {
      occupied[index] = Math.max(
        occupied[index] ?? 0,
        rows === 0 ? Number.POSITIVE_INFINITY : rows,
      );
    }
    column = start + width;
  }
  occupied.forEach((rows, index) => {
    occupied[index] = Math.max(0, rows - 1);
  });
};

// Cells lying entirely in collapsed columns, placed as table layout places them: each row group
// separately, skipping slots that cells from earlier rows still span.
const collapsedCells = (
  table: Element,
  spend: (slots: number) => void,
  visibility: string,
) => {
  const collapsed = collapsedColumns(table, spend, visibility);
  const cells = new Set<Element>();
  if (collapsed.size > 0) {
    for (const group of tableElements(
      table,
      ['thead', 'tbody', 'tfoot'],
      visibility,
    )) {
      const occupied: number[] = [];
      for (const row of tableElements(
        group,
        ['tr'],
        visibilityOf(group, visibility),
      )) {
        spend(occupied.length);
        placeRow(row, { occupied, collapsed, cells, spend });
      }
    }
  }
  return cells;
};

// The most consecutive line breaks kept between visible content, and the most height they may
// add: half the narrowest reader, so tall lines cannot move the text after them out of view.
const maximumBreaks = 4;
const maximumBreakPixels = narrowestReaderPixels / 2;

// An inherited line height: a factor, a computed length, or font-dependent normal metrics.
type LineHeight = Readonly<
  { factor: number } | { pixels: number } | { normal: true }
>;
const normalLineHeight: LineHeight = { normal: true };

const systemFontIn = (value: string | undefined, parent: boolean) => {
  const family = value?.trim().toLowerCase();
  return family === undefined || /^(?:inherit|unset)$/u.test(family)
    ? parent
    : /^(?:-apple-system|system-ui)$/u.test(family);
};

const lineHeightIn = (
  value: string | undefined,
  parent: LineHeight,
  font: number,
): LineHeight => {
  const declared = value?.trim().toLowerCase();
  if (declared === undefined || /^(?:inherit|unset)$/u.test(declared)) {
    return parent;
  }
  if (/^(?:normal|initial|revert(?:-layer)?)$/u.test(declared)) {
    return normalLineHeight;
  }
  const factor = Number(declared);
  if (declared !== '' && Number.isFinite(factor) && factor >= 0) {
    return { factor };
  }
  const resolved = lengthPixels(declared, { font, percent: font });
  return resolved === undefined || resolved < 0 ? parent : { pixels: resolved };
};

const contentSecurityPolicy =
  "default-src 'none'; img-src data:; media-src 'none'; style-src 'unsafe-inline'; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";

// The app's fixed light canvas: sender colors are removed, so the app sets text, background and
// link colors together.
const readerStyle =
  ':root{color-scheme:light;font-size:16px}html,body{margin:0;padding:0;background:#fff;color:#17202a}' +
  'body{font:-apple-system-body;font-family:-apple-system,system-ui,sans-serif;line-height:1.5;' +
  'overflow-wrap:anywhere;-webkit-text-size-adjust:100%}a{color:#245cca}' +
  'img{max-width:100%;height:auto}table{max-width:100%}pre{white-space:pre-wrap}' +
  '.blocked-image{display:inline-block;border:1px dashed #a3afbf;border-radius:4px;' +
  'padding:2px 6px;color:#596574;font-size:max(4px,.85em)}';

// Turns untrusted HTML into a passive document: allowlisted elements, attributes, CSS and URLs,
// sender colors removed, remote images replaced by non-loading placeholders, and only admitted
// inline images shown, as `data:` sources the app generated from validated bytes.
// An image description as readable text, spaced from its neighbours.
const altText = (alt: string) => (alt === '' ? '' : ` ${alt} `);

const withProperties = (
  style: FilteredStyle,
  entries: ReadonlyArray<readonly [string, string]>,
): FilteredStyle => {
  const retained = new Map(style.retained);
  for (const [name, value] of entries) {
    // Overrides must follow shorthands even when the sender already supplied a longhand.
    retained.delete(name);
    retained.set(name, value);
  }
  return {
    ...style,
    retained,
    css: [...retained].map(([key, value]) => `${key}: ${value}`).join('; '),
  };
};

const whiteSpaceIn = (
  value: string | undefined,
  tag: string,
  parent: string,
) => {
  const declared = value?.toLowerCase() ?? '';
  if (
    /^(?:normal|nowrap|pre|pre-wrap|pre-line|break-spaces)$/u.test(declared)
  ) {
    return declared;
  }
  if (declared === 'initial') {
    return 'normal';
  }
  if (/^(?:inherit|unset)$/u.test(declared)) {
    return parent;
  }
  return tag === 'pre' ? 'pre-wrap' : parent;
};

export function sanitizeHtml(
  html: string,
  images: ReadonlyMap<string, InlineImage> = new Map(),
  preserveImages = false,
): SanitizedHtml {
  const builder = paragraphBuilder();
  const contentIds: string[] = [];
  const discovered = new Set<string>();
  const contentIdOccurrences: string[] = [];
  const links: BodyLink[] = [];
  let hidesImages = false;
  let output = '';
  // The link currently open in the readable fallback, and its collected visible text.
  let link:
    | { href: string; text: string; description: string; visible: boolean }
    | undefined = undefined;
  let whiteSpace = 'normal';
  let visibleContent = 0;
  // Off-canvas text boxes, and inherited font size and indent states.
  let direction = 'ltr';
  let margins: ReadonlyMap<string, string> = new Map();
  let fontPixels = bodyFontPixels;
  let visibility = 'visible';
  const visibleNow = () => visibility === 'visible';
  // Consecutive line breaks since the last visible text or image, and the height they add.
  let breakRun = 0;
  let breakPixels = 0;
  // The reader's body text uses a line height of 1.5.
  let lineHeight: LineHeight = { factor: 1.5 };
  let systemFont = true;
  // A smaller inline child cannot shrink its ancestor's line-box strut. Conservatively
  // keep the largest active ancestor line until traversal leaves that ancestor.
  let ancestorLinePixels = bodyFontPixels * 1.5;
  const linePixels = () => {
    // Normal depends on the chosen font's metrics. The system-font estimate must not
    // grant cheap breaks to arbitrary taller sender fonts; keep their text and font.
    if ('normal' in lineHeight && !systemFont) {
      return Infinity;
    }
    const height =
      'pixels' in lineHeight
        ? lineHeight.pixels
        : ('factor' in lineHeight ? lineHeight.factor : 1.2) * fontPixels;
    return Math.max(ancestorLinePixels, height);
  };
  // Whether one more break fits the run, counting it if so.
  const takeBreak = (height = linePixels()) => {
    if (
      breakRun >= maximumBreaks ||
      breakPixels + height > maximumBreakPixels
    ) {
      return false;
    }
    breakRun += 1;
    breakPixels += height;
    return true;
  };
  const resetBreaks = () => {
    breakRun = 0;
    breakPixels = 0;
  };
  const readableNow = () => fontPixels >= minimumTextPixels && visibleNow();
  // Cells of collapsed table columns, which WebKit would not show.
  const collapsed = new Set<Element>();
  // One bound across every table, including nested ones, before span expansion or slot scans.
  let tableWork = 1_000_000;
  const spendTableWork = (slots: number) => {
    tableWork -= slots;
    if (tableWork < 0) {
      throw new RangeError('Message table layout exceeds its work limit');
    }
  };

  // Text newlines and elements share the run across text nodes and containers.
  const textWithBreakLimit = (value: string) =>
    value.replaceAll(/\n|[^\n]+/gu, (part) => {
      if (part === '\n') {
        if (!takeBreak()) {
          return '';
        }
      } else if (readableNow() && hasVisibleText(part)) {
        resetBreaks();
      }
      return part;
    });

  const addReadableText = (readable: string, preservesLines: boolean) => {
    if (!readableNow()) {
      return;
    }
    builder.add(readable, link?.href);
    if (hasVisibleText(readable)) {
      visibleContent += 1;
      if (!preservesLines) {
        resetBreaks();
      }
    }
    if (link !== undefined) {
      link.text += readable;
    }
  };

  const addText = (value: string) => {
    // Hidden text has layout width even though it supplies no inspected label. Within a
    // link, omit it without dropping descendants that restore visibility.
    if (link !== undefined && !readableNow()) {
      return;
    }
    const preservesLines = /^(?:pre|pre-wrap|pre-line|break-spaces)$/u.test(
      whiteSpace,
    );
    const normalized = preservesLines ? textWithBreakLimit(value) : value;
    let readable = normalized;
    if (!preservesLines) {
      readable = normalized.replaceAll(/[\t\n\f\r ]+/gu, ' ');
    } else if (whiteSpace === 'pre-line') {
      readable = normalized.replaceAll(/[\t\f\r ]+/gu, ' ');
    }
    addReadableText(readable, preservesLines);
    if (link !== undefined && visibleNow() && hasVisibleText(normalized)) {
      link.visible = true;
    }
    output += escapeText(normalized);
  };

  // Descriptions stay in the readable fallback. Only placeholder descriptions are painted;
  // admitted image alt text supplies a rich link label when there is no painted text.
  const describeImage = (alt: string, painted = true, contentId?: string) => {
    if (readableNow() || (preserveImages && contentId !== undefined)) {
      builder.add(
        altText(alt),
        link?.href,
        preserveImages ? contentId : undefined,
      );
      if (link !== undefined) {
        if (painted) {
          link.text += altText(alt);
        } else {
          link.description += altText(alt);
        }
      }
    }
  };

  const placeholder = (alt: string, style: FilteredStyle) => {
    hidesImages = true;
    describeImage(alt);
    const values = [
      ...(fontPixels < minimumTextPixels ? [`font-size: ${fontPixels}px`] : []),
      ...(style.retained.has('visibility') ? ['visibility: visible'] : []),
    ];
    const override = values.length === 0 ? '' : ` style="${values.join('; ')}"`;
    output += `<span class="blocked-image"${override} role="img" aria-label="${escapeAttribute(alt === '' ? 'Image not loaded' : alt)}">${escapeText(alt === '' ? 'Image' : alt)}</span>`;
  };

  // Records a visible Content-ID reference for MIME resolution. Resolution attempts only the
  // first unique references, so later ones are never collected and render as placeholders.
  const reference = (element: Element) => {
    const contentId = contentIdReference(attributeOf(element, 'src') ?? '');
    if (contentId !== undefined) {
      contentIdOccurrences.push(contentId);
    }
    if (contentId !== undefined && !discovered.has(contentId)) {
      discovered.add(contentId);
      if (contentIds.length < inlineImageLimits.attempts) {
        contentIds.push(contentId);
      }
    }
    return contentId === undefined ? undefined : images.get(contentId);
  };

  const image = (element: Element, style: FilteredStyle) => {
    if (
      isTrackingPixel(element, style) ||
      // Dropped from the output too, so WebKit never draws what is not requested.
      /^contents$/iu.test(style.declared.get('display') ?? '')
    ) {
      return;
    }
    if (!visibleNow()) {
      // Hidden boxes can still displace a link's inspected suffix. Other hidden images
      // retain declared geometry, without a source, bytes or a readable placeholder.
      const hiddenStyle =
        link === undefined
          ? style
          : withProperties(style, [['display', 'none']]);
      output += `<img${attributes(element, hiddenStyle)}>`;
      return;
    }
    if (link !== undefined) {
      link.visible = true;
    }
    resetBreaks();
    visibleContent += 1;
    const alt = (attributeOf(element, 'alt') ?? '').trim();
    const admittedImage = reference(element);
    if (admittedImage === undefined) {
      placeholder(alt, style);
      return;
    }
    output += `<img${attributes(element, style)} src="data:${admittedImage.mimeType};base64,${admittedImage.data}">`;
    describeImage(alt, false, admittedImage.contentId);
  };

  const anchor = (element: Element, style: FilteredStyle) => {
    const href = vettedHref(attributeOf(element, 'href') ?? '');
    if (
      href === undefined ||
      link !== undefined ||
      links.length >= messageLinkLimit
    ) {
      output += `<span${attributes(element, style)}>`;
      children(element);
      output += '</span>';
      return;
    }
    const before = output;
    output = '';
    // A link is offered only when something visible is rendered inside it.
    link = { href, text: '', description: '', visible: false };
    const opened = link;
    children(element);
    link = undefined;
    const tag = opened.visible ? 'a' : 'span';
    const destination = opened.visible
      ? ` href="${messageLinkHref(links.length)}" rel="noreferrer noopener"`
      : '';
    output = `${before}<${tag}${attributes(element, style)}${destination}>${output}</${tag}>`;
    if (opened.visible) {
      const label = hasVisibleText(opened.text)
        ? opened.text
        : opened.description;
      links.push({ href, text: label.replaceAll(/\s+/gu, ' ').trim() });
    }
  };

  // Readable markers a container adds before its content.
  const marker = (name: string) => {
    if (!readableNow()) {
      return;
    }
    if (name === 'li') {
      builder.add('• ', undefined);
    } else if (name === 'td' || name === 'th') {
      builder.add(' ', link?.href);
    }
  };

  const container = (node: Element, style: FilteredStyle) => {
    const name = node.tagName;
    const tag = outputTag(name);
    const before = output.length;
    const content = visibleContent;
    output += `<${tag}${attributes(node, style)}>`;
    const start = output.length;
    marker(name);
    children(node);
    if (link !== undefined && visibleContent === content) {
      // Empty boxes can accumulate thousands of pixels with individually ordinary sizes.
      // Keep descendants and inherited text styles, but give the empty wrapper no box.
      const normalized = withProperties(style, [['display', 'contents']]);
      output = `${output.slice(0, before)}<${tag}${attributes(node, normalized)}>${output.slice(start)}`;
    }
    output += `</${tag}>`;
  };

  // Elements with their own output; every other kept element is a container.
  const special = new Map<
    string,
    (node: Element, style: FilteredStyle) => void
  >([
    ['img', image],
    ['a', anchor],
    [
      'br',
      (node, style) => {
        // A long run of breaks would push the text after it out of view, away from the
        // label it extends, so only a few consecutive breaks are kept.
        if (!takeBreak()) {
          return;
        }
        if (readableNow()) {
          builder.add('\n', link?.href);
        }
        output += `<br${attributes(node, style)}>`;
      },
    ],
    [
      'hr',
      (node, style) => {
        // A rule ends the preceding line and adds its own box, including margins and
        // borders. Pin its vertical geometry to the ordinary rule rather than infer
        // sender-controlled sizing, padding, border shorthands or inherited margins.
        if (!takeBreak(linePixels() + fontPixels + 2)) {
          return;
        }
        if (link !== undefined && visibleNow()) {
          link.visible = true;
        }
        const normalized = withProperties(style, [
          ['display', 'block'],
          ['height', '0'],
          ['min-height', '0'],
          ['max-height', '0'],
          ['padding-top', '0'],
          ['padding-bottom', '0'],
          ['margin-top', '.5em'],
          ['margin-bottom', '.5em'],
          ['border-top-width', '1px'],
          ['border-bottom-width', '1px'],
        ]);
        output += `<hr${attributes(node, normalized)}>`;
      },
    ],
  ]);

  // A blocked-image span drops the source image's margins along with its geometry.
  const textMargins = (node: Element, style: FilteredStyle) =>
    node.tagName === 'img' &&
    !images.has(contentIdReference(attributeOf(node, 'src') ?? '') ?? '')
      ? new Map<string, string>()
      : marginEdges(style.retained, margins);

  // Font size and visibility inherit, and a descendant can reset each one.
  const withTextState = (
    style: FilteredStyle,
    node: Element,
    run: (style: FilteredStyle) => void,
  ) => {
    const parentDirection = direction;
    const parentMargins = margins;
    const parentFont = fontPixels;
    const parentWhiteSpace = whiteSpace;
    const parentSystemFont = systemFont;
    systemFont = systemFontIn(
      style.retained.get('font-family'),
      parentSystemFont,
    );
    const replacedImage =
      node.tagName === 'img' &&
      !images.has(contentIdReference(attributeOf(node, 'src') ?? '') ?? '');
    fontPixels = replacedImage
      ? parentFont * 0.85
      : fontSizeIn(style.retained.get('font-size'), parentFont, node.tagName);
    const sizedStyle = replacedImage
      ? style
      : normalizeFont(style, node.tagName, fontPixels);
    direction = directionIn(node, direction);
    const display = displayOf(node.tagName, sizedStyle);
    const ownMargins = textMargins(node, sizedStyle);
    const normalized = normalizeMargins(sizedStyle, ownMargins, {
      display:
        node.tagName === 'img' && display === 'inline'
          ? 'inline-block'
          : display,
      directional: direction === 'rtl' || parentDirection === 'rtl',
      font: fontPixels,
    });
    margins = ownMargins;
    const inheritedVisibility = visibility;
    visibility = visibilityIn(style, visibility);
    whiteSpace = whiteSpaceIn(
      style.retained.get('white-space'),
      node.tagName,
      parentWhiteSpace,
    );
    const parentLineHeight = lineHeight;
    const parentAncestorLinePixels = ancestorLinePixels;
    lineHeight = lineHeightIn(
      normalized.retained.get('line-height'),
      parentLineHeight,
      fontPixels,
    );
    ancestorLinePixels = linePixels();
    run(normalized);
    ancestorLinePixels = parentAncestorLinePixels;
    lineHeight = parentLineHeight;
    direction = parentDirection;
    margins = parentMargins;
    fontPixels = parentFont;
    visibility = inheritedVisibility;
    whiteSpace = parentWhiteSpace;
    systemFont = parentSystemFont;
  };

  const element = (node: Element) => {
    const name = node.tagName.toLowerCase();
    const style = filterStyle(attributeOf(node, 'style') ?? '', name);
    if (isDropped(node, style, visibility) || collapsed.has(node)) {
      return;
    }
    if (droppedColumnGroup(node)) {
      return;
    }
    if (name === 'table') {
      for (const cell of collapsedCells(
        node,
        spendTableWork,
        visibilityIn(style, visibility),
      )) {
        collapsed.add(cell);
      }
    }
    const block = paragraphs.has(name);
    if (block) {
      builder.end();
    }
    withTextState(style, node, (normalized) => {
      (special.get(name) ?? container)(node, normalized);
    });
    if (block) {
      builder.end();
    }
  };

  function children(parent: DefaultTreeAdapterTypes.ParentNode) {
    for (const node of parent.childNodes) {
      if (node.nodeName === '#text' && 'value' in node) {
        addText(node.value);
      } else if (isElement(node)) {
        element(node);
      }
    }
  }

  const document = parse(html);
  const root = document.childNodes.find(isElement);
  const body = root?.childNodes.find(
    (node): node is Element => isElement(node) && node.tagName === 'body',
  );
  if (body !== undefined) {
    children(body);
  }
  builder.end();
  const readable = { paragraphs: builder.paragraphs, hidesImages };
  return {
    document:
      `<!doctype html><html><head><meta charset="utf-8">` +
      `<meta http-equiv="Content-Security-Policy" content="${contentSecurityPolicy}">` +
      `<meta name="referrer" content="no-referrer">` +
      `<meta name="viewport" content="width=device-width, initial-scale=1">` +
      `<style>${readerStyle}</style></head><body>${output}</body></html>`,
    readable,
    // A blocked-image placeholder is visible content too, so an image-only message renders.
    renderable:
      hasReadableText(readable) || contentIds.length > 0 || hidesImages,
    contentIds,
    contentIdOccurrences,
    links,
  };
}
