import * as Schema from 'effect/Schema';

// The Semantic Message Document: ordered body blocks, each a run of marked text. It is the stored
// and edited form of a Draft body; Markdown is only an input shortcut over it.

export const MarkSchema = Schema.Literals([
  'bold',
  'italic',
  'underline',
  'strikethrough',
  'code',
]);
export type Mark = typeof MarkSchema.Type;
const markOrder: readonly Mark[] = MarkSchema.literals;

export const BlockKindSchema = Schema.Literals([
  'paragraph',
  'heading1',
  'heading2',
  'heading3',
  'bulleted',
  'numbered',
  'quote',
  'code',
]);
export type BlockKind = typeof BlockKindSchema.Type;

// The character an inline image occupies in the editor's text; typed text never contains it.
export const imageCharacter = '\uFFFC';

const assetFields = {
  // Random and unique within the account's Drafts; native storage files the bytes under it.
  id: Schema.String.check(Schema.isPattern(/^[\da-z]{8,64}$/u)),
  name: Schema.NonEmptyString,
  // The MIME type, empty when unknown.
  type: Schema.String,
};
// A file or image added to a Draft. Only a complete asset has verified bytes on this device: its
// size and SHA-256 digest. An interrupted import stays 'importing' after a relaunch.
export const AssetSchema = Schema.Union([
  Schema.Struct({
    ...assetFields,
    state: Schema.Literals(['importing', 'cancelled']),
  }),
  Schema.Struct({
    ...assetFields,
    state: Schema.Literal('failed'),
    // Over the per-file limit or the space left for Drafts on this device.
    reason: Schema.optionalKey(Schema.Literal('too-large')),
  }),
  Schema.Struct({
    ...assetFields,
    state: Schema.Literal('complete'),
    size: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
    digest: Schema.String.check(Schema.isPattern(/^[\da-f]{64}$/u)),
  }),
]);
export type Asset = typeof AssetSchema.Type;

const SpanSchema = Schema.Union([
  Schema.Struct({
    text: Schema.NonEmptyString.check(
      Schema.makeFilter(
        (text) => !text.includes('\n') && !text.includes(imageCharacter),
      ),
    ),
    marks: Schema.optionalKey(Schema.NonEmptyArray(MarkSchema)),
  }),
  // An inline image: one character of the text, carrying the image it shows.
  Schema.Struct({
    text: Schema.Literal(imageCharacter),
    image: AssetSchema,
    marks: Schema.optionalKey(Schema.NonEmptyArray(MarkSchema)),
  }),
]);
export const BlockSchema = Schema.Struct({
  kind: BlockKindSchema,
  spans: Schema.Array(SpanSchema),
});
export type Block = typeof BlockSchema.Type;
export const SemanticDocumentSchema = Schema.NonEmptyArray(BlockSchema);
export type SemanticDocument = typeof SemanticDocumentSchema.Type;

export const emptyDocument: SemanticDocument = [
  { kind: 'paragraph', spans: [] },
];

// The editor shows one text: blocks joined by line breaks, list items after a marker that is
// displayed but never stored.
type Char = Readonly<{ ch: string; marks: readonly Mark[]; image?: Asset }>;
type Line = Readonly<{
  kind: BlockKind;
  length: number;
  chars: readonly Char[];
}>;

// Cache compact wrappers, never expanded characters: history keeps old blocks alive. Only the
// edited blocks expand; unchanged blocks keep their identity across history versions.
// ponytail: one very long block still expands whole per edit; chunk it if typing stalls.
const lineOfBlock = new WeakMap<Block, Line>();
const blockOfLine = new WeakMap<Line, Block>();

const linesOf = (document: SemanticDocument): Line[] =>
  document.map((block) => {
    const cached = lineOfBlock.get(block);
    if (cached !== undefined) {
      return cached;
    }
    const line: Line = {
      kind: block.kind,
      length: block.spans.reduce((count, { text }) => count + text.length, 0),
      get chars() {
        return block.spans.flatMap((span) =>
          'image' in span
            ? [
                {
                  ch: imageCharacter,
                  marks: span.marks ?? [],
                  image: span.image,
                },
              ]
            : // Code units, as editor offsets count them; a split surrogate pair rejoins in order.
              span.text
                .split('')
                .map((ch) => ({ ch, marks: span.marks ?? [] })),
        );
      },
    };
    lineOfBlock.set(block, line);
    blockOfLine.set(line, block);
    return line;
  });

