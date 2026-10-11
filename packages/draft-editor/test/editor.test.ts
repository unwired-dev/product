// @vitest-environment happy-dom
import type { SemanticDocument } from '@private-email/mail-core/semantic-document';
import type { Editor } from '@tiptap/core';

import { SemanticDocumentSchema } from '@private-email/mail-core/semantic-document';
import * as Schema from 'effect/Schema';

import { pageHtml } from '../build.cjs';
import { supported } from '../src/conversion.ts';

const Change = Schema.fromJsonString(
  Schema.Struct({
    type: Schema.Literal('change'),
    document: SemanticDocumentSchema,
  }),
);

const opened: SemanticDocument = [
  { kind: 'paragraph', spans: [{ text: 'Dear Ana,' }] },
  { kind: 'paragraph', spans: [] },
  { kind: 'paragraph', spans: [{ text: 'Příliš žluťoučký kůň 🐎' }] },
];

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

  it('posts edits as Semantic Message Documents, and Undo restores the stored body', async () => {
    expect.hasAssertions();
    const posted: SemanticDocument[] = [];
    globalThis.ReactNativeWebView = {
      postMessage: (message) => {
        posted.push(Schema.decodeSync(Change)(message).document);
      },
    };
    globalThis.draftEditor = { document: opened, label: 'Message' };
    document.body.innerHTML = '<div id="editor"></div>';
    await import('../src/editor.ts');
    const view = document.querySelector<HTMLElement & { editor: Editor }>(
      '[role="textbox"]',
    );
    expect(view?.getAttribute('aria-label')).toBe('Message');
    const editor = view?.editor;

    // An Inline Image's character never enters a plain paragraph's text.
    editor?.chain().focus('end').insertContent(' Ahoj￼!').run();
    expect(posted.at(-1)).toStrictEqual([
      opened[0],
      opened[1],
      { kind: 'paragraph', spans: [{ text: 'Příliš žluťoučký kůň 🐎 Ahoj!' }] },
    ]);
    editor?.commands.undo();
    expect(posted.at(-1)).toStrictEqual(opened);
  });

  it('opens only bodies it can show without loss', () => {
    expect.hasAssertions();
    expect(supported(opened)).toBe(true);
    expect(
      supported([
        { kind: 'paragraph', spans: [{ text: 'x', marks: ['bold'] }] },
      ]),
    ).toBe(false);
    expect(supported([{ kind: 'heading1', spans: [{ text: 'x' }] }])).toBe(
      false,
    );
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
