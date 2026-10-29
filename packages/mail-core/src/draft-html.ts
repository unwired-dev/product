/* oxlint-disable typescript/prefer-readonly-parameter-types -- parse5 tree nodes are mutable library types; the conversion only reads them. */
import type { DefaultTreeAdapterTypes } from 'parse5';

import { isTokenComma, TokenType, tokenize } from '@csstools/css-tokenizer';
import * as Schema from 'effect/Schema';
import { parse } from 'parse5';

import type {
  Block,
  BlockKind,
  Mark,
  SemanticDocument,
} from './semantic-document.ts';

import { fontKeywordPixels, parseDeclarations } from './html-sanitizer.ts';
import { vettedHref } from './link-inspection.ts';
import {
  emptyDocument,
  FontSchema,
  imageCharacter,
  MarkSchema,
  SemanticDocumentSchema,
} from './semantic-document.ts';

// A Draft body written as HTML, by another mail client or by outgoing mail, as a Semantic
// Message Document. HTML the document cannot hold is not approximated: the result names the
// element, attribute or CSS property instead, never the text around it.
export type DraftHtml =
  | Readonly<{ document: SemanticDocument }>
  | Readonly<{ unsupported: readonly string[] }>;

type Span = Block['spans'][number];
type Format = Readonly<{
  marks: readonly Mark[];
  link?: string;
  color?: string | undefined;
  background?: string | undefined;
  font?: string | undefined;
  size?: number | undefined;
}>;
type Context = Readonly<{
  kind: BlockKind;
  list?: 'bulleted' | 'numbered';
  align?: Block['align'];
  linkColor?: string;
  format: Format;
}>;

const markOrder: readonly Mark[] = MarkSchema.literals;
const markTags: ReadonlyMap<string, Mark> = new Map([
  ['b', 'bold'],
  ['strong', 'bold'],
  ['i', 'italic'],
  ['em', 'italic'],
  ['u', 'underline'],
  ['ins', 'underline'],
  ['s', 'strikethrough'],
  ['strike', 'strikethrough'],
  ['del', 'strikethrough'],
  ['code', 'code'],
]);
// Never shown as body text.
const hiddenTags = new Set([
  'head',
  'title',
  'meta',
  'link',
  'base',
  'style',
  'script',
  'template',
  'wbr',
]);
// Text-level elements that only carry the formatting of their attributes and style.
const transparentTags = new Set(['span', 'font', 'a', 'o:p', 'br']);
const blockTags = new Set(['html', 'body', 'div', 'p']);
// Headings, quotes, code and lists hold only paragraphs; list items belong in lists.
const withMark = (format: Format, mark: Mark, on = true): Format => ({
  ...format,
  marks: markOrder.filter((each) =>
    each === mark ? on : format.marks.includes(each),
  ),
});
const formatted = (context: Context, format: Partial<Format>): Context => ({
  ...context,
  format: { ...context.format, ...format },
});
const topLevel = (next: (context: Context) => Context) => (context: Context) =>
  context.kind === 'paragraph' && context.list === undefined
    ? next(context)
    : undefined;
// A heading's own size is relative to the size it inherits.
const heading = (context: Context, kind: BlockKind) =>
  formatted({ ...context, kind }, { size: undefined });
const structureTags: ReadonlyMap<
  string,
  (context: Context) => Context | undefined
> = new Map([
  ['h1', topLevel((context) => heading(context, 'heading1'))],
  ['h2', topLevel((context) => heading(context, 'heading2'))],
  ['h3', topLevel((context) => heading(context, 'heading3'))],
  ['blockquote', topLevel((context) => ({ ...context, kind: 'quote' }))],
  [
    'pre',
    topLevel((context) =>
      formatted({ ...context, kind: 'code' }, { font: undefined }),
    ),
  ],
  ['ul', topLevel((context) => ({ ...context, list: 'bulleted' }))],
  ['ol', topLevel((context) => ({ ...context, list: 'numbered' }))],
  [
    'li',
    (context) =>
      context.list === undefined
        ? undefined
        : { ...context, kind: context.list },
  ],
]);
const isBlock = (tag: string) =>
  !transparentTags.has(tag) && !markTags.has(tag);