const lineOf = (kind: BlockKind, chars: readonly Char[]): Line => ({
  kind,
  length: chars.length,
  chars,
});

const sameMarks = (left: readonly Mark[], right: readonly Mark[]) =>
  left.length === right.length && left.every((mark, i) => right[i] === mark);

const blockOf = ({ kind, chars }: Line): Block => {
  const spans: Array<{ text: string; marks: readonly Mark[]; image?: Asset }> =
    [];
  for (const { ch, marks, image } of chars) {
    const last = spans.at(-1);
    // An image is a span of its own.
    if (
      last !== undefined &&
      image === undefined &&
      last.image === undefined &&
      sameMarks(last.marks, marks)
    ) {
      last.text += ch;
    } else {
      spans.push(
        image === undefined ? { text: ch, marks } : { text: ch, marks, image },
      );
    }
  }
  return {
    kind,
    spans: spans.map(({ text, marks, image }) => {
      const [first, ...rest] = marks;
      const marked =
        first === undefined ? {} : { marks: [first, ...rest] as const };
      return image === undefined
        ? { text, ...marked }
        : { text: imageCharacter, image, ...marked };
    }),
  };
};

const documentOf = (lines: readonly Line[]): SemanticDocument => {
  const blocks = lines.map((line) => {
    const cached = blockOfLine.get(line);
    if (cached !== undefined) {
      return cached;
    }
    const block = blockOf(line);
    blockOfLine.set(line, block);
    return block;
  });
  const [first, ...rest] = blocks;
  return first === undefined ? emptyDocument : [first, ...rest];
};

// Consecutive numbered items count from one; any other block restarts the count.
const markersOf = (lines: readonly Line[]) => {
  let number = 0;
  return lines.map(({ kind }) => {
    number = kind === 'numbered' ? number + 1 : 0;
    if (kind === 'bulleted') {
      return '• ';
    }
    return kind === 'numbered' ? `${number}. ` : '';
  });
};

export type DisplayLine = Readonly<{
  kind: BlockKind;
  marker: string;
  spans: Block['spans'];
}>;

// What the editor shows for a document, line by line, and as one text.
export function displayOf(document: SemanticDocument) {
  const markers = markersOf(linesOf(document));
  const lines: DisplayLine[] = document.map(({ kind, spans }, i) => ({
    kind,
    marker: markers[i] ?? '',
    spans,
  }));
  return {
    lines,
    text: lines
      .map(
        ({ marker, spans }) => marker + spans.map(({ text }) => text).join(''),
      )
      .join('\n'),
  };
}

export const plainText = (document: SemanticDocument) =>
  document
    .map(({ spans }) => spans.map(({ text }) => text).join(''))
    .join('\n');

// At most `limit` code units of `text`, never ending inside a surrogate pair.
export const clip = (text: string, limit = 300) => {
  if (text.length <= limit) {
    return text;
  }
  const cut = text.slice(0, limit);
  // A split surrogate pair would show a replacement character.
  return /\p{Cs}$/u.test(cut) ? cut.slice(0, -1) : cut;
};

/**
 * The start of the body on one line, with spaces between blocks and whitespace
 * preserved.
 *
 * @example
 *   previewOf([{ kind: 'paragraph', spans: [{ text: 'Hello' }] }], 3); // 'Hel'
 *
 * @param {SemanticDocument} document - The semantic body to preview.
 * @param {number} limit - A finite nonnegative integer counting UTF-16 code
 *   units.
 * @returns {string} At most `limit` code units, without splitting a surrogate
 *   pair at the cut.
 */
