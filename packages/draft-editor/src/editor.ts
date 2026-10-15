// The page's script: Tiptap over the Semantic Message Document's blocks, marks and Inline Images,
// and the Draft's Attachments, posting each edit and selection change to the host. The host
// injects `draftEditor` before this script runs and sends commands through `draftCommand`.
import type {
  Asset,
  BlockKind,
  SemanticDocument,
} from '@private-email/mail-core/semantic-document';
import type { ChainedCommands, Editor as TiptapEditor } from '@tiptap/core';
import type { EditorState, Transaction } from '@tiptap/pm/state';

import { Editor, Extension, Node } from '@tiptap/core';
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
import { Plugin, TextSelection } from '@tiptap/pm/state';

import type { Command, Update } from './messages.ts';

import {
  displayOffset,
  editorPosition,
  fromEditor,
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
// verified the bytes. Only an image this page shows parses back from a paste, as when it is cut
// and pasted to move it; other pasted images are dropped.
const InlineImage = Node.create({
  name: 'inlineImage',
  group: 'inline',
  inline: true,
  atom: true,
  draggable: true,
  addAttributes: () => ({ id: { default: '', rendered: false } }),
  parseHTML: () => [
    {
      tag: 'img[data-draft-asset]',
      getAttrs: (element) => {
        const id = element.dataset.draftAsset ?? '';
        return assets.has(id) ? { id } : false;
      },
    },
  ],
  renderHTML: ({ node }) => {
    const id = String(node.attrs.id);
    return ['img', { 'data-draft-asset': id, alt: assets.get(id)?.name }];
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
  renderHTML: () => ['pre', ['code', 0]],
});

// Sets every selected block to `kind`, from a paragraph: no block nests in another.
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
  const cleared = chain.clearNodes();
  return kindCommands[kind]?.(cleared) ?? cleared;
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

// Return in an empty list item or quote line continues it, as in the current composer; Tiptap's
// own Return would lift it out of the list or quote.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Tiptap's editor is a class; this dispatches through its view.
const continueEmpty = ({ state, view }: TiptapEditor) => {
  const { $from, empty } = state.selection;
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
  const tr = state.tr.insert(
    at,
    item ? container.type.create(null, paragraph) : paragraph,
  );
  view.dispatch(
    tr.setSelection(TextSelection.create(tr.doc, at + (item ? 2 : 1))),
  );
  return true;
};

// Undo steps a word of typing at a time; every other edit is a step of its own. A Markdown
// shortcut first stores its literal marker, so one Undo restores it. Text never keeps an Inline
// Image's character, a code line never keeps a line break, and a list item holds one paragraph.
const DraftBehavior = Extension.create<unknown, { typing: boolean }>({
  name: 'draftBehavior',
  // Ahead of the list item's own Return.
  priority: 1000,
  addKeyboardShortcuts() {
    return { Enter: ({ editor }) => continueEmpty(editor) };
  },
  addProseMirrorPlugins() {
    const { editor } = this;
    return [
      new Plugin({
        props: {
          // A pasted image is read from the pasteboard by native code, where it can; the page
          // never reads the data, and a dropped file is refused.
          handlePaste: (_view, event) => {
            if (!carriesFiles(event.clipboardData)) {
              return false;
            }
            event.preventDefault();
            globalThis.ReactNativeWebView?.postMessage(
              JSON.stringify({ type: 'paste' }),
            );
            return true;
          },
          // oxlint-disable-next-line max-params -- ProseMirror's handleDrop signature.
          handleDrop: (_view, event, _slice, moved) => {
            if (moved || !carriesFiles(event.dataTransfer)) {
              return false;
            }
            event.preventDefault();
            return true;
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
            view.dispatch(word ? deflt().setMeta(typing, true) : deflt());
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
  dispatchTransaction({ transaction, next }) {
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
      kind: kindAt(editor.state.selection.$from),
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
      tr.replaceSelectionWith(editor.schema.node('inlineImage', { id }), false);
    } else if (remove(tr, id)) {
      tr.setDocAttribute('attachments', [...attachmentsOf(tr), id]);
    }
    editor.view.dispatch(tr);
  };
  // Images go inline at the selection and the rest become Attachments, as one edit.
  const add = ({ images, attachments }: Extract<Command, { type: 'add' }>) => {
    learn([...images, ...attachments]);
    const { tr } = editor.state;
    if (images.length > 0) {
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
  const showPreviews = (next: Readonly<Record<string, string>>) => {
    for (const [id, preview] of Object.entries(next)) {
      previews.set(id, preview);
    }
    for (const image of element.querySelectorAll('img')) {
      show(image);
    }
  };
  // fallow-ignore-next-line complexity -- One dispatcher maps each host command to its page edit.
  globalThis.draftCommand = (command) => {
    if (command.type === 'add') {
      add(command);
    } else if (command.type === 'remove') {
      const { tr } = editor.state;
      remove(tr, command.id);
      editor.view.dispatch(tr);
    } else if (command.type === 'convert') {
      convert(command.id);
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
      // As in the current composer: when every selected block has the kind, they become paragraphs.
      const all = [...kindsIn(editor)].every((kind) => kind === command.kind);
      setKind(editor.chain(), all ? 'paragraph' : command.kind).run();
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
