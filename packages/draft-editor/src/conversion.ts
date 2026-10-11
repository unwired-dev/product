import type { SemanticDocument } from '@private-email/mail-core/semantic-document';
import type { JSONContent } from '@tiptap/core';

// The explicit boundary between the stored Semantic Message Document and Tiptap's JSON. The
// Draft stores only the Semantic Message Document; editor JSON never leaves the page.
// shortcut: plain paragraphs only; formatting, other blocks and Inline Images join with #819 and #820.

// The character an Inline Image occupies; typed or pasted text never stores it.
const imageCharacter = '￼';

// Whether the evaluation editor can show `document` without losing anything.
export const supported = (document: SemanticDocument) =>
  document.every(
    ({ kind, spans }) =>
      kind === 'paragraph' &&
      spans.every((span) => span.marks === undefined && !('image' in span)),
  );

export const toEditor = (document: SemanticDocument): JSONContent => ({
  type: 'doc',
  content: document.map(({ spans }) => {
    const text = spans.map((span) => span.text).join('');
    return text === ''
      ? { type: 'paragraph' }
      : { type: 'paragraph', content: [{ type: 'text', text }] };
  }),
});

// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Tiptap's JSON type is mutable; this only reads it.
export const fromEditor = (editor: JSONContent): SemanticDocument => {
  const [first = { kind: 'paragraph', spans: [] }, ...rest] = (
    editor.content ?? []
  ).map(({ content = [] }) => {
    const text = content
      .map((node) => node.text ?? '')
      .join('')
      .replaceAll(imageCharacter, '');
    return {
      kind: 'paragraph' as const,
      spans: text === '' ? [] : [{ text }],
    };
  });
  return [first, ...rest];
};
