import { ok } from 'node:assert/strict';

import type { Command } from '@private-email/draft-editor/messages';
import type { Draft } from '@private-email/mail-core/drafts';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type { SemanticDocument } from '@private-email/mail-core/semantic-document';

import { commandScript } from '@private-email/draft-editor/messages';
import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { mailboxesOf } from '@private-email/mail-core/registration';
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
import { useMemo, useState } from 'react';

import { DraftComposer } from '../src/evaluation-composer.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { AssistanceContext } from '../src/message-summary.tsx';
import { AccountContext } from '../src/registration-gate.tsx';
import { TranslationContext } from '../src/translation.tsx';
import { injectedScripts } from './webview.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));
// oxlint-disable-next-line vitest/prefer-import-in-mock -- The Inbox's keyboard avoidance reads the inset; the host has none here.
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, left: 0, right: 0, bottom: 0 }),
}));
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
      'window.draftEditor = {"document":[{"kind":"paragraph","spans":[]}],"label":"Message body"}; true;',
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
    // The page stops editing so the software keyboard does not cover the review.
    expect(lastCommand()).toBe(sent({ type: 'blur' }));
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

  it('leaves a Draft with an Inline Image unchanged instead of opening it', async () => {
    expect.hasAssertions();
    injectedScripts.length = 0;
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await render(<App drafts={drafts} />);
    await press('New Message');
    const [draft] = draftsOf(drafts.getSnapshot());
    ok(draft, 'Expected a Draft');
    const withImage = {
      ...draft,
      body: [
        {
          kind: 'paragraph',
          spans: [
            {
              text: '\uFFFC',
              image: {
                id: 'abcdefgh',
                name: 'a.png',
                type: 'image/png',
                state: 'importing',
              },
            },
          ],
        },
      ] as const,
    };
    await act(async () => {
      await drafts.update(withImage, draft);
    });
    await expect(
      screen.findByText(
        'The evaluation editor does not open Drafts with inline images yet, so this Draft stays unchanged. Close it to return to the Inbox.',
      ),
    ).resolves.toBeOnTheScreen();
    expect(screen.queryByTestId('message-webview')).not.toBeOnTheScreen();
    expect(draftsOf(drafts.getSnapshot())[0]?.body).toStrictEqual(
      withImage.body,
    );
  });
});
