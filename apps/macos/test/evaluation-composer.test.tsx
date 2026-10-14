import { ok } from 'node:assert/strict';

import type { Command } from '@private-email/draft-editor/messages';
import type { Draft } from '@private-email/mail-core/drafts';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type {
  Asset,
  SemanticDocument,
} from '@private-email/mail-core/semantic-document';

import { commandScript } from '@private-email/draft-editor/messages';
import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { mailboxesOf } from '@private-email/mail-core/registration';
import {
  AssetSchema,
  imagesOf,
} from '@private-email/mail-core/semantic-document';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import {
  createMockMailSession,
  syntheticReply,
  syntheticRewrite,
  syntheticTranslation,
} from '@private-email/mail-core/testing/mock-session';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-session';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';
import * as Schema from 'effect/Schema';
import { useMemo, useState } from 'react';

import { DraftComposer } from '../src/evaluation-composer.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { AssistanceContext } from '../src/message-summary.tsx';
import { AccountContext } from '../src/registration-gate.tsx';
import { TranslationContext } from '../src/translation.tsx';
import { injectedScripts } from './webview.tsx';

// What a `registration-draft-editor` build substitutes; the page itself runs only in WebKit.
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('@private-email/draft-editor/page', () => ({
  editorPage: '<!doctype html><title>Tiptap evaluation page</title>',
}));

const alex = syntheticMailboxes['alex@example.invalid'];
const registration = {
  getSnapshot: () => ({
    snapshot: {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      mailboxes: JSON.stringify([
        { id: alex, address: 'alex@example.invalid', state: 'connected' },
      ]),
    } satisfies RegistrationSnapshot,
    busy: false,
    failed: false,
  }),
  subscribe: () => () => undefined,
};

function App({ drafts }: { readonly drafts: ReturnType<typeof createDrafts> }) {
  const mailboxes = useMemo(
    () =>
      createMailboxes(
        syntheticConnections({ [alex]: createSyntheticGmail({ messages: 1 }) }),
        registration,
      ),
    [],
  );
  const [composing, setComposing] = useState<string>();
  return (
    <AccountContext
      value={{
        mailboxes: mailboxesOf(registration.getSnapshot().snapshot),
        openAccount: () => undefined,
        authorizeMailbox: () => Promise.resolve(),
        refreshInbox: (load) => load(),
      }}>
      <InboxProvider
        drafts={drafts}
        mailboxes={mailboxes}>
        <Inbox
          composing={composing}
          onCompose={setComposing}
          onSelect={() => undefined}
          selected={undefined}
        />
        {composing === undefined ? null : (
          <DraftComposer
            id={composing}
            onClose={() => {
              setComposing(undefined);
            }}
            onRebind={setComposing}
          />
        )}
      </InboxProvider>
    </AccountContext>
  );
}

const press = async (name: string | RegExp) => {
  const button = await screen.findByRole('button', { name });
  await act(async () => {
    await fireEvent.press(button);
  });
};

