import { ok } from 'node:assert/strict';

// @vitest-environment happy-dom
import type {
  Asset,
  Block,
  BlockKind,
  Mark,
  SemanticDocument,
} from '@private-email/mail-core/semantic-document';
import type { Editor } from '@tiptap/core';

import {
  displayOf,
  replaceSelection,
  selectedText,
} from '@private-email/mail-core/semantic-document';
import { Slice } from '@tiptap/pm/model';

import type { Command, Update } from '../src/messages.ts';

import { pageHtml } from '../build.cjs';
import { decodeMessage } from '../src/messages.ts';

const kinds: readonly BlockKind[] = [
  'paragraph',
  'heading1',
  'heading2',
  'heading3',
  'bulleted',
  'numbered',
  'quote',
  'code',
];
const markSets: ReadonlyArray<readonly [Mark, ...Mark[]]> = [
  ['bold'],
  ['italic', 'underline'],
  ['strikethrough'],
  ['bold', 'code'],
  ['bold', 'italic', 'underline', 'strikethrough', 'code'],
];

// Every ordered pair of block kinds, empty and with mixed formatting and Unicode text.
const everyCombination: SemanticDocument = [
  { kind: 'paragraph', spans: [] },
  ...kinds.flatMap((first, i) =>
    kinds.flatMap((second, j): Block[] => [
      { kind: first, spans: [] },
      {
        kind: second,
        spans: [
          { text: `Příliš ${i}${j} ` },
          { text: 'žluťoučký 🐎', marks: markSets[(i + j) % markSets.length] },
          { text: ' kůň' },
        ],
      },
    ]),
  ),
  { kind: 'paragraph', spans: [] },
];

const photo: Asset = {
  id: 'photo0001',
  name: 'Photo.png',
  type: 'image/png',
  state: 'complete',
  size: 4,
  digest: 'a'.repeat(64),
};
const plan: Asset = {
  id: 'plan00001',
  name: 'Plan.pdf',
  type: 'application/pdf',
  state: 'importing',
};

const paragraph = (text: string): Block => ({
  kind: 'paragraph',
  spans: text === '' ? [] : [{ text }],
});
const paragraphs = (first: string, ...rest: string[]): SemanticDocument => [
  paragraph(first),
  ...rest.map(paragraph),
];

type Page = Readonly<{
  editor: Editor;
  posted: Update[];
  // Pastes the page asked the host to read from the pasteboard.
  pastes: () => number;
  command: (command: Command) => void;
  // Each character arrives as text input does in WebKit.
  type: (text: string) => void;
}>;

// Loads a fresh page with `body` and `attachments`, as the host does.
async function open(
  body: SemanticDocument,
  attachments: readonly Asset[] = [],
): Promise<Page> {
  vi.resetModules();
  const posted: Update[] = [];
  let pastes = 0;
  globalThis.ReactNativeWebView = {
    postMessage: (message) => {
      const decoded = decodeMessage(message);
      ok(decoded, `Expected a valid page message: ${message}`);
      if (decoded.type === 'paste') {
        pastes += 1;
      } else {
        posted.push(decoded);
      }
    },
  };
  globalThis.draftEditor = {
    document: body,
    attachments,
    label: 'Message body',
  };
  document.body.innerHTML = '<div id="editor"></div>';
  await import('../src/editor.ts');
  const view = document.querySelector<HTMLElement & { editor: Editor }>(
    '[role="textbox"]',
  );
  ok(view, 'Expected the editor');
  const { editor } = view;
  onTestFinished(() => {
    editor.destroy();
    globalThis.draftCommand = undefined;
    globalThis.draftEditor = undefined;
    globalThis.ReactNativeWebView = undefined;
  });
  const { draftCommand } = globalThis;
  ok(draftCommand, 'Expected the command bridge');
  return {
    editor,
    posted,
    pastes: () => pastes,
    command: draftCommand,
    type: (text) => {
      for (const character of text) {
        const { from, to } = editor.state.selection;
        editor.view.someProp('handleTextInput', (handle) =>
          handle(editor.view, from, to, character, () =>
            editor.state.tr.insertText(character, from, to),
          ),
        );
      }
    },
  };
}

