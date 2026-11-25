// The page's script: Tiptap over the Semantic Message Document's blocks, marks, links and Inline
// Images, and the Draft's Attachments, posting each edit and selection change to the host. The host
// injects `draftEditor` before this script runs and sends commands through `draftCommand`.
import type {
  Asset,
  BlockKind,
  SemanticDocument,
} from '@private-email/mail-core/semantic-document';
import type { ChainedCommands, Editor as TiptapEditor } from '@tiptap/core';
import type { EditorState, Transaction } from '@tiptap/pm/state';

import { formatStyleOf } from '@private-email/mail-core/body-display';
import { vettedHref } from '@private-email/mail-core/link-inspection';
import { Editor, Extension, Mark, Node } from '@tiptap/core';
import Blockquote from '@tiptap/extension-blockquote';
import Bold from '@tiptap/extension-bold';
import Code from '@tiptap/extension-code';
import Document from '@tiptap/extension-document';
import Heading from '@tiptap/extension-heading';
import Italic from '@tiptap/extension-italic';
import {
  BulletList,
  ListItem,
  ListKeymap,
  OrderedList,
} from '@tiptap/extension-list';
import Paragraph from '@tiptap/extension-paragraph';
import Strike from '@tiptap/extension-strike';
import Text from '@tiptap/extension-text';
import Underline from '@tiptap/extension-underline';
import { UndoRedo } from '@tiptap/extensions';
import { closeHistory } from '@tiptap/pm/history';
import { Fragment, Node as ProseMirrorNode, Slice } from '@tiptap/pm/model';
import { Plugin, Selection, TextSelection } from '@tiptap/pm/state';

import type { Command, Update } from './messages.ts';

import {
  displayOffset,
  editorPosition,
  formatOf,
  fromEditor,
  isImageWidth,
  kindAt,
  linesOfDocument,
  markOrder,
  tiptapMarks,
  toEditor,
} from './conversion.ts';

declare global {
  var draftEditor:
    | Readonly<{
        document: SemanticDocument;
        attachments: readonly Asset[];
        label: string;
      }>
    | undefined;
  var draftCommand: ((command: Command) => void) | undefined;
  var ReactNativeWebView:
    | Readonly<{ postMessage: (message: string) => void }>
    | undefined;
}

// The assets the host gave this page, by identifier, and the thumbnails native code made from their
// verified bytes. The page never receives an asset's bytes.
const assets = new Map<string, Asset>();
const previews = new Map<string, string>();
const learn = (given: readonly Asset[]) => {
  for (const asset of given) {
    assets.set(asset.id, asset);
  }
};

// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- The DOM image is mutable by design.
const show = (image: HTMLImageElement) => {
  const preview = previews.get(image.dataset.draftAsset ?? '');
  if (preview === undefined) {
    image.removeAttribute('src');
  } else {
    image.src = preview;
  }
};

// An Inline Image: one position of the text, showing its asset's thumbnail when native code has
// verified the bytes, with any display width it was given. Only an image this page shows parses
// back from a paste, as when it is cut and pasted to move it; other pasted images are dropped.
const InlineImage = Node.create({
  name: 'inlineImage',
  group: 'inline',
  inline: true,
  atom: true,
  draggable: true,
  addAttributes: () => ({
    id: { default: '', rendered: false },
    width: { default: null, rendered: false },
  }),
  parseHTML: () => [
    {
      tag: 'img[data-draft-asset]',
      getAttrs: (element) => {
        const id = element.dataset.draftAsset ?? '';
        const width = Number(element.dataset.draftWidth);
        return assets.has(id)
          ? { id, width: isImageWidth(width) ? width : null }
          : false;
      },
    },
  ],
  renderHTML: ({ node }) => {
    const id = String(node.attrs.id);
    const width: unknown = node.attrs.width;
    return [
      'img',
      {
        'data-draft-asset': id,
        'data-draft-width': isImageWidth(width) ? String(width) : undefined,
        alt: assets.get(id)?.name,
      },
    ];
  },
  addNodeView:
    () =>
    ({ node }) => {
      const id = String(node.attrs.id);
      const dom = document.createElement('img');
      dom.dataset.draftAsset = id;
      dom.alt = assets.get(id)?.name ?? '';
      show(dom);
      return { dom };
    },
});

// Linked text. Text typed inside a link joins it, and at its edges stays unlinked. A pasted link
// keeps its destination only when it is one the Draft admits as written; otherwise only its text
// is pasted. The host refuses every navigation, so selecting linked text never opens it.
const Link = Mark.create({
  name: 'link',
  inclusive: false,
  keepOnSplit: false,
  addAttributes: () => ({ href: { default: null } }),
  parseHTML: () => [
    {
      tag: 'a[href]',
      getAttrs: (element) => {
        const href = element.getAttribute('href') ?? '';
        return vettedHref(href) === href ? { href } : false;
      },
    },
  ],
  renderHTML: ({ HTMLAttributes }) => ['a', HTMLAttributes, 0],
});

