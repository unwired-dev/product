/* oxlint-disable typescript/prefer-readonly-parameter-types -- parse5 tree nodes are mutable library types; the sanitizer only reads them. */
import type { DefaultTreeAdapterTypes } from 'parse5';

import { html as htmlSpec, parse } from 'parse5';

import type { ImageFacts } from './inline-images.ts';
import type { ReadableBody } from './readable-text.ts';

import { messageLinkHref, vettedHref } from './link-inspection.ts';
import { hasReadableText, paragraphBuilder } from './readable-text.ts';

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

// CSS properties kept from a sender's inline style; colors and backgrounds are the app's.
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

const parseDeclarations = (style: string) => {
  const declared = new Map<string, string>();
  for (const declaration of style.split(';')) {
    const colon = declaration.indexOf(':');
    if (colon > 0) {
      const name = declaration.slice(0, colon).trim().toLowerCase();
      // Keep the last declaration's position as well as its value for shorthand precedence.
      declared.delete(name);
      declared.set(
        name,
        declaration
          .slice(colon + 1)
          .replace(/!\s*important\s*$/iu, '')
          .trim(),
      );
    }
  }
  return declared;
};

// Content no one sees: hidden preheaders, zero-sized or off-canvas text.
const hiddenBy: ReadonlyArray<
  (declared: ReadonlyMap<string, string>) => boolean
> = [
  (declared) => /^none$/iu.test(declared.get('display') ?? ''),
  (declared) => {
    const opacity = /^(?<amount>[+-]?\d*(?:\.\d+)?)(?:%)?$/u.exec(
      declared.get('opacity') ?? '',
    );
    return opacity !== null && opacity[1] !== '' && Number(opacity[1]) <= 0;
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
  for (const [name, value] of retained) {
    if (
      spacingProperties.has(name) &&
      value.split(/\s+/u).some((token) => farRight(token, font))
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
  for (const edge of ['left', 'right', 'top']) {
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

const validSize = (name: string, value: string) =>
  name === 'font-size'
    ? cssFontSize(value)
    : !dimensionProperties.has(name) || cssDimension(value);

// Properties WebKit accepts only as one of these keywords.
const keywordValues = new Map([
  ['display', displays],
  [
    'visibility',
    /^(?:visible|hidden|collapse|inherit|initial|unset|revert(?:-layer)?)$/iu,
  ],
]);

const keptDeclaration = ([name, value]: readonly [string, string]) =>
  properties.has(name) &&
  value !== '' &&
  !unsafeValue.test(value) &&
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

function filterStyle(style: string, tag = ''): FilteredStyle {
  const declared = parseDeclarations(style);
  const retained = new Map([...declared].filter(keptDeclaration));
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

export function sanitizeHtml(
  html: string,
  images: ReadonlyMap<string, InlineImage> = new Map(),
): SanitizedHtml {
  const builder = paragraphBuilder();
  const contentIds: string[] = [];
  const contentIdOccurrences: string[] = [];
  const links: BodyLink[] = [];
  let hidesImages = false;
  let output = '';
  // The link currently open in the readable fallback, and its collected visible text.
  let link: { href: string; text: string; visible: boolean } | undefined =
    undefined;
  let preformatted = 0;
  // Off-canvas text boxes, and inherited font size and indent states.
  let direction = 'ltr';
  let margins: ReadonlyMap<string, string> = new Map();
  let fontPixels = bodyFontPixels;
  let visibility = 'visible';
  const visibleNow = () => visibility === 'visible';
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

  const addText = (value: string) => {
    const readable =
      preformatted > 0 ? value : value.replaceAll(/[\t\n\f\r ]+/gu, ' ');
    if (readableNow()) {
      builder.add(readable, link?.href);
    }
    if (link !== undefined && readableNow()) {
      link.text += readable;
    }
    if (link !== undefined && visibleNow()) {
      link.visible = true;
    }
    output += escapeText(value);
  };

  // An image description reads as text, including in its enclosing link's inspected text.
  const describeImage = (alt: string) => {
    if (readableNow()) {
      builder.add(altText(alt), link?.href);
      if (link !== undefined) {
        link.text += altText(alt);
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

  // Records a visible Content-ID reference for MIME resolution.
  const reference = (element: Element) => {
    const contentId = contentIdReference(attributeOf(element, 'src') ?? '');
    if (contentId !== undefined) {
      contentIdOccurrences.push(contentId);
    }
    if (contentId !== undefined && !contentIds.includes(contentId)) {
      contentIds.push(contentId);
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
      // Preserve declared geometry without a source, decoded bytes or a readable placeholder.
      output += `<img${attributes(element, style)}>`;
      return;
    }
    if (link !== undefined) {
      link.visible = true;
    }
    const alt = (attributeOf(element, 'alt') ?? '').trim();
    const admittedImage = reference(element);
    if (admittedImage === undefined) {
      placeholder(alt, style);
      return;
    }
    output += `<img${attributes(element, style)} src="data:${admittedImage.mimeType};base64,${admittedImage.data}">`;
    describeImage(alt);
  };

  const anchor = (element: Element, style: FilteredStyle) => {
    const href = vettedHref(attributeOf(element, 'href') ?? '');
    if (href === undefined || link !== undefined) {
      output += `<span${attributes(element, style)}>`;
      children(element);
      output += '</span>';
      return;
    }
    const before = output;
    output = '';
    link = { href, text: '', visible: visibleNow() };
    const opened = link;
    children(element);
    link = undefined;
    const tag = opened.visible ? 'a' : 'span';
    const destination = opened.visible
      ? ` href="${messageLinkHref(links.length)}" rel="noreferrer noopener"`
      : '';
    output = `${before}<${tag}${attributes(element, style)}${destination}>${output}</${tag}>`;
    if (opened.visible) {
      links.push({ href, text: opened.text.replaceAll(/\s+/gu, ' ').trim() });
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
    if (link !== undefined && visibleNow()) {
      link.visible = true;
    }
    const name = node.tagName;
    const tag = outputTag(name);
    output += `<${tag}${attributes(node, style)}>`;
    marker(name);
    const pre = name === 'pre' ? 1 : 0;
    preformatted += pre;
    children(node);
    preformatted -= pre;
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
        if (readableNow()) {
          builder.add('\n', link?.href);
        }
        output += `<br${attributes(node, style)}>`;
      },
    ],
    [
      'hr',
      (node, style) => {
        if (link !== undefined && visibleNow()) {
          link.visible = true;
        }
        output += `<hr${attributes(node, style)}>`;
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
    run(normalized);
    direction = parentDirection;
    margins = parentMargins;
    fontPixels = parentFont;
    visibility = inheritedVisibility;
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
