import { ok } from 'node:assert/strict';

import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { imagesOf } from '@private-email/mail-core/semantic-document';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import { act, render, screen, waitFor } from '@testing-library/react-native';

import { App, alex, registration } from './evaluation-app.tsx';
import { lastAdded, press, simulatedPage } from './evaluation-page.ts';

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
      await press('Save', false);
      // Nor while Save waits for the page to acknowledge its last edit.
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

  it('keeps the surviving Draft and its image when Don’t Save races an import', async () => {
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
    await press('Insert Image…');
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
    await press('Don’t Save');
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
