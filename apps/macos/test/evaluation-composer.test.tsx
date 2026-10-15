import { ok } from 'node:assert/strict';

import type { Command } from '@private-email/draft-editor/messages';
import type { Draft } from '@private-email/mail-core/drafts';
import type { SemanticDocument } from '@private-email/mail-core/semantic-document';

import { commandScript } from '@private-email/draft-editor/messages';
import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { imagesOf } from '@private-email/mail-core/semantic-document';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import {
  createMockMailSession,
  syntheticReply,
  syntheticRewrite,
  syntheticTranslation,
} from '@private-email/mail-core/testing/mock-session';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';
import { View } from 'react-native';

import { AssistanceContext } from '../src/message-summary.tsx';
import { TranslationContext } from '../src/translation.tsx';
import { App, alex, registration } from './evaluation-app.tsx';
import {
  lastAdded,
  lastCommand,
  lastSent,
  press,
  simulatedPage,
} from './evaluation-page.ts';
import { injectedScripts } from './webview.tsx';

// What a `registration-draft-editor` build substitutes; the page itself runs only in WebKit.
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('@private-email/draft-editor/page', () => ({
  editorPage: '<!doctype html><title>Tiptap evaluation page</title>',
}));

// Chooses `title` in the system context menu around `element`.
const choose = async (
  element: ReturnType<typeof screen.getByText>,
  title: string,
) => {
  let menu = element.parent;
  while (menu !== null && menu.type !== 'UnwiredContextMenu') {
    menu = menu.parent;
  }
  ok(menu, 'Expected a context menu');
  const sections: ReadonlyArray<{
    items: ReadonlyArray<{ id: string; title: string }>;
  }> = menu.props.sections;
  const item = sections
    .flatMap(({ items }) => items)
    .find((each) => each.title === title);
  ok(item, `Expected ${title}`);
  const select: (event: { nativeEvent: { id: string } }) => void =
    menu.props.onSelect;
  await act(async () => {
    select({ nativeEvent: { id: item.id } });
  });
};
const saveBlocked =
  'This Draft could not be saved, so it stays open. Try again, or discard it.';
// Reopens a saved Draft while its native import is pending, then completes it before an exit.
async function settledImport(action: 'save' | 'delete' | 'unchanged') {
  const storage = createSyntheticDrafts(() => 'synthetic-product-account');
  const drafts = createDrafts(storage.native, registration);
  await drafts.load();
  const id = await drafts.create({ id: alex, address: 'alex@example.invalid' });
  ok(id, 'Expected a Draft');
  const [original] = draftsOf(drafts.getSnapshot());
  ok(original, 'Expected the created Draft');
  storage.addFile('file:///pending.png', 'pending');
  const asset = drafts.prepare({ name: 'pending.png', type: 'image/png' });
  await drafts.update({ ...original, attachments: [asset] }, original);
  storage.holdImports();
  const importing = drafts.importAsset(asset, {
    kind: 'file',
    uri: 'file:///pending.png',
  });
  await render(<App drafts={drafts} />);
  await press(/^Draft\./u);
  await act(async () => {
    storage.releaseImports();
    await importing;
  });
  if (action !== 'unchanged') {
    await act(async () => {
      fireEvent.changeText(
        screen.getByLabelText('Subject'),
        'Edited after import',
      );
    });
  }
  await press('Close');
  if (action !== 'unchanged') {
    await press(action === 'save' ? 'Save' : 'Don’t Save');
  }
  return { drafts, id };
}