const systemFamilies = new Set(['system-ui', 'ui-serif', 'ui-monospace']);

// A span's stored color, background, font family and size, shown as the current composer shows
// them: Dark adapts text colors on screen only. Typed text takes the format of the text before it,
// and at a block's start the text after it; the line Return starts has none. Pasted text never
// carries one.
const Format = Mark.create({
  name: 'format',
  keepOnSplit: false,
  addAttributes: () => ({
    color: { default: null, rendered: false },
    background: { default: null, rendered: false },
    font: { default: null, rendered: false },
    size: { default: null, rendered: false },
  }),
  renderHTML: ({ mark }) => {
    const span = { text: ' ', ...formatOf(mark.attrs) };
    const light = formatStyleOf(span, 'light');
    const dark = formatStyleOf(span, 'dark');
    // The system families stay keywords; any other name is a CSS string.
    const family = systemFamilies.has(light.fontFamily ?? '')
      ? light.fontFamily
      : `"${light.fontFamily?.replaceAll(/["\\]/gu, String.raw`\$&`)}"`;
    return [
      'span',
      {
        'data-draft-format': '',
        style: [
          light.color === undefined ? '' : `--draft-light: ${light.color};`,
          dark.color === undefined ? '' : `--draft-dark: ${dark.color};`,
          light.backgroundColor === undefined
            ? ''
            : `background-color: ${light.backgroundColor};`,
          light.fontFamily === undefined
            ? ''
            : `font-family: ${family}, system-ui;`,
          light.fontSize === undefined
            ? ''
            : `font-size: ${light.fontSize}px; line-height: ${light.lineHeight}px;`,
        ].join(''),
      },
      0,
    ];
  },
});

// Each textblock's stored alignment and each list item's level, as the current composer shows
// them. Return keeps both; pasted HTML carries neither.
const Layout = Extension.create({
  name: 'layout',
  addGlobalAttributes: () => [
    {
      types: ['paragraph', 'heading', 'codeLine'],
      attributes: {
        align: {
          default: null,
          parseHTML: () => null,
          renderHTML: ({ align }) =>
            typeof align === 'string' ? { style: `text-align: ${align}` } : {},
        },
      },
    },
    {
      types: ['listItem'],
      attributes: {
        indent: {
          default: 0,
          parseHTML: () => 0,
          renderHTML: ({ indent }) =>
            indent === 0 ? {} : { 'data-indent': String(indent) },
        },
      },
    },
  ],
});

// One code line per textblock, as the Semantic Message Document stores code; consecutive lines
// show as one block. A pasted multi-line block splits into lines.
const CodeLine = Node.create({
  name: 'codeLine',
  group: 'block',
  content: 'inline*',
  marks: '_',
  code: true,
  defining: true,
  parseHTML: () => [
    {
      tag: 'pre',
      preserveWhitespace: 'full',
      // A `code` element inside is the line's text, not inline code.
      contentElement: (pre) => pre.querySelector('code') ?? pre,
    },
  ],
  renderHTML: ({ HTMLAttributes }) => ['pre', HTMLAttributes, ['code', 0]],
});

// Every selected textblock, in order, with its alignment and the list item holding it.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- ProseMirror's transaction is a class; this only reads it.
const textblocksIn = ({ doc, selection: { from, to } }: Transaction) => {
  const found: Array<{
    position: number;
    align: unknown;
    item?: { position: number; indent: unknown };
  }> = [];
  doc.nodesBetween(from, to, (node, position, parent) => {
    if (node.isTextblock) {
      const attrs: Readonly<Record<string, unknown>> = node.attrs;
      const item: Readonly<Record<string, unknown>> | undefined =
        parent?.type.name === 'listItem' ? parent.attrs : undefined;
      found.push({
        position,
        align: attrs.align,
        ...(item === undefined
          ? {}
          : {
              item: {
                position: doc.resolve(position).before(),
                indent: item.indent,
              },
            }),
      });
    }
    return !node.isTextblock;
  });
  return found;
};

