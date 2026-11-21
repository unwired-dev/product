import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import { createInboxPreferences } from '@private-email/mail-core/inbox-preferences';
import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';
import { useState } from 'react';

import type { MailboxView } from '../src/sidebar.tsx';

import { CommandPaletteProvider } from '../src/command-palette.tsx';
import { InboxPreferencesContext } from '../src/list-density.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { AccountContext } from '../src/registration-gate.tsx';
import { Mailboxes } from '../src/sidebar.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Mailboxes clears the status bar itself; this host has no inset.
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, left: 0, right: 0, bottom: 0 }),
}));

const ignore = () => undefined;

const account = {
  mailboxes: [],
  openAccount: ignore,
  authorizeMailbox: () => Promise.resolve(),
  refreshInbox: (load: () => Promise<void>) => load(),
  account: 'synthetic-product-account',
  profiles: [],
  createProfile: () => Promise.resolve(undefined),
  chooseFolders: () => Promise.resolve(true),
};

// Inbox preferences kept for one signed-in Product Account, as native storage keeps them.
const preferences = () => {
  const kept = { revision: 0, document: null as string | null };
  const registration = {
    getSnapshot: () => ({
      snapshot: {
        kind: 'connected',
        productAccountId: 'account-1',
        signInProvider: 'google',
        mailboxes: '[]',
      } satisfies RegistrationSnapshot,
      busy: false,
      failed: false,
    }),
  };
  return () =>
    createInboxPreferences(
      {
        openInboxPreferences: async () => ({ owner: 'account-1', ...kept }),
        commitInboxPreferences: async (owner, expectedRevision, document) => {
          Object.assign(kept, { revision: expectedRevision + 1, document });
          return { owner, revision: kept.revision };
        },
      },
      registration,
    );
};

const touch = (pageY: number) => ({
  persist: ignore,
  currentTarget: 1,
  nativeEvent: { pageX: 0, pageY, locationX: 0, locationY: 0, timestamp: 0 },
});

const names = new Set([
  'All Inboxes',
  'Sent',
  'Archive',
  'All Mail',
  'Spam',
  'Trash',
]);

