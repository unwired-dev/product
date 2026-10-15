import type {
  Asset,
  SemanticDocument,
} from '@private-email/mail-core/semantic-document';

import { commandScript } from '@private-email/draft-editor/messages';
import { act, fireEvent, screen } from '@testing-library/react-native';

import { injectedScripts } from './webview.tsx';

// The command the host last sent its page.
export const lastCommand = () => injectedScripts.at(-1);

export const press = async (name: string | Readonly<RegExp>, flush = true) => {
  const button = await screen.findByRole('button', { name });
  await act(async () => {
    await fireEvent.press(button);
    // The native WebView boundary acknowledges a finishing command after queued edits.
    if (
      flush &&
      lastCommand() === commandScript({ type: 'editable', editable: false })
    ) {
      const page = screen.queryByTestId('message-webview', {
        includeHiddenElements: true,
      });
      if (page !== null) {
        void fireEvent(page, 'message', {
          nativeEvent: {
            data: JSON.stringify({
              type: 'update',
              frozen: true,
              revision: 0,
              selection: { start: 0, end: 0 },
              marks: [],
              kind: 'paragraph',
              undo: false,
              redo: false,
            }),
          },
        });
      }
    }
  });
};

// The packaged page, as the host sees it: after each edit or selection change it reports its
// state, with the whole body after an edit. `revision` counts its body edits.
export function simulatedPage() {
  let revision = 0;
  const report = async (
    state: Readonly<{
      frozen?: boolean;
      document?: SemanticDocument;
      attachments?: readonly Asset[];
      selection?: Readonly<{ start: number; end: number }>;
      marks?: readonly string[];
      kind?: string;
    }>,
  ) => {
    revision += state.document === undefined ? 0 : 1;
    await act(async () => {
      await fireEvent(screen.getByTestId('message-webview'), 'message', {
        nativeEvent: {
          data: JSON.stringify({
            type: 'update',
            revision,
            selection: { start: 0, end: 0 },
            marks: [],
            kind: 'paragraph',
            undo: revision > 0,
            redo: false,
            ...state,
          }),
        },
      });
    });
  };
  return {
    report,
    typed: async (text: string) =>
      report({ document: [{ kind: 'paragraph', spans: [{ text }] }] }),
    revision: () => revision,
  };
}
