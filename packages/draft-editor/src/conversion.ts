import type {
  Asset,
  Block,
  BlockKind,
  Mark,
  SemanticDocument,
} from '@private-email/mail-core/semantic-document';
import type { JSONContent } from '@tiptap/core';
import type { Node, ResolvedPos } from '@tiptap/pm/model';

// The explicit boundary between the stored Semantic Message Document and Tiptap's JSON. The
// Draft stores only the Semantic Message Document; editor JSON never leaves the page.
// Consecutive list items and quote lines share one Tiptap container, as they share one in
// outgoing mail, and split back into one block each. Each code line is a textblock of its own.
// An Inline Image is an inline node naming its Draft Asset, and the Draft's Attachments are an
// attribute of the editor document naming theirs, so one edit and one Undo step can change both.
// The page keeps the assets it was given by identifier.

// The character an Inline Image occupies; typed or pasted text never stores it.
const imageCharacter = '￼';

// The document's mark order, and the Tiptap mark that shows each mark.
export const markOrder: readonly Mark[] = [
  'bold',
  'italic',
  'underline',
  'strikethrough',
  'code',
];
export const tiptapMarks: Readonly<Record<Mark, string>> = {
  bold: 'bold',
  italic: 'italic',
  underline: 'underline',
  strikethrough: 'strike',
  code: 'code',
};

// Consecutive blocks of these kinds share one container.
const containerOf: Partial<Record<BlockKind, string>> = {
  bulleted: 'bulletList',
  numbered: 'orderedList',
  quote: 'blockquote',
};
const containedKind: Readonly<Record<string, BlockKind | undefined>> = {
  bulletList: 'bulleted',
  orderedList: 'numbered',
  blockquote: 'quote',
};
const headingLevel: Partial<Record<BlockKind, number>> = {
  heading1: 1,
  heading2: 2,
  heading3: 3,
};
const headingKind: Readonly<Record<number, BlockKind | undefined>> = {
  1: 'heading1',
  2: 'heading2',
  3: 'heading3',
};

type Span = Block['spans'][number];

const inlineOf = (span: Span): JSONContent => ({
  ...('image' in span
    ? { type: 'inlineImage', attrs: { id: span.image.id } }
    : { type: 'text', text: span.text }),
  ...(span.marks === undefined
    ? {}
    : { marks: span.marks.map((mark) => ({ type: tiptapMarks[mark] })) }),
});

const textblock = (type: string, { spans }: Block): JSONContent =>
  spans.length === 0 ? { type } : { type, content: spans.map(inlineOf) };

// One Tiptap node for a run of blocks of one kind; only lists and quotes have runs longer than one.
const nodeOf = (run: readonly [Block, ...Block[]]): JSONContent => {
  const [first] = run;
  const level = headingLevel[first.kind];
  if (level !== undefined) {
    return { ...textblock('heading', first), attrs: { level } };
  }
  const container = containerOf[first.kind];
  if (container === undefined) {
    return textblock(first.kind === 'code' ? 'codeLine' : 'paragraph', first);
  }
  return {
    type: container,
    content: run.map((block) =>
      first.kind === 'quote'
        ? textblock('paragraph', block)
        : { type: 'listItem', content: [textblock('paragraph', block)] },
    ),
  };
};

export const toEditor = (
  document: SemanticDocument,
  attachments: readonly Asset[] = [],
): JSONContent => {
  const runs: Array<[Block, ...Block[]]> = [];
  for (const block of document) {
    const run = runs.at(-1);
    if (
      run !== undefined &&
      block.kind in containerOf &&
      run[0].kind === block.kind
    ) {
      run.push(block);
    } else {
      runs.push([block]);
    }
  }
  return {
    type: 'doc',
    attrs: { attachments: attachments.map(({ id }) => id) },
    content: runs.map(nodeOf),
  };
};

type Assets = ReadonlyMap<string, Asset>;

