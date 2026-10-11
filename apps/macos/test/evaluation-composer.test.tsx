import { ok } from 'node:assert/strict';

import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { mailboxesOf } from '@private-email/mail-core/registration';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
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
import { AccountContext } from '../src/registration-gate.tsx';

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
        authorizeGmail: () => Promise.resolve(),
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

// The page posts the whole body after each edit.
const typed = async (text: string) => {
  await act(async () => {
    await fireEvent(screen.getByTestId('message-webview'), 'message', {
      nativeEvent: {
        data: JSON.stringify({
          type: 'change',
          document: [{ kind: 'paragraph', spans: [{ text }] }],
        }),
      },
    });
  });
};

describe('the Tiptap evaluation composer', () => {
  /* oxlint-disable vitest/max-expects -- The journey proves one evaluation path end to end. */
  it('saves page edits through the Draft store and reopens them after relaunch', async () => {
    expect.hasAssertions();
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const first = await render(
      <App drafts={createDrafts(storage.native, registration)} />,
    );
    await press('New Message');
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
        nativeEvent: { data: '{"type":"change","document":[]}' },
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
        'This Draft could not be saved, so it stays open. Try again, or discard it.',
      ),
    ).toBeOnTheScreen();
    await press('Try again');
    expect(screen.queryByText('Evaluation editor')).not.toBeOnTheScreen();
    // WebKit can queue a callback before Close removes the page. Retired pages cannot edit.
    await act(async () => {
      page.props.onMessage({
        nativeEvent: {
          data: JSON.stringify({
            type: 'change',
            document: [
              { kind: 'paragraph', spans: [{ text: 'Late closed page' }] },
            ],
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

  it('leaves a formatted Draft unchanged instead of opening it', async () => {
    expect.hasAssertions();
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await render(<App drafts={drafts} />);
    await press('New Message');
    const [draft] = draftsOf(drafts.getSnapshot());
    ok(draft, 'Expected a Draft');
    const formatted = {
      ...draft,
      body: [
        {
          kind: 'paragraph',
          spans: [{ text: 'Bold', marks: ['bold'] }],
        },
      ] as const,
    };
    await act(async () => {
      await drafts.update(formatted, draft);
    });
    await expect(
      screen.findByText(
        'The evaluation editor opens plain paragraphs only, so this Draft stays unchanged. Close it to return to the Inbox.',
      ),
    ).resolves.toBeOnTheScreen();
    expect(screen.queryByTestId('message-webview')).not.toBeOnTheScreen();
    expect(draftsOf(drafts.getSnapshot())[0]?.body).toStrictEqual(
      formatted.body,
    );
  });
});
