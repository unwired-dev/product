import { ok } from 'node:assert/strict';

import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
// @vitest-environment happy-dom
import type {
  Asset,
  Block,
  BlockKind,
  Mark,
  SemanticDocument,
  Table,
  TableDocument,
} from '@private-email/mail-core/semantic-document';
import type { Editor } from '@tiptap/core';
import type { Schema } from '@tiptap/pm/model';

import {
  createDrafts,
  draftOf,
  draftsOf,
} from '@private-email/mail-core/drafts';
import {
  displayOf,
  replaceSelection,
  selectedText,
  textOf,
} from '@private-email/mail-core/semantic-document';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import { palette } from '@private-email/mail-core/theme';
import { Slice } from '@tiptap/pm/model';
import { NodeSelection, TextSelection } from '@tiptap/pm/state';
import { CellSelection, TableMap } from '@tiptap/pm/tables';
import * as Arr from 'effect/Array';
import * as Fn from 'effect/Function';

import type { Command, Update } from '../src/messages.ts';

import { pageHtml } from '../build.cjs';
import { fillsGrid } from '../src/conversion.ts';
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

// A Draft with every alignment, every list level, and text with colors, a background and fonts.
const formatted: SemanticDocument = [
  {
    kind: 'heading1',
    align: 'center',
    spans: [
      {
        text: 'Agenda',
        font: '"Helvetica Neue", Arial, sans-serif',
        size: 24,
      },
    ],
  },
  {
    kind: 'paragraph',
    align: 'right',
    spans: [
      { text: 'Red ', color: '#c00000' },
      { text: 'on yellow', marks: ['bold'], background: '#ffff00' },
      { text: ' plain' },
    ],
  },
  {
    kind: 'paragraph',
    align: 'justify',
    spans: [
      {
        text: 'Serif',
        link: 'https://example.com',
        color: '#1f3864',
        font: 'serif',
      },
    ],
  },
  { kind: 'numbered', spans: [{ text: 'one' }] },
  { kind: 'numbered', indent: 1, spans: [{ text: 'one.a' }] },
  { kind: 'bulleted', indent: 2, spans: [{ text: 'deep', color: '#941751' }] },
  { kind: 'numbered', indent: 1, spans: [{ text: 'one.b' }] },
  { kind: 'numbered', spans: [{ text: 'two' }] },
  {
    kind: 'quote',
    align: 'center',
    spans: [{ text: 'quoted', color: '#000000' }],
  },
  { kind: 'code', align: 'right', spans: [{ text: 'code' }] },
  { kind: 'paragraph', spans: [] },
];

type Page = Readonly<{
  editor: Editor;
  posted: Update[];
  // Pastes the page asked the host to read from the pasteboard.
  pastes: () => number;
  // Keys the page handed to the host's Slash Command Menu.
  keys: string[];
  command: (command: Command) => void;
  // Each character arrives as text input does in WebKit.
  type: (text: string) => void;
}>;