// Each of these holds at least one block, so an empty heading or list item reads back.
const lineTags = new Set(['p', 'li', 'h1', 'h2', 'h3', 'pre']);
// Spacing and wrapping that browsers and mail clients add; the document has none of its own.
const ignoredProperties =
  /^(?:margin|padding|line-height|word-wrap|overflow-wrap|line-break|caret-color|-webkit-nbsp-mode|mso-)/u;
// The pixel sizes of <font size="1"> to <font size="7">.
const fontSizeAttribute = [10, 13, 16, 18, 24, 32, 48];
const alignments: ReadonlyMap<string, Block['align']> = new Map([
  ['left', undefined],
  ['start', undefined],
  ['center', 'center'],
  ['right', 'right'],
  ['justify', 'justify'],
]);

const hex = /^#(?<digits>[\da-f]{3}|[\da-f]{6})$/iu;
const rgb =
  /^rgba?\([\t\n\f\r ]*(?<r>\d{1,3})[\t\n\f\r ]*,[\t\n\f\r ]*(?<g>\d{1,3})[\t\n\f\r ]*,[\t\n\f\r ]*(?<b>\d{1,3})(?:[\t\n\f\r ]*,[\t\n\f\r ]*(?<alpha>1(?:\.0+)?|100%))?[\t\n\f\r ]*\)$/iu;
const modernRgb =
  /^rgba?\([\t\n\f\r ]*(?<r>\d{1,3})[\t\n\f\r ]+(?<g>\d{1,3})[\t\n\f\r ]+(?<b>\d{1,3})(?:[\t\n\f\r ]*\/[\t\n\f\r ]*(?<alpha>1(?:\.0+)?|100%))?[\t\n\f\r ]*\)$/iu;

// #rrggbb, #rgb and opaque rgb(); any other form, including color names, is undefined.
const colorOf = (value: string) => {
  const digits = hex.exec(value)?.[1];
  if (digits !== undefined) {
    const full =
      digits.length === 3
        ? [...digits].map((each) => each + each).join('')
        : digits;
    return `#${full.toLowerCase()}`;
  }
  const channels = rgb.exec(value) ?? modernRgb.exec(value);
  if (channels === null) {
    return undefined;
  }
  const values = channels.slice(1, 4).map(Number);
  return values.every((each) => each <= 255)
    ? `#${values.map((each) => each.toString(16).padStart(2, '0')).join('')}`
    : undefined;
};
// Legacy HTML color attributes do not parse rgb() as CSS does.
const attributeColorOf = (value: string) =>
  hex.test(value) ? colorOf(value) : undefined;

const isFont = Schema.is(FontSchema);
const trimValue = (value: string) =>
  value.replaceAll(/^[\t\n\f\r ]+|[\t\n\f\r ]+$/gu, '');
// CSS-wide keywords and the reserved `default` control the cascade; they are never family names.
const cssKeywords = /^(?:inherit|initial|unset|revert|revert-layer|default)$/iu;
const genericFamilies =
  /^(?:serif|sans-serif|monospace|cursive|fantasy|system-ui|ui-serif|ui-sans-serif|ui-monospace|ui-rounded|math|emoji|fangsong|caption|icon|menu|message-box|small-caption|status-bar)$/iu;