export const previewOf = (document: SemanticDocument, limit = 300) => {
  let preview = '';
  // Retain at most `limit + 1` code units to detect a cut. Nonempty spans and block spaces
  // bound traversal too, however long the Draft is.
  const pieces = function* () {
    for (const [index, { spans }] of document.entries()) {
      yield index === 0 ? '' : ' ';
      for (const span of spans) {
        yield 'image' in span ? '' : span.text;
      }
    }
  };
  for (const text of pieces()) {
    preview += text.slice(0, limit + 1 - preview.length);
    if (preview.length > limit) {
      return clip(preview, limit);
    }
  }
  return preview;
};

// A display offset as a line and a column within that line's text, after its marker.
const locate = (lines: readonly Line[], offset: number) => {
  const markers = markersOf(lines);
  let start = 0;
  for (const [index, line] of lines.entries()) {
    const marker = markers[index]?.length ?? 0;
    const end = start + marker + line.length;
    if (offset <= end || index === lines.length - 1) {
      const column = Math.min(offset - start, marker + line.length);
      return { line: index, column, marker };
    }
    start = end + 1;
  }
  return { line: 0, column: 0, marker: 0 };
};

const offsetOf = (lines: readonly Line[], line: number, column: number) => {
  const markers = markersOf(lines);
  let offset = 0;
  for (let index = 0; index < line; index += 1) {
    offset += (markers[index]?.length ?? 0) + (lines[index]?.length ?? 0) + 1;
  }
  return offset + (markers[line]?.length ?? 0) + column;
};

// Return continues lists, quotes and code; after a heading the next block is a paragraph.
const continuation = (kind: BlockKind): BlockKind =>
  kind === 'bulleted' ||
  kind === 'numbered' ||
  kind === 'quote' ||
  kind === 'code'
    ? kind
    : 'paragraph';

const shortcuts: ReadonlyArray<readonly [string, BlockKind]> = [
  ['# ', 'heading1'],
  ['## ', 'heading2'],
  ['### ', 'heading3'],
  ['- ', 'bulleted'],
  ['* ', 'bulleted'],
  ['1. ', 'numbered'],
  ['> ', 'quote'],
  ['```', 'code'],
];

export type Selection = Readonly<{ start: number; end: number }>;

export type Edit = Readonly<{
  document: SemanticDocument;
  // Where the caret belongs when the shown text differs from what was typed.
  selection?: Selection;
  // The document with a typed Markdown marker still literal, before the shortcut applied it;
  // one Undo returns to it.
  literal?: SemanticDocument;
}>;

type Change = Readonly<{ start: number; end: number; inserted: string }>;

// The changed span between two texts from their unchanged start and end.
const diffOf = (previous: string, next: string): Change => {
  const limit = Math.min(previous.length, next.length);
  let prefix = 0;
  while (prefix < limit && previous[prefix] === next[prefix]) {
    prefix += 1;
  }
  let suffix = 0;
  while (
    suffix < limit - prefix &&
    previous[previous.length - 1 - suffix] === next[next.length - 1 - suffix]
  ) {
    suffix += 1;
  }
  return {
    start: prefix,
    end: previous.length - suffix,
    inserted: next.slice(prefix, next.length - suffix),
  };
};

// The span `from`..`to` of `previous`, when replacing it alone turns `previous` into `next`.
const replacing = (
  previous: string,
  next: string,
  [from, to]: readonly [number, number],
): Change | undefined => {
  const insertedEnd = to + next.length - previous.length;
  const fits =
    from >= 0 &&
    to <= previous.length &&
    insertedEnd >= from &&
    previous.slice(0, from) === next.slice(0, from) &&
    previous.slice(to) === next.slice(insertedEnd);
  return fits
    ? { start: from, end: to, inserted: next.slice(from, insertedEnd) }
    : undefined;
};

