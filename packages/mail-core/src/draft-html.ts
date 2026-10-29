/* oxlint-disable typescript/prefer-readonly-parameter-types -- parse5 tree nodes are mutable library types; the conversion only reads them. */
import type { DefaultTreeAdapterTypes } from 'parse5';

import { isTokenComma, tokenize } from '@csstools/css-tokenizer';
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
  color?: string;
  background?: string;
  font?: string;
  size?: number;
}>;
type Context = Readonly<{
  kind: BlockKind;
  list?: 'bulleted' | 'numbered';
  align?: Block['align'];
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
const transparentTags = new Set(['span', 'font', 'a', 'o:p']);
const blockTags = new Set(['html', 'body', 'div', 'p']);
// Headings, quotes, code and lists hold only paragraphs; list items belong in lists.
const topLevel = (next: (context: Context) => Context) => (context: Context) =>
  context.kind === 'paragraph' && context.list === undefined
    ? next(context)
    : undefined;
const structureTags: ReadonlyMap<
  string,
  (context: Context) => Context | undefined
> = new Map([
  ['h1', topLevel((context) => ({ ...context, kind: 'heading1' }))],
  ['h2', topLevel((context) => ({ ...context, kind: 'heading2' }))],
  ['h3', topLevel((context) => ({ ...context, kind: 'heading3' }))],
  ['blockquote', topLevel((context) => ({ ...context, kind: 'quote' }))],
  ['pre', topLevel((context) => ({ ...context, kind: 'code' }))],
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
const lineTags = new Set(['p', 'li', 'h1', 'h2', 'h3']);
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
  /^rgba?\(\s*(?<r>\d{1,3})(?:\s*,\s*|\s+)(?<g>\d{1,3})(?:\s*,\s*|\s+)(?<b>\d{1,3})(?:\s*[,/]\s*(?<alpha>1(?:\.0*)?|100%))?\s*\)$/iu;

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
  const channels = rgb.exec(value);
  if (channels === null) {
    return undefined;
  }
  const values = channels.slice(1, 4).map(Number);
  return values.every((each) => each <= 255)
    ? `#${values.map((each) => each.toString(16).padStart(2, '0')).join('')}`
    : undefined;
};

const isFont = Schema.is(FontSchema);
const familyOf = (value: string) => {
  const names: string[] = [];
  let current = '';
  for (const token of tokenize({ css: value })) {
    if (isTokenComma(token)) {
      names.push(current);
      current = '';
    } else {
      current += token[1];
    }
  }
  const family = [...names, current]
    .map((name) => {
      const trimmed = name.trim();
      const quoted = /^(?<quote>["'])(?<name>.*)\k<quote>$/u.exec(trimmed);
      return quoted?.[2] === undefined
        ? trimmed.replaceAll(/\s+/gu, ' ')
        : `"${quoted[2]}"`;
    })
    .join(', ');
  return isFont(family) ? family : undefined;
};

const sizeOf = (value: string) => {
  const keyword = fontKeywordPixels.get(value.toLowerCase());
  if (keyword !== undefined) {
    return keyword;
  }
  const length = /^(?<amount>\d+(?:\.\d+)?|\.\d+)(?<unit>px|pt)$/iu.exec(value);
  const amount = Number(length?.[1]);
  if (length === null || amount <= 0) {
    return undefined;
  }
  return length[2]?.toLowerCase() === 'pt' ? (amount * 4) / 3 : amount;
};

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
  for (const line of value.toLowerCase().split(/\s+/u)) {
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
      const weight = Number(lower);
      const bold = lower === 'bold' || lower === 'bolder' || weight >= 600;
      return bold || lower === 'normal' || lower === 'lighter' || weight > 0
        ? { ...context, format: withMark(context.format, 'bold', bold) }
        : undefined;
    },
  ],
  [
    'font-style',
    (context, value) => {
      const lower = value.toLowerCase();
      return ['italic', 'oblique', 'normal'].includes(lower)
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
      if (/^(?:transparent|none)$/iu.test(value)) {
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
  ...['ol start', 'ol type', 'ul type', 'li value', 'li type'].map(
    (attribute): [string, Rule] => [attribute, () => undefined],
  ),
  ['font color', colorRule],
  ['font face', fontRule],
  [
    'font size',
    (context, value) => {
      const size = fontSizeAttribute[Number(value) - 1];
      return size === undefined ? undefined : formatted(context, { size });
    },
  ],
  [
    'a href',
    (context, value) => {
      const link = vettedHref(value);
      return link === undefined ? undefined : formatted(context, { link });
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
  const next = rule(context, value.trim(), block);
  if (next === undefined) {
    unsupported.add(name);
  }
  return next ?? context;
};

const styled = (applying: Applying, style: string): Context => {
  const { declared, unsafe } = parseDeclarations(style);
  return [...declared].reduce((context, [property, value]) => {
    if (/^\s*inherit\s*$/iu.test(value) && !unsafe.has(property)) {
      return context;
    }
    const rule = unsafe.has(property)
      ? () => undefined
      : (propertyRules.get(property) ?? otherProperty(property));
    return applied({ ...applying, context }, [property, value], rule);
  }, applying.context);
};

// The context an element's children take by its tag, or undefined where the document cannot
// hold it.
const tagContext = (
  element: DefaultTreeAdapterTypes.Element,
  context: Context,
): Context | undefined => {
  const tag = element.tagName;
  const structure = structureTags.get(tag);
  if (structure !== undefined) {
    return structure(context);
  }
  const mark = markTags.get(tag);
  const plain =
    blockTags.has(tag) ||
    transparentTags.has(tag) ||
    (tag === 'code' && element.parentNode?.nodeName === 'pre');
  if (plain) {
    return context;
  }
  return mark === undefined
    ? undefined
    : { ...context, format: withMark(context.format, mark) };
};

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
          (name === 'align' && block ? alignRule : genericRules.get(name)),
      ),
    tagged,
  );
  const style = element.attrs.find(({ name }) => name === 'style')?.value;
  return style === undefined
    ? attributed
    : styled({ context: attributed, block, unsupported }, style);
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
    const shown =
      kind === 'code' || runs.some(({ text }) => text.trim() !== '');
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

  const visit = (
    element: DefaultTreeAdapterTypes.Element,
    context: Context,
  ) => {
    const inner = contextOf(element, context, unsupported);
    if (inner === undefined) {
      return;
    }
    const block = isBlock(element.tagName);
    if (block && line !== undefined) {
      endLine(context);
    }
    const before = blocks.length;
    // oxlint-disable-next-line typescript/no-use-before-define -- Elements and their children recurse.
    walk(element.childNodes, inner);
    const empty = lineTags.has(element.tagName) && blocks.length === before;
    if (block && (line !== undefined || empty)) {
      endLine(inner);
    }
  };

  const walk = (
    nodes: readonly DefaultTreeAdapterTypes.ChildNode[],
    context: Context,
  ) => {
    for (const node of nodes) {
      if (node.nodeName === '#text' && 'value' in node) {
        addText(node.value, context);
      } else if ('tagName' in node && node.tagName === 'br') {
        endLine(context);
      } else if ('tagName' in node && !hiddenTags.has(node.tagName)) {
        visit(node, context);
      }
    }
  };

  walk(parse(html).childNodes, { kind: 'paragraph', format: { marks: [] } });
  if (unsupported.size > 0) {
    return { unsupported: [...unsupported] };
  }
  const [first, ...rest] = blocks;
  const document: SemanticDocument =
    first === undefined ? emptyDocument : [first, ...rest];
  return isDocument(document) ? { document } : { unsupported: ['document'] };
}