describe('the Tiptap evaluation composer', () => {
  /* oxlint-disable vitest/max-expects -- The journey proves one evaluation path end to end. */

  it('keeps background composer controls out of the save decision', async () => {
    expect.hasAssertions();
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await render(<App drafts={drafts} />);
    await press('New Message');
    const { typed } = simulatedPage();
    await typed('An unsaved message');
    const send = screen.getByRole('button', { name: 'Send' });
    const focus = jest.spyOn(View.prototype, 'focus');
    try {
      await press('Close');
      // Native View methods are substituted here; these are focus requests, not AppKit evidence.
      expect(focus.mock.contexts.at(-1)?.props.onFocus).toBe(
        screen.getByRole('button', { name: 'Save' }).props.onFocus,
      );
      for (const [from, event, shiftKey, to] of [
        ['Save', 'focus', true, 'Cancel'],
        ['Cancel', 'focus', false, 'Save'],
        ['Save', 'blur', false, 'Save'],
        ['Save', 'blur', true, 'Cancel'],
      ] as const) {
        const button = screen.getByRole('button', { name: from });
        await fireEvent(button, 'focus');
        await fireEvent(button, event);
        focus.mockClear();
        await fireEvent(
          screen.getByText('Do you want to save this message as a draft?'),
          'keyDown',
          {
            nativeEvent: {
              key: 'Tab',
              shiftKey,
              metaKey: false,
              ctrlKey: false,
              altKey: false,
            },
          },
        );
        expect(focus.mock.contexts.at(-1)?.props.onFocus).toBe(
          screen.getByRole('button', { name: to }).props.onFocus,
        );
      }
      expect(screen.getByRole('button', { name: 'Save' })).toBeOnTheScreen();
      expect(screen.queryByRole('button', { name: 'Send' })).toBeNull();
      expect(screen.queryByLabelText('Subject')).toBeNull();
      await act(async () => {
        await fireEvent.press(send);
      });
      expect(screen.getByRole('button', { name: 'Save' })).toBeOnTheScreen();
      expect(draftsOf(drafts.getSnapshot())[0]?.body).toStrictEqual([
        { kind: 'paragraph', spans: [] },
      ]);
      await fireEvent(
        screen.getByText('Do you want to save this message as a draft?'),
        'keyDown',
        {
          nativeEvent: {
            key: 'Escape',
            shiftKey: false,
            metaKey: false,
            ctrlKey: false,
            altKey: false,
          },
        },
      );
      expect(screen.getByRole('button', { name: 'Send' })).toBeOnTheScreen();
      expect(screen.getByLabelText('Subject')).toBeOnTheScreen();
      await press('Close');
      await press('Save');
      expect(draftsOf(drafts.getSnapshot())[0]?.body).toStrictEqual([
        { kind: 'paragraph', spans: [{ text: 'An unsaved message' }] },
      ]);
    } finally {
      focus.mockRestore();
    }
  });

  it('keeps edits in the editor until Save, and reopens them after relaunch', async () => {
    expect.hasAssertions();
    injectedScripts.length = 0;
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    const first = await render(<App drafts={drafts} />);
    await press('New Message');
    const { typed } = simulatedPage();
    const page = await screen.findByTestId('message-webview');
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

    // Edits stay in the editor: nothing is saved, and no saving status is shown.
    await typed('Hello from Tiptap');
    expect(screen.queryByText(/^Draft · /u)).toBeNull();
    expect(draftsOf(drafts.getSnapshot())[0]?.body).toStrictEqual([
      { kind: 'paragraph', spans: [] },
    ]);
    // A page message that is not a valid body changes nothing.
    await act(async () => {
      await fireEvent(page, 'message', {
        nativeEvent: {
          data: '{"type":"update","revision":1,"document":[],"selection":{"start":0,"end":0},"marks":[],"kind":"paragraph","undo":true,"redo":false}',
        },
      });
    });
    // Close asks first; a Save Draft that storage refuses keeps the editor open to try again.
    await press('Close');
    storage.setLocked(true);
    await press('Save');
    expect(screen.getByText(saveBlocked)).toBeOnTheScreen();
    expect(page).toBeOnTheScreen();
    // Editing again clears the notice, and the unsaved edit still asks on Close.
    await typed('Hello from Tiptap, again');
    expect(screen.queryByText(saveBlocked)).not.toBeOnTheScreen();
    storage.setLocked(false);
    await press('Close');
    await press('Save');
    expect(screen.queryByTestId('message-webview')).toBeNull();
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
    // An unchanged Draft closes without asking.
    await press('Close');
    expect(screen.queryByTestId('message-webview')).toBeNull();
    expect(draftsOf(reopened.getSnapshot())).toHaveLength(1);
  });

  it('includes queued page edits before Save and locks editing until storage finishes', async () => {
    expect.hasAssertions();
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await render(<App drafts={drafts} />);
    await press('New Message');
    const page = simulatedPage();
    await page.typed('Before Close');
    storage.hold();
    await press('Close');
    await press('Save', false);
    // WebKit may still have a text update queued when the native Save control is pressed.
    await page.typed('Last queued edit');
    await page.report({ frozen: true });
    expect(screen.getByLabelText('Subject')).toHaveProp('editable', false);
    await act(async () => {
      storage.release();
    });
    await waitFor(() => {
      expect(screen.queryByTestId('message-webview')).toBeNull();
    });
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    expect(draftsOf(reopened.getSnapshot())[0]?.body).toStrictEqual([
      { kind: 'paragraph', spans: [{ text: 'Last queued edit' }] },
    ]);
  });

  it('asks to save a queued edit instead of discarding an apparently empty Draft', async () => {
    expect.hasAssertions();
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await render(<App drafts={drafts} />);
    await press('New Message');
    const page = simulatedPage();
    await page.report({});
    await press('Close', false);
    await page.typed('Queued before Close');
    await page.report({ frozen: true });
    expect(screen.getByRole('button', { name: 'Save' })).toBeOnTheScreen();
    await press('Don’t Save');
    expect(draftsOf(drafts.getSnapshot())).toStrictEqual([]);
  });

  it.each([
    ['save', ['Edited after import']],
    ['delete', []],
    ['unchanged', ['']],
  ] as const)(
    'keeps the saved baseline current when an import finishes before %s',
    async (action, subjects) => {
      expect.hasAssertions();
      const { drafts, id } = await settledImport(action);
      expect(screen.queryByTestId('message-webview')).toBeNull();
      const saved = draftsOf(drafts.getSnapshot());
      expect(saved.map(({ subject }) => subject)).toStrictEqual(subjects);
      expect(
        saved.map(({ id: current, conflict }) => [current, conflict]),
      ).toStrictEqual(subjects.map(() => [id, undefined]));
    },
  );

  it('removes an empty Draft on Close, deletes an edited one, and stores a refused Send', async () => {
    expect.hasAssertions();
    injectedScripts.length = 0;
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await render(<App drafts={drafts} />);
    await press('New Message');
    await screen.findByTestId('message-webview');
    expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
    await press('Close');
    expect(screen.queryByRole('button', { name: 'Save' })).toBeNull();
    expect(draftsOf(drafts.getSnapshot())).toStrictEqual([]);

    await press('New Message');
    await simulatedPage().typed('Never mind');
    await press('Close');
    await press('Don’t Save');
    expect(screen.queryByTestId('message-webview')).toBeNull();
    expect(draftsOf(drafts.getSnapshot())).toStrictEqual([]);

    // Send without recipients stays open with its reason, and the shown version is stored.
    await press('New Message');
    await simulatedPage().typed('Hello');
    await press('Send');
    expect(
      screen.getByText('Add a recipient before sending.'),
    ).toBeOnTheScreen();
    expect(draftsOf(drafts.getSnapshot())[0]?.body).toStrictEqual([
      { kind: 'paragraph', spans: [{ text: 'Hello' }] },
    ]);
  });

  it('formats through page commands and applies reviewed writing tools as one page edit', async () => {
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
    await press('Writing tools');
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
    await press('Writing tools');
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
    await press('Writing tools');
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
    // The page's next update carries the replacement, which Save Draft stores like any edit.
    await report({
      document: [{ kind: 'quote', spans: [{ text: replaced }] }],
    });
    await press('Close');
    await press('Save');
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
      await press('Writing tools');
      await press('Rewrite the message body');
      await screen.findByText(syntheticRewrite);
      const apply = screen.getByRole('button', {
        name: 'Replace your text with this rewrite',
      });
      const page = screen.getByTestId('message-webview');
      const scripts = injectedScripts.length;
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
      // The body the page last reported can still be saved.
      await press('Close');
      await press('Save');
      expect(draftsOf(drafts.getSnapshot())[0]?.body).toStrictEqual([
        { kind: 'paragraph', spans: [{ text: 'Keep this body' }] },
      ]);
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
    await press('Writing tools');
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
    await press('Writing tools');
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
    await press('Save');
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
    const pick = press;
    // The photo goes inline at the page's selection; native code imports it meanwhile.
    storage.holdImports();
    storage.addFile('file:///chart.png', 'chart');
    storage.pickNext('photos', [
      { uri: 'file:///chart.png', name: 'chart.png', type: 'image/png' },
    ]);
    await pick('Insert Image…');
    const [chart] = lastAdded().images;
    ok(chart, 'Expected the inline photo');
    const body = (...spans: SemanticDocument[number]['spans']) =>
      [{ kind: 'paragraph', spans }] as const;
    await report({
      document: body({ text: 'Hi ' }, { text: '￼', image: chart }),
      attachments: [],
    });
    await screen.findByLabelText('chart.png, Adding…');
    // Typing while the import completes keeps the edit, and the page's older copy of the asset
    // cannot undo its completion.
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
    await pick('Attach Files…');
    const attached = lastAdded();
    const [plan] = attached.attachments;
    ok(plan, 'Expected the attached file');
    // Secondary-clicking the image offers Attach Instead, and VoiceOver offers it as an action.
    const chip = screen.getByLabelText(/^chart\.png, /u);
    await choose(chip, 'Attach Instead');
    const converted = lastSent();
    await act(async () => {
      await fireEvent(chip, 'accessibilityAction', {
        nativeEvent: { actionName: 'convert' },
      });
    });
    expect(lastSent()).toStrictEqual(converted);
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
    const removed = lastSent();
    await press('Close');
    await press('Save');
    expect({
      attached: attached.images,
      converted,
      pasted,
      removed,
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

  it('cancels imports, shows damaged bytes and completes an import after Save', async () => {
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
    // Save Draft waits only for the save; the import completes into the stored Draft.
    await press('Close');
    await press('Save');
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

  it('sends the page a thumbnail once a locked image can be read again', async () => {
    expect.hasAssertions();
    injectedScripts.length = 0;
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await render(<App drafts={drafts} />);
    await press('New Message');
    const { report } = simulatedPage();
    await report({});
    storage.addFile('file:///chart.png', 'chart');
    storage.pickNext('photos', [
      { uri: 'file:///chart.png', name: 'chart.png', type: 'image/png' },
    ]);
    await press('Insert Image…');
    const [chart] = lastAdded().images;
    ok(chart, 'Expected the inline photo');
    await report({
      document: [
        { kind: 'paragraph', spans: [{ text: '\uFFFC', image: chart }] },
      ],
      attachments: [],
    });
    await press('Close');
    await press('Save');
    // Reopened while private storage is locked, the image cannot be checked yet.
    storage.setLocked(true);
    injectedScripts.length = 0;
    await press(/^Draft\./u);
    await simulatedPage().report({});
    const retry = await screen.findByRole('button', {
      name: 'Check chart.png again',
    });
    expect(
      injectedScripts.filter((script) => script.includes('"previews"')),
    ).toStrictEqual([]);
    // The row's Try again reads it again, and the page shows the same thumbnail.
    storage.setLocked(false);
    await act(async () => {
      await fireEvent.press(retry);
    });
    await waitFor(() => {
      expect(lastSent()).toStrictEqual({
        type: 'previews',
        previews: { [chart.id]: 'data:image/png;base64,Y2hhcnQ=' },
      });
    });
    await choose(screen.getByText('chart.png'), 'Attach Instead');
    const nextPage = simulatedPage();
    await nextPage.report({
      document: [{ kind: 'paragraph', spans: [] }],
      attachments: [chart],
    });
    storage.setLocked(true);
    await choose(screen.getByText('chart.png'), 'Show Inline');
    await nextPage.report({
      document: [
        { kind: 'paragraph', spans: [{ text: '\uFFFC', image: chart }] },
      ],
      attachments: [],
    });
    await screen.findByLabelText(
      'chart.png, 5 bytes · Not checked while private storage is locked',
    );
    expect(lastSent()).toStrictEqual({
      type: 'previews',
      previews: { [chart.id]: null },
    });
    storage.setLocked(false);
    await press('Check chart.png again');
    await waitFor(() => {
      expect(lastSent()).toStrictEqual({
        type: 'previews',
        previews: { [chart.id]: 'data:image/png;base64,Y2hhcnQ=' },
      });
    });
  });

  it('keeps an import that a queued Cancel reaches after Save starts', async () => {
    expect.hasAssertions();
    injectedScripts.length = 0;
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await render(<App drafts={drafts} />);
    await press('New Message');
    const { report } = simulatedPage();
    await report({});
    storage.holdImports();
    storage.addFile('file:///chart.png', 'chart');
    storage.pickNext('photos', [
      { uri: 'file:///chart.png', name: 'chart.png', type: 'image/png' },
    ]);
    await press('Insert Image…');
    const [chart] = lastAdded().images;
    ok(chart, 'Expected the inline photo');
    await report({
      document: [
        { kind: 'paragraph', spans: [{ text: '\uFFFC', image: chart }] },
      ],
      attachments: [],
    });
    const cancel = await screen.findByRole('button', {
      name: 'Cancel adding chart.png',
    });
    await press('Close');
    // A Cancel queued before React disables the row arrives after Save has started.
    const queued: (event: object) => void = cancel.props.onClick;
    const save = await screen.findByRole('button', { name: 'Save' });
    await act(async () => {
      fireEvent.press(save);
      queued({ nativeEvent: {} });
    });
    await report({ frozen: true });
    await act(async () => {
      storage.releaseImports();
    });
    await waitFor(() => {
      const [stored] = draftsOf(drafts.getSnapshot());
      ok(stored, 'Expected the stored Draft');
      expect(imagesOf(stored.body).map(({ state }) => state)).toStrictEqual([
        'complete',
      ]);
    });
  });
});