// Exercises the page's key handlers; Tiptap's keyboardShortcut command would keep only the
// document steps of its handler, not the caret it places.
const press = ({ editor }: Page, key: string) =>
  editor.view.someProp('handleKeyDown', (handle) =>
    handle(editor.view, new KeyboardEvent('keydown', { key })),
  );

// The body and Attachments the page last posted.
const bodyOf = ({ posted }: Page) =>
  posted.findLast(({ document: body }) => body !== undefined)?.document;
const attachmentsOf = ({ posted }: Page) =>
  posted.findLast(({ attachments }) => attachments !== undefined)?.attachments;
const kindsOf = (page: Page) => bodyOf(page)?.map(({ kind }) => kind);

// Every textblock's editor range and text, in reading order.
const textblocks = ({ state }: Editor) => {
  const blocks: Array<Readonly<{ from: number; to: number; text: string }>> =
    [];
  state.doc.descendants((node, position) => {
    if (node.isTextblock) {
      const from = position + 1;
      blocks.push({
        from,
        to: from + node.textContent.length,
        text: node.textContent,
      });
    }
    return !node.isTextblock;
  });
  return blocks;
};

// The item at `index`, which the test expects to exist.
const nth = <T>(items: readonly T[], index: number) => {
  const item = items.at(index);
  ok(item !== undefined, `Expected an item at ${index}`);
  return item;
};

// The display selection the page reports for an editor range.
const selectionOf = (page: Page, from: number, to: number) => {
  page.editor.commands.setTextSelection({ from, to });
  const reported = page.posted.at(-1)?.selection;
  ok(reported, 'Expected a reported selection');
  return reported;
};

