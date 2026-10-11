// The page's script: Tiptap core over plain paragraphs, posting each change to the host as a
// Semantic Message Document. The host injects `draftEditor` before this script runs.
import type { SemanticDocument } from '@private-email/mail-core/semantic-document';

import { Editor } from '@tiptap/core';
import Document from '@tiptap/extension-document';
import Paragraph from '@tiptap/extension-paragraph';
import Text from '@tiptap/extension-text';
import { UndoRedo } from '@tiptap/extensions';

import { fromEditor, toEditor } from './conversion.ts';

declare global {
  var draftEditor:
    | Readonly<{ document: SemanticDocument; label: string }>
    | undefined;
  var ReactNativeWebView:
    | Readonly<{ postMessage: (message: string) => void }>
    | undefined;
}

const { draftEditor, ReactNativeWebView } = globalThis;
const element = document.querySelector('#editor');
if (draftEditor !== undefined && element !== null) {
  // oxlint-disable-next-line no-new -- The editor lives as long as the page.
  new Editor({
    element,
    extensions: [Document, Paragraph, Text, UndoRedo],
    content: toEditor(draftEditor.document),
    editorProps: {
      attributes: {
        'aria-label': draftEditor.label,
        'aria-multiline': 'true',
        role: 'textbox',
      },
    },
    onUpdate: ({ editor }) => {
      const change = JSON.stringify({
        type: 'change',
        document: fromEditor(editor.getJSON()),
      });
      // oxlint-disable-next-line unicorn/require-post-message-target-origin -- The native bridge, not a window.
      ReactNativeWebView?.postMessage(change);
    },
  });
}
