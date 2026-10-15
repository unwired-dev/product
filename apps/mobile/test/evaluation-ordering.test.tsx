import { ok } from 'node:assert/strict';

import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { imagesOf } from '@private-email/mail-core/semantic-document';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import {
  createMockMailSession,
  syntheticRewrite,
} from '@private-email/mail-core/testing/mock-session';
import { act, render, screen, waitFor } from '@testing-library/react-native';

import { AssistanceContext } from '../src/message-summary.tsx';
import { App, alex, registration } from './evaluation-app.tsx';
import {
  lastAdded,
  lastCommand,
  press,
  simulatedPage,
} from './evaluation-page.ts';

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

describe('evaluation Draft save ordering', () => {
  it.each([
    {
      firstReport: 'body',
      next: { document: [{ kind: 'paragraph', spans: [{ text: 'One two' }] }] },
    },
    { firstReport: 'selection', next: { selection: { start: 7, end: 7 } } },
  ] as const)(
    'keeps the newest page body when its $firstReport report arrives first',
    async ({ next }) => {
      expect.hasAssertions();
      const storage = createSyntheticDrafts(() => 'synthetic-product-account');
      const drafts = createDrafts(storage.native, registration);
      await render(<App drafts={drafts} />);
      await press('New Message');
      const { report, typed } = simulatedPage();
      const first = [{ kind: 'paragraph', spans: [{ text: 'One' }] }] as const;
      await typed('One');
      await report({ revision: 2, ...next });
      // WebKit delivers the first edit's report after the second; it cannot replace the newer body.
      await report({ revision: 1, document: first });
      await press('Close');
      await press('Save Draft', false);
      // Nor while Save Draft waits for the page to acknowledge its last edit.
      await report({ revision: 1, document: first });
      expect(screen.getByLabelText('Subject')).toHaveProp('editable', false);
      await report({
        frozen: true,
        revision: 2,
        document: [{ kind: 'paragraph', spans: [{ text: 'One two' }] }],
      });
      await waitFor(() => {
        expect(screen.queryByTestId('message-webview')).toBeNull();
      });
      const reopened = createDrafts(storage.native, registration);
      await reopened.load();
      expect(draftsOf(reopened.getSnapshot())[0]?.body).toStrictEqual([
        { kind: 'paragraph', spans: [{ text: 'One two' }] },
      ]);
    },
  );

  it('captures writing tools only once the body at the selection revision arrives', async () => {
    expect.hasAssertions();
    const mock = createMockMailSession('open-read-relaunch');
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    await render(
      <AssistanceContext value={mock.assistance}>
        <App drafts={createDrafts(storage.native, registration)} />
      </AssistanceContext>,
    );
    await press('New Message');
    const { report, typed } = simulatedPage();
    await typed('One');
    // The selection of revision 2 arrives before its body; the editor still holds revision 1.
    await report({ revision: 2, selection: { start: 7, end: 7 } });
    const before = lastCommand();
    await press('Writing tools');
    await press('Rewrite the message body');
    expect(lastCommand()).toBe(before);
    expect(screen.queryByText(syntheticRewrite)).toBeNull();
    // Once that body arrives, the capture describes it and replaces it at its revision.
    await report({
      revision: 2,
      document: [{ kind: 'paragraph', spans: [{ text: 'One two' }] }],
    });
    await press('Writing tools');
    await press('Rewrite the message body');
    await screen.findByText(syntheticRewrite);
    await press('Replace your text with this rewrite');
    expect(lastCommand()).toContain('"type":"replace","revision":2');
  });

  it('keeps the surviving Draft and its image when Delete Draft races an import', async () => {
    expect.hasAssertions();
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await drafts.load();
    await drafts.create({ id: alex, address: 'alex@example.invalid' });
    const [created] = draftsOf(drafts.getSnapshot());
    ok(created, 'Expected the created Draft');
    storage.addFile('file:///kept.png', 'kept');
    const kept = drafts.prepare({ name: 'kept.png', type: 'image/png' });
    await drafts.update(
      {
        ...created,
        body: [{ kind: 'paragraph', spans: [{ text: '\uFFFC', image: kept }] }],
      },
      created,
    );
    await drafts.importAsset(kept, { kind: 'file', uri: 'file:///kept.png' });
    await drafts.save();
    await render(<App drafts={drafts} />);
    await press(/^Draft\./u);
    const { report } = simulatedPage();
    await report({});
    // Another device changes the Draft while this editor is open.
    const other = createDrafts(storage.native, registration);
    await other.load();
    const [current] = draftsOf(other.getSnapshot());
    ok(current, 'Expected the stored Draft');
    await other.update({ ...current, subject: 'Other writer' }, current);
    // A new image is still importing when the person deletes this editor's version.
    storage.holdImports();
    storage.addFile('file:///late.png', 'late');
    storage.pickNext('photos', [
      { uri: 'file:///late.png', name: 'late.png', type: 'image/png' },
    ]);
    await press('Add files');
    await press('Insert Image');
    const [late] = lastAdded().images;
    ok(late, 'Expected the inline photo');
    await report({
      document: [
        {
          kind: 'paragraph',
          spans: [
            { text: '\uFFFC', image: kept },
            { text: '\uFFFC', image: late },
          ],
        },
      ],
      attachments: [],
    });
    await press('Close');
    await press('Delete Draft');
    await act(async () => {
      storage.releaseImports();
    });
    await waitFor(() => {
      expect(screen.queryByTestId('message-webview')).toBeNull();
    });
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    const survivors = draftsOf(reopened.getSnapshot());
    expect(survivors).toMatchObject([
      { id: created.id, subject: 'Other writer' },
    ]);
    const [survivor] = survivors;
    ok(survivor, 'Expected the surviving Draft');
    expect(
      imagesOf(survivor.body).map((image) => [image.id, image.state]),
    ).toStrictEqual([[kept.id, 'complete']]);
    // The surviving Draft keeps its bytes; the abandoned import keeps none.
    await waitFor(() => {
      expect(storage.assets()).toStrictEqual([kept.id]);
    });
  });
});