// Text spans with their marks in document order; adjacent text spans with the same marks merge,
// and each Inline Image is a span of its own.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Tiptap's JSON type is mutable; this only reads it.
const spansOf = (nodes: readonly JSONContent[], assets: Assets) => {
  const spans: Span[] = [];
  for (const node of nodes) {
    const names = new Set(node.marks?.map(({ type }) => type));
    const [first, ...rest] = markOrder.filter((mark) =>
      names.has(tiptapMarks[mark]),
    );
    const marks =
      first === undefined ? {} : { marks: [first, ...rest] as const };
    const image =
      node.type === 'inlineImage'
        ? assets.get(String(node.attrs?.id))
        : undefined;
    const text = (node.text ?? '').replaceAll(imageCharacter, '');
    const span: Span = { text, ...marks };
    const last = spans.at(-1);
    if (image !== undefined) {
      spans.push({ text: imageCharacter, image, ...marks });
    } else if (
      last !== undefined &&
      !('image' in last) &&
      last.marks?.join(',') === span.marks?.join(',')
    ) {
      spans[spans.length - 1] = { ...last, text: last.text + text };
    } else if (text !== '') {
      spans.push(span);
    }
  }
  return spans;
};

// Every block a node holds, in reading order. The schema admits no nesting: a list item or quote
// holds only paragraphs.
const blocksOf = (
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Tiptap's JSON type is mutable; this only reads it.
  node: JSONContent,
  kind: BlockKind,
  assets: Assets,
): Block[] => {
  const { type = '', content = [], attrs } = node;
  const contained = containedKind[type];
  if (contained !== undefined || type === 'listItem') {
    return content.flatMap((child) =>
      blocksOf(child, contained ?? kind, assets),
    );
  }
  let own = kind;
  if (type === 'heading') {
    own = headingKind[Number(attrs?.level)] ?? 'heading1';
  } else if (type === 'codeLine') {
    own = 'code';
  }
  return [{ kind: own, spans: spansOf(content, assets) }];
};

export const fromEditor = (
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Tiptap's JSON type is mutable; this only reads it.
  editor: JSONContent,
  assets: Assets,
): SemanticDocument => {
  const [first = { kind: 'paragraph', spans: [] }, ...rest] = (
    editor.content ?? []
  ).flatMap((node) => blocksOf(node, 'paragraph', assets));
  return [first, ...rest];
};

// The block kind of the textblock at `$position`.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- ProseMirror's resolved position is a class; this only reads it.
export const kindAt = ($position: ResolvedPos): BlockKind => {
  for (let { depth } = $position; depth > 0; depth -= 1) {
    const { type, attrs } = $position.node(depth);
    if (type.name === 'heading') {
      return headingKind[Number(attrs.level)] ?? 'heading1';
    }
    if (type.name === 'codeLine') {
      return 'code';
    }
    const kind = containedKind[type.name];
    if (kind !== undefined) {
      return kind;
    }
  }
  return 'paragraph';
};

// Where each semantic line starts in the editor and in the composer's display text, and its text
// length. The display text joins blocks with line breaks and shows list items after their marker
// (`displayOf` in mail-core): consecutive numbered items count from one. Offsets inside a
// textblock count code units, and an Inline Image counts one, as its character does.
export type Line = Readonly<{
  editor: number;
  start: number;
  marker: number;
  length: number;
}>;

const markerLength = (kind: BlockKind, number: number) => {
  if (kind === 'bulleted') {
    return '• '.length;
  }
  return kind === 'numbered' ? `${number}. `.length : 0;
};

// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- ProseMirror's node is a class; this only reads it.
export const linesOfDocument = (doc: Node): Line[] => {
  const lines: Line[] = [];
  let start = 0;
  let number = 0;
  doc.descendants((node, position) => {
    if (!node.isTextblock) {
      return true;
    }
    const kind = kindAt(doc.resolve(position + 1));
    number = kind === 'numbered' ? number + 1 : 0;
    const marker = markerLength(kind, number);
    const length = node.content.size;
    lines.push({ editor: position + 1, start, marker, length });
    start += marker + length + 1;
    return false;
  });
  return lines;
};

// The last line starting at or before `at`; positions before the first line belong to it.
const lineAt = (
  lines: readonly Line[],
  at: number,
  start: (line: Line) => number,
) => {
  let [found] = lines;
  for (const line of lines) {
    if (start(line) > at) {
      break;
    }
    found = line;
  }
  return found;
};

// An editor position as a display offset, and back. A display offset inside a list marker
// belongs to the start of that item's text.
export const displayOffset = (lines: readonly Line[], position: number) => {
  const line = lineAt(lines, position, ({ editor }) => editor);
  return line === undefined
    ? 0
    : line.start +
        line.marker +
        Math.min(Math.max(0, position - line.editor), line.length);
};

export const editorPosition = (lines: readonly Line[], offset: number) => {
  const line = lineAt(lines, offset, ({ start }) => start);
  return line === undefined
    ? 1
    : line.editor +
        Math.min(Math.max(0, offset - line.start - line.marker), line.length);
};
