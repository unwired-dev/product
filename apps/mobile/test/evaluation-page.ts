import { ok } from 'node:assert/strict';

import type {
  Asset,
  SemanticDocument,
} from '@private-email/mail-core/semantic-document';

import { commandScript } from '@private-email/draft-editor/messages';
import { AssetSchema } from '@private-email/mail-core/semantic-document';
import { act, fireEvent, screen } from '@testing-library/react-native';
import * as Schema from 'effect/Schema';

import { injectedScripts } from './webview.tsx';

// The command the host last sent its page.
export const lastCommand = () => injectedScripts.at(-1);

// That command as the page receives it.
const Assets = Schema.optionalKey(Schema.Array(AssetSchema));
const Previews = Schema.optionalKey(
  Schema.Record(Schema.String, Schema.NullOr(Schema.String)),
);
const SentSchema = Schema.fromJsonString(
  Schema.Struct({
    type: Schema.String,
    id: Schema.optionalKey(Schema.String),
    images: Assets,
    attachments: Assets,
    previews: Previews,
  }),
);
export const lastSent = () => {
  const [, json] =
    /^globalThis\.draftCommand\?\.\((?<json>.*)\); true;$/su.exec(
      lastCommand() ?? '',
    ) ?? [];
  return json === undefined ? undefined : Schema.decodeSync(SentSchema)(json);
};
// The assets the host last asked the page to add.
export const lastAdded = () => {
  const sent = lastSent();
  ok(sent?.type === 'add', 'Expected the page to add assets');
  return { images: sent.images ?? [], attachments: sent.attachments ?? [] };
};

// Each open page's body revision, which only grows until the page closes.
const revisions = new WeakMap<object, number>();

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
              revision: revisions.get(page) ?? 0,
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
export function simulatedPage(
  target = () => screen.getByTestId('message-webview'),
) {
  const report = async (
    state: Readonly<{
      // An earlier revision, for a report WebKit delivers late.
      revision?: number;
      frozen?: boolean;
      document?: SemanticDocument;
      attachments?: readonly Asset[];
      selection?: Readonly<{ start: number; end: number }>;
      marks?: readonly string[];
      kind?: string;
    }>,
  ) => {
    const page = target();
    const latest = revisions.get(page) ?? 0;
    const revision =
      state.revision ?? latest + (state.document === undefined ? 0 : 1);
    revisions.set(page, Math.max(latest, revision));
    await act(async () => {
      await fireEvent(page, 'message', {
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
    revision: () => revisions.get(target()) ?? 0,
  };
}