describe('iPhone Mailboxes', () => {
  it('shows a connection that needs sign-in beside its header and in a banner above its folders', async () => {
    expect.hasAssertions();
    const address = 'alex@example.invalid';
    const gmail = createSyntheticGmail({ address });
    gmail.deliver({ subject: 'Saved Inbox message' });
    const inbox = createInboxStore(gmail.native);
    await inbox.load();
    const authorizeMailbox = jest.fn(() => Promise.resolve());
    await render(
      <AccountContext
        value={{
          mailboxes: [],
          openAccount: ignore,
          authorizeMailbox,
          refreshInbox: (load) => load(),
          account: 'synthetic-product-account',
          profiles: [],
          createProfile: () => Promise.resolve(undefined),
          chooseFolders: () => Promise.resolve(true),
        }}>
        <InboxProvider mailboxes={singleMailbox(inbox, address)}>
          <CommandPaletteProvider>
            <Mailboxes
              view={{}}
              onView={ignore}
              onProfile={ignore}
            />
          </CommandPaletteProvider>
        </InboxProvider>
      </AccountContext>,
    );
    const header = `Gmail · ${address}`;
    // Waiting out Gmail's usage limit is a pause, not a problem beside the mailbox.
    gmail.fail({ status: 429 });
    await act(inbox.load);
    expect(screen.getByRole('header', { name: header })).toBeVisible();
    // Closing the Inbox ends the pause and its wait.
    await act(() => {
      inbox.forget();
    });
    gmail.fail({ status: 401 });
    await act(inbox.load);
    expect(
      screen.getByRole('header', {
        name: `${header}, Gmail needs your permission again to show new mail.`,
      }),
    ).toBeVisible();
    expect(
      screen.getByText('Gmail needs you to sign in again to keep syncing.'),
    ).toBeVisible();
    // The Inbox row keeps its unread count.
    expect(
      screen.getByRole('button', { name: `Inbox. In ${address}` }),
    ).toHaveAccessibilityValue({ text: '1 unread' });

    await fireEvent.press(
      screen.getByRole('button', { name: `Sign In to ${address}…` }),
    );
    expect(authorizeMailbox).toHaveBeenCalledWith(address);
  });

  it('hides, shows and reorders Favorites in Edit mode, and keeps them after a relaunch', async () => {
    expect.hasAssertions();
    const relaunch = preferences();
    const launch = async (
      store: ReturnType<ReturnType<typeof preferences>>,
    ) => {
      await store.load();
      const inbox = createInboxStore(
        createSyntheticGmail({ address: 'alex@example.invalid' }).native,
      );
      await inbox.load();
      function Window() {
        const [view, setView] = useState<MailboxView>({ unified: 'SPAM' });
        return (
          <Mailboxes
            view={view}
            onView={setView}
            onProfile={ignore}
          />
        );
      }
      return render(
        <AccountContext value={account}>
          <InboxPreferencesContext value={store}>
            <InboxProvider
              mailboxes={singleMailbox(inbox, 'alex@example.invalid')}>
              <CommandPaletteProvider>
                <Window />
              </CommandPaletteProvider>
            </InboxProvider>
          </InboxPreferencesContext>
        </AccountContext>,
      );
    };
    // The Favorites rows in order, by name, and in Edit mode with whether each is shown.
    const rows = (app: Awaited<ReturnType<typeof launch>>) =>
      app
        .getAllByRole('button')
        .map(({ props }) =>
          [
            String(props.accessibilityLabel).replace('. In All Mailboxes', ''),
            props.accessibilityValue?.text,
          ]
            .filter((part) => part !== undefined)
            .join(' '),
        )
        .filter((row) => names.has(row.replace(/ (?:Shown|Hidden)$/u, '')));
    const app = await launch(relaunch());
    await fireEvent.press(app.getByRole('button', { name: 'Edit' }));
    expect(app.queryByRole('button', { name: 'Account' })).toBeNull();
    // Hiding the selected Spam; All Inboxes stays shown.
    await fireEvent.press(app.getByRole('button', { name: 'Spam' }));
    await fireEvent.press(app.getByRole('button', { name: 'All Inboxes' }));
    await fireEvent(
      app.getByRole('button', { name: 'Trash' }),
      'accessibilityAction',
      { nativeEvent: { actionName: 'moveUp' } },
    );
    await waitFor(() => {
      expect(rows(app)).toStrictEqual([
        'All Inboxes Shown',
        'Sent Shown',
        'Archive Shown',
        'All Mail Shown',
        'Trash Shown',
        'Spam Hidden',
      ]);
    });
    // Sent's handle, dragged two 52pt rows down, lands after All Mail.
    const handle = app
      .getByRole('button', { name: 'Sent' })
      .queryAll((node) => node.props.onResponderGrant !== undefined)
      .at(0)!;
    await fireEvent(app.getByRole('button', { name: 'Sent' }), 'layout', {
      nativeEvent: { layout: { x: 0, y: 0, width: 370, height: 52 } },
    });
    await fireEvent(handle, 'responderGrant', touch(0));
    await fireEvent(handle, 'responderMove', touch(104));
    await fireEvent(handle, 'responderRelease', touch(104));
    const edited = [
      'All Inboxes Shown',
      'Archive Shown',
      'All Mail Shown',
      'Sent Shown',
      'Trash Shown',
      'Spam Hidden',
    ];
    await waitFor(() => {
      expect(rows(app)).toStrictEqual(edited);
    });
    await fireEvent.press(app.getByRole('button', { name: 'Done' }));
    // Hiding the selected Spam selected All Inboxes, the first row still shown.
    expect({
      favorites: rows(app),
      selected: app.getByRole('button', { name: 'All Inboxes' }).props
        .accessibilityState?.selected,
      account: app.getByRole('button', { name: 'Account' }) !== null,
    }).toStrictEqual({
      favorites: ['All Inboxes', 'Archive', 'All Mail', 'Sent', 'Trash'],
      selected: true,
      account: true,
    });
    await app.unmount();

    const again = await launch(relaunch());
    await fireEvent.press(again.getByRole('button', { name: 'Edit' }));
    expect(rows(again)).toStrictEqual(edited);
    await again.unmount();
  });
});