// Sets every selected block to `kind`, from a paragraph: no block nests in another. As in the
// current composer, each keeps its alignment, and a list item its level while it stays one.
type Chain = ChainedCommands;
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Tiptap's command chain is mutable by design.
const kindCommands: Partial<Record<BlockKind, (chain: Chain) => Chain>> = {
  heading1: (chain) => chain.setNode('heading', { level: 1 }),
  heading2: (chain) => chain.setNode('heading', { level: 2 }),
  heading3: (chain) => chain.setNode('heading', { level: 3 }),
  bulleted: (chain) => chain.wrapInList('bulletList'),
  numbered: (chain) => chain.wrapInList('orderedList'),
  quote: (chain) => chain.wrapIn('blockquote'),
  code: (chain) => chain.setNode('codeLine'),
};
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Tiptap's command chain is mutable by design.
const setKind = (chain: Chain, kind: BlockKind) => {
  let kept: ReturnType<typeof textblocksIn> = [];
  const cleared = chain
    .command(({ tr }) => {
      kept = textblocksIn(tr);
      return true;
    })
    .clearNodes();
  return (kindCommands[kind]?.(cleared) ?? cleared).command(({ tr }) => {
    for (const [index, { position, item }] of textblocksIn(tr).entries()) {
      const before = kept[index];
      tr.setNodeAttribute(position, 'align', before?.align ?? null);
      if (item !== undefined && before?.item !== undefined) {
        tr.setNodeAttribute(item.position, 'indent', before.item.indent);
      }
    }
    return true;
  });
};

// The block kinds of every selected textblock.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Tiptap's editor is a class; this only reads it.
const kindsIn = ({ state }: TiptapEditor) => {
  const kinds = new Set<BlockKind>();
  const { from, to } = state.selection;
  state.doc.nodesBetween(from, to, (node, position) => {
    if (node.isTextblock) {
      kinds.add(kindAt(state.doc.resolve(position + 1)));
    }
    return !node.isTextblock;
  });
  return kinds;
};

// Sets every selected block to `kind`, or to paragraphs when they all have it, as the current
// composer does.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Tiptap's editor is a class; this runs commands on it.
const setBlockKind = (editor: TiptapEditor, kind: BlockKind) => {
  const all = [...kindsIn(editor)].every((each) => each === kind);
  return setKind(editor.chain(), all ? 'paragraph' : kind).run();
};

// Tiptap's block kind shortcuts.
const blockKeys = new Map<string, BlockKind>([
  ['Mod-Alt-1', 'heading1'],
  ['Mod-Alt-2', 'heading2'],
  ['Mod-Alt-3', 'heading3'],
  ['Mod-Shift-8', 'bulleted'],
  ['Mod-Shift-7', 'numbered'],
  ['Mod-Shift-b', 'quote'],
]);

// Typed at the start of a paragraph, these apply their block kind; the marker is removed.
const shortcuts = new Map<string, BlockKind>([
  ['# ', 'heading1'],
  ['## ', 'heading2'],
  ['### ', 'heading3'],
  ['- ', 'bulleted'],
  ['* ', 'bulleted'],
  ['1. ', 'numbered'],
  ['> ', 'quote'],
  ['```', 'code'],
]);

const typing = 'draftTyping';
const imageCharacter = '\uFFFC';

// A pasted slice without alignments and list levels, which copying within the page would carry.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- ProseMirror's Fragment is a class; this only reads it.
const unlaidOut = (fragment: Fragment): Fragment =>
  Fragment.fromArray(
    fragment.content.map((node) =>
      node.isText
        ? node
        : node.type.create(
            {
              ...node.attrs,
              ...('align' in node.attrs ? { align: null } : {}),
              ...('indent' in node.attrs ? { indent: 0 } : {}),
            },
            unlaidOut(node.content),
            node.marks,
          ),
    ),
  );

// A pasted slice opened as far as it goes at its start and, when it holds one line, at its end.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- ProseMirror's Slice is a class; this only reads it.
const joined = (slice: Slice) => {
  const open = Slice.maxOpen(slice.content);
  let lines = 0;
  slice.content.descendants((node) => {
    lines += node.isTextblock ? 1 : 0;
    return !node.isTextblock;
  });
  return new Slice(
    slice.content,
    open.openStart,
    lines === 1 ? open.openEnd : slice.openEnd,
  );
};

// Whether a paste or drop carries files or image data, which only native code may read.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- The DOM's DataTransfer is mutable by design; this only reads it.
const carriesFiles = (data: DataTransfer | null) =>
  data !== null &&
  [...data.types].some((type) => type === 'Files' || type.startsWith('image/'));