// The packaged page, as the host sees it: after each edit or selection change it reports its
// state, with the whole body after an edit. `revision` counts its body edits.
function simulatedPage() {
  let revision = 0;
  const report = async (
    state: Readonly<{
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
// The command the host last sent its page.
const lastCommand = () => injectedScripts.at(-1);
// That command as the page receives it.
const Assets = Schema.optionalKey(Schema.Array(AssetSchema));
const Previews = Schema.optionalKey(
  Schema.Record(Schema.String, Schema.String),
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
const lastSent = () => {
  const [, json] =
    /^globalThis\.draftCommand\?\.\((?<json>.*)\); true;$/su.exec(
      lastCommand() ?? '',
    ) ?? [];
  return json === undefined ? undefined : Schema.decodeSync(SentSchema)(json);
};
// The assets the host last asked the page to add.
const lastAdded = () => {
  const sent = lastSent();
  ok(sent?.type === 'add', 'Expected the page to add assets');
  return { images: sent.images ?? [], attachments: sent.attachments ?? [] };
};

describe('the Tiptap evaluation composer', () => {
  /* oxlint-disable vitest/max-expects -- The journey proves one evaluation path end to end. */
  it('saves page edits through the Draft store and reopens them after relaunch', async () => {
    expect.hasAssertions();
    injectedScripts.length = 0;
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const first = await render(
      <App drafts={createDrafts(storage.native, registration)} />,
    );
    await press('New Message');
    const { typed } = simulatedPage();
    await expect(
      screen.findByText('Evaluation editor'),
    ).resolves.toBeOnTheScreen();
    // The Draft row and the composer both name the sending mailbox.
    expect(screen.getAllByText('From alex@example.invalid')).toHaveLength(2);
    const page = screen.getByTestId('message-webview');
    // A non-persistent, cache-free WebKit view that never leaves its packaged page.
    expect(page).toHaveProp('incognito', true);
    expect(page).toHaveProp('cacheEnabled', false);
    expect(page).toHaveProp('source', {
      html: '<!doctype html><title>Tiptap evaluation page</title>',
    });
    expect(
      page.props.onShouldStartLoadWithRequest({
        url: 'about:blank',
        navigationType: 'other',
      }),
    ).toBe(true);
    expect([
      page.props.onShouldStartLoadWithRequest({
        url: 'https://example.com/',
        navigationType: 'other',
      }),
    ]).toStrictEqual([false]);
    expect(page.props.injectedJavaScriptBeforeContentLoaded).toBe(
      'window.draftEditor = {"document":[{"kind":"paragraph","spans":[]}],"attachments":[],"label":"Message body"}; true;',
    );

    await typed('Hello from Tiptap');
    await waitFor(() => {
      expect(
        screen.getByText('Draft · Saved on this device'),
      ).toBeOnTheScreen();
    });
    // A page message that is not a valid body changes nothing.
    await act(async () => {
      await fireEvent(page, 'message', {
        nativeEvent: {
          data: '{"type":"update","revision":1,"document":[],"selection":{"start":0,"end":0},"marks":[],"kind":"paragraph","undo":true,"redo":false}',
        },
      });
    });
    // Locked storage is visible, keeps the edit in memory, and blocks Close until a retry saves.
    storage.failNextCommit('locked');
    await typed('Hello from Tiptap, again');
    await waitFor(() => {
      expect(
        screen.getByText(
          'Draft · Not saved while private storage is locked. Unlock your device.',
        ),
      ).toBeOnTheScreen();
    });
    storage.failNextCommit('locked');
    await press('Close');
    expect(
      screen.getByText(
        'This Draft could not be saved, so it stays open. Try again once storage is available.',
      ),
    ).toBeOnTheScreen();
    // Editing again clears the failed Close's notice.
    await typed('Hello from Tiptap, again');
    expect(
      screen.queryByText(
        'This Draft could not be saved, so it stays open. Try again once storage is available.',
      ),
    ).not.toBeOnTheScreen();
    await press('Close');
    expect(screen.queryByText('Evaluation editor')).not.toBeOnTheScreen();
    // WebKit can queue a callback before Close removes the page. Retired pages cannot edit.
    await act(async () => {
      page.props.onMessage({
        nativeEvent: {
          data: JSON.stringify({
            type: 'update',
            revision: 99,
            document: [
              { kind: 'paragraph', spans: [{ text: 'Late closed page' }] },
            ],
            selection: { start: 0, end: 0 },
            marks: [],
            kind: 'paragraph',
            undo: true,
            redo: false,
          }),
        },
      });
    });
    await first.unmount();

    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    const [saved] = draftsOf(reopened.getSnapshot());
    ok(saved, 'Expected the saved Draft');
    expect(saved.body).toStrictEqual([
      { kind: 'paragraph', spans: [{ text: 'Hello from Tiptap, again' }] },
    ]);
    await render(<App drafts={reopened} />);
    await press(/^Draft\./u);
    expect(
      screen.getByTestId('message-webview').props
        .injectedJavaScriptBeforeContentLoaded,
    ).toContain('"spans":[{"text":"Hello from Tiptap, again"}]');
  });

  it('formats through page commands and applies reviewed assistance as one page edit', async () => {
    expect.hasAssertions();
    injectedScripts.length = 0;
    const mock = createMockMailSession('open-read-relaunch');
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await render(
      <AssistanceContext value={mock.assistance}>
        <TranslationContext value={mock.translation}>
          <App drafts={drafts} />
        </TranslationContext>
      </AssistanceContext>,
    );
    await press('New Message');
    const { report, typed, revision } = simulatedPage();
    const sent = (command: Command) => commandScript(command);
    // No control can send a command before the page reports that it is ready.
    expect(screen.queryByRole('toolbar', { name: 'Formatting' })).toBeNull();
    await report({});
    // Formatting and history controls each send one command; the page reports what is active.
    await press('Bold');
    expect(lastCommand()).toBe(sent({ type: 'mark', mark: 'bold' }));
    await press('Numbered list');
    await press('Numbered list');
    expect(injectedScripts.slice(-2)).toStrictEqual([
      sent({ type: 'block', kind: 'numbered' }),
      sent({ type: 'block', kind: 'numbered' }),
    ]);
    expect(screen.getByRole('button', { name: 'Undo' })).toBeDisabled();
    const body: SemanticDocument = [
      { kind: 'heading1', spans: [{ text: 'Plan' }] },
      {
        kind: 'numbered',
        spans: [{ text: 'lets ', marks: ['bold'] }, { text: 'meet friday' }],
      },
    ];
    await report({ document: body, marks: ['bold'], kind: 'numbered' });
    expect(screen.getByRole('button', { name: 'Bold' })).toBeSelected();
    expect(
      screen.getByRole('button', { name: 'Numbered list' }),
    ).toBeSelected();
    await press('Undo');
    await press('Undo');
    expect(injectedScripts.slice(-2)).toStrictEqual([
      sent({ type: 'undo' }),
      sent({ type: 'undo' }),
    ]);

    // Rewrite without a selection captures the whole body; the result replaces it in the page,
    // for the body revision it was captured from.
    await press('Rewrite the message body');
    await screen.findByText(syntheticRewrite);
    await press('Replace your text with this rewrite');
    expect(lastCommand()).toBe(
      sent({
        type: 'replace',
        revision: revision(),
        document: [{ kind: 'heading1', spans: [{ text: syntheticRewrite }] }],
        selection: { start: 32, end: 32 },
      }),
    );
    expect(screen.queryByLabelText('Rewrite of your text')).toBeNull();
    // An edit retires a pending capture: its result is never offered.
    await report({ selection: { start: 9, end: 13 } });
    await press('Translate the selected text');
    await fireEvent.press(
      await screen.findByRole('radio', { name: 'Translate into German' }),
    );
    await screen.findByText(syntheticTranslation);
    await typed('Plan B');
    expect(screen.queryByText(syntheticTranslation)).toBeNull();

    // A selected translation replaces exactly the selected text in the reported body.
    const latest: SemanticDocument = [
      { kind: 'quote', spans: [{ text: 'Hola amigos' }] },
    ];
    await report({ document: latest, selection: { start: 5, end: 11 } });
    await press('Translate the selected text');
    await fireEvent.press(
      await screen.findByRole('radio', { name: 'Translate into German' }),
    );
    await screen.findByText(syntheticTranslation);
    await press('Replace the selected text with this translation');
    const replaced = `Hola ${syntheticTranslation}`;
    expect(lastCommand()).toBe(
      sent({
        type: 'replace',
        revision: revision(),
        document: [{ kind: 'quote', spans: [{ text: replaced }] }],
        selection: { start: replaced.length, end: replaced.length },
      }),
    );
    // The page's next update carries the replacement, which saves like any edit.
    await report({
      document: [{ kind: 'quote', spans: [{ text: replaced }] }],
    });
    await waitFor(() => {
      expect(
        screen.getByText('Draft · Saved on this device'),
      ).toBeOnTheScreen();
    });
    expect(draftsOf(drafts.getSnapshot())[0]?.body).toStrictEqual([
      { kind: 'quote', spans: [{ text: replaced }] },
    ]);
  });

  it.each(['onError', 'onContentProcessDidTerminate'])(
    'retires captures and queued page input when the page reports %s',
    async (event) => {
      expect.hasAssertions();
      injectedScripts.length = 0;
      const mock = createMockMailSession('open-read-relaunch');
      const storage = createSyntheticDrafts(() => 'synthetic-product-account');
      const drafts = createDrafts(storage.native, registration);
      await render(
        <AssistanceContext value={mock.assistance}>
          <App drafts={drafts} />
        </AssistanceContext>,
      );
      await press('New Message');
      const { typed } = simulatedPage();
      await typed('Keep this body');
      await press('Rewrite the message body');
      await screen.findByText(syntheticRewrite);
      const apply = screen.getByRole('button', {
        name: 'Replace your text with this rewrite',
      });
      const page = screen.getByTestId('message-webview');
      const scripts = injectedScripts.length;
      const before = draftsOf(drafts.getSnapshot())[0]?.body;
      // Failure and already-queued callbacks can arrive before React removes the page/panel.
      await act(async () => {
        page.props[event]();
        await fireEvent.press(apply);
        page.props.onMessage({
          nativeEvent: {
            data: JSON.stringify({
              type: 'update',
              revision: 2,
              document: [
                { kind: 'paragraph', spans: [{ text: 'Late stopped page' }] },
              ],
              selection: { start: 0, end: 0 },
              marks: [],
              kind: 'paragraph',
              undo: true,
              redo: false,
            }),
          },
        });
      });
      expect(screen.queryByText(syntheticRewrite)).toBeNull();
      expect(screen.queryByTestId('message-webview')).toBeNull();
      expect(injectedScripts).toHaveLength(scripts);
      expect(draftsOf(drafts.getSnapshot())[0]?.body).toBe(before);
    },
  );

  it('suggests a reply in a reply Draft and replaces the whole authored body', async () => {
    expect.hasAssertions();
    injectedScripts.length = 0;
    const mock = createMockMailSession('open-read-relaunch');
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await render(
      <AssistanceContext value={mock.assistance}>
        <App drafts={drafts} />
      </AssistanceContext>,
    );
    await press('New Message');
    await simulatedPage().report({});
    expect(
      screen.queryByRole('button', {
        name: 'Suggest a reply to the quoted message',
      }),
    ).toBeNull();
    const [draft] = draftsOf(drafts.getSnapshot());
    ok(draft, 'Expected a Draft');
    const reply: Draft = {
      ...draft,
      to: [{ name: 'Rowan Hale', address: 'rowan@example.invalid' }],
      cc: [{ name: 'Oliver Park', address: 'oliver@example.invalid' }],
      bcc: [{ address: 'hidden@example.invalid' }],
      subject: 'Re: Garden plans',
      body: [{ kind: 'paragraph', spans: [{ text: 'Thanks' }] }],
      quoted: [{ kind: 'paragraph', spans: [{ text: 'Can we meet?' }] }],
      response: {
        kind: 'reply',
        message: 'synthetic-message',
        thread: { connection: draft.connection, id: 'synthetic-thread' },
        references: [],
      },
    };
    await act(async () => {
      await drafts.update(reply, draft);
    });
    await press('Close');
    // The reopened page starts again at its first body revision.
    await press(/^Draft\./u);
    await simulatedPage().report({});
    await press('Suggest a reply to the quoted message');
    await screen.findByText(syntheticReply);
    await press('Replace your reply with this suggestion');
    expect(lastCommand()).toBe(
      commandScript({
        type: 'replace',
        revision: 0,
        document: [{ kind: 'paragraph', spans: [{ text: syntheticReply }] }],
        selection: { start: syntheticReply.length, end: syntheticReply.length },
      }),
    );
    // The page's authored-body update must retain all excluded content through durable reopen.
    await simulatedPage().report({
      document: [{ kind: 'paragraph', spans: [{ text: syntheticReply }] }],
    });
    await press('Close');
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    const [saved] = draftsOf(reopened.getSnapshot());
    ok(saved, 'Expected the saved reply');
    expect(saved).toStrictEqual({
      ...reply,
      body: [{ kind: 'paragraph', spans: [{ text: syntheticReply }] }],
      updatedAt: saved.updatedAt,
    });
  });

  it('adds, converts and removes Inline Images and Attachments through native imports', async () => {
    expect.hasAssertions();
    injectedScripts.length = 0;
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    const first = await render(<App drafts={drafts} />);
    await press('New Message');
    const { report } = simulatedPage();
    await report({});
    // The photo goes inline at the page's selection; native code imports it meanwhile.
    storage.holdImports();
    storage.addFile('file:///chart.png', 'chart');
    storage.pickNext('photos', [
      { uri: 'file:///chart.png', name: 'chart.png', type: 'image/png' },
    ]);
    await press('Insert Image…');
    const [chart] = lastAdded().images;
    ok(chart, 'Expected the inline photo');
    const body = (...spans: SemanticDocument[number]['spans']) =>
      [{ kind: 'paragraph', spans }] as const;
    await report({
      document: body({ text: 'Hi ' }, { text: '￼', image: chart }),
      attachments: [],
    });
    await screen.findByLabelText('chart.png, Adding…');
    // Typing while the import completes neither loses the edit nor makes a conflicting copy, and
    // the page's older copy of the asset cannot undo its completion.
    await report({
      document: body(
        { text: 'Hi ' },
        { text: '￼', image: chart },
        { text: ' there' },
      ),
      attachments: [],
    });
    await act(async () => {
      storage.releaseImports();
    });
    await report({
      document: body(
        { text: 'Hi ' },
        { text: '￼', image: chart },
        { text: ' there!' },
      ),
      attachments: [],
    });
    await waitFor(() => {
      expect(drafts.getSnapshot()).toMatchObject({ save: 'saved' });
    });
    const [saved] = draftsOf(drafts.getSnapshot());
    ok(saved, 'Expected the saved Draft');
    const [complete] = imagesOf(saved.body);
    ok(complete?.state === 'complete', 'Expected the completed photo');
    // The page receives only the native thumbnail of verified bytes.
    await waitFor(() => {
      expect(lastSent()).toStrictEqual({
        type: 'previews',
        previews: { [chart.id]: 'data:image/png;base64,Y2hhcnQ=' },
      });
    });
    // A file from the Files picker is attached; converting and removing are page edits.
    storage.addFile('file:///plan.pdf', 'plan');
    storage.pickNext('files', [
      { uri: 'file:///plan.pdf', name: 'plan.pdf', type: 'application/pdf' },
    ]);
    await press('Attach Files…');
    const attached = lastAdded();
    const [plan] = attached.attachments;
    ok(plan, 'Expected the attached file');
    await press('Attach chart.png instead of showing it inline');
    const converted = lastSent();
    // The page refused a paste carrying images; the Mac adds nothing for it yet.
    await act(async () => {
      await fireEvent(screen.getByTestId('message-webview'), 'message', {
        nativeEvent: { data: '{"type":"paste"}' },
      });
    });
    const pasted = lastSent();
    // The page can name only assets the host gave it.
    const forged = {
      id: 'forged000001',
      name: 'forged.png',
      type: 'image/png',
      state: 'complete',
      size: 1,
      digest: 'f'.repeat(64),
    } as const;
    await report({
      document: body({ text: 'Hi ' }, { text: '￼', image: forged }),
      attachments: [plan, chart, forged],
    });
    await press('Remove plan.pdf');
    expect({
      attached: attached.images,
      converted,
      pasted,
      removed: lastSent(),
      stored: draftsOf(drafts.getSnapshot())[0],
    }).toMatchObject({
      attached: [],
      converted: { type: 'convert', id: chart.id },
      pasted: converted,
      removed: { type: 'remove', id: plan.id },
      stored: {
        body: body({ text: 'Hi ' }),
        attachments: [
          { name: 'plan.pdf', state: 'complete' },
          { id: chart.id, state: 'complete' },
        ],
      },
    });
    await press('Close');
    await first.unmount();
    // Reopening gives the page the stored body and Attachments, with the same asset identities.
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    await render(<App drafts={reopened} />);
    await press(/^Draft\./u);
    const injected = String(
      screen.getByTestId('message-webview').props
        .injectedJavaScriptBeforeContentLoaded,
    );
    expect(injected).toContain(`"id":"${chart.id}"`);
  });

  it('cancels imports, shows damaged bytes and completes an import after Close', async () => {
    expect.hasAssertions();
    injectedScripts.length = 0;
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    const first = await render(<App drafts={drafts} />);
    await press('New Message');
    const { report } = simulatedPage();
    await report({});
    const insert = async (name: string) => {
      storage.addFile(`file:///${name}`, name);
      storage.pickNext('photos', [
        { uri: `file:///${name}`, name, type: 'image/png' },
      ]);
      await press('Insert Image…');
      const [image] = lastAdded().images;
      ok(image, 'Expected the photo');
      return image;
    };
    storage.holdImports();
    const cancelled = await insert('cancelled.png');
    await report({
      document: [
        {
          kind: 'paragraph',
          spans: [{ text: '￼', image: cancelled }],
        },
      ],
      attachments: [],
    });
    await press('Cancel adding cancelled.png');
    await screen.findByLabelText('cancelled.png, Not added: cancelled');
    const late = await insert('late.png');
    await report({
      document: [
        {
          kind: 'paragraph',
          spans: [
            { text: '￼', image: cancelled },
            { text: '￼', image: late },
          ],
        },
      ],
      attachments: [],
    });
    // Closing waits only for the save; the import completes into the stored Draft.
    await press('Close');
    await act(async () => {
      storage.releaseImports();
    });
    await waitFor(() => {
      const [stored] = draftsOf(drafts.getSnapshot());
      ok(stored, 'Expected the stored Draft');
      expect(imagesOf(stored.body).map(({ state }) => state)).toStrictEqual([
        'cancelled',
        'complete',
      ]);
    });
    await first.unmount();
    // Bytes that no longer verify are listed as damaged, and the page gets no thumbnail.
    storage.damage(late.id);
    injectedScripts.length = 0;
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    await render(<App drafts={reopened} />);
    await press(/^Draft\./u);
    await simulatedPage().report({});
    await screen.findByLabelText('late.png, 8 bytes · Damaged on this device');
    expect(
      injectedScripts.filter((script) => script.includes('"previews"')),
    ).toStrictEqual([]);
  });
});