// Loads a fresh page with `body` and `attachments`, as the host does.
async function open(
  body: TableDocument,
  attachments: readonly Asset[] = [],
): Promise<Page> {
  vi.resetModules();
  const posted: Update[] = [];
  const keys: string[] = [];
  let pastes = 0;
  globalThis.ReactNativeWebView = {
    postMessage: (message) => {
      const decoded = decodeMessage(message);
      ok(decoded, `Expected a valid page message: ${message}`);
      if (decoded.type === 'paste') {
        pastes += 1;
      } else if (decoded.type === 'key') {
        keys.push(decoded.key);
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
    keys,
    command: draftCommand,
    type: (text) => {
      for (const character of text) {
        const { from, to } = editor.state.selection;
        editor.view.someProp('handleTextInput', (handle) =>
          handle(editor.view, from, to, character, () =>
            editor.state.tr.insertText(character),
          ),
        );
      }
    },
  };
}

// Exercises the page's key handlers; Tiptap's keyboardShortcut command would keep only the
// document steps of its handler, not the caret it places.
const press = ({ editor }: Page, key: string, init: KeyboardEventInit = {}) =>
  editor.view.someProp('handleKeyDown', (handle) =>
    handle(editor.view, new KeyboardEvent('keydown', { key, ...init })),
  );
const mod = /Mac|iP(?:hone|[ao]d)/u.test(navigator.platform)
  ? { metaKey: true }
  : { ctrlKey: true };

// The body and Attachments the page last posted.
const bodyOf = ({ posted }: Page) =>
  posted.findLast(({ document: body }) => body !== undefined)?.document;
// The text of the body the page last posted, without its tables.
const textBodyOf = (page: Page) => {
  const body = bodyOf(page);
  return body === undefined ? undefined : textOf(body);
};
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
    const { text } = displayOf(textOf(edited));
    const blocks = textblocks(page.editor);
    const shown = blocks.map(({ from, to }) => {
      const { start, end } = selectionOf(page, from, to);
      return text.slice(start, end);
    });
    expect(shown).toStrictEqual(blocks.map((block) => block.text));
    expect(blocks).toHaveLength(edited.length);
    // A selection across blocks reads the same text as the current composer's.
    const across = selectionOf(page, nth(blocks, 2).from, nth(blocks, 40).to);
    expect(selectedText(textOf(edited), across)).toBe(
      blocks
        .slice(2, 41)
        .map((block) => block.text)
        .join('\n'),
    );
  });

  it('freezes editing and reports the latest document before the host saves or sends', async () => {
    expect.hasAssertions();
    const page = await open(paragraphs('Before'));
    page.editor.commands.setTextSelection(7);
    page.type(' queued');
    page.command({ type: 'editable', editable: false });
    expect(page.editor.isEditable).toBe(false);
    expect(page.posted.at(-1)).toMatchObject({
      frozen: true,
      document: paragraphs('Before queued'),
      attachments: [],
    });
    // A native toolbar callback can already be queued when the host freezes the page.
    page.command({ type: 'undo' });
    expect(bodyOf(page)).toStrictEqual(paragraphs('Before queued'));
    page.command({ type: 'editable', editable: true });
    expect(page.editor.isEditable).toBe(true);
    page.command({ type: 'undo' });
    expect(bodyOf(page)).toStrictEqual(paragraphs('Before '));
  });

  it('keeps real page history bound to its conflict copy through Save and Discard', async () => {
    expect.hasAssertions();
    const mailbox = {
      id: 'connection-alex',
      address: 'alex@example.invalid',
    };
    const registration = {
      getSnapshot: () => ({
        snapshot: {
          kind: 'connected',
          productAccountId: 'synthetic-product-account',
          signInProvider: 'google',
          mailboxes: JSON.stringify([{ ...mailbox, state: 'connected' }]),
        } satisfies RegistrationSnapshot,
        busy: false,
        failed: false,
      }),
      subscribe: () => () => undefined,
    };
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await drafts.load();
    const id = await drafts.create(mailbox);
    const opened = draftOf(drafts.getSnapshot(), id);
    ok(opened, 'Expected the opened Draft');
    const page = await open(textOf(opened.body));
    page.type('Window B');
    page.command({ type: 'editable', editable: false });
    const frozen = page.posted.at(-1);
    ok(frozen?.frozen, 'Expected the frozen page');
    ok(frozen.document, 'Expected the final page body');
    // Another window saves first while this page keeps its document and history.
    await drafts.update({ ...opened, body: paragraphs('Window A') }, opened);
    let target = opened.id;
    const rebind = (copy: string) => {
      target = copy;
    };
    onTestFinished(() => drafts.release(rebind));
    storage.setLocked(true);
    await expect(
      drafts.update({ ...opened, body: frozen.document }, opened, rebind),
    ).resolves.toBe(false);
    ok(target !== opened.id, 'Expected a separate conflict copy');
    const copy = draftOf(drafts.getSnapshot(), target);
    ok(copy, 'Expected the rebound conflict copy');
    page.command({ type: 'editable', editable: true });
    // Undo reaches the typing history made before the conflict, then Redo restores it.
    page.command({ type: 'undo' });
    expect(bodyOf(page)).toStrictEqual(paragraphs('Window '));
    page.command({ type: 'redo' });
    expect(bodyOf(page)).toStrictEqual(paragraphs('Window B'));
    const revision = page.posted.at(-1)?.revision;
    ok(revision, 'Expected the revision after Redo');
    page.command({
      type: 'replace',
      revision,
      document: paragraphs('Window B, later'),
      selection: { start: 15, end: 15 },
    });
    page.command({ type: 'editable', editable: false });
    const body = page.posted.at(-1)?.document;
    ok(body, 'Expected the final body after Redo');
    storage.setLocked(false);
    await drafts.update({ ...copy, body }, copy, rebind);
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    expect(
      Object.fromEntries(
        draftsOf(reopened.getSnapshot()).map((draft) => [draft.id, draft.body]),
      ),
    ).toStrictEqual({
      [opened.id]: paragraphs('Window A'),
      [target]: paragraphs('Window B, later'),
    });
    await drafts.discard(() => target);
    const afterDiscard = createDrafts(storage.native, registration);
    await afterDiscard.load();
    expect(
      draftsOf(afterDiscard.getSnapshot()).map((draft) => [
        draft.id,
        draft.body,
      ]),
    ).toStrictEqual([[opened.id, paragraphs('Window A')]]);
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

  it('reports the first selected block kind after Select All', async () => {
    expect.hasAssertions();
    const page = await open([
      { kind: 'numbered', spans: [{ text: 'one' }] },
      { kind: 'numbered', spans: [{ text: 'two' }] },
    ]);
    // Select All uses an AllSelection starting outside the first list item.
    page.editor.commands.selectAll();
    expect(page.posted.at(-1)?.kind).toBe('numbered');
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

  it('reports where a line starting with a slash is, for the Slash Command Menu', async () => {
    expect.hasAssertions();
    const page = await open(paragraphs('Hello'));
    const { editor } = page;
    editor.commands.setTextSelection(nth(textblocks(editor), 0).to);
    press(page, 'Enter');
    page.type('/he');
    expect(page.posted.at(-1)?.caret).toStrictEqual({
      top: expect.any(Number),
      bottom: expect.any(Number),
    });
    press(page, 'Enter');
    expect(page.posted.at(-1)?.caret).toBeUndefined();
    page.type('a /');
    expect(page.posted.at(-1)?.caret).toBeUndefined();
  });

  it('hands Return, Tab, the arrows and Escape to the host only while its menu shows', async () => {
    expect.hasAssertions();
    const page = await open(paragraphs('/he'));
    const { editor } = page;
    editor.commands.setTextSelection(nth(textblocks(editor), 0).to);
    press(page, 'Escape');
    expect(page.keys).toStrictEqual([]);
    page.command({ type: 'menu', open: true });
    const keys = ['ArrowDown', 'ArrowUp', 'Tab', 'Enter', 'Escape'];
    expect(keys.map((key) => press(page, key))).toStrictEqual(
      keys.map(() => true),
    );
    expect(page.keys).toStrictEqual(keys);
    page.command({ type: 'menu', open: false });
    press(page, 'Enter');
    expect(page.keys).toStrictEqual(keys);
    expect(textBodyOf(page)).toStrictEqual(paragraphs('/he', ''));
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

  it('keeps alignment, list levels, colors and fonts through opening, editing and saving', async () => {
    expect.hasAssertions();
    const page = await open(formatted);
    // Opening changes nothing; the first edit posts the whole body unchanged around it.
    page.editor.chain().focus('end').run();
    page.type('!');
    const edited = bodyOf(page);
    expect(edited).toStrictEqual([...formatted.slice(0, -1), paragraph('!')]);
    ok(edited);
    // Display offsets follow the current composer's nested and per-level numbered markers.
    const { text } = displayOf(textOf(edited));
    const blocks = textblocks(page.editor);
    expect(
      blocks.map(({ from, to }) => {
        const { start, end } = selectionOf(page, from, to);
        return text.slice(start, end);
      }),
    ).toStrictEqual(blocks.map((block) => block.text));
  });

  it('shows alignment, list levels, colors and fonts as the current composer does', async () => {
    expect.hasAssertions();
    const { editor } = await open(formatted);
    const html = editor.view.dom.innerHTML;
    expect(html).toContain('<h1 style="text-align: center;">');
    expect(html).toContain(
      '<pre style="text-align: right;"><code>code</code></pre>',
    );
    expect(html).toContain('<li data-indent="1">');
    expect(html).toContain('<li data-indent="2">');
    // Light shows colors as stored and Dark adapts text colors; text on a background keeps the
    // Light ink in both.
    const styles = [
      ...editor.view.dom.querySelectorAll('[data-draft-format]'),
    ].map((span) => [span.textContent, span.getAttribute('style')]);
    expect(styles).toStrictEqual([
      [
        'Agenda',
        'font-family: "Helvetica Neue", system-ui; font-size: 24px; line-height: 32px;',
      ],
      ['Red ', '--draft-light: #c00000; --draft-dark: #d96666;'],
      [
        'on yellow',
        `--draft-light: ${palette.light.textPrimary}; --draft-dark: ${palette.light.textPrimary}; background-color: #ffff00;`,
      ],
      [
        'Serif',
        '--draft-light: #1f3864; --draft-dark: #7988a2; font-family: ui-serif, system-ui;',
      ],
      ['deep', '--draft-light: #941751; --draft-dark: #bf7497;'],
      [
        'quoted',
        `--draft-light: #000000; --draft-dark: ${palette.dark.textPrimary};`,
      ],
    ]);
  });

  it('keeps formatting through typing, Return, joining, marks and block kinds', async () => {
    expect.hasAssertions();
    const page = await open(formatted);
    const { editor, command } = page;
    const line = (wanted: string) => {
      const block = textblocks(editor).find(({ text }) => text === wanted);
      ok(block, `Expected the line ${wanted}`);
      return block;
    };
    // Typed text takes the format of the text before it, and at a block's start the text after
    // it; at a link's edge it stays unlinked.
    editor.commands.setTextSelection(line('Red on yellow plain').from + 4);
    page.type('x');
    editor.commands.setTextSelection(line('Serif').from);
    page.type('y');
    // Return keeps the alignment on both sides, and a list item's level.
    editor.commands.setTextSelection(line('ySerif').from + 3);
    press(page, 'Enter');
    editor.commands.setTextSelection(line('one.b').to);
    press(page, 'Enter');
    press(page, 'Enter');
    page.type('z');
    // A mark keeps the color it formats.
    editor.commands.setTextSelection({
      from: line('Red xon yellow plain').from,
      to: line('Red xon yellow plain').from + 3,
    });
    command({ type: 'mark', mark: 'italic' });
    expect(bodyOf(page)?.slice(1, 11)).toStrictEqual([
      {
        kind: 'paragraph',
        align: 'right',
        spans: [
          { text: 'Red', marks: ['italic'], color: '#c00000' },
          { text: ' x', color: '#c00000' },
          { text: 'on yellow', marks: ['bold'], background: '#ffff00' },
          { text: ' plain' },
        ],
      },
      {
        kind: 'paragraph',
        align: 'justify',
        spans: [
          { text: 'y', color: '#1f3864', font: 'serif' },
          {
            text: 'Se',
            link: 'https://example.com',
            color: '#1f3864',
            font: 'serif',
          },
        ],
      },
      {
        kind: 'paragraph',
        align: 'justify',
        spans: [
          {
            text: 'rif',
            link: 'https://example.com',
            color: '#1f3864',
            font: 'serif',
          },
        ],
      },
      ...formatted.slice(3, 6),
      { kind: 'numbered', indent: 1, spans: [{ text: 'one.b' }] },
      { kind: 'numbered', indent: 1, spans: [] },
      { kind: 'numbered', indent: 1, spans: [{ text: 'z' }] },
      { kind: 'numbered', spans: [{ text: 'two' }] },
    ]);
    // Joining keeps the first block's alignment.
    editor.commands.setTextSelection(line('rif').from);
    press(page, 'Backspace');
    expect(bodyOf(page)?.[2]).toMatchObject({ align: 'justify' });
    // Block kinds keep alignment, list items keep their level, and a paragraph stops nesting.
    editor.commands.setTextSelection(line('Agenda').from);
    command({ type: 'block', kind: 'heading1' });
    editor.commands.setTextSelection(line('one.a').from);
    command({ type: 'block', kind: 'bulleted' });
    editor.commands.setTextSelection(line('deep').from);
    command({ type: 'block', kind: 'bulleted' });
    const body = bodyOf(page);
    expect(body?.[0]).toStrictEqual({ ...formatted[0], kind: 'paragraph' });
    expect(body?.slice(4, 6)).toStrictEqual([
      { kind: 'bulleted', indent: 1, spans: [{ text: 'one.a' }] },
      { kind: 'paragraph', spans: [{ text: 'deep', color: '#941751' }] },
    ]);
    command({ type: 'undo' });
    expect(bodyOf(page)?.[5]).toStrictEqual(formatted[5]);
  });

  it('keeps alignment and format at block edges and in replacements as the current composer does', async () => {
    expect.hasAssertions();
    const red = { color: '#c00000' };
    const blue = { color: '#1f3864' };
    const page = await open([
      { kind: 'heading1', align: 'right', spans: [{ text: 'Title' }] },
      { kind: 'paragraph', align: 'right', spans: [] },
      { kind: 'paragraph', align: 'center', spans: [{ text: 'Centre' }] },
      { kind: 'paragraph', align: 'right', spans: [] },
      { kind: 'paragraph', align: 'center', spans: [{ text: 'Middle' }] },
      {
        kind: 'paragraph',
        spans: [
          { text: 'ab', ...red },
          { text: 'cd', ...blue },
        ],
      },
      { kind: 'numbered', indent: 2, spans: [{ text: 'deep item' }] },
      { kind: 'paragraph', spans: [{ text: 'plain' }] },
      // A font named "undefined" is a font, not the absence of one.
      {
        kind: 'paragraph',
        spans: [{ text: 'x' }, { text: 'y', font: 'undefined' }],
      },
      paragraph(''),
    ]);
    const { editor } = page;
    const line = (index: number) => nth(textblocks(editor), index);
    // Return at the start of a heading inserts a paragraph above it with the heading's alignment.
    editor.commands.setTextSelection(line(0).from);
    press(page, 'Enter');
    // Backspace and Delete keep the first joined block's alignment, even when it is empty.
    editor.commands.setTextSelection(line(3).from);
    press(page, 'Backspace');
    editor.commands.setTextSelection(line(3).from);
    press(page, 'Delete');
    // Replacing text takes the format before it, and at a block's start the format after it.
    editor.commands.setTextSelection({
      from: line(4).from + 2,
      to: line(4).from + 3,
    });
    page.type('x');
    editor.commands.setTextSelection({
      from: line(4).from,
      to: line(4).from + 3,
    });
    page.type('y');
    // Return at the end of formatted text starts an unformatted line.
    editor.commands.setTextSelection(line(4).to);
    press(page, 'Enter');
    page.type('n');
    // A paste of part of a nested item carries no list level.
    editor.commands.setTextSelection({
      from: line(6).from,
      to: line(6).from + 4,
    });
    const { dom } = editor.view.serializeForClipboard(
      editor.state.selection.content(),
    );
    editor.commands.setTextSelection(line(-1).from);
    editor.view.pasteHTML(dom.innerHTML);
    expect(bodyOf(page)).toStrictEqual([
      { kind: 'paragraph', align: 'right', spans: [] },
      { kind: 'heading1', align: 'right', spans: [{ text: 'Title' }] },
      { kind: 'paragraph', align: 'right', spans: [{ text: 'Centre' }] },
      { kind: 'paragraph', align: 'right', spans: [{ text: 'Middle' }] },
      { kind: 'paragraph', spans: [{ text: 'yd', ...blue }] },
      paragraph('n'),
      { kind: 'numbered', indent: 2, spans: [{ text: 'deep item' }] },
      paragraph('plain'),
      {
        kind: 'paragraph',
        spans: [{ text: 'x' }, { text: 'y', font: 'undefined' }],
      },
      { kind: 'numbered', spans: [{ text: 'deep' }] },
    ]);
  });

  it('keeps the first block layout when a selection is replaced, deleted or split', async () => {
    expect.hasAssertions();
    const red = { color: '#c00000' };
    const blue = { color: '#1f3864' };
    const page = await open([
      { kind: 'heading1', align: 'right', spans: [{ text: 'Title' }] },
      { kind: 'numbered', indent: 2, align: 'right', spans: [{ text: 'two' }] },
      {
        kind: 'numbered',
        indent: 1,
        align: 'center',
        spans: [{ text: 'one' }],
      },
      {
        kind: 'paragraph',
        spans: [
          { text: 'ab', ...red },
          { text: 'cd', ...blue },
          { text: 'ef' },
        ],
      },
      { kind: 'paragraph', align: 'right', spans: [] },
      { kind: 'quote', align: 'center', spans: [{ text: 'Q' }] },
      { kind: 'paragraph', align: 'right', spans: [{ text: 'left' }] },
      { kind: 'paragraph', align: 'center', spans: [{ text: 'right' }] },
    ]);
    const { editor } = page;
    const line = (index: number) => nth(textblocks(editor), index);
    const select = (from: number, to: number) =>
      editor.commands.setTextSelection({ from, to });
    // Return over a selection keeps the first block's alignment and level on both lines.
    select(line(1).from, line(2).from + 1);
    press(page, 'Enter');
    // Return over a heading's first character adds a paragraph above with its alignment.
    select(line(0).from, line(0).from + 1);
    press(page, 'Enter');
    // Typing after a deletion takes the format before it.
    select(line(4).from + 2, line(4).from + 4);
    press(page, 'Backspace');
    page.type('x');
    // Delete in an empty block joins the next line, even a quote's, into it.
    editor.commands.setTextSelection(line(5).from);
    press(page, 'Delete');
    // Block kind shortcuts keep each block's alignment.
    select(line(6).from, line(7).to);
    press(page, '1', { altKey: true, ...mod });
    expect(bodyOf(page)).toStrictEqual([
      { kind: 'paragraph', align: 'right', spans: [] },
      { kind: 'heading1', align: 'right', spans: [{ text: 'itle' }] },
      { kind: 'numbered', indent: 2, align: 'right', spans: [] },
      { kind: 'numbered', indent: 2, align: 'right', spans: [{ text: 'ne' }] },
      {
        kind: 'paragraph',
        spans: [{ text: 'abx', ...red }, { text: 'ef' }],
      },
      { kind: 'paragraph', align: 'right', spans: [{ text: 'Q' }] },
      { kind: 'heading1', align: 'right', spans: [{ text: 'left' }] },
      { kind: 'heading1', align: 'center', spans: [{ text: 'right' }] },
    ]);
  });

  it('keeps the first block after Select All, moves dragged content as it is and shows one family per font name', async () => {
    expect.hasAssertions();
    const page = await open([
      { kind: 'heading1', align: 'right', spans: [{ text: 'Title' }] },
      {
        kind: 'numbered',
        indent: 2,
        align: 'center',
        spans: [{ text: 'item' }],
      },
    ]);
    const { editor, command } = page;
    // A font name is one family, even one that begins as a system family does.
    const font = editor.schema.marks.format?.create({
      font: '"ui-brand, Georgia", Arial',
    });
    ok(font);
    expect(font.type.spec.toDOM?.(font, true)).toMatchObject([
      'span',
      { style: 'font-family: "ui-brand, Georgia", system-ui;' },
      0,
    ]);
    const title = { kind: 'heading1', align: 'right' } as const;
    editor.commands.selectAll();
    page.type('x');
    expect(bodyOf(page)).toStrictEqual([{ ...title, spans: [{ text: 'x' }] }]);
    command({ type: 'undo' });
    editor.commands.selectAll();
    press(page, 'Backspace');
    expect(bodyOf(page)).toStrictEqual([{ ...title, spans: [] }]);
    command({ type: 'undo' });
    // Dropping a drag from within the page keeps the list level and alignment.
    editor.commands.setTextSelection({
      from: 0,
      to: editor.state.doc.content.size,
    });
    const slice = editor.state.doc.slice(
      nth(textblocks(editor), 1).from - 3,
      editor.state.doc.content.size,
    );
    editor.view.dragging = { slice, move: true };
    expect(
      editor.view.someProp('transformPasted', (transform) =>
        transform(slice, editor.view, false),
      ),
    ).toBe(slice);
    editor.view.dragging = null;
  });

  it('drops whole paragraphs into an empty line as they are', async () => {
    expect.hasAssertions();
    const right = { kind: 'paragraph', align: 'right' } as const;
    const centred = { kind: 'paragraph', align: 'center' } as const;
    const page = await open([
      { ...right, spans: [{ text: 'ab' }] },
      { ...centred, spans: [{ text: 'cd' }] },
      // The empty line is a heading; the dragged paragraphs stay paragraphs.
      { kind: 'heading1', spans: [] },
    ]);
    const { editor } = page;
    const line = (index: number) => nth(textblocks(editor), index);
    const [first, second, empty] = [line(0), line(1), line(2)];
    editor.commands.setTextSelection({ from: first.from, to: second.to });
    const slice = editor.state.doc.slice(first.from, second.to);
    editor.view.posAtCoords = () => ({ pos: empty.from, inside: -1 });
    const event = new DragEvent('drop', { clientX: 1, clientY: 1 });
    expect(
      editor.view.someProp('handleDrop', (drop) =>
        drop(editor.view, event, slice, true),
      ),
    ).toBe(true);
    expect(bodyOf(page)).toStrictEqual([
      { kind: 'paragraph', align: 'right', spans: [] },
      { ...right, spans: [{ text: 'ab' }] },
      { ...centred, spans: [{ text: 'cd' }] },
    ]);
  });

  it('drops list items into an empty item of the same list as they are', async () => {
    expect.hasAssertions();
    const nested = { kind: 'numbered', indent: 1, align: 'right' } as const;
    const page = await open([
      { ...nested, spans: [{ text: 'one' }] },
      { ...nested, spans: [{ text: 'two' }] },
      { kind: 'numbered', spans: [] },
    ]);
    const { editor } = page;
    const line = (index: number) => nth(textblocks(editor), index);
    const [first, second, empty] = [line(0), line(1), line(2)];
    editor.commands.setTextSelection({ from: first.from, to: second.to });
    const slice = editor.state.doc.slice(first.from, second.to);
    editor.view.posAtCoords = () => ({ pos: empty.from, inside: -1 });
    const event = new DragEvent('drop', { clientX: 1, clientY: 1 });
    editor.view.someProp('handleDrop', (drop) =>
      drop(editor.view, event, slice, true),
    );
    expect(bodyOf(page)).toStrictEqual([
      { ...nested, spans: [] },
      { ...nested, spans: [{ text: 'one' }] },
      { ...nested, spans: [{ text: 'two' }] },
    ]);
  });

  it('types over unlinked text between two runs of one link without linking it', async () => {
    expect.hasAssertions();
    const link = 'https://example.com';
    const page = await open([
      {
        kind: 'paragraph',
        spans: [{ text: 'ab', link }, { text: 'x' }, { text: 'cd', link }],
      },
    ]);
    page.editor.commands.setTextSelection({ from: 3, to: 4 });
    page.type('y');
    expect(textBodyOf(page)?.[0]?.spans).toStrictEqual([
      { text: 'ab', link },
      { text: 'y' },
      { text: 'cd', link },
    ]);
  });

  it('deletes, splits and cuts across blocks as the current composer does', async () => {
    expect.hasAssertions();
    const item = { kind: 'numbered', indent: 2, align: 'right' } as const;
    const centred = { kind: 'paragraph', align: 'center' } as const;
    const page = await open([
      { ...item, spans: [{ text: 'left' }] },
      { ...centred, spans: [{ text: 'right' }] },
      { kind: 'paragraph', align: 'right', spans: [{ text: 'ab' }] },
      { ...centred, spans: [{ text: 'cd' }] },
      { ...item, spans: [{ text: 'one' }] },
      { ...centred, spans: [{ text: 'two' }] },
      { kind: 'quote', spans: [{ text: 'q1' }] },
      { kind: 'quote', spans: [{ text: 'q2' }] },
    ]);
    const { editor } = page;
    const line = (index: number) => nth(textblocks(editor), index);
    const select = (from: number, to: number) =>
      editor.commands.setTextSelection({ from, to });
    // The first block keeps its kind, level and alignment and takes the rest of the last.
    select(line(0).from, line(1).from + 1);
    press(page, 'Backspace');
    select(line(0).from, line(0).from + 1);
    press(page, 'Enter');
    // Cut deletes as Backspace does.
    select(line(2).from + 1, line(3).from + 1);
    editor.view.dispatch(
      editor.state.tr.deleteSelection().setMeta('uiEvent', 'cut'),
    );
    // Delete at the end of a list item joins the next paragraph into it.
    editor.commands.setTextSelection(line(3).to);
    press(page, 'Delete');
    // Backspace at the start of a quote line joins it into the line before.
    editor.commands.setTextSelection(line(4).from);
    press(page, 'Backspace');
    expect(bodyOf(page)).toStrictEqual([
      { ...item, spans: [] },
      { ...item, spans: [{ text: 'ght' }] },
      { kind: 'paragraph', align: 'right', spans: [{ text: 'ad' }] },
      { ...item, spans: [{ text: 'onetwoq1' }] },
      { kind: 'quote', spans: [{ text: 'q2' }] },
    ]);
  });

  it('keeps the first block through Select All with typing, deletion, paste and images', async () => {
    expect.hasAssertions();
    const item = { kind: 'numbered', indent: 2, align: 'right' } as const;
    const page = await open([
      { ...item, spans: [{ text: 'item' }] },
      { kind: 'quote', spans: [{ text: 'quote' }] },
    ]);
    const { editor, command } = page;
    const replaced = (edit: () => void) => {
      editor.commands.selectAll();
      edit();
      const body = bodyOf(page);
      command({ type: 'undo' });
      return body;
    };
    expect(replaced(() => page.type('x'))).toStrictEqual([
      { ...item, spans: [{ text: 'x' }] },
    ]);
    expect(replaced(() => press(page, 'Delete'))).toStrictEqual([
      { ...item, spans: [] },
    ]);
    expect(
      replaced(() => editor.view.pasteHTML('<p>pasted</p>')),
    ).toStrictEqual([{ ...item, spans: [{ text: 'pasted' }] }]);
    // Text inserted without a key press, as by dictation, and an empty pasteboard.
    expect(
      replaced(() =>
        editor.view.dom.dispatchEvent(
          new InputEvent('beforeinput', {
            inputType: 'insertText',
            data: 'said',
            cancelable: true,
          }),
        ),
      ),
    ).toStrictEqual([{ ...item, spans: [{ text: 'said' }] }]);
    expect(
      replaced(() =>
        command({ type: 'add', images: [photo], attachments: [] }),
      )?.[0],
    ).toMatchObject({ ...item, spans: [{ image: photo }] });
  });

  it('leaves a selection for an empty pasteboard and joins a paragraph copied whole', async () => {
    expect.hasAssertions();
    const item = { kind: 'numbered', indent: 2, align: 'right' } as const;
    const page = await open([
      { ...item, spans: [{ text: 'item' }] },
      { kind: 'quote', spans: [{ text: 'quote' }] },
    ]);
    const { editor } = page;
    editor.commands.selectAll();
    const selected = editor.state.selection;
    editor.view.pasteHTML('');
    expect([bodyOf(page), editor.state.selection.eq(selected)]).toStrictEqual([
      undefined,
      true,
    ]);
    // A paragraph copied whole, as after Select All, joins the line it is pasted into.
    const { from, to } = nth(textblocks(editor), 0);
    editor.commands.setTextSelection({ from, to });
    editor.view.pasteHTML('<p data-pm-slice="0 0 []">copied</p>');
    expect(bodyOf(page)?.[0]).toStrictEqual({
      ...item,
      spans: [{ text: 'copied' }],
    });
    // A list item copied whole stays an item, without its layout.
    const { dom } = editor.view.serializeForClipboard(
      editor.state.doc.slice(0, editor.state.doc.firstChild?.nodeSize),
    );
    const quote = nth(textblocks(editor), 1);
    editor.commands.setTextSelection(quote.from + 2);
    editor.view.pasteHTML(dom.innerHTML);
    expect(bodyOf(page)?.slice(1)).toStrictEqual([
      { kind: 'quote', spans: [{ text: 'qu' }] },
      { kind: 'numbered', spans: [{ text: 'copied' }] },
      { kind: 'quote', spans: [{ text: 'ote' }] },
    ]);
  });

  it('pastes a quote copied whole over a selected quote line into that line', async () => {
    expect.hasAssertions();
    const page = await open([
      { kind: 'quote', align: 'justify', spans: [{ text: 'kept' }] },
      { kind: 'paragraph', spans: [{ text: 'gap' }] },
      { kind: 'quote', spans: [{ text: 'copied' }] },
    ]);
    const { editor } = page;
    const line = (index: number) => nth(textblocks(editor), index);
    const { dom } = editor.view.serializeForClipboard(
      editor.state.doc.slice(line(2).from - 2, line(2).to + 2),
    );
    editor.commands.setTextSelection({ from: line(0).from, to: line(0).to });
    editor.view.pasteHTML(dom.innerHTML);
    expect(bodyOf(page)?.[0]).toStrictEqual({
      kind: 'quote',
      align: 'justify',
      spans: [{ text: 'copied' }],
    });
  });

  it('keeps the text after a selection on its own line under lines pasted from elsewhere', async () => {
    expect.hasAssertions();
    const page = await open(paragraphs('abc'));
    page.editor.commands.setTextSelection({ from: 2, to: 3 });
    page.editor.view.pasteHTML('<p>one</p><p>two</p>');
    expect(bodyOf(page)).toStrictEqual(paragraphs('aone', 'two', 'c'));
  });

  it('pastes a paragraph copied whole at the caret as its text and keeps the line after a selection', async () => {
    expect.hasAssertions();
    const right = { kind: 'paragraph', align: 'right' } as const;
    const page = await open([
      { ...right, spans: [{ text: 'abc' }] },
      { kind: 'paragraph', spans: [{ text: 'copied' }] },
      { kind: 'numbered', spans: [{ text: 'one' }] },
      { kind: 'numbered', spans: [{ text: 'two' }] },
    ]);
    const { editor } = page;
    const line = (index: number) => nth(textblocks(editor), index);
    const copy = (from: number, to: number) =>
      editor.view.serializeForClipboard(editor.state.doc.slice(from, to)).dom
        .innerHTML;
    const paragraph = copy(line(1).from - 1, line(1).to + 1);
    const list = copy(line(2).from - 3, line(3).to + 3);
    editor.commands.setTextSelection(line(0).from + 1);
    editor.view.pasteHTML(paragraph);
    expect(bodyOf(page)?.[0]).toStrictEqual({
      ...right,
      spans: [{ text: 'acopiedbc' }],
    });
    editor.commands.setTextSelection({
      from: line(0).from + 7,
      to: line(0).from + 8,
    });
    editor.view.pasteHTML(list);
    expect(bodyOf(page)?.slice(0, 3)).toStrictEqual([
      { ...right, spans: [{ text: 'acopiedone' }] },
      { kind: 'numbered', spans: [{ text: 'two' }] },
      { ...right, spans: [{ text: 'c' }] },
    ]);
    // Replacing a line's end adds no empty line and leaves the caret after the pasted text.
    editor.commands.setTextSelection({
      from: line(0).from + 7,
      to: line(0).to,
    });
    editor.view.pasteHTML(list);
    expect([
      bodyOf(page)?.slice(0, 3),
      editor.state.selection.from,
    ]).toStrictEqual([
      [
        { ...right, spans: [{ text: 'acopiedone' }] },
        { kind: 'numbered', spans: [{ text: 'two' }] },
        { kind: 'numbered', spans: [{ text: 'two' }] },
      ],
      line(1).to,
    ]);
  });

  it('pastes a whole Draft over a line end without changing the lines after it', async () => {
    expect.hasAssertions();
    const bullet = { kind: 'bulleted' } as const;
    const page = await open([
      { ...bullet, spans: [{ text: 'abc' }] },
      { ...bullet, spans: [{ text: 'survivor' }] },
      { kind: 'paragraph', spans: [{ text: 'one' }] },
      { kind: 'numbered', spans: [{ text: 'three' }] },
    ]);
    const { editor } = page;
    const { dom } = editor.view.serializeForClipboard(
      editor.state.doc.slice(0, editor.state.doc.content.size),
    );
    const first = nth(textblocks(editor), 0);
    editor.commands.setTextSelection({ from: first.from + 1, to: first.to });
    editor.view.pasteHTML(dom.innerHTML);
    expect(bodyOf(page)).toStrictEqual([
      { ...bullet, spans: [{ text: 'aabc' }] },
      { ...bullet, spans: [{ text: 'survivor' }] },
      { kind: 'paragraph', spans: [{ text: 'one' }] },
      { kind: 'numbered', spans: [{ text: 'three' }] },
      { ...bullet, spans: [{ text: 'survivor' }] },
      { kind: 'paragraph', spans: [{ text: 'one' }] },
      { kind: 'numbered', spans: [{ text: 'three' }] },
    ]);
  });

  it('keeps a pasted blank last line and a line a paste leaves empty', async () => {
    expect.hasAssertions();
    const item = { kind: 'bulleted', indent: 1, align: 'right' } as const;
    const page = await open([
      { kind: 'paragraph', spans: [{ text: 'abc' }] },
      { ...item, spans: [{ text: 'item' }] },
      { kind: 'paragraph', spans: [] },
    ]);
    const { editor } = page;
    const line = (index: number) => nth(textblocks(editor), index);
    const blank = editor.view.serializeForClipboard(
      editor.state.doc.slice(line(2).from - 1, line(2).to + 1),
    ).dom.innerHTML;
    editor.commands.setTextSelection({ from: line(1).from, to: line(1).to });
    editor.view.pasteHTML(blank);
    editor.commands.setTextSelection({
      from: line(0).from + 1,
      to: line(0).to,
    });
    editor.view.pasteText('first\n\n');
    expect([bodyOf(page), editor.state.selection.from]).toStrictEqual([
      [
        { kind: 'paragraph', spans: [{ text: 'afirst' }] },
        { kind: 'paragraph', spans: [] },
        { ...item, spans: [] },
        { kind: 'paragraph', spans: [] },
      ],
      line(1).from,
    ]);
  });

  it('drops a heading into an empty list item with the heading alignment', async () => {
    expect.hasAssertions();
    const page = await open([
      { kind: 'heading1', align: 'right', spans: [{ text: 'head' }] },
      { kind: 'numbered', spans: [{ text: 'item' }] },
      { kind: 'numbered', align: 'justify', spans: [] },
    ]);
    const { editor } = page;
    const line = (index: number) => nth(textblocks(editor), index);
    const [first, second, empty] = [line(0), line(1), line(2)];
    editor.commands.setTextSelection({ from: first.from, to: second.to });
    const slice = editor.state.doc.slice(first.from, second.to);
    editor.view.posAtCoords = () => ({ pos: empty.from, inside: -1 });
    const event = new DragEvent('drop', { clientX: 1, clientY: 1 });
    editor.view.someProp('handleDrop', (drop) =>
      drop(editor.view, event, slice, true),
    );
    expect(bodyOf(page)).toContainEqual({
      kind: 'numbered',
      align: 'right',
      spans: [{ text: 'head' }],
    });
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
        // The page's own rendering of stored formatting, as copying within the page carries it.
        '<p style="text-align: right;"><span data-draft-format="" style="--draft-light: #c00000;">own</span></p><ol><li data-indent="1"><p>level</p></li></ol>',
        '<p style="color: red; font-size: 40px; text-align: center">styled</p>',
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
          { text: ' ' },
          { text: 'link text', link: 'https://example.com' },
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
      paragraph('own'),
      { kind: 'numbered', spans: [{ text: 'level' }] },
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

  it('keeps links through typing, saving and reopening, and pastes only admitted destinations', async () => {
    expect.hasAssertions();
    const plan = 'https://example.com/plan';
    const docs = 'https://example.com/docs';
    const mail = 'mailto:team@example.com';
    const opened: SemanticDocument = [
      {
        kind: 'paragraph',
        spans: [
          { text: 'Read ' },
          { text: 'the plan', link: plan },
          { text: 'docs', link: docs },
          { text: ' or ' },
          { text: 'mail', marks: ['bold'], link: mail },
          { text: ' us', marks: ['bold'] },
        ],
      },
    ];
    const page = await open(opened);
    // From the end, so earlier positions stay valid: after the last text, at the end of a link,
    // inside a link and at the start of one.
    for (const [at, text] of [
      [29, '!'],
      [18, 'y'],
      [10, 'x'],
      [6, 'z'],
    ] as const) {
      page.editor.commands.setTextSelection(at);
      page.type(text);
    }
    const edited: SemanticDocument = [
      {
        kind: 'paragraph',
        spans: [
          { text: 'Read z' },
          { text: 'the xplan', link: plan },
          { text: 'docs', link: docs },
          { text: 'y or ' },
          { text: 'mail', marks: ['bold'], link: mail },
          { text: ' us!', marks: ['bold'] },
        ],
      },
    ];
    expect(bodyOf(page)).toStrictEqual(edited);
    // The body the host saves before sending reopens with the same links.
    const reopened = await open(edited);
    reopened.command({ type: 'editable', editable: false });
    expect(bodyOf(reopened)).toStrictEqual(edited);

    const pasted = await open(paragraphs(''));
    pasted.editor.view.pasteHTML(
      [
        '<a href="https://example.com/a">web</a> ',
        '<a href="mailto:a@example.com">mail</a> ',
        '<a href="tel:+420123456789">call</a> ',
        '<a href="javascript:alert(1)">script</a> ',
        '<a href=" https://example.com/b">spaced</a> ',
        '<a href="ftp://example.com">ftp</a> ',
        '<a href="#top">anchor</a>',
      ].join(''),
    );
    expect(bodyOf(pasted)).toStrictEqual([
      {
        kind: 'paragraph',
        spans: [
          { text: 'web', link: 'https://example.com/a' },
          { text: ' ' },
          { text: 'mail', link: 'mailto:a@example.com' },
          { text: ' ' },
          { text: 'call', link: 'tel:+420123456789' },
          { text: ' script spaced ftp anchor' },
        ],
      },
    ]);
    // One Undo removes the paste, links included.
    pasted.command({ type: 'undo' });
    expect(bodyOf(pasted)).toStrictEqual(paragraphs(''));
  });

  it('keeps typing at the new link edge unlinked after Return', async () => {
    expect.hasAssertions();
    const link = 'https://example.com/plan';
    for (const kind of kinds) {
      const page = await open([{ kind, spans: [{ text: 'abcd', link }] }]);
      const [line] = textblocks(page.editor);
      ok(line, 'Expected a linked line');
      page.editor.commands.setTextSelection(line.from + 2);
      press(page, 'Enter');
      page.type('X');
      expect(bodyOf(page)).toStrictEqual([
        { kind, spans: [{ text: 'ab', link }] },
        { kind, spans: [{ text: 'X' }, { text: 'cd', link }] },
      ]);
      page.command({ type: 'undo' });
      expect(bodyOf(page)).toStrictEqual([
        { kind, spans: [{ text: 'ab', link }] },
        { kind, spans: [{ text: 'cd', link }] },
      ]);
      page.command({ type: 'redo' });
      expect(bodyOf(page)).toStrictEqual([
        { kind, spans: [{ text: 'ab', link }] },
        { kind, spans: [{ text: 'X' }, { text: 'cd', link }] },
      ]);
    }
  });

  it('keeps the link of the first replaced character when typing across its end', async () => {
    expect.hasAssertions();
    const link = 'https://example.com/plan';
    const other = 'https://example.com/docs';
    const opened: SemanticDocument = [
      {
        kind: 'paragraph',
        spans: [
          { text: 'abcd', link },
          { text: 'efgh' },
          { text: 'ijkl', link: other },
        ],
      },
    ];
    const page = await open(opened);
    page.editor.commands.setTextSelection({ from: 2, to: 7 });
    page.type('X');
    const edited: SemanticDocument = [
      {
        kind: 'paragraph',
        spans: [
          { text: 'aX', link },
          { text: 'gh' },
          { text: 'ijkl', link: other },
        ],
      },
    ];
    expect(bodyOf(page)).toStrictEqual(edited);
    page.command({ type: 'undo' });
    expect(bodyOf(page)).toStrictEqual(opened);
    page.command({ type: 'redo' });
    expect(bodyOf(page)).toStrictEqual(edited);
    // Starting in unlinked text, the replacement stays unlinked and the rest of the link keeps it.
    const unlinked = await open(opened);
    unlinked.editor.commands.setTextSelection({ from: 7, to: 11 });
    unlinked.type('Z');
    expect(bodyOf(unlinked)).toStrictEqual([
      {
        kind: 'paragraph',
        spans: [
          { text: 'abcd', link },
          { text: 'efZ' },
          { text: 'kl', link: other },
        ],
      },
    ]);
    // Select All uses an AllSelection starting outside the first paragraph.
    const all = await open(opened);
    all.editor.commands.selectAll();
    all.type('Y');
    expect(bodyOf(all)).toStrictEqual([
      { kind: 'paragraph', spans: [{ text: 'Y', link }] },
    ]);
  });

  it('keeps replacement links when DOM text input reports a range apart from the caret', async () => {
    expect.hasAssertions();
    const link = 'https://example.com/plan';
    const opened: SemanticDocument = [
      { kind: 'paragraph', spans: [{ text: 'abcd', link }, { text: ' tail' }] },
    ];
    for (const caret of [5, 10]) {
      const page = await open(opened);
      page.editor.commands.setTextSelection(caret);
      // ProseMirror's DOM-change path supplies the changed range independently of selection.
      page.editor.view.someProp('handleTextInput', (handle) =>
        handle(page.editor.view, 1, 5, 'ABCD', () =>
          page.editor.state.tr.insertText('ABCD', 1, 5),
        ),
      );
      const edited: SemanticDocument = [
        {
          kind: 'paragraph',
          spans: [{ text: 'ABCD', link }, { text: ' tail' }],
        },
      ];
      expect(bodyOf(page)).toStrictEqual(edited);
      page.command({ type: 'undo' });
      expect(bodyOf(page)).toStrictEqual(opened);
      page.command({ type: 'redo' });
      expect(bodyOf(page)).toStrictEqual(edited);
    }
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
      pasted: textBodyOf(page)?.[0].spans,
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

  it('keeps and sets Inline Image display widths through typing, Undo and cut and paste', async () => {
    expect.hasAssertions();
    const page = await open([
      {
        kind: 'paragraph',
        spans: [
          { text: 'a' },
          { text: '￼', image: photo, width: 640 },
          { text: 'b' },
          { text: '￼', image: photo },
        ],
      },
    ]);
    const spans = () => textBodyOf(page)?.[0].spans;
    page.editor.commands.setTextSelection(1);
    page.type('X');
    const typed = spans();
    // Copying keeps the width with the image; every use of the asset is resized as one edit.
    const copied = page.editor.getHTML();
    page.command({ type: 'resize', id: photo.id, width: 1024 });
    const resized = spans();
    // Choosing the current size again is no edit, so one Undo restores both earlier sizes.
    page.command({ type: 'resize', id: photo.id, width: 1024 });
    page.command({ type: 'undo' });
    const undone = spans();
    page.command({ type: 'resize', id: photo.id, width: null });
    const original = spans();
    // A pasted width the document does not admit shows the original size.
    page.editor.commands.setTextSelection(1);
    page.editor.view.pasteHTML(
      '<p><img data-draft-asset="photo0001" data-draft-width="320"><img data-draft-asset="photo0001" data-draft-width="500"></p>',
    );
    expect({
      typed,
      copied: copied.includes(
        '<img data-draft-asset="photo0001" data-draft-width="640"',
      ),
      resized,
      undone,
      original,
      pasted: spans(),
    }).toStrictEqual({
      typed: [
        { text: 'Xa' },
        { text: '￼', image: photo, width: 640 },
        { text: 'b' },
        { text: '￼', image: photo },
      ],
      copied: true,
      resized: [
        { text: 'Xa' },
        { text: '￼', image: photo, width: 1024 },
        { text: 'b' },
        { text: '￼', image: photo, width: 1024 },
      ],
      undone: typed,
      original: [
        { text: 'Xa' },
        { text: '￼', image: photo },
        { text: 'b' },
        { text: '￼', image: photo },
      ],
      pasted: [
        { text: '￼', image: photo, width: 320 },
        { text: '￼', image: photo },
        { text: 'Xa' },
        { text: '￼', image: photo },
        { text: 'b' },
        { text: '￼', image: photo },
      ],
    });
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
    page.command({ type: 'previews', previews: { [photo.id]: null } });
    const revoked = shown();
    page.command({ type: 'convert', id: photo.id });
    page.command({ type: 'convert', id: photo.id });
    const unverified = shown();
    page.command({ type: 'previews', previews: { [photo.id]: thumbnail } });
    const rechecked = shown();
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
      revoked,
      unverified,
      rechecked,
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
      revoked: null,
      unverified: null,
      rechecked: thumbnail,
      handled: [true, true, undefined],
      prevented: [true, true, false],
      pastes: 1,
      body: [{ kind: 'paragraph', spans: [{ text: '￼', image: photo }] }],
    });
  });
});

type Cell = Table['rows'][number][number];
const cell = (text: string, rest: Omit<Cell, 'blocks'> = {}): Cell => ({
  blocks: paragraphs(text),
  ...rest,
});
const heading = (text: string): Cell => ({
  blocks: [{ kind: 'paragraph', spans: [{ text, marks: ['bold'] }] }],
  header: true,
});
// The approved frames' table: a header row, three rows and a last row of one merged cell.
const handover: Table = {
  kind: 'table',
  rows: [
    [heading('Item'), heading('Date'), heading('Who')],
    [cell('Key handover'), cell('1 Dec'), cell('Mara')],
    [cell('Meter readings'), cell('2 Dec'), cell('Tomáš')],
    [cell('Parking card'), cell('3 Dec'), cell('Mara')],
    [
      {
        blocks: [
          {
            kind: 'paragraph',
            spans: [
              { text: 'Bring photo ID', marks: ['bold'] },
              { text: '; the office checks it.' },
            ],
          },
        ],
        columns: 3,
      },
    ],
  ],
};
const letter: TableDocument = [
  paragraph('Dear Tomáš,'),
  handover,
  paragraph('Kind regards,'),
];

// Each table cell's first text position, in reading order.
const cellsOf = ({ state }: Editor) => {
  const starts: number[] = [];
  state.doc.descendants((node, position) => {
    const isCell = ['tableCell', 'tableHeader'].includes(node.type.name);
    if (isCell) {
      starts.push(position + 2);
    }
    return !isCell;
  });
  return starts;
};
const selected = ({ editor }: Page) => {
  const { from, to } = editor.state.selection;
  return editor.state.doc.textBetween(from, to);
};

// `table` as the page's table node, whatever its shape, to ask prosemirror-tables about it.
const tableNode = (schema: Schema, { rows }: Table) =>
  schema.nodeFromJSON({
    type: 'table',
    content: rows.map((row) => ({
      type: 'tableRow',
      content: row.map(({ columns = 1, rows: span = 1 }) => ({
        type: 'tableCell',
        attrs: { colspan: columns, rowspan: span },
        content: [{ type: 'paragraph' }],
      })),
    })),
  });

// A table of `shape`, each cell's text naming its row and place.
const shaped = (
  shape: Arr.NonEmptyReadonlyArray<
    Arr.NonEmptyReadonlyArray<Omit<Cell, 'blocks'>>
  >,
  suffix = '',
): Table => ({
  kind: 'table',
  rows: Fn.pipe(
    shape,
    Arr.map((row, y) =>
      Fn.pipe(
        row,
        Arr.map((rest, x) => cell(`${y}${x}${suffix}`, rest)),
      ),
    ),
  ),
});

describe('tables in the Tiptap page', () => {
  it('round-trips header cells, merged cells and marks, and keeps them through an edit', async () => {
    expect.hasAssertions();
    const page = await open(letter);
    page.editor.commands.setTextSelection(nth(cellsOf(page.editor), 7) + 5);
    page.type(' am');
    expect(bodyOf(page)).toStrictEqual([
      paragraph('Dear Tomáš,'),
      {
        ...handover,
        rows: handover.rows.with(2, [
          cell('Meter readings'),
          cell('2 Dec am'),
          cell('Tomáš'),
        ]),
      },
      paragraph('Kind regards,'),
    ]);
  });

  it.each([
    [
      'cells',
      [
        [{}, {}],
        [{}, {}],
      ],
    ],
    [
      'a header row',
      [
        [{ header: true }, { header: true }],
        [{}, {}],
      ],
    ],
    ['merged columns', [[{ columns: 2 }], [{}, {}]]],
    ['merged rows', [[{ rows: 2 }, {}], [{}]]],
    [
      'a block of merged cells',
      [[{ columns: 2, rows: 2 }, {}], [{}], [{}, {}, {}]],
    ],
  ] as const)(
    'edits a table of %s without changing its cells',
    async (_, shape) => {
      expect.hasAssertions();
      const table = shaped(shape);
      const page = await open([table, paragraph('after')]);
      expect(page.editor.state.doc.child(0).type.name).toBe('table');
      const count = cellsOf(page.editor).length;
      for (let index = 0; index < count; index += 1) {
        const start = nth(cellsOf(page.editor), index);
        page.editor.commands.setTextSelection(start + 2);
        page.type('!');
      }
      expect(bodyOf(page)).toStrictEqual([
        shaped(shape, '!'),
        paragraph('after'),
      ]);
      expect(fillsGrid(table)).toBe(true);
      expect(
        TableMap.get(tableNode(page.editor.schema, table)).problems,
      ).toBeNull();
    },
  );

  it.each([
    ['a short row', [[{}, {}], [{}]]],
    ['a merged cell past the last row', [[{ rows: 3 }, {}], [{}]]],
    ['a longer row', [[{ rows: 2 }, {}], [{ columns: 2 }]]],
    ['overlapping merged cells', [[{}, { rows: 2 }], [{ columns: 2 }]]],
  ] as const)(
    'keeps a table with %s unchanged and not editable',
    async (_, shape) => {
      expect.hasAssertions();
      const table = shaped(shape);
      const page = await open([table, paragraph('after')]);
      // prosemirror-tables would change its shape, so the page keeps it as one node.
      expect({
        fills: fillsGrid(table),
        fixed: TableMap.get(tableNode(page.editor.schema, table)).problems
          ?.length,
        node: page.editor.state.doc.child(0).type.name,
        cells: cellsOf(page.editor),
      }).toStrictEqual({
        fills: false,
        fixed: expect.any(Number),
        node: 'keptTable',
        cells: [],
      });
      // Shown with its cells and text, as the page cannot edit it.
      expect(
        [...document.querySelectorAll('.draft-table td')].map(
          ({ textContent }) => textContent,
        ),
      ).toStrictEqual(
        shape.flatMap((row, y) => row.map((_cell, x) => `${y}${x}`)),
      );
      page.editor.chain().focus('end').run();
      page.type('!');
      expect(bodyOf(page)).toStrictEqual([table, paragraph('after!')]);
    },
  );

  it('moves between cells with Tab and Shift-Tab, and leaves the last cell without adding a row', async () => {
    expect.hasAssertions();
    const page = await open(letter);
    const opened = page.editor.getJSON();
    page.editor.commands.setTextSelection(nth(cellsOf(page.editor), 0) + 2);
    const walked = cellsOf(page.editor)
      .slice(1)
      .map(() => {
        press(page, 'Tab');
        return selected(page);
      });
    expect(walked).toStrictEqual([
      'Date',
      'Who',
      'Key handover',
      '1 Dec',
      'Mara',
      'Meter readings',
      '2 Dec',
      'Tomáš',
      'Parking card',
      '3 Dec',
      'Mara',
      'Bring photo ID; the office checks it.',
    ]);
    // The last cell's Tab moves to the text after the table.
    const left = press(page, 'Tab');
    const { $head, empty } = page.editor.state.selection;
    expect({
      left,
      empty,
      text: $head.parent.textContent,
      offset: $head.parentOffset,
    }).toStrictEqual({
      left: true,
      empty: true,
      text: 'Kind regards,',
      offset: 0,
    });
    // Shift-Tab moves back a cell, and stays in the first.
    page.editor.commands.setTextSelection(nth(cellsOf(page.editor), 1));
    press(page, 'Tab', { shiftKey: true });
    const back = selected(page);
    const handled = press(page, 'Tab', { shiftKey: true });
    expect({ back, handled, stayed: selected(page) }).toStrictEqual({
      back: 'Item',
      handled: true,
      stayed: 'Item',
    });
    expect(page.editor.getJSON()).toStrictEqual(opened);
  });

  it('adds the paragraph to move to when Tab leaves a table that ends the body', async () => {
    expect.hasAssertions();
    const table = shaped([[{}, {}]]);
    const page = await open([paragraph('Before'), table]);
    page.editor.commands.setTextSelection(nth(cellsOf(page.editor), 1));
    press(page, 'Tab');
    expect(bodyOf(page)).toStrictEqual([
      paragraph('Before'),
      table,
      paragraph(''),
    ]);
    page.type('After');
    expect(bodyOf(page)).toStrictEqual([
      paragraph('Before'),
      table,
      paragraph('After'),
    ]);
    page.command({ type: 'undo' });
    page.command({ type: 'undo' });
    expect(bodyOf(page)).toStrictEqual([paragraph('Before'), table]);
  });

  it('adds lines with Return and formats text inside a cell', async () => {
    expect.hasAssertions();
    const page = await open(letter);
    page.editor.commands.setTextSelection(nth(cellsOf(page.editor), 4) + 5);
    press(page, 'Enter');
    page.command({ type: 'mark', mark: 'italic' });
    page.type('Lobby');
    const table = bodyOf(page)?.[1];
    ok(table?.kind === 'table', 'Expected the table');
    expect(table.rows[1]).toStrictEqual([
      cell('Key handover'),
      {
        blocks: [
          paragraph('1 Dec'),
          { kind: 'paragraph', spans: [{ text: 'Lobby', marks: ['italic'] }] },
        ],
      },
      cell('Mara'),
    ]);
    expect(table.rows).toHaveLength(handover.rows.length);
  });

  it('selects a table with Backspace after it, and deletes it as one Undo step', async () => {
    expect.hasAssertions();
    const page = await open(letter);
    const after =
      page.editor.state.doc.child(0).nodeSize +
      page.editor.state.doc.child(1).nodeSize;
    page.editor.commands.setTextSelection(after + 1);
    press(page, 'Backspace');
    const { selection } = page.editor.state;
    // The table is selected, and no text merged into it.
    expect({
      node: selection instanceof NodeSelection,
      type: selection.$from.nodeAfter?.type.name,
      body: bodyOf(page),
    }).toStrictEqual({ node: true, type: 'table', body: undefined });
    press(page, 'Backspace');
    expect(bodyOf(page)).toStrictEqual(
      paragraphs('Dear Tomáš,', 'Kind regards,'),
    );
    page.command({ type: 'undo' });
    expect(bodyOf(page)).toStrictEqual(letter);
    page.command({ type: 'redo' });
    expect(bodyOf(page)).toStrictEqual(
      paragraphs('Dear Tomáš,', 'Kind regards,'),
    );
  });

  it.each([
    ['a kept table', shaped([[{}, {}], [{}]]), paragraph('after')],
    ['a table before an empty paragraph', shaped([[{}, {}]]), paragraph('')],
  ] as const)(
    'selects %s with Backspace before deleting it',
    async (_, table, after) => {
      expect.hasAssertions();
      const page = await open([table, after]);
      page.editor.commands.setTextSelection(
        page.editor.state.doc.child(0).nodeSize + 1,
      );
      press(page, 'Backspace');
      expect({
        node: page.editor.state.selection instanceof NodeSelection,
        body: bodyOf(page),
      }).toStrictEqual({ node: true, body: undefined });
      press(page, 'Backspace');
      expect(bodyOf(page)).toStrictEqual([after]);
      page.command({ type: 'undo' });
      expect(bodyOf(page)).toStrictEqual([table, after]);
    },
  );

  it('pastes into selected cells without changing them', async () => {
    expect.hasAssertions();
    const page = await open([
      shaped([[{ header: true, columns: 2 }], [{}, {}]]),
    ]);
    const { state, view } = page.editor;
    const header = nth(cellsOf(page.editor), 0) - 2;
    view.dispatch(
      state.tr.setSelection(CellSelection.create(state.doc, header)),
    );
    // An image-only paste keeps nothing, so the cells stay as they are.
    view.pasteHTML('<img src="photo.png">');
    const kept = bodyOf(page);
    view.pasteText('new');
    expect(kept).toBeUndefined();
    expect(bodyOf(page)).toStrictEqual([
      {
        kind: 'table',
        rows: [
          [cell('new', { header: true, columns: 2 })],
          [cell('10'), cell('11')],
        ],
      },
    ]);
  });

  it('keeps alignment, list levels, colors and fonts inside cells', async () => {
    expect.hasAssertions();
    const table: Table = {
      kind: 'table',
      rows: [
        [
          {
            blocks: [
              {
                kind: 'paragraph',
                align: 'center',
                spans: [{ text: 'red', color: '#c00000', font: 'serif' }],
              },
              { kind: 'numbered', spans: [{ text: 'one' }] },
              { kind: 'numbered', indent: 1, spans: [{ text: 'one.a' }] },
            ],
          },
          cell('plain'),
        ],
      ],
    };
    const page = await open([table, paragraph('after')]);
    page.editor.chain().focus('end').run();
    page.type('!');
    expect(bodyOf(page)).toStrictEqual([table, paragraph('after!')]);
  });

  it('keeps text in its cell at a cell edge and clears selected cells', async () => {
    expect.hasAssertions();
    const page = await open([shaped([[{}, {}]])]);
    const { editor } = page;
    editor.commands.setTextSelection(nth(cellsOf(editor), 0) + 2);
    press(page, 'Delete');
    editor.commands.setTextSelection(nth(cellsOf(editor), 1));
    press(page, 'Backspace');
    expect(bodyOf(page)).toBeUndefined();
    const { state, view } = editor;
    view.dispatch(
      state.tr.setSelection(
        CellSelection.create(
          state.doc,
          nth(cellsOf(editor), 0) - 2,
          nth(cellsOf(editor), 1) - 2,
        ),
      ),
    );
    press(page, 'Delete');
    expect(bodyOf(page)).toStrictEqual([
      { kind: 'table', rows: [[cell(''), cell('')]] },
    ]);
  });

  it('keeps cell text when Return or text input meets a selected table or cells', async () => {
    expect.hasAssertions();
    const table = shaped([[{}, {}]]);
    const page = await open([table, paragraph('after')]);
    const { editor } = page;
    editor.view.dispatch(
      editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, 0)),
    );
    press(page, 'Enter');
    const afterNode = bodyOf(page)?.filter(({ kind }) => kind === 'table');
    const { state, view } = editor;
    view.dispatch(
      state.tr.setSelection(
        CellSelection.create(
          state.doc,
          nth(cellsOf(editor), 0) - 2,
          nth(cellsOf(editor), 1) - 2,
        ),
      ),
    );
    const input = new InputEvent('beforeinput', {
      inputType: 'insertText',
      data: 'X',
      cancelable: true,
    });
    const uncancelled = view.dom.dispatchEvent(input);
    press(page, 'Enter');
    expect([
      afterNode,
      uncancelled,
      textblocks(editor).map(({ text }) => text),
    ]).toStrictEqual([[table], true, ['', '00', '01', '', 'after']]);
  });

  it.each([
    ['a kept table', shaped([[{}, {}], [{}]])],
    ['a table', shaped([[{}, {}]])],
  ] as const)(
    'deletes %s inside a selection and never joins text across it',
    async (_, table) => {
      expect.hasAssertions();
      const page = await open([paragraph('before'), table, paragraph('after')]);
      const { editor } = page;
      editor.commands.setTextSelection(nth(textblocks(editor), 0).to);
      press(page, 'Delete');
      const joined = [
        bodyOf(page),
        editor.state.selection instanceof NodeSelection,
      ];
      editor.commands.selectAll();
      press(page, 'Backspace');
      expect([joined, bodyOf(page)]).toStrictEqual([
        [undefined, true],
        [paragraph('')],
      ]);
    },
  );

  it('keeps the first line layout inside a cell and the grid under an edit across lines into a table', async () => {
    expect.hasAssertions();
    const page = await open([
      {
        kind: 'table',
        rows: [
          [
            {
              blocks: [
                { kind: 'numbered', spans: [{ text: 'a' }] },
                {
                  kind: 'numbered',
                  indent: 1,
                  align: 'right',
                  spans: [{ text: 'bb' }],
                },
                { kind: 'bulleted', align: 'center', spans: [{ text: 'cc' }] },
              ],
            },
          ],
        ],
      },
    ]);
    const { editor } = page;
    editor.commands.setTextSelection({
      from: nth(textblocks(editor), 1).from,
      to: nth(textblocks(editor), 2).from + 1,
    });
    press(page, 'Backspace');
    const crossing = await open([
      paragraph('before'),
      shaped([
        [{}, {}],
        [{}, {}],
      ]),
      paragraph('after'),
    ]);
    crossing.editor.commands.setTextSelection({
      from: nth(textblocks(crossing.editor), 5).from + 2,
      to: nth(textblocks(crossing.editor), 1).from + 1,
    });
    crossing.type('X');
    expect([bodyOf(page), bodyOf(crossing)]).toStrictEqual([
      [
        {
          kind: 'table',
          rows: [
            [
              {
                blocks: [
                  { kind: 'numbered', spans: [{ text: 'a' }] },
                  {
                    kind: 'numbered',
                    align: 'right',
                    indent: 1,
                    spans: [{ text: 'c' }],
                  },
                ],
              },
            ],
          ],
        },
      ],
      [
        paragraph('before'),
        {
          kind: 'table',
          rows: [
            [cell('0X'), cell('')],
            [cell(''), cell('')],
          ],
        },
        paragraph('ter'),
      ],
    ]);
  });

  it('keeps an Inline Image after a deletion from a cell out of the table', async () => {
    expect.hasAssertions();
    const after = {
      kind: 'paragraph',
      spans: [{ text: 'ab' }, { text: '￼', image: photo }],
    } as const;
    const page = await open([shaped([[{}, {}]]), after], [photo]);
    const { editor } = page;
    editor.commands.setTextSelection({
      from: nth(textblocks(editor), 0).from + 1,
      to: nth(textblocks(editor), 2).from + 1,
    });
    press(page, 'Backspace');
    expect(bodyOf(page)).toStrictEqual([
      { kind: 'table', rows: [[cell('0'), cell('')]] },
      {
        kind: 'paragraph',
        spans: [{ text: 'b' }, { text: '￼', image: photo }],
      },
    ]);
  });

  it('selects a kept table ending the body before Delete removes it, and Return after Select All leaves a caret', async () => {
    expect.hasAssertions();
    const page = await open([paragraph('before'), shaped([[{}, {}], [{}]])]);
    page.editor.commands.setTextSelection(nth(textblocks(page.editor), 0).to);
    press(page, 'Delete');
    const selected = [
      bodyOf(page),
      page.editor.state.selection instanceof NodeSelection,
    ];
    press(page, 'Delete');
    const deleted = bodyOf(page);
    const all = await open([shaped([[{}, {}], [{}]]), paragraph('after')]);
    all.editor.commands.selectAll();
    press(all, 'Enter');
    expect([
      selected,
      deleted,
      bodyOf(all),
      all.editor.state.selection instanceof TextSelection,
    ]).toStrictEqual([
      [undefined, true],
      paragraphs('before'),
      paragraphs('', ''),
      true,
    ]);
  });

  it.each([
    ['one table', [shaped([[{}, {}]])]],
    [
      'a table and a kept table',
      [shaped([[{}, {}]]), shaped([[{}, {}], [{}]])],
    ],
  ] as const)(
    'empties a body of %s with Select All and Backspace',
    async (_, body) => {
      expect.hasAssertions();
      const page = await open(body);
      page.editor.commands.selectAll();
      press(page, 'Backspace');
      expect(bodyOf(page)).toStrictEqual([paragraph('')]);
    },
  );

  it('cuts a selected kept table', async () => {
    expect.hasAssertions();
    const page = await open([shaped([[{}, {}], [{}]]), paragraph('after')]);
    const { editor } = page;
    editor.view.dispatch(
      editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, 0)),
    );
    editor.view.dispatch(
      editor.state.tr.deleteSelection().setMeta('uiEvent', 'cut'),
    );
    expect(bodyOf(page)).toStrictEqual([paragraph('after')]);
  });

  it('outlines the cell holding the caret, inside a frame that scrolls sideways', async () => {
    expect.hasAssertions();
    const page = await open(letter);
    const focused = () =>
      document.querySelector('.draft-focused-cell')?.textContent;
    page.editor.commands.setTextSelection(nth(cellsOf(page.editor), 7) + 1);
    const inCell = focused();
    press(page, 'Tab');
    const afterTab = focused();
    page.editor.commands.setTextSelection(2);
    expect({ inCell, afterTab, outside: focused() }).toStrictEqual({
      inCell: '2 Dec',
      afterTab: 'Tomáš',
      outside: undefined,
    });
    expect(document.querySelector('.draft-table > table')).not.toBeNull();
    const html = pageHtml();
    expect(html).toContain('.ProseMirror .draft-table { overflow-x: auto;');
    expect(html).toMatch(
      /\.draft-focused-cell \{ outline: 2px solid #3A3D44; outline-offset: -2px; \}/u,
    );
  });

  it('opens no nested table or Inline Image in a cell', async () => {
    expect.hasAssertions();
    const sketch: Asset = { ...photo, id: 'sketch001', name: 'Sketch.png' };
    const page = await open(letter, [photo]);
    page.editor.commands.setTextSelection(nth(cellsOf(page.editor), 7) + 5);
    // A pasted table keeps only its text, in a cell as anywhere else.
    page.editor.view.pasteHTML('<table><tr><td>-nested</td></tr></table>');
    const table = bodyOf(page)?.[1];
    ok(table?.kind === 'table', 'Expected the table');
    expect(table.rows[2]).toStrictEqual([
      cell('Meter readings'),
      cell('2 Dec-nested'),
      cell('Tomáš'),
    ]);
    const before = page.posted.length;
    // An image pasted or converted into a cell is refused; one added there becomes an Attachment.
    page.editor.view.pasteHTML('<p>x<img data-draft-asset="photo0001"></p>');
    page.command({ type: 'convert', id: photo.id });
    expect(
      page.posted
        .slice(before)
        .filter(({ document: body }) => body !== undefined),
    ).toStrictEqual([]);
    page.command({ type: 'add', images: [sketch], attachments: [] });
    expect(attachmentsOf(page)).toStrictEqual([photo, sketch]);
    expect(bodyOf(page)?.[1]).toStrictEqual(table);
  });
});