// The fixes an edit needs before the document can be stored: an Inline Image's character is
// removed, a line break splits a code line (from Return or a paste) and is a space elsewhere, and
// each further paragraph of a list item becomes an item of its own. Applied from the end, so
// earlier positions stay valid.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- ProseMirror's state is a class; this only reads it.
const normalized = (state: EditorState) => {
  const { tr } = state;
  const fixes: Array<readonly [number, (at: number) => void]> = [];
  state.doc.descendants((node, position, parent) => {
    node.forEach((_child, offset, index) => {
      if (node.type.name === 'listItem' && index > 0) {
        fixes.push([
          position + 1 + offset,
          (at) => {
            tr.split(at, 1);
          },
        ]);
      }
    });
    // Code units, as document positions count them.
    const text = node.text ?? '';
    for (let index = 0; index < text.length; index += 1) {
      const at = position + index;
      if (text[index] === imageCharacter) {
        fixes.push([
          at,
          () => {
            tr.delete(at, at + 1);
          },
        ]);
      } else if (text[index] === '\n') {
        fixes.push([
          at,
          () => {
            if (parent?.type.name === 'codeLine') {
              tr.delete(at, at + 1).split(at);
            } else {
              tr.insertText(' ', at, at + 1);
            }
          },
        ]);
      }
    }
    return !node.isText;
  });
  for (const [at, fix] of fixes.toSorted(([a], [b]) => b - a)) {
    fix(at);
  }
  return tr.docChanged ? tr : null;
};

// Deletes `from` to `to` as the current composer deletes across lines: the textblock holding
// `from` keeps its kind, alignment and list level and takes the rest of the last one, and every
// textblock after it in the range goes, with any quote or list item left empty. After Select All
// the first textblock stays, emptied; Tiptap would reset a document emptied this way.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- ProseMirror's transaction is a class; this edits it.
const flatDelete = (tr: Transaction, from: number, to: number) => {
  const blocks: Array<Readonly<{ node: ProseMirrorNode; position: number }>> =
    [];
  tr.doc.nodesBetween(from, to, (node, position) => {
    if (node.isTextblock) {
      blocks.push({ node, position });
    }
    return !node.isTextblock;
  });
  const [first, ...rest] = blocks;
  if (from === to || first === undefined) {
    return;
  }
  const last = rest.at(-1) ?? first;
  const start = Math.max(from, first.position + 1);
  const tail = last.node.content.cut(
    Math.min(Math.max(0, to - last.position - 1), last.node.content.size),
  );
  for (const { node, position } of rest.toReversed()) {
    tr.deleteRange(position, position + node.nodeSize);
  }
  tr.replaceWith(start, first.position + first.node.nodeSize - 1, tail);
  tr.setSelection(TextSelection.create(tr.doc, start));
  tr.setMeta('preventClearDocument', true);
};

// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- ProseMirror's transaction is a class; this edits it.
const deleteSelected = (tr: Transaction) => {
  flatDelete(tr, tr.selection.from, tr.selection.to);
  return true;
};

// Text typed over `from` to `to`, now at `start` to `end`, takes the format of the text before
// it, and at a block's start the text after it, as in the current composer. Replacing text takes
// the first replaced character's link, or none: including for Select All and, unlike marksAcross,
// when the selection crosses the link's end.
const keepReplaced = (
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- ProseMirror's transaction is a class; this marks the text it inserted.
  tr: Transaction,
  [from, to]: readonly [number, number],
  [start, end]: readonly [number, number],
) => {
  const doc = tr.before;
  const $from = doc.resolve(from);
  const beside =
    $from.parentOffset > 0 ? $from.nodeBefore : doc.resolve(to).nodeAfter;
  const format = beside?.marks.find((mark) => mark.type.name === 'format');
  if (format === undefined) {
    tr.removeMark(start, end, doc.type.schema.marks.format);
  } else {
    tr.addMark(start, end, format);
  }
  if (from === to) {
    return;
  }
  let node = doc.nodeAt(from);
  while (node !== null && !node.isInline) {
    node = node.firstChild;
  }
  const link = node?.marks.find((mark) => mark.type.name === 'link');
  if (link === undefined) {
    tr.removeMark(start, end, doc.type.schema.marks.link);
  } else {
    tr.addMark(start, end, link);
  }
};

// Return in an empty list item or quote line continues it, as in the current composer; Tiptap's
// own Return would lift it out of the list or quote.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- ProseMirror's transaction is a class; this edits it.
const continueEmpty = (tr: Transaction) => {
  const { $from, empty } = tr.selection;
  const container = $from.node(-1);
  if (
    !empty ||
    $from.parent.content.size > 0 ||
    !['listItem', 'blockquote'].includes(container.type.name)
  ) {
    return false;
  }
  const item = container.type.name === 'listItem';
  const paragraph = $from.parent.copy();
  const at = item ? $from.after(-1) : $from.after();
  tr.insert(
    at,
    item ? container.type.create(container.attrs, paragraph) : paragraph,
  );
  tr.setSelection(TextSelection.create(tr.doc, at + (item ? 2 : 1)));
  return true;
};

// Return at the start of a heading inserts a paragraph above it with the heading's alignment, as
// in the current composer; Tiptap's would be start-aligned.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- ProseMirror's transaction is a class; this edits it.
const paragraphAbove = (tr: Transaction) => {
  const { $from, empty } = tr.selection;
  if (
    !empty ||
    $from.parentOffset > 0 ||
    $from.parent.content.size === 0 ||
    $from.parent.type.name !== 'heading'
  ) {
    return false;
  }
  const { align }: Readonly<Record<string, unknown>> = $from.parent.attrs;
  tr.insert($from.before(), tr.doc.type.schema.node('paragraph', { align }));
  return true;
};