// The changed span between two texts: what remained before and after it, and what replaced it.
// Repeated characters are ambiguous in a text-only diff, so the selected replacement, insertion
// at the caret, or deletion immediately beside it wins when the unchanged text agrees.
const changeOf = (
  previous: string,
  next: string,
  {
    selection,
    deletion,
  }: Readonly<{
    selection?: Selection | undefined;
    deletion?: 'backward' | 'forward' | undefined;
  }>,
): Change => {
  if (selection === undefined) {
    return diffOf(previous, next);
  }
  const start = Math.min(selection.start, selection.end);
  const end = Math.max(selection.start, selection.end);
  const delta = next.length - previous.length;
  const backward = [start + delta, end] as const;
  const forward = [start, end - delta] as const;
  const deleting = start === end && delta < 0;
  const ordered =
    deletion === 'forward' ? [forward, backward] : [backward, forward];
  const candidates = deleting ? ordered : [[start, end] as const];
  for (const range of candidates) {
    const change = replacing(previous, next, range);
    if (change !== undefined) {
      return change;
    }
  }
  return diffOf(previous, next);
};

// The kind of each block a change creates. Return continues the block it splits; at the start of
// a block, it inserts a block before it and keeps this block's kind.
const createdKind = (
  kind: BlockKind,
  {
    index,
    count,
    above,
  }: Readonly<{ index: number; count: number; above: boolean }>,
): BlockKind => {
  if (index === 0) {
    return above ? continuation(kind) : kind;
  }
  return above && index === count - 1 ? kind : continuation(kind);
};

// The kept text before and after a change, and the kind of the block it starts in. Typing before
// a list marker belongs to the item; any other change to the marker removes it.
const edgesOf = (lines: readonly Line[], { start, end }: Change) => {
  const from = locate(lines, start);
  const to = locate(lines, end);
  const first = lines[from.line] ?? lineOf('paragraph', []);
  const last = lines[to.line] ?? first;
  const firstChars = first.chars;
  const lastChars = first === last ? firstChars : last.chars;
  const intoMarker = from.column < from.marker;
  const removesMarker = intoMarker && (start !== end || from.column !== 0);
  return {
    from,
    to,
    kind: removesMarker ? 'paragraph' : first.kind,
    head: firstChars.slice(0, Math.max(0, from.column - from.marker)),
    tail: lastChars.slice(Math.max(0, to.column - to.marker)),
  } as const;
};

// Replaces the changed span of the lines, returning the new lines and the caret after it.
// fallow-ignore-next-line complexity -- Inherited marks and created block kinds are one splice.
const splice = (
  lines: readonly Line[],
  change: Change,
  marks: readonly Mark[] | undefined,
) => {
  const { from, to, kind, head, tail } = edgesOf(lines, change);
  const typed = marks ?? head.at(-1)?.marks ?? tail[0]?.marks ?? [];
  const parts = change.inserted
    // Only an inserted image carries its character; typed or pasted ones are dropped.
    .replaceAll(imageCharacter, '')
    .split('\n')
    .map((part) => part.split('').map((ch) => ({ ch, marks: typed })));
  const above = head.length === 0 && parts.length > 1 && parts[0]?.length === 0;
  const last = parts.length - 1;
  const created = parts.map((chars, index) =>
    lineOf(createdKind(kind, { index, count: parts.length, above }), [
      ...(index === 0 ? head : []),
      ...chars,
      ...(index === last ? tail : []),
    ]),
  );
  return {
    lines: [
      ...lines.slice(0, from.line),
      ...created,
      ...lines.slice(to.line + 1),
    ],
    line: from.line + last,
    column: (last === 0 ? head.length : 0) + (parts.at(-1)?.length ?? 0),
  };
};

// The block a just-typed Markdown marker turns its paragraph into, if any.
const shortcutAt = (
  line: Line | undefined,
  column: number,
  inserted: string,
) => {
  if (line?.kind !== 'paragraph' || (inserted !== ' ' && inserted !== '`')) {
    return undefined;
  }
  const before = line.chars
    .slice(0, column)
    .map(({ ch }) => ch)
    .join('');
  return shortcuts.find(([marker]) => marker === before)?.[1];
};

