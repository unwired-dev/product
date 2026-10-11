import { ok } from 'node:assert/strict';

// @vitest-environment happy-dom
import type {
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

import type { Command, Update } from '../src/messages.ts';

import { pageHtml } from '../build.cjs';
import { supported } from '../src/conversion.ts';
import { decodeUpdate } from '../src/messages.ts';

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
  command: (command: Command) => void;
  // Each character arrives as text input does in WebKit.
  type: (text: string) => void;
}>;

// Loads a fresh page with `body`, as the host does.
async function open(body: SemanticDocument): Promise<Page> {
  vi.resetModules();
  const posted: Update[] = [];
  globalThis.ReactNativeWebView = {
    postMessage: (message) => {
      const update = decodeUpdate(message);
      ok(update, `Expected a valid page message: ${message}`);
      posted.push(update);
    },
  };
  globalThis.draftEditor = { document: body, label: 'Message body' };
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

// The body the page last posted.
const bodyOf = ({ posted }: Page) =>
  posted.findLast(({ document: body }) => body !== undefined)?.document;
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
      `content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'"`,
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
      editor.commands.keyboardShortcut('Enter');
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
    editor.commands.keyboardShortcut('Backspace');
    expect(bodyOf(page)?.slice(0, 2)).toStrictEqual([
      { kind: 'bulleted', spans: [{ text: 'a' }] },
      paragraph('next'),
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

  it('opens only bodies it can show without loss', () => {
    expect.hasAssertions();
    expect(supported(everyCombination)).toBe(true);
    expect(
      supported([
        {
          kind: 'paragraph',
          spans: [
            {
              text: '￼',
              image: {
                id: 'abcdefgh',
                name: 'a.png',
                type: 'image/png',
                state: 'importing',
              },
            },
          ],
        },
      ]),
    ).toBe(false);
  });
});