// Return over a selection deletes it first, so both lines Return leaves keep the first selected
// block's layout.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Tiptap's editor is a class; this runs commands on it.
const returnKey = (editor: TiptapEditor) =>
  editor.state.selection.empty
    ? editor.commands.command(
        ({ tr }) => continueEmpty(tr) || paragraphAbove(tr),
      )
    : editor
        .chain()
        .command(({ tr }) => deleteSelected(tr))
        .first(({ commands }) => [
          () =>
            commands.command(
              ({ tr }) => continueEmpty(tr) || paragraphAbove(tr),
            ),
          () => commands.splitListItem('listItem'),
          () => commands.newlineInCode(),
          () => commands.splitBlock(),
        ])
        .scrollIntoView()
        .run();

// Backspace and Delete delete a selection, and at a block's edge join it with the textblock
// before or after it, as the current composer does: the first keeps its kind, alignment and list
// level, even across a quote or list. Backspace at the start of a list item keeps turning it into
// a paragraph, and at the start of the document keeps Tiptap's behavior.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Tiptap's editor is a class; this runs commands on it.
const deleteKey = (editor: TiptapEditor, forward: boolean) => {
  const { selection, doc } = editor.state;
  const { $from, empty } = selection;
  if (!empty) {
    return editor.commands.command(({ tr }) => deleteSelected(tr));
  }
  const $other = forward
    ? $from.parentOffset === $from.parent.content.size &&
      Selection.findFrom(doc.resolve($from.after()), 1, true)?.$from
    : $from.parentOffset === 0 &&
      $from.node(-1).type.name !== 'listItem' &&
      Selection.findFrom(doc.resolve($from.before()), -1, true)?.$from;
  if (!$other) {
    return false;
  }
  return editor.commands.command(({ tr }) => {
    flatDelete(
      tr,
      forward ? $from.pos : $other.end(),
      forward ? $other.start() : $from.pos,
    );
    tr.scrollIntoView();
    return true;
  });
};

