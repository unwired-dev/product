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
  dir: /^(?:ltr|rtl|auto)$/iu,
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

const parseDeclarations = (style: string) =>
  new Map(
    style.split(';').flatMap((declaration) => {
      const colon = declaration.indexOf(':');
      return colon > 0
        ? [
            [
              declaration.slice(0, colon).trim().toLowerCase(),
              declaration
                .slice(colon + 1)
                .replace(/!\s*important\s*$/iu, '')
                .trim(),
            ] as const,
          ]
        : [];
    }),
  );

const declaredZero = (
  declared: ReadonlyMap<string, string>,
  names: readonly string[],
) => names.some((name) => pixels(declared.get(name)) === 0);

// Content no one sees: hidden preheaders, zero-sized or off-canvas text.
const hiddenBy: ReadonlyArray<
  (declared: ReadonlyMap<string, string>) => boolean
> = [
  (declared) => /^none$/iu.test(declared.get('display') ?? ''),
  (declared) =>
    /^(?:hidden|collapse)$/iu.test(declared.get('visibility') ?? ''),
  (declared) => {
    const opacity = /^(?<amount>[+-]?\d*(?:\.\d+)?)(?:%)?$/u.exec(
      declared.get('opacity') ?? '',
    );
    return opacity !== null && opacity[1] !== '' && Number(opacity[1]) <= 0;
  },
];

// These wrappers may still paint overflowing images. Only their text is unreadable.
const unreadableText = (declared: ReadonlyMap<string, string>) =>
  declaredZero(declared, [
    'font-size',
    'line-height',
    'max-height',
    'max-width',
  ]) ||
  (declaredZero(declared, ['height', 'width']) &&
    /hidden/iu.test(declared.get('overflow') ?? '')) ||
  /^-\d{4,}/u.test(declared.get('text-indent') ?? '') ||
  ['margin', 'margin-top', 'margin-right', 'margin-bottom', 'margin-left'].some(
    (name) =>
      (declared.get(name) ?? '')
        .split(/\s+/u)
        .some((value) => /^-\d{4,}/u.test(value)),
  );

// Sizes WebKit applies only when they follow the validated dimension grammar.
const dimensionProperties = new Set([
  'width',
  'height',
  'max-width',
  'max-height',
  'min-width',
  'min-height',
]);

const keptDeclaration = ([name, value]: readonly [string, string]) =>
  properties.has(name) &&
  value !== '' &&
  !unsafeValue.test(value) &&
  (!dimensionProperties.has(name) || cssDimension(value)) &&
  (name !== 'display' || displays.test(value));

function filterStyle(style: string): FilteredStyle {
  const declared = parseDeclarations(style);
  const retained = new Map([...declared].filter(keptDeclaration));
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

// Declared 1×1 or zero-sized images are tracking pixels, removed rather than shown as blocked.
const isTrackingPixel = (element: Element, style: FilteredStyle) => {
  const size = (name: 'width' | 'height') => {
    // A retained CSS dimension overrides the HTML attribute, even when it is not in pixels.
    const dimension = pixels(
      style.retained.get(name) ?? attributeOf(element, name),
    );
    const maximum = pixels(style.retained.get(`max-${name}`));
    return maximum === undefined
      ? dimension
      : Math.min(dimension ?? maximum, maximum);
  };
  const width = size('width');
  const height = size('height');
  return (
    width === 0 ||
    height === 0 ||
    (width !== undefined && width <= 1 && height !== undefined && height <= 1)
  );
};

// One admitted attribute with a valid value, or nothing.
const keptAttribute =
  (tag: string, allowed: ReadonlySet<string>) =>
  ({ name: raw, value }: Readonly<{ name: string; value: string }>) => {
    const attribute = raw.toLowerCase();
    const rule =
      attribute === 'type' ? listTypes[tag] : attributeRules[attribute];
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
const outputTag = (name: string) => {
  if (admitted.has(name)) {
    return name;
  }
  return asBlock.has(name) ? 'div' : 'span';
};

// Elements that never reach the output: removed, foreign, or hidden from readers.
const isDropped = (node: Element, name: string, style: FilteredStyle) =>
  removed.has(name) ||
  node.namespaceURI !== htmlSpec.NS.HTML ||
  attributeOf(node, 'hidden') !== undefined ||
  style.hidden;

const contentSecurityPolicy =
  "default-src 'none'; img-src data:; media-src 'none'; style-src 'unsafe-inline'; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";

// The app's fixed light canvas: sender colors are removed, so the app sets text, background and
// link colors together.
const readerStyle =
  ':root{color-scheme:light}html,body{margin:0;padding:0;background:#fff;color:#17202a}' +
  'body{font:-apple-system-body;font-family:-apple-system,system-ui,sans-serif;line-height:1.5;' +
  'overflow-wrap:anywhere;-webkit-text-size-adjust:100%}a{color:#245cca}' +
  'img{max-width:100%;height:auto}table{max-width:100%}pre{white-space:pre-wrap}' +
  '.blocked-image{display:inline-block;border:1px dashed #a3afbf;border-radius:4px;' +
  'padding:2px 6px;color:#596574;font-size:.85em}';

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
  let link: { href: string; text: string } | undefined = undefined;
  let preformatted = 0;
  let unreadable = 0;

  const addText = (value: string) => {
    const readable =
      preformatted > 0 ? value : value.replaceAll(/[\t\n\f\r ]+/gu, ' ');
    if (unreadable === 0) {
      builder.add(readable, link?.href);
    }
    if (link !== undefined && unreadable === 0) {
      link.text += readable;
    }
    output += escapeText(value);
  };

  // An image description reads as text, including in its enclosing link's inspected text.
  const describeImage = (alt: string) => {
    if (unreadable === 0) {
      builder.add(altText(alt), link?.href);
      if (link !== undefined) {
        link.text += altText(alt);
      }
    }
  };

  const placeholder = (alt: string) => {
    hidesImages = true;
    describeImage(alt);
    output += `<span class="blocked-image" role="img" aria-label="${escapeAttribute(alt === '' ? 'Image not loaded' : alt)}">${escapeText(alt === '' ? 'Image' : alt)}</span>`;
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
    const alt = (attributeOf(element, 'alt') ?? '').trim();
    const admittedImage = reference(element);
    if (admittedImage === undefined) {
      placeholder(alt);
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
    output += `<a${attributes(element, style)} href="${messageLinkHref(links.length)}" rel="noreferrer noopener">`;
    link = { href, text: '' };
    const opened = link;
    children(element);
    link = undefined;
    links.push({ href, text: opened.text.replaceAll(/\s+/gu, ' ').trim() });
    output += '</a>';
  };

  // Readable markers a container adds before its content.
  const marker = (name: string) => {
    if (unreadable > 0) {
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
      () => {
        if (unreadable === 0) {
          builder.add('\n', link?.href);
        }
        output += '<br>';
      },
    ],
    [
      'hr',
      () => {
        output += '<hr>';
      },
    ],
  ]);

  const element = (node: Element) => {
    const name = node.tagName.toLowerCase();
    const style = filterStyle(attributeOf(node, 'style') ?? '');
    if (isDropped(node, name, style)) {
      return;
    }
    const block = paragraphs.has(name);
    if (block) {
      builder.end();
    }
    const suppressText = unreadableText(style.retained) ? 1 : 0;
    unreadable += suppressText;
    (special.get(name) ?? container)(node, style);
    unreadable -= suppressText;
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
