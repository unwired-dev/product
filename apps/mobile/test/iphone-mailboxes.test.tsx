import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import { createInboxPreferences } from '@private-email/mail-core/inbox-preferences';
import { createInboxStore } from '@private-email/mail-core/inbox-store';
import {
  createMailboxes,
  singleMailbox,
} from '@private-email/mail-core/mailboxes';
import {
  defaultProfile,
  mailboxesOf,
} from '@private-email/mail-core/registration';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-vault';
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
import { Inbox } from '../src/inbox.tsx';
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
    for (const name of ['Sent', 'Archive', 'All Mail']) {
      await fireEvent(app.getByRole('button', { name }), 'layout', {
        nativeEvent: { layout: { x: 0, y: 0, width: 370, height: 52 } },
      });
    }
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

  it('hides, shows and reorders accounts and their folders in Edit mode; a hidden account leaves All Inboxes', async () => {
    expect.hasAssertions();
    const alex = syntheticMailboxes['alex@example.invalid'];
    const other = syntheticMailboxes['other@example.invalid'];
    const registration = {
      getSnapshot: () => ({
        snapshot: {
          kind: 'connected',
          productAccountId: 'synthetic-product-account',
          signInProvider: 'google',
          mailboxes: JSON.stringify([
            { id: alex, address: 'alex@example.invalid', state: 'connected' },
            { id: other, address: 'other@example.invalid', state: 'connected' },
          ]),
        } satisfies RegistrationSnapshot,
        busy: false,
        failed: false,
      }),
      subscribe: () => () => undefined,
    };
    const gmail = createSyntheticGmail();
    gmail.deliver({ subject: 'From Alex’s Inbox' });
    const otherGmail = createSyntheticGmail({
      address: 'other@example.invalid',
    });
    otherGmail.deliver({ subject: 'First' });
    otherGmail.deliver({ subject: 'Second' });
    const mailboxes = createMailboxes(
      syntheticConnections({ [alex]: gmail, [other]: otherGmail }),
      registration,
    );
    await mailboxes.load();
    const store = preferences()();
    await store.load();
    const arrangeMailboxes = jest.fn(() => Promise.resolve());
    function Window() {
      const [view, setView] = useState<MailboxView>({ mailbox: other });
      return (
        <Mailboxes
          view={view}
          onView={setView}
          onProfile={ignore}
        />
      );
    }
    const app = await render(
      <AccountContext
        value={{
          ...account,
          mailboxes: mailboxesOf(registration.getSnapshot().snapshot),
          arrangeMailboxes,
        }}>
        <InboxPreferencesContext value={store}>
          <InboxProvider mailboxes={mailboxes}>
            <CommandPaletteProvider>
              <Window />
              <Inbox
                onClose={ignore}
                onSelect={ignore}
                onView={ignore}
                selected={undefined}
                view={{}}
              />
            </CommandPaletteProvider>
          </InboxProvider>
        </InboxPreferencesContext>
      </AccountContext>,
    );
    const allInboxes = () => app.getByRole('button', { name: 'All Inboxes' });
    // The rows after Favorites: each account's header and its folders, with whether each shows.
    const rows = () =>
      app
        .getAllByRole(/^(?:button|header)$/u)
        .map(({ props }) =>
          [
            props.accessibilityLabel,
            props.children,
            props.accessibilityValue?.text,
          ]
            .filter((part) => typeof part === 'string')
            .join(' '),
        )
        .filter((row) =>
          /^(?:Gmail · |[\w ]+\. In \S+example\.invalid)/u.test(row),
        );
    await waitFor(() => {
      expect(allInboxes()).toHaveAccessibilityValue({ text: '3 unread' });
    });
    expect(app.getByText('Second')).toBeVisible();

    await fireEvent.press(app.getByRole('button', { name: 'Edit' }));
    // Hiding the selected account; Alex's Inbox stays shown.
    await fireEvent.press(
      app.getByRole('button', { name: 'Gmail · other@example.invalid' }),
    );
    await fireEvent.press(
      app.getByRole('button', { name: 'Spam. In alex@example.invalid' }),
    );
    await fireEvent.press(
      app.getByRole('button', { name: 'Inbox. In alex@example.invalid' }),
    );
    await fireEvent(
      app.getByRole('button', { name: 'Trash. In alex@example.invalid' }),
      'accessibilityAction',
      { nativeEvent: { actionName: 'moveUp' } },
    );
    await fireEvent(
      app.getByRole('button', { name: 'Gmail · other@example.invalid' }),
      'accessibilityAction',
      { nativeEvent: { actionName: 'moveUp' } },
    );
    await waitFor(() => {
      expect(rows()).toStrictEqual([
        'Gmail · alex@example.invalid Shown',
        'Inbox. In alex@example.invalid Shown',
        'All Mail. In alex@example.invalid Shown',
        'Trash. In alex@example.invalid Shown',
        'Spam. In alex@example.invalid Hidden',
        'Gmail · other@example.invalid Hidden',
      ]);
    });

    await fireEvent.press(app.getByRole('button', { name: 'Done' }));
    expect({
      rows: rows(),
      unread: allInboxes().props.accessibilityValue?.text,
      selected: allInboxes().props.accessibilityState?.selected,
      arranged: arrangeMailboxes.mock.calls,
      listed: app.queryByText('Second'),
    }).toStrictEqual({
      rows: [
        'Gmail · alex@example.invalid',
        'Inbox. In alex@example.invalid 1 unread',
        'All Mail. In alex@example.invalid',
        'Trash. In alex@example.invalid',
      ],
      unread: '1 unread',
      selected: true,
      arranged: [[defaultProfile, [other, alex]]],
      // All Inboxes lists only the shown account's mail.
      listed: null,
    });
    await app.unmount();
  });
});