// Applies the editor's new text to the document. The change is the span between the unchanged
// start and end of the text; inserted characters take `marks`, or those of the text before them.
// Deleting into a list marker turns that item into a paragraph.
export function applyText(
  document: SemanticDocument,
  next: string,
  {
    marks,
    selection,
    deletion,
  }: Readonly<{
    marks?: readonly Mark[] | undefined;
    selection?: Selection;
    deletion?: 'backward' | 'forward' | undefined;
  }> = {},
): Edit {
  const previous = displayOf(document).text;
  if (previous === next) {
    return { document };
  }
  const change = changeOf(previous, next, { selection, deletion });
  const { lines, line, column } = splice(linesOf(document), change, marks);
  const caret = (forLines: readonly Line[], at: number) => {
    const offset = offsetOf(forLines, line, at);
    return { start: offset, end: offset };
  };
  const current = lines[line];
  const shortcut = shortcutAt(current, column, change.inserted);
  if (current !== undefined && shortcut !== undefined) {
    const converted = lines.map((each, index) =>
      index === line ? lineOf(shortcut, current.chars.slice(column)) : each,
    );
    return {
      document: documentOf(converted),
      selection: caret(converted, 0),
      literal: documentOf(lines),
    };
  }
  const edited = documentOf(lines);
  return displayOf(edited).text === next
    ? { document: edited }
    : { document: edited, selection: caret(lines, column) };
}

// The characters a selection covers, line by line, excluding list markers.
const covered = (lines: readonly Line[], { start, end }: Selection) => {
  const from = locate(lines, Math.min(start, end));
  const to = locate(lines, Math.max(start, end));
  return lines.map((line, index) => {
    if (index < from.line || index > to.line) {
      return [0, 0] as const;
    }
    const first =
      index === from.line ? Math.max(0, from.column - from.marker) : 0;
    const last =
      index === to.line ? Math.max(0, to.column - to.marker) : line.length;
    return [first, last] as const;
  });
};

// The marks shared by every selected character, or of the character before a caret.
export function marksAt(document: SemanticDocument, selection: Selection) {
  const lines = linesOf(document);
  const ranges = covered(lines, selection);
  if (selection.start === selection.end) {
    // The marks typed text takes there: the character before the caret, or at the start of a
    // block the one after it, as insertion inherits them.
    const { line, column, marker } = locate(lines, selection.start);
    const chars = lines[line]?.chars ?? [];
    const at = Math.max(0, column - marker);
    return chars[at - 1]?.marks ?? chars[at]?.marks ?? [];
  }
  const chars = lines.flatMap((line, index) => {
    const [first, last] = ranges[index] ?? [0, 0];
    return first === last ? [] : line.chars.slice(first, last);
  });
  return markOrder.filter(
    (mark) =>
      chars.length > 0 && chars.every(({ marks }) => marks.includes(mark)),
  );
}

// Adds a mark to the selected text, or removes it when every selected character has it.
export function toggleMark(
  document: SemanticDocument,
  selection: Selection,
  mark: Mark,
): SemanticDocument {
  const lines = linesOf(document);
  const ranges = covered(lines, selection);
  const has = marksAt(document, selection).includes(mark);
  return documentOf(
    lines.map((line, index) => {
      const [first, last] = ranges[index] ?? [0, 0];
      if (first === last) {
        return line;
      }
      return lineOf(
        line.kind,
        line.chars.map((char, column) =>
          column < first || column >= last
            ? char
            : {
                ...char,
                marks: markOrder.filter((each) =>
                  each === mark ? !has : char.marks.includes(each),
                ),
              },
        ),
      );
    }),
  );
}

// The marks typed text takes after toggling one at a caret.
export const toggled = (marks: readonly Mark[], mark: Mark) =>
  markOrder.filter((each) => (each === mark) !== marks.includes(each));

export const blockKindAt = (document: SemanticDocument, offset: number) => {
  const lines = linesOf(document);
  return lines[locate(lines, offset).line]?.kind ?? 'paragraph';
};