const familyTokens = new Set([
  TokenType.Ident,
  TokenType.String,
  TokenType.Whitespace,
  TokenType.EOF,
]);
const familyNameOf = (name: string) => {
  const trimmed = trimValue(name);
  const quoted = /^(?<quote>["'])(?<name>.*)\k<quote>$/u.exec(trimmed);
  if (quoted?.[2] !== undefined) {
    return `"${quoted[2]}"`;
  }
  const words = trimmed.split(/[\t\n\f\r ]+/u);
  return words.some((word) => cssKeywords.test(word)) ||
    (words.length > 1 && words.some((word) => genericFamilies.test(word)))
    ? undefined
    : words.join(' ');
};
const familyOf = (value: string) => {
  const names: string[] = [];
  let current = '';
  for (const token of tokenize({ css: value })) {
    if (isTokenComma(token)) {
      names.push(current);
      current = '';
    } else {
      if (!familyTokens.has(token[0])) {
        return undefined;
      }
      current += token[1];
    }
  }
  const family = [...names, current].map(familyNameOf);
  return family.includes(undefined) || !isFont(family.join(', '))
    ? undefined
    : family.join(', ');
};

const sizeOf = (value: string) => {
  const keyword = fontKeywordPixels.get(value.toLowerCase());
  if (keyword !== undefined) {
    return keyword;
  }
  const length =
    /^(?<amount>\+?(?:\d+(?:\.\d+)?|\.\d+)(?:e[+-]?\d+)?)(?<unit>px|pt)$/iu.exec(
      value,
    );
  const amount = Number(length?.[1]);
  if (length === null || !Number.isFinite(amount) || amount <= 0) {
    return undefined;
  }
  const size = length[2]?.toLowerCase() === 'pt' ? amount * (4 / 3) : amount;
  return Number.isFinite(size) ? size : undefined;
};

// An attribute or CSS property applied to the context, or undefined when the document cannot
// hold its value. Values arrive trimmed, in their written case.
type Rule = (
  context: Context,
  value: string,
  block: boolean,
) => Context | undefined;

const colorRule: Rule = (context, value) => {
  const color = colorOf(value);
  return color === undefined ? undefined : formatted(context, { color });
};
const attributeColorRule: Rule = (context, value) => {
  const color = attributeColorOf(value);
  return color === undefined ? undefined : formatted(context, { color });
};
const fontRule: Rule = (context, value) => {
  const font = familyOf(value);
  return font === undefined ? undefined : formatted(context, { font });
};
const alignRule: Rule = (context, value) => {
  const lower = value.toLowerCase();
  return alignments.has(lower)
    ? { ...context, align: alignments.get(lower) }
    : undefined;
};
const decorations: ReadonlyMap<string, Mark> = new Map([
  ['underline', 'underline'],
  ['line-through', 'strikethrough'],
]);
const decorationRule: Rule = (context, value) => {
  let { format } = context;
  const lines = value.toLowerCase().split(/[\t\n\f\r ]+/u);
  if (
    (lines.includes('none') && lines.length > 1) ||
    new Set(lines).size !== lines.length
  ) {
    return undefined;
  }
  for (const line of lines) {
    const mark = decorations.get(line);
    if (mark === undefined && line !== 'none') {
      return undefined;
    }
    format = mark === undefined ? format : withMark(format, mark);
  }
  return { ...context, format };
};

const propertyRules: ReadonlyMap<string, Rule> = new Map<string, Rule>([
  ['color', colorRule],
  ['font-family', fontRule],
  [
    'font-size',
    (context, value) => {
      const size = sizeOf(value);
      return size === undefined ? undefined : formatted(context, { size });
    },
  ],
  [
    'font-weight',
    (context, value) => {
      const lower = value.toLowerCase();
      const weight = /^[+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:e[+-]?\d+)?$/iu.test(
        lower,
      )
        ? Number(lower)
        : undefined;
      const bold = lower === 'bold' || weight === 700;
      return bold ||
        ((lower === 'normal' || weight === 400) &&
          !context.kind.startsWith('heading'))
        ? { ...context, format: withMark(context.format, 'bold', bold) }
        : undefined;
    },
  ],
  [
    'font-style',
    (context, value) => {
      const lower = value.toLowerCase();
      return ['italic', 'normal'].includes(lower)
        ? {
            ...context,
            format: withMark(context.format, 'italic', lower !== 'normal'),
          }
        : undefined;
    },
  ],
  ['text-decoration', decorationRule],
  ['text-decoration-line', decorationRule],
  // A background fills a whole block, which the document cannot show.
  ...['background', 'background-color'].map((property): [string, Rule] => [
    property,
    (context, value, block) => {
      if (
        /^transparent$/iu.test(value) ||
        (property === 'background' && /^none$/iu.test(value))
      ) {
        return context;
      }
      const background = colorOf(value);
      return block || background === undefined
        ? undefined
        : formatted(context, { background });
    },
  ]),
  // Alignment belongs to blocks; inline text ignores it, as browsers do.
  [
    'text-align',
    (context, value, block) =>
      block ? alignRule(context, value, block) : context,
  ],
]);
// A bordered blockquote is a quote; without a border, it only indents.
const otherProperty =
  (property: string): Rule =>
  (context, value) => {
    if (property.startsWith('border')) {
      return context.kind === 'quote' && !/^(?:none|0)\b/iu.test(value)
        ? context
        : undefined;
    }
    return ignoredProperties.test(property) ? context : undefined;
  };

const attributeRules: ReadonlyMap<string, Rule> = new Map<string, Rule>([
  // Numbers and markers come from the block kind alone.
  ...[
    'ol start',
    'ol type',
    'ol reversed',
    'ul type',
    'li value',
    'li type',
    'body bgcolor',
    'body background',
    'br clear',
    'hidden',
    'popover',
  ].map((attribute): [string, Rule] => [attribute, () => undefined]),
  ['font color', attributeColorRule],
  ['body text', attributeColorRule],
  [
    'body link',
    (context, value) => {
      const linkColor = attributeColorOf(value);
      return linkColor === undefined ? undefined : { ...context, linkColor };
    },
  ],
  ['font face', fontRule],
  [
    'font size',
    (context, value) => {
      if (!/^[1-7]$/u.test(value)) {
        return undefined;
      }
      const size = fontSizeAttribute[Number(value) - 1];
      return size === undefined ? undefined : formatted(context, { size });
    },
  ],
  [
    'a href',
    (context, value) => {
      const link = vettedHref(value);
      return link === undefined
        ? undefined
        : // A link shows the link color instead of the color it inherits.
          formatted(context, { link, color: context.linkColor });
    },
  ],
]);

// Text direction is left to right throughout the document.
const genericRules: ReadonlyMap<string, Rule> = new Map([
  [
    'dir',
    (context: Context, value: string) =>
      /^(?:ltr|auto)$/iu.test(value) ? context : undefined,
  ],
]);

type Applying = Readonly<{
  context: Context;
  block: boolean;
  unsupported: Set<string>;
}>;
// The context after one rule, which names the attribute or property it cannot hold.
const applied = (
  { context, block, unsupported }: Applying,
  [name, value]: readonly [string, string],
  rule: Rule | undefined,
) => {
  if (rule === undefined) {
    return context;
  }
  const next = rule(context, trimValue(value), block);
  if (next === undefined) {
    unsupported.add(name);
  }
  return next ?? context;
};

const headingStarts = (context: Context, parent: Context) =>
  context.kind.startsWith('heading') && context.kind !== parent.kind;
const parentDecorations = (context: Context, parent: Context): Context => ({
  ...context,
  format: withMark(
    withMark(
      context.format,
      'underline',
      parent.format.marks.includes('underline'),
    ),
    'strikethrough',
    parent.format.marks.includes('strikethrough'),
  ),
});

const inheritedRules: ReadonlyMap<
  string,
  (context: Context, parent: Context) => Context | undefined
> = new Map([
  [
    'color',
    (context, parent) =>
      context.format.link !== undefined &&
      parent.format.link === undefined &&
      parent.format.color === undefined
        ? undefined
        : formatted(context, { color: parent.format.color }),
  ],
  [
    'background',
    (context, parent) =>
      formatted(context, { background: parent.format.background }),
  ],
  [
    'background-color',
    (context, parent) =>
      formatted(context, { background: parent.format.background }),
  ],
  [
    'font-family',
    (context, parent) =>
      ((context.format.marks.includes('code') &&
        !parent.format.marks.includes('code')) ||
        (context.kind === 'code' && parent.kind !== 'code')) &&
      parent.format.font === undefined
        ? undefined
        : formatted(context, { font: parent.format.font }),
  ],
  [
    'font-size',
    (context, parent) =>
      headingStarts(context, parent) && parent.format.size === undefined
        ? undefined
        : formatted(context, { size: parent.format.size }),
  ],
  ['text-align', (context, parent) => ({ ...context, align: parent.align })],
  [
    'font-weight',
    (context, parent) =>
      headingStarts(context, parent) && !parent.format.marks.includes('bold')
        ? undefined
        : {
            ...context,
            format: withMark(
              context.format,
              'bold',
              parent.format.marks.includes('bold'),
            ),
          },
  ],
  ['text-decoration', parentDecorations],
  ['text-decoration-line', parentDecorations],
  [
    'font-style',
    (context, parent) => ({
      ...context,
      format: withMark(
        context.format,
        'italic',
        parent.format.marks.includes('italic'),
      ),
    }),
  ],
]);

const replacementProperties = new Set([
  'text-decoration',
  'text-decoration-line',
  'background',
  'background-color',
]);
const replacementContext = (
  context: Context,
  parent: Context,
  property: string,
) =>
  replacementProperties.has(property)
    ? (inheritedRules.get(property)?.(context, parent) ?? context)
    : context;

// The parser drops values it cannot vet, such as calc() sizes. Drafts must refuse them instead.
const reportRejected = (
  unsupported: Set<string>,
  rejected: ReadonlySet<string>,
) => {
  for (const property of rejected) {
    if (!ignoredProperties.test(property)) {
      unsupported.add(property);
    }
  }
};

const styled = (
  applying: Applying,
  style: string,
  parent: Context,
): Context => {
  // The reader parser discards some valid escaped CSS. Drafts must refuse it instead.
  if (style.includes('\\')) {
    applying.unsupported.add('style');
    return applying.context;
  }
  const { declared, limited, important, rejected } = parseDeclarations(style);
  if (limited) {
    applying.unsupported.add('style');
  }
  reportRejected(applying.unsupported, rejected);
  // Longhands and shorthands compete at the same priority before they replace each other.
  const entries = [...declared];
  const ordered = [
    ...entries.filter(([property]) => !important.has(property)),
    ...entries.filter(([property]) => important.has(property)),
  ];
  const inner = ordered.reduce((context, [property, value]) => {
    if (/^inherit$/iu.test(trimValue(value))) {
      const inherit = inheritedRules.get(property);
      if (inherit !== undefined) {
        return applied({ ...applying, context }, [property, value], () =>
          inherit(context, parent),
        );
      }
    }
    // Any other CSS-wide keyword resolves through a cascade the document does not keep.
    const keyword = cssKeywords.test(trimValue(value));
    if (keyword && ignoredProperties.test(property)) {
      return context;
    }
    const rule = keyword
      ? () => undefined
      : (propertyRules.get(property) ?? otherProperty(property));
    const base = replacementContext(context, parent, property);
    return applied({ ...applying, context: base }, [property, value], rule);
  }, applying.context);
  // Check the winning decoration and ancestor lines, not an overridden declaration.
  if (
    inner.format.link !== undefined &&
    parent.format.link === undefined &&
    !inner.format.marks.includes('underline')
  ) {
    const property = ordered.find(
      ([name]) => name === 'text-decoration' || name === 'text-decoration-line',
    )?.[0];
    if (property !== undefined) {
      applying.unsupported.add(property);
    }
  }
  return inner;
};

// The context an element's children take by its tag, or undefined where the document cannot
// hold it.
const tagContext = (
  element: DefaultTreeAdapterTypes.Element,
  context: Context,
): Context | undefined => {
  const tag = element.tagName;
  if (tag === 'code' && element.parentNode?.nodeName === 'pre') {
    return formatted(context, { font: undefined });
  }
  const structure = structureTags.get(tag);
  if (structure !== undefined) {
    return structure(context);
  }
  const mark = markTags.get(tag);
  const plain = blockTags.has(tag) || transparentTags.has(tag);
  if (plain) {
    return context;
  }
  // <code> shows its own monospace font instead of the one it inherits.
  return mark === undefined
    ? undefined
    : formatted(context, {
        ...withMark(context.format, mark),
        ...(mark === 'code' ? { font: undefined } : {}),
      });
};

// Outgoing links put colors on their text spans, leaving the anchor underline at its default.
const linkColorChanged = (tag: string, context: Context) =>
  tag === 'a' &&
  context.format.link !== undefined &&
  context.format.color !== undefined;
// Ancestor lines keep their original color; outgoing marks take the text's color.
const decorationColorChanged = (
  tag: string,
  context: Context,
  parent: Context,
) =>
  linkColorChanged(tag, context) ||
  (parent.format.marks.some(
    (mark) => mark === 'underline' || mark === 'strikethrough',
  ) &&
    (context.format.color !== parent.format.color ||
      (context.format.link !== parent.format.link &&
        context.format.color === undefined)));

// List markers inherit from the item, but outgoing formatting is inside the item.
const markerStyled = (tag: string, format: Format) =>
  tag === 'li' &&
  (format.color !== undefined ||
    format.font !== undefined ||
    format.size !== undefined ||
    format.marks.some((mark) => ['bold', 'italic', 'code'].includes(mark)));

// The context an element's children take, or undefined when the document cannot hold it.
// Attributes apply first, then the style that overrides them.
const contextOf = (
  element: DefaultTreeAdapterTypes.Element,
  context: Context,
  unsupported: Set<string>,
): Context | undefined => {
  const tag = element.tagName;
  const tagged = tagContext(element, context);
  if (tagged === undefined) {
    unsupported.add(tag);
    return undefined;
  }
  const block = isBlock(tag);
  const attributed = element.attrs.reduce(
    (next, { name, value }) =>
      applied(
        { context: next, block, unsupported },
        [name, value],
        attributeRules.get(`${tag} ${name}`) ??
          attributeRules.get(name) ??
          (name === 'align' && block ? alignRule : genericRules.get(name)),
      ),
    tagged,
  );
  const style = element.attrs.find(({ name }) => name === 'style')?.value;
  const inner =
    style === undefined
      ? attributed
      : styled({ context: attributed, block, unsupported }, style, context);
  if (decorationColorChanged(tag, inner, context)) {
    unsupported.add('color');
  }
  if (markerStyled(tag, inner.format)) {
    unsupported.add(tag);
  }
  // Outgoing mail sends a heading's size from its own style alone.
  if (
    headingStarts(inner, context) &&
    context.format.size !== undefined &&
    inner.format.size === undefined
  ) {
    unsupported.add('font-size');
  }
  return inner;
};

const spanOf = (text: string, format: Format): Span => {
  const [first, ...rest] = format.marks;
  return {
    text,
    ...(first === undefined ? {} : { marks: [first, ...rest] }),
    ...(format.link === undefined ? {} : { link: format.link }),
    ...(format.color === undefined ? {} : { color: format.color }),
    ...(format.background === undefined
      ? {}
      : { background: format.background }),
    ...(format.font === undefined ? {} : { font: format.font }),
    ...(format.size === undefined ? {} : { size: format.size }),
  };
};

const sameFormat = (one: Format, other: Format) =>
  one.marks.join(',') === other.marks.join(',') &&
  one.link === other.link &&
  one.color === other.color &&
  one.background === other.background &&
  one.font === other.font &&
  one.size === other.size;

const isDocument = Schema.is(SemanticDocumentSchema);

const listChanged = (tag: string, before: number, blocks: readonly Block[]) =>
  tag === 'li'
    ? blocks.length - before > 1
    : tag === 'ol' &&
      blocks[before]?.kind === 'numbered' &&
      blocks[before - 1]?.kind === 'numbered';

const hiddenElement = (element: DefaultTreeAdapterTypes.Element) => {
  const hidden = element.attrs.find(({ name }) => name === 'hidden');
  if (hidden === undefined) {
    return false;
  }
  const style = element.attrs.find(({ name }) => name === 'style')?.value ?? '';
  const { declared, limited } = parseDeclarations(style);
  return (
    !/^until-found$/iu.test(hidden.value) &&
    !style.includes('\\') &&
    !limited &&
    !declared.has('display')
  );
};

export function documentFromHtml(html: string): DraftHtml {
  const unsupported = new Set<string>();
  const blocks: Block[] = [];
  let runs: Array<{ text: string; format: Format }> = [];
  // The context of the line's first text, which decides its kind and alignment.
  let line: Context | undefined = undefined;

  const endLine = (context: Context) => {
    const { kind, align } = line ?? context;
    const last = runs.at(-1);
    if (kind !== 'code' && last !== undefined) {
      // A collapsed space at the end of a line is not shown; at most one remains.
      last.text = last.text.replace(/ $/u, '');
    }
    const shown = kind === 'code' || runs.some(({ text }) => text !== '');
    const spans = shown
      ? runs
          .filter(({ text }) => text !== '')
          .map(({ text, format }) => spanOf(text, format))
      : [];
    blocks.push({ kind, spans, ...(align === undefined ? {} : { align }) });
    runs = [];
    line = undefined;
  };

  const append = (text: string, context: Context) => {
    if (text === '') {
      return;
    }
    if (text.includes(imageCharacter)) {
      unsupported.add('U+FFFC');
      return;
    }
    line ??= context;
    const last = runs.at(-1);
    if (last !== undefined && sameFormat(last.format, context.format)) {
      last.text += text;
    } else {
      runs.push({ text, format: context.format });
    }
  };

  const addText = (value: string, context: Context) => {
    if (context.kind === 'code') {
      for (const [index, part] of value.split('\n').entries()) {
        if (index > 0) {
          endLine(context);
        }
        append(part, context);
      }
      return;
    }
    const collapsed = value.replaceAll(/[\t\n\f\r ]+/gu, ' ');
    const atSpace = runs.at(-1)?.text.endsWith(' ') ?? true;
    append(atSpace ? collapsed.replace(/^ /u, '') : collapsed, context);
  };

  type Step =
    | Readonly<{
        kind: 'node';
        node: DefaultTreeAdapterTypes.ChildNode;
        context: Context;
      }>
    | Readonly<{ kind: 'end'; tag: string; context: Context; before: number }>;
  const context: Context = { kind: 'paragraph', format: { marks: [] } };
  const steps: Step[] = [];
  const pushChildren = (
    nodes: readonly DefaultTreeAdapterTypes.ChildNode[],
    inner: Context,
  ) => {
    for (let index = nodes.length - 1; index >= 0; index -= 1) {
      const node = nodes[index];
      if (node !== undefined) {
        steps.push({ kind: 'node', node, context: inner });
      }
    }
  };
  const visitElement = (
    node: DefaultTreeAdapterTypes.Element,
    outer: Context,
  ) => {
    if (hiddenTags.has(node.tagName) || hiddenElement(node)) {
      return;
    }
    const inner = contextOf(node, outer, unsupported);
    if (inner === undefined) {
      return;
    }
    if (node.tagName === 'br') {
      endLine(inner);
      return;
    }
    if (isBlock(node.tagName)) {
      if (line !== undefined) {
        endLine(outer);
      }
      steps.push({
        kind: 'end',
        tag: node.tagName,
        context: inner,
        before: blocks.length,
      });
    }
    pushChildren(node.childNodes, inner);
  };
  const endElement = (step: Extract<Step, { kind: 'end' }>) => {
    const empty = lineTags.has(step.tag) && blocks.length === step.before;
    if (line !== undefined || empty) {
      endLine(step.context);
    }
    if (listChanged(step.tag, step.before, blocks)) {
      unsupported.add(step.tag);
    }
  };
  const visit = (step: Step) => {
    if (step.kind === 'end') {
      endElement(step);
      return;
    }
    const { node, context: outer } = step;
    if (node.nodeName === '#text' && 'value' in node) {
      addText(node.value, outer);
    } else if ('tagName' in node) {
      visitElement(node, outer);
    }
  };
  pushChildren(parse(html).childNodes, context);
  while (steps.length > 0) {
    const step = steps.pop();
    if (step !== undefined) {
      visit(step);
    }
  }
  if (unsupported.size > 0) {
    return { unsupported: [...unsupported] };
  }
  const [first, ...rest] = blocks;
  const document: SemanticDocument =
    first === undefined ? emptyDocument : [first, ...rest];
  return isDocument(document) ? { document } : { unsupported: ['document'] };
}