// Undo steps a word of typing at a time; every other edit is a step of its own. A Markdown
// shortcut first stores its literal marker, so one Undo restores it. Text never keeps an Inline
// Image's character, a code line never keeps a line break, and a list item holds one paragraph.
const DraftBehavior = Extension.create<unknown, { typing: boolean }>({
  name: 'draftBehavior',
  // Ahead of the list item's own Return.
  priority: 1000,
  addKeyboardShortcuts() {
    return {
      Enter: ({ editor }) => returnKey(editor),
      // Tiptap binds the modified keys to its Backspace and Delete as well.
      ...Object.fromEntries(
        [
          'Backspace',
          'Mod-Backspace',
          'Shift-Backspace',
          'Delete',
          'Mod-Delete',
        ].map((key) => [
          key,
          () => deleteKey(this.editor, key.endsWith('Delete')),
        ]),
      ),
      // Block kind shortcuts set kinds as the Format menu does.
      ...Object.fromEntries(
        [...blockKeys].map(([key, kind]) => [
          key,
          () => setBlockKind(this.editor, kind),
        ]),
      ),
    };
  },
  addProseMirrorPlugins() {
    const { editor } = this;
    return [
      new Plugin({
        props: {
          // A drag within the page moves its content as it is. A paragraph copied whole, as by
          // Select All, pastes as its text, as a partial copy does; other blocks stay blocks.
          transformPasted: (slice, view) => {
            if (view.dragging !== null) {
              return slice;
            }
            const content = unlaidOut(slice.content);
            const { firstChild } = content;
            const text =
              slice.openStart === 0 &&
              slice.openEnd === 0 &&
              content.childCount === 1 &&
              firstChild?.type.name === 'paragraph' &&
              firstChild.content.size > 0;
            return text
              ? new Slice(content, 1, 1)
              : new Slice(content, slice.openStart, slice.openEnd);
          },
          // A pasted image is read from the pasteboard by native code, where it can; the page
          // never reads the data, and a dropped file is refused.
          // Pasting over a selection deletes it as Backspace does first, and the first pasted block
          // joins the line left, even when copied whole; the line's text after the selection stays
          // on its own line unless only one line is pasted.
          handlePaste: (view, event, slice) => {
            if (!carriesFiles(event.clipboardData)) {
              if (view.state.selection.empty || slice.size === 0) {
                return false;
              }
              const { tr } = view.state;
              deleteSelected(tr);
              view.dispatch(
                tr
                  .replaceSelection(joined(slice))
                  .scrollIntoView()
                  .setMeta('paste', true)
                  .setMeta('uiEvent', 'paste'),
              );
              return true;
            }
            event.preventDefault();
            globalThis.ReactNativeWebView?.postMessage(
              JSON.stringify({ type: 'paste' }),
            );
            return true;
          },
          // A drag within the page into an empty line fills it with the content as it is: the line
          // takes the first dragged block's kind, where it may, alignment and list level.
          // oxlint-disable-next-line max-params -- ProseMirror's handleDrop signature.
          handleDrop: (view, event, slice, moved) => {
            if (!moved) {
              if (!carriesFiles(event.dataTransfer)) {
                return false;
              }
              event.preventDefault();
              return true;
            }
            const { tr } = view.state;
            const target = view.posAtCoords({
              left: event.clientX,
              top: event.clientY,
            });
            const $target = target && tr.doc.resolve(target.pos);
            const { $from: $source, from, to } = tr.selection;
            if (
              target === null ||
              !$target?.parent.isTextblock ||
              $target.parent.content.size > 0 ||
              slice.openStart === 0 ||
              (target.pos >= from && target.pos <= to)
            ) {
              return false;
            }
            tr.deleteSelection();
            const at = tr.mapping.map(target.pos);
            const steps = tr.mapping.maps.length;
            tr.replaceRange(at, at, slice);
            const end = tr.mapping.slice(steps).map(at);
            const $at = tr.doc.resolve(at);
            const { parent: line } = $source;
            const { align }: Readonly<Record<string, unknown>> = line.attrs;
            const index = $at.index($at.depth - 1);
            const adopts =
              $at.node(-1).canReplaceWith(index, index + 1, line.type) &&
              line.type.validContent($at.parent.content);
            tr.setNodeMarkup(
              $at.before(),
              adopts ? line.type : null,
              adopts ? line.attrs : { ...$at.parent.attrs, align },
            );
            if (
              $source.node(-1).type.name === 'listItem' &&
              $at.node(-1).type.name === 'listItem'
            ) {
              tr.setNodeAttribute(
                $at.before(-1),
                'indent',
                $source.node(-1).attrs.indent,
              );
            }
            tr.setSelection(
              TextSelection.between(tr.doc.resolve(at), tr.doc.resolve(end)),
            );
            view.focus();
            view.dispatch(tr.setMeta('uiEvent', 'drop'));
            return true;
          },
          // Text inserted over a selection across lines without a key press, as by dictation or a
          // suggestion, goes through handleTextInput too; ProseMirror would read it from the DOM.
          handleDOMEvents: {
            beforeinput: (view, event) => {
              const { from, to, $from, $to } = view.state.selection;
              const text = event.data;
              if (
                event.inputType !== 'insertText' ||
                text === null ||
                ($from.sameParent($to) && $from.parent.isTextblock)
              ) {
                return false;
              }
              event.preventDefault();
              return (
                view.someProp('handleTextInput', (input) =>
                  input(view, from, to, text, () =>
                    view.state.tr.insertText(text, from, to),
                  ),
                ) ?? false
              );
            },
          },
          // oxlint-disable-next-line max-params -- ProseMirror's handleTextInput signature.
          handleTextInput: (view, from, to, text, deflt) => {
            const $from = view.state.doc.resolve(from);
            const marker =
              from === to &&
              $from.depth === 1 &&
              $from.parent.type.name === 'paragraph'
                ? $from.parent.textBetween(0, $from.parentOffset) + text
                : '';
            const kind = shortcuts.get(marker);
            const word =
              from === to && [...text].length === 1 && !/\s/u.test(text);
            // Typing over a selection deletes it as Backspace does first.
            const tr = from === to ? deflt() : view.state.tr;
            // oxlint-disable-next-line unicorn/no-array-method-this-argument -- ProseMirror Mapping.map takes an association, not an array thisArg.
            let start = tr.mapping.map(from, -1);
            if (from !== to) {
              flatDelete(tr, from, to);
              start = tr.selection.from;
              tr.insertText(text);
            }
            keepReplaced(tr, [from, to], [start, start + text.length]);
            view.dispatch(word ? tr.setMeta(typing, true) : tr);
            if (kind !== undefined) {
              setKind(
                editor.chain().deleteRange({
                  from: $from.start(),
                  to: $from.start() + marker.length,
                }),
                kind,
              ).run();
            }
            return true;
          },
        },
        appendTransaction: (transactions, _previous, state) =>
          transactions.some(({ docChanged }) => docChanged)
            ? normalized(state)
            : null,
      }),
    ];
  },
  dispatchTransaction({ transaction: dispatched, next }) {
    // Cut deletes the selection as Backspace does.
    const transaction =
      dispatched.getMeta('uiEvent') === 'cut'
        ? this.editor.state.tr.setMeta('uiEvent', 'cut').scrollIntoView()
        : dispatched;
    if (transaction !== dispatched) {
      deleteSelected(transaction);
    }
    const typed = transaction.getMeta(typing) === true;
    const { storage } = this;
    if (transaction.docChanged && !(typed && storage.typing)) {
      closeHistory(transaction);
    }
    if (transaction.docChanged || transaction.selectionSet) {
      storage.typing = typed;
    }
    next(transaction);
  },
  addStorage: () => ({ typing: false }),
});