// Replaces the selection with an inline image, leaving the caret after it.
export function insertImage(
  document: SemanticDocument,
  selection: Selection,
  image: Asset,
): Edit {
  const start = Math.min(selection.start, selection.end);
  const end = Math.max(selection.start, selection.end);
  const { lines, line, column } = splice(
    linesOf(document),
    { start, end, inserted: '' },
    undefined,
  );
  const result = lines.map((each, index) =>
    index === line
      ? lineOf(each.kind, [
          ...each.chars.slice(0, column),
          { ch: imageCharacter, marks: [], image },
          ...each.chars.slice(column),
        ])
      : each,
  );
  const offset = offsetOf(result, line, column + 1);
  return {
    document: documentOf(result),
    selection: { start: offset, end: offset },
  };
}

// The document's inline images, in reading order.
export const imagesOf = (document: SemanticDocument) =>
  document.flatMap(({ spans }) =>
    spans.flatMap((span) => ('image' in span ? [span.image] : [])),
  );

const showsImage = (span: Block['spans'][number], id: string) =>
  'image' in span && span.image.id === id;

// Applies `edit` to each block showing the inline image `id`; the same document when none does.
const editImageBlocks = (
  document: SemanticDocument,
  id: string,
  edit: (block: Block) => Block,
): SemanticDocument => {
  if (!imagesOf(document).some((image) => image.id === id)) {
    return document;
  }
  const [first, ...rest] = document.map((block) =>
    block.spans.some((span) => showsImage(span, id)) ? edit(block) : block,
  );
  return first === undefined ? document : [first, ...rest];
};

// The document with the inline image `id` replaced; the same document when it has none.
export const withImage = (
  document: SemanticDocument,
  id: string,
  next: (image: Asset) => Asset,
) =>
  editImageBlocks(document, id, (block) => ({
    ...block,
    spans: block.spans.map((span) =>
      'image' in span && span.image.id === id
        ? { ...span, image: next(span.image) }
        : span,
    ),
  }));

// The document without the inline image `id`, keeping the text around it.
export const withoutImage = (document: SemanticDocument, id: string) =>
  editImageBlocks(document, id, (block) =>
    blockOf(
      lineOf(
        block.kind,
        (linesOf([block])[0]?.chars ?? []).filter(
          (char) => char.image?.id !== id,
        ),
      ),
    ),
  );

// Sets every selected block to `kind`, or back to a paragraph when they all have it already.
export function setBlockKind(
  document: SemanticDocument,
  selection: Selection,
  kind: BlockKind,
): Edit {
  const lines = linesOf(document);
  const from = locate(lines, Math.min(selection.start, selection.end));
  const to = locate(lines, Math.max(selection.start, selection.end));
  const chosen = lines.slice(from.line, to.line + 1);
  const next = chosen.every((line) => line.kind === kind) ? 'paragraph' : kind;
  const result = lines.map((line, index) =>
    index < from.line || index > to.line ? line : lineOf(next, line.chars),
  );
  const column = (at: Readonly<typeof from>) =>
    Math.max(0, at.column - at.marker);
  return {
    document: documentOf(result),
    selection: {
      start: offsetOf(result, from.line, column(from)),
      end: offsetOf(result, to.line, column(to)),
    },
  };
}

// Undo and redo over whole editor states. Typing extends the current step until a word ends;
// every other change is its own step.
export type History<T> = Readonly<{
  past: readonly T[];
  present: T;
  future: readonly T[];
  typing: boolean;
}>;

const historyLimit = 100;

export const historyOf = <T>(present: T): History<T> => ({
  past: [],
  present,
  future: [],
  typing: false,
});

export function record<T>(
  history: History<T>,
  next: T,
  typing = false,
): History<T> {
  return {
    past:
      typing && history.typing
        ? history.past
        : [...history.past, history.present].slice(-historyLimit),
    present: next,
    future: [],
    typing,
  };
}

export function undo<T>(history: History<T>): History<T> {
  const previous = history.past.at(-1);
  return previous === undefined
    ? history
    : {
        past: history.past.slice(0, -1),
        present: previous,
        future: [history.present, ...history.future],
        typing: false,
      };
}

export function redo<T>(history: History<T>): History<T> {
  const [next, ...future] = history.future;
  return next === undefined
    ? history
    : {
        past: [...history.past, history.present],
        present: next,
        future,
        typing: false,
      };
}