describe('the Tiptap evaluation page', () => {
  it('refuses every resource it does not carry inline', () => {
    expect.hasAssertions();
    const page = pageHtml();
    expect(page).toContain(
      `content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:"`,
    );
    expect(page).not.toMatch(
      /<(?:script|link|img|iframe)\b[^>]*\b(?:src|href)=/iu,
    );
    expect(page.match(/<\/script/giu)).toHaveLength(1);
  });

  it('round-trips every supported block combination, mark and selection offset', async () => {
    expect.hasAssertions();
    const page = await open(everyCombination);
    // Opening changes nothing; the first edit posts the whole body unchanged around it.
    page.editor.chain().focus('end').run();
    page.type('!');
    const edited = bodyOf(page);
    expect(edited).toStrictEqual([
      ...everyCombination.slice(0, -1),
      paragraph('!'),
    ]);
    ok(edited);

    // Display offsets match the current composer's for every textblock, including list markers
    // and numbering, code lines and empty blocks.
    const { text } = displayOf(edited);
    const blocks = textblocks(page.editor);
    const shown = blocks.map(({ from, to }) => {
      const { start, end } = selectionOf(page, from, to);
      return text.slice(start, end);
    });
    expect(shown).toStrictEqual(blocks.map((block) => block.text));
    expect(blocks).toHaveLength(edited.length);
    // A selection across blocks reads the same text as the current composer's.
    const across = selectionOf(page, nth(blocks, 2).from, nth(blocks, 40).to);
    expect(selectedText(edited, across)).toBe(
      blocks
        .slice(2, 41)
        .map((block) => block.text)
        .join('\n'),
    );
  });

  it('formats the selection and the next typed text', async () => {
    expect.hasAssertions();
    const page = await open(paragraphs('one two', 'three'));
    const { editor, command } = page;
    // On load the page reports that it is ready, without a body change.
    expect(page.posted).toStrictEqual([
      {
        type: 'update',
        revision: 0,
        selection: { start: 0, end: 0 },
        marks: [],
        kind: 'paragraph',
        undo: false,
        redo: false,
      },
    ]);
    editor.commands.setTextSelection({ from: 1, to: 4 });
    command({ type: 'mark', mark: 'bold' });
    command({ type: 'mark', mark: 'code' });
    expect(page.posted.at(-1)?.marks).toStrictEqual(['bold', 'code']);
    // A caret toggle applies to the text typed there; moving the caret ends it.
    editor.commands.setTextSelection(8);
    command({ type: 'mark', mark: 'italic' });
    page.type('!');
    editor.commands.setTextSelection(16);
    page.type('?');
    expect(bodyOf(page)).toStrictEqual([
      {
        kind: 'paragraph',
        spans: [
          { text: 'one', marks: ['bold', 'code'] },
          { text: ' two' },
          { text: '!', marks: ['italic'] },
        ],
      },
      paragraph('three?'),
    ]);
  });

  it('sets every selected block kind, and paragraphs when they all have it', async () => {
    expect.hasAssertions();
    const page = await open(paragraphs('one', 'two', 'three'));
    page.editor.commands.setTextSelection({ from: 2, to: 7 });
    const steps = (
      ['numbered', 'code', 'quote', 'heading2', 'heading2'] as const
    ).map((kind) => {
      page.command({ type: 'block', kind });
      return [page.posted.at(-1)?.kind, kindsOf(page)];
    });
    expect(steps).toStrictEqual([
      ['numbered', ['numbered', 'numbered', 'paragraph']],
      ['code', ['code', 'code', 'paragraph']],
      ['quote', ['quote', 'quote', 'paragraph']],
      ['heading2', ['heading2', 'heading2', 'paragraph']],
      ['paragraph', ['paragraph', 'paragraph', 'paragraph']],
    ]);
  });

  it.each([
    ['# ', 'heading1'],
    ['## ', 'heading2'],
    ['### ', 'heading3'],
    ['- ', 'bulleted'],
    ['* ', 'bulleted'],
    ['1. ', 'numbered'],
    ['> ', 'quote'],
    ['```', 'code'],
  ] as const)(
    'applies %j at the start of a paragraph, and one Undo restores the marker',
    async (marker, kind) => {
      expect.hasAssertions();
      const page = await open(paragraphs(''));
      page.type(`${marker}Item`);
      expect(bodyOf(page)).toStrictEqual([{ kind, spans: [{ text: 'Item' }] }]);
      page.command({ type: 'undo' });
      page.command({ type: 'undo' });
      expect(bodyOf(page)).toStrictEqual(paragraphs(marker));
      page.command({ type: 'redo' });
      expect(bodyOf(page)).toStrictEqual([{ kind, spans: [] }]);
    },
  );

  it('steps Undo and Redo a word at a time, once per command before any redraw', async () => {
    expect.hasAssertions();
    const page = await open(paragraphs(''));
    page.type('Hello brave world');
    expect(page.posted.at(-1)).toMatchObject({ undo: true, redo: false });
    page.command({ type: 'undo' });
    expect(bodyOf(page)).toStrictEqual(paragraphs('Hello brave '));
    // A space is a step of its own, as in the current composer.
    page.command({ type: 'undo' });
    page.command({ type: 'undo' });
    page.command({ type: 'undo' });
    expect(bodyOf(page)).toStrictEqual(paragraphs('Hello'));
    page.command({ type: 'redo' });
    page.command({ type: 'redo' });
    expect(bodyOf(page)).toStrictEqual(paragraphs('Hello brave'));
    expect(page.posted.at(-1)).toMatchObject({ undo: true, redo: true });
  });

  it('continues lists, quotes and code with Return, and Backspace turns an item into a paragraph', async () => {
    expect.hasAssertions();
    const page = await open([
      { kind: 'bulleted', spans: [{ text: 'a' }] },
      { kind: 'quote', spans: [{ text: 'b' }] },
      { kind: 'code', spans: [{ text: 'c' }] },
    ]);
    const { editor } = page;
    for (const block of [0, 1, 2]) {
      editor.commands.setTextSelection(nth(textblocks(editor), block * 2).to);
      press(page, 'Enter');
      page.type('next');
    }
    expect(bodyOf(page)).toStrictEqual([
      { kind: 'bulleted', spans: [{ text: 'a' }] },
      { kind: 'bulleted', spans: [{ text: 'next' }] },
      { kind: 'quote', spans: [{ text: 'b' }] },
      { kind: 'quote', spans: [{ text: 'next' }] },
      { kind: 'code', spans: [{ text: 'c' }] },
      { kind: 'code', spans: [{ text: 'next' }] },
    ]);
    // Deleting into the second item's marker makes it a paragraph between the lists.
    editor.commands.setTextSelection(nth(textblocks(editor), 1).from);
    press(page, 'Backspace');
    expect(bodyOf(page)?.slice(0, 2)).toStrictEqual([
      { kind: 'bulleted', spans: [{ text: 'a' }] },
      paragraph('next'),
    ]);
  });

  it('continues an empty list item or quote line with Return, as the current composer does', async () => {
    expect.hasAssertions();
    const page = await open([
      { kind: 'bulleted', spans: [{ text: 'a' }] },
      { kind: 'numbered', spans: [{ text: 'n' }] },
      { kind: 'quote', spans: [{ text: 'b' }] },
    ]);
    const { editor } = page;
    for (const line of ['a', 'n', 'b']) {
      const block = textblocks(editor).find(({ text }) => text === line);
      ok(block, `Expected the line ${line}`);
      editor.commands.setTextSelection(block.to);
      press(page, 'Enter');
      const first = bodyOf(page);
      press(page, 'Enter');
      const continued = bodyOf(page);
      page.command({ type: 'undo' });
      expect(bodyOf(page)).toStrictEqual(first);
      page.command({ type: 'redo' });
      expect(bodyOf(page)).toStrictEqual(continued);
      page.type('c');
    }
    expect(bodyOf(page)).toStrictEqual([
      { kind: 'bulleted', spans: [{ text: 'a' }] },
      { kind: 'bulleted', spans: [] },
      { kind: 'bulleted', spans: [{ text: 'c' }] },
      { kind: 'numbered', spans: [{ text: 'n' }] },
      { kind: 'numbered', spans: [] },
      { kind: 'numbered', spans: [{ text: 'c' }] },
      { kind: 'quote', spans: [{ text: 'b' }] },
      { kind: 'quote', spans: [] },
      { kind: 'quote', spans: [{ text: 'c' }] },
    ]);
  });

  it('pastes supported meaning only and never stores unsupported content', async () => {
    expect.hasAssertions();
    const page = await open(paragraphs(''));
    page.editor.view.pasteHTML(
      [
        '<h1>Title</h1>',
        '<h5>Small heading</h5>',
        '<p><b>bold</b> <i>it</i> <u>u</u> <s>s</s> <code>c</code> <a href="https://example.com">link text</a></p>',
        '<p>Image <img src="https://example.com/a.png" alt="a">here￼</p>',
        '<ol start="3"><li>three<ul><li>nested</li></ul></li></ol>',
        '<blockquote><h2>Quoted heading</h2><p>quote</p></blockquote>',
        '<pre><code>line 1\nline 2</code></pre>',
        '<table><tr><td>cell</td></tr></table>',
        '<p style="color: red; font-size: 40px">styled</p>',
      ].join(''),
    );
    expect(bodyOf(page)).toStrictEqual([
      { kind: 'heading1', spans: [{ text: 'Title' }] },
      paragraph('Small heading'),
      {
        kind: 'paragraph',
        spans: [
          { text: 'bold', marks: ['bold'] },
          { text: ' ' },
          { text: 'it', marks: ['italic'] },
          { text: ' ' },
          { text: 'u', marks: ['underline'] },
          { text: ' ' },
          { text: 's', marks: ['strikethrough'] },
          { text: ' ' },
          { text: 'c', marks: ['code'] },
          { text: ' link text' },
        ],
      },
      paragraph('Image here'),
      { kind: 'numbered', spans: [{ text: 'three' }] },
      { kind: 'bulleted', spans: [{ text: 'nested' }] },
      { kind: 'quote', spans: [{ text: 'Quoted heading' }] },
      { kind: 'quote', spans: [{ text: 'quote' }] },
      { kind: 'code', spans: [{ text: 'line 1' }] },
      { kind: 'code', spans: [{ text: 'line 2' }] },
      paragraph('cell'),
      paragraph('styled'),
    ]);
    // Numbering shown in the page follows the stored document: it counts from one.
    expect(page.editor.getJSON().content?.[4]?.attrs?.start).toBe(1);
    // Plain text keeps its lines as paragraphs.
    page.editor.view.pasteText('first\nsecond');
    expect(bodyOf(page)?.slice(-2)).toStrictEqual(
      paragraphs('styledfirst', 'second'),
    );
  });

  it('replaces the body revision it was computed from as one undoable edit', async () => {
    expect.hasAssertions();
    const opened: SemanticDocument = [
      { kind: 'heading1', spans: [{ text: 'Plan' }] },
      {
        kind: 'bulleted',
        spans: [{ text: 'old ', marks: ['bold'] }, { text: 'text' }],
      },
    ];
    const page = await open(opened);
    const at = selectionOf(page, 9, 13);
    const { revision } = nth(page.posted, -1);
    expect(selectedText(opened, at)).toBe('old ');
    const { document: result, selection } = replaceSelection(
      opened,
      at,
      'new ',
    );
    ok(selection);
    // A replacement for another body revision is refused.
    page.command({
      type: 'replace',
      revision: revision + 1,
      document: result,
      selection,
    });
    const refused = bodyOf(page);
    page.command({ type: 'replace', revision, document: result, selection });
    const applied = [bodyOf(page), page.posted.at(-1)?.selection];
    page.command({ type: 'undo' });
    const undone = bodyOf(page);
    page.command({ type: 'redo' });
    expect({ refused, applied, undone, redone: bodyOf(page) }).toStrictEqual({
      refused: undefined,
      applied: [result, selection],
      undone: opened,
      redone: result,
    });
  });

  it('keeps Inline Images through typing, deletion, moving, Undo and Redo', async () => {
    expect.hasAssertions();
    const opened: SemanticDocument = [
      {
        kind: 'paragraph',
        spans: [
          { text: 'Hello ' },
          { text: '￼', image: photo, marks: ['bold'] },
          { text: ' world' },
        ],
      },
      {
        kind: 'bulleted',
        spans: [{ text: 'item ' }, { text: '￼', image: photo }],
      },
    ];
    const page = await open(opened, [plan]);
    // The image is one display character, as in the current composer.
    const offsets = [selectionOf(page, 8, 8), selectionOf(page, 23, 23)];
    page.editor.commands.setTextSelection(1);
    page.type('A');
    const typed = [bodyOf(page), attachmentsOf(page)];
    // Deleting the image, as WebKit's Backspace does, and Undo restores the same asset in place.
    page.editor.commands.deleteRange({ from: 8, to: 9 });
    const deleted = bodyOf(page)?.[0];
    page.command({ type: 'undo' });
    const undone = bodyOf(page);
    page.command({ type: 'redo' });
    page.command({ type: 'undo' });
    // Cut and pasted back, the image moves with its asset; an image the page was never given is
    // dropped, as is any other pasted image.
    page.editor.commands.setTextSelection(15);
    page.editor.view.pasteHTML(
      '<p><img data-draft-asset="photo0001" alt="x"><img data-draft-asset="unknown01"><img src="data:image/png;base64,AAAA"></p>',
    );
    const typedBody: SemanticDocument = [
      {
        kind: 'paragraph',
        spans: [
          { text: 'AHello ' },
          { text: '￼', image: photo, marks: ['bold'] },
          { text: ' world' },
        ],
      },
      {
        kind: 'bulleted',
        spans: [{ text: 'item ' }, { text: '￼', image: photo }],
      },
    ];
    expect({
      offsets,
      typed,
      deleted,
      undone,
      pasted: bodyOf(page)?.[0]?.spans,
    }).toStrictEqual({
      offsets: [
        { start: 7, end: 7 },
        { start: 21, end: 21 },
      ],
      typed: [typedBody, [plan]],
      deleted: paragraph('AHello  world'),
      undone: typedBody,
      pasted: [
        { text: 'AHello ' },
        { text: '￼', image: photo, marks: ['bold'] },
        { text: ' world' },
        { text: '￼', image: photo },
      ],
    });
  });

  it('adds, removes and converts Inline Images and Attachments as one undoable edit each', async () => {
    expect.hasAssertions();
    const page = await open(paragraphs('ab'));
    const state = () => [bodyOf(page), attachmentsOf(page)];
    const steps: Array<ReturnType<typeof state>> = [];
    const step = (command: Command) => {
      page.command(command);
      steps.push(state());
    };
    page.editor.commands.setTextSelection(2);
    step({ type: 'add', images: [photo], attachments: [plan] });
    step({ type: 'undo' });
    step({ type: 'redo' });
    // The Inline Image becomes an Attachment, keeping its asset; Undo puts it back in place.
    step({ type: 'convert', id: photo.id });
    step({ type: 'undo' });
    step({ type: 'redo' });
    // An image Attachment goes inline at the selection; a file that is not an image stays attached.
    page.editor.commands.setTextSelection(1);
    step({ type: 'convert', id: photo.id });
    step({ type: 'convert', id: plan.id });
    step({ type: 'remove', id: plan.id });
    step({ type: 'remove', id: photo.id });
    step({ type: 'undo' });
    step({ type: 'undo' });
    const added = [
      [
        {
          kind: 'paragraph',
          spans: [{ text: 'a' }, { text: '￼', image: photo }, { text: 'b' }],
        },
      ],
      [plan],
    ];
    const attached = [paragraphs('ab'), [plan, photo]];
    const inline = [
      [
        {
          kind: 'paragraph',
          spans: [{ text: '￼', image: photo }, { text: 'ab' }],
        },
      ],
      [plan],
    ];
    const empty = [paragraphs('ab'), []];
    expect(steps).toStrictEqual([
      added,
      empty,
      added,
      attached,
      added,
      attached,
      inline,
      inline,
      [inline[0], []],
      empty,
      [inline[0], []],
      inline,
    ]);
  });

  it('shows only native thumbnails, and never reads pasted or dropped files', async () => {
    expect.hasAssertions();
    const page = await open([
      { kind: 'paragraph', spans: [{ text: '￼', image: photo }] },
    ]);
    const shown = () =>
      document
        .querySelector('img[data-draft-asset="photo0001"]')
        ?.getAttribute('src');
    const before = shown();
    const thumbnail = 'data:image/png;base64,iVBORw0KGgo=';
    page.command({ type: 'previews', previews: { [photo.id]: thumbnail } });
    const after = shown();
    // An image Undo recreates shows the thumbnail too.
    page.command({ type: 'remove', id: photo.id });
    page.command({ type: 'undo' });
    const restored = shown();
    const { view } = page.editor;
    const files = { types: ['Files', 'image/png'] };
    const paste = new ClipboardEvent('paste', { cancelable: true });
    Object.defineProperty(paste, 'clipboardData', { value: files });
    const drop = new DragEvent('drop', { cancelable: true });
    Object.defineProperty(drop, 'dataTransfer', { value: files });
    const move = new DragEvent('drop', { cancelable: true });
    Object.defineProperty(move, 'dataTransfer', { value: files });
    const handled = [
      view.someProp('handlePaste', (handle) =>
        handle(view, paste, Slice.empty),
      ),
      view.someProp('handleDrop', (handle) =>
        handle(view, drop, Slice.empty, false),
      ),
      // Moving content within the page stays ProseMirror's own.
      view.someProp('handleDrop', (handle) =>
        handle(view, move, Slice.empty, true),
      ),
    ];
    expect({
      before,
      after,
      restored,
      handled,
      prevented: [paste, drop, move].map(
        ({ defaultPrevented }) => defaultPrevented,
      ),
      pastes: page.pastes(),
      body: bodyOf(page),
    }).toStrictEqual({
      before: null,
      after: thumbnail,
      restored: thumbnail,
      handled: [true, true, undefined],
      prevented: [true, true, false],
      pastes: 1,
      body: [{ kind: 'paragraph', spans: [{ text: '￼', image: photo }] }],
    });
  });
});