// The identifiers of the document's Attachments.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- ProseMirror's state and transaction are classes; this only reads them.
const attachmentsOf = ({ doc }: EditorState | Transaction): string[] => {
  const ids: unknown = doc.attrs.attachments;
  return Array.isArray(ids) ? ids.map(String) : [];
};

const { draftEditor, ReactNativeWebView } = globalThis;
const element = document.querySelector('#editor');
if (draftEditor !== undefined && element !== null) {
  learn(draftEditor.attachments);
  for (const { spans } of draftEditor.document) {
    learn(spans.flatMap((span) => ('image' in span ? [span.image] : [])));
  }
  let revision = 0;
  const post = (
    // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Tiptap's editor is a class; this only reads it.
    editor: TiptapEditor,
    // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- ProseMirror's transaction is a class; this only reads it.
    transaction: Transaction,
    frozen = false,
  ) => {
    if (transaction.docChanged) {
      revision += 1;
    }
    const lines = linesOfDocument(editor.state.doc);
    const { from, to } = editor.state.selection;
    const update: Update = {
      type: 'update',
      revision,
      ...(frozen ? { frozen: true as const } : {}),
      ...(transaction.docChanged || frozen
        ? {
            document: fromEditor(editor.getJSON(), assets),
            attachments: attachmentsOf(editor.state).flatMap((id) => {
              const asset = assets.get(id);
              return asset === undefined ? [] : [asset];
            }),
          }
        : {}),
      selection: {
        start: displayOffset(lines, from),
        end: displayOffset(lines, to),
      },
      marks: markOrder.filter((mark) => editor.isActive(tiptapMarks[mark])),
      // The first selected textblock's; Select All's selection starts outside every textblock.
      kind: [...kindsIn(editor)][0] ?? 'paragraph',
      undo: editor.can().undo(),
      redo: editor.can().redo(),
    };
    // oxlint-disable-next-line unicorn/require-post-message-target-origin -- The native bridge, not a window.
    ReactNativeWebView?.postMessage(JSON.stringify(update));
  };
  const editor = new Editor({
    element,
    extensions: [
      // The Draft's Attachments, so one edit and one Undo step can change them with the body.
      Document.extend({
        addAttributes: () => ({
          attachments: { default: [], rendered: false },
        }),
      }),
      // A pasted heading or code inside a quote or list item keeps its text as that line.
      Paragraph.extend({
        parseHTML: () => [
          { tag: 'p' },
          ...['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'pre'].flatMap((tag) =>
            ['blockquote/', 'listItem/'].map((context) => ({
              tag,
              context,
              priority: 60,
            })),
          ),
        ],
      }),
      Text,
      Heading.configure({ levels: [1, 2, 3] }),
      BulletList,
      OrderedList.extend({
        addAttributes() {
          // Numbered items count from one; a pasted list's start is not kept.
          return { start: { default: 1, parseHTML: () => 1 } };
        },
      }),
      ListItem.extend({
        content: 'paragraph+',
        addKeyboardShortcuts() {
          return { Enter: () => this.editor.commands.splitListItem(this.name) };
        },
      }),
      ListKeymap,
      Blockquote.extend({ content: 'paragraph+' }),
      CodeLine,
      InlineImage,
      Bold,
      Italic,
      Underline,
      Strike,
      // The Semantic Message Document admits inline code with other marks.
      Code.extend({ excludes: '' }),
      Link,
      Format,
      Layout,
      UndoRedo.configure({ newGroupDelay: Number.MAX_SAFE_INTEGER }),
      DraftBehavior,
    ],
    enableInputRules: false,
    enablePasteRules: false,
    content: toEditor(draftEditor.document, draftEditor.attachments),
    editorProps: {
      attributes: {
        'aria-label': draftEditor.label,
        'aria-multiline': 'true',
        role: 'textbox',
      },
    },
    onTransaction: ({ editor: current, transaction }) => {
      post(current, transaction);
    },
  });
  // Replaces the whole body, for the revision it was computed from, as one undoable edit.
  const replace = ({
    document: body,
    selection,
    revision: base,
  }: Extract<Command, { type: 'replace' }>) => {
    if (base !== revision) {
      return;
    }
    const { state, view } = editor;
    const tr = state.tr.replaceWith(
      0,
      state.doc.content.size,
      ProseMirrorNode.fromJSON(state.schema, toEditor(body)).content,
    );
    const lines = linesOfDocument(tr.doc);
    view.dispatch(
      tr.setSelection(
        TextSelection.create(
          tr.doc,
          editorPosition(lines, selection.start),
          editorPosition(lines, selection.end),
        ),
      ),
    );
  };
  // Removes every use of asset `id`: its Inline Images, from the last, and its Attachment.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- ProseMirror's transaction is mutable by design.
  const remove = (tr: Transaction, id: string) => {
    const positions: number[] = [];
    tr.doc.descendants((node, position) => {
      if (node.type.name === 'inlineImage' && node.attrs.id === id) {
        positions.push(position);
      }
    });
    for (const position of positions.toReversed()) {
      tr.delete(position, position + 1);
    }
    const attachments = attachmentsOf(tr);
    if (attachments.includes(id)) {
      tr.setDocAttribute(
        'attachments',
        attachments.filter((each) => each !== id),
      );
    }
    return positions.length > 0;
  };
  // An Inline Image becomes an Attachment; an image Attachment goes inline at the selection.
  const convert = (id: string) => {
    const { tr } = editor.state;
    const image = assets.get(id);
    if (image === undefined) {
      return;
    }
    if (attachmentsOf(tr).includes(id)) {
      if (!image.type.startsWith('image/')) {
        return;
      }
      remove(tr, id);
      deleteSelected(tr);
      tr.replaceSelectionWith(editor.schema.node('inlineImage', { id }), false);
    } else if (remove(tr, id)) {
      tr.setDocAttribute('attachments', [...attachmentsOf(tr), id]);
    }
    editor.view.dispatch(tr);
  };
  // Every use of an Inline Image shows at `width`, or at its original size, as one edit.
  const resize = ({ id, width }: Extract<Command, { type: 'resize' }>) => {
    const { tr } = editor.state;
    tr.doc.descendants((node, position) => {
      if (
        node.type.name === 'inlineImage' &&
        node.attrs.id === id &&
        node.attrs.width !== width
      ) {
        tr.setNodeAttribute(position, 'width', width);
      }
    });
    editor.view.dispatch(tr);
  };
  // Images go inline at the selection and the rest become Attachments, as one edit.
  const add = ({ images, attachments }: Extract<Command, { type: 'add' }>) => {
    learn([...images, ...attachments]);
    const { tr } = editor.state;
    if (images.length > 0) {
      deleteSelected(tr);
      tr.replaceSelection(
        new Slice(
          Fragment.from(
            images.map(({ id }) => editor.schema.node('inlineImage', { id })),
          ),
          0,
          0,
        ),
      );
    }
    if (attachments.length > 0) {
      tr.setDocAttribute('attachments', [
        ...attachmentsOf(tr),
        ...attachments.map(({ id }) => id),
      ]);
    }
    editor.view.dispatch(tr);
  };
  const showPreviews = (next: Readonly<Record<string, string | null>>) => {
    for (const [id, preview] of Object.entries(next)) {
      if (preview === null) {
        previews.delete(id);
      } else {
        previews.set(id, preview);
      }
    }
    for (const image of element.querySelectorAll('img')) {
      show(image);
    }
  };
  // fallow-ignore-next-line complexity -- One dispatcher maps each host command to its page edit.
  globalThis.draftCommand = (command) => {
    if (
      !editor.isEditable &&
      command.type !== 'editable' &&
      command.type !== 'previews'
    ) {
      return;
    }
    if (command.type === 'add') {
      add(command);
    } else if (command.type === 'remove') {
      const { tr } = editor.state;
      remove(tr, command.id);
      editor.view.dispatch(tr);
    } else if (command.type === 'convert') {
      convert(command.id);
    } else if (command.type === 'resize') {
      resize(command);
    } else if (command.type === 'previews') {
      showPreviews(command.previews);
    } else if (command.type === 'editable') {
      editor.setEditable(command.editable);
      if (!command.editable) {
        editor.commands.blur();
        post(editor, editor.state.tr, true);
      }
    } else if (command.type === 'mark') {
      editor.commands.toggleMark(tiptapMarks[command.mark]);
    } else if (command.type === 'block') {
      setBlockKind(editor, command.kind);
    } else if (command.type === 'undo') {
      editor.commands.undo();
    } else if (command.type === 'redo') {
      editor.commands.redo();
    } else if (command.type === 'blur') {
      editor.commands.blur();
    } else if (command.type === 'focus') {
      editor.commands.focus();
    } else {
      replace(command);
    }
  };
  // The host offers its controls once the page reports, so no command arrives before this.
  post(editor, editor.state.tr);
}
