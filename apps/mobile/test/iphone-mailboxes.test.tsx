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
import { Alert, ScrollView } from 'react-native';

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

// Inbox preferences kept for one signed-in Product Account, as native storage keeps them. While
// `gate.held` is set, writes wait for it.
const preferences = (gate: { held?: Promise<void> } = {}) => {
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
          await gate.held;
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
    gmail.archive(gmail.deliver({ subject: 'Second look' }));
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
    const gate: { held?: Promise<void> } = {};
    const store = preferences(gate)();
    await store.load();
    // The account order is refused, as offline.
    const arrangeMailboxes = jest.fn(() => Promise.resolve(false));
    const alert = jest.spyOn(Alert, 'alert').mockReturnValue(undefined);
    // The window's view, and how to select one as Go To would.
    let selected: MailboxView = {};
    let select: (view: MailboxView) => void = ignore;
    function Window() {
      const [view, setView] = useState<MailboxView>({ mailbox: other });
      selected = view;
      select = setView;
      return (
        <Mailboxes
          view={view}
          onView={setView}
          onProfile={ignore}
        />
      );
    }
    const connections = mailboxesOf(registration.getSnapshot().snapshot);
    // The window, with the Profile's connections in `order` and the Inbox showing `view`.
    const tree = (order: typeof connections, view: MailboxView = {}) => (
      <AccountContext
        value={{
          ...account,
          mailboxes: order,
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
                view={view}
              />
            </CommandPaletteProvider>
          </InboxProvider>
        </InboxPreferencesContext>
      </AccountContext>
    );
    const app = await render(tree(connections));
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
    // Hiding the selected account, then Done and choosing Alex's Inbox while the write is slow,
    // keeps that choice; hiding the selected Spam selects All Inboxes. Alex's Inbox stays shown.
    const written = Promise.withResolvers<undefined>();
    gate.held = written.promise;
    await fireEvent.press(
      app.getByRole('button', { name: 'Gmail · other@example.invalid' }),
    );
    await fireEvent.press(app.getByRole('button', { name: 'Done' }));
    await act(() => {
      select({ mailbox: alex });
    });
    delete gate.held;
    await act(async () => {
      written.resolve(undefined);
      await written.promise;
    });
    expect(selected).toStrictEqual({ mailbox: alex });
    await fireEvent.press(app.getByRole('button', { name: 'Edit' }));
    await act(() => {
      select({ mailbox: alex, folder: 'SPAM' });
    });
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
    // Alex's header handle, released where it was pressed, and dragged past the other account
    // while another device reorders them, arranges nothing.
    const header = () =>
      app
        .getByRole('button', { name: 'Gmail · alex@example.invalid' })
        .queryAll((node) => node.props.onResponderGrant !== undefined)
        .at(0)!;
    for (const name of [
      'Gmail · alex@example.invalid',
      'Gmail · other@example.invalid',
    ]) {
      await fireEvent(app.getByRole('button', { name }), 'layout', {
        nativeEvent: { layout: { x: 0, y: 0, width: 370, height: 52 } },
      });
    }
    await fireEvent(header(), 'responderGrant', touch(0));
    await fireEvent(header(), 'responderRelease', touch(10));
    await fireEvent(header(), 'responderGrant', touch(100));
    await fireEvent(header(), 'responderMove', touch(110));
    await app.rerender(tree(connections.toReversed()));
    await fireEvent(header(), 'responderMove', touch(20));
    await fireEvent(header(), 'responderRelease', touch(20));
    await app.rerender(tree(connections));

    await fireEvent.press(app.getByRole('button', { name: 'Done' }));
    expect({
      rows: rows(),
      unread: allInboxes().props.accessibilityValue?.text,
      selected: allInboxes().props.accessibilityState?.selected,
      arranged: arrangeMailboxes.mock.calls,
      refused: alert.mock.calls.map(([title, message]) => [title, message]),
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
      arranged: [[defaultProfile, [other, alex], [alex, other]]],
      refused: [
        [
          'The accounts couldn’t be reordered',
          'They keep their order on every device. Check your connection and try again.',
        ],
      ],
      // All Inboxes lists only the shown account's mail, and searches only its server.
      listed: null,
    });
    const field = app.getByLabelText('Search senders and subjects');
    await fireEvent(field, 'focus');
    await fireEvent.changeText(field, 'Second');
    await fireEvent.press(
      await app.findByRole('button', {
        name: 'Search Mail Servers for “Second”',
      }),
    );
    await app.findByRole('button', { name: /Second look/u });
    expect(
      app.queryAllByRole('button', { name: /Second(?! look)/u }),
    ).toStrictEqual([]);
    // With the hidden account's own Inbox open, search finds its mail until widened to every Inbox.
    await app.rerender(tree(connections, { mailbox: other }));
    await fireEvent.changeText(field, 'F');
    await app.findByRole('button', { name: /First/u });
    await fireEvent.press(app.getByRole('tab', { name: 'All Mailboxes' }));
    await app.findByRole('button', { name: /From Alex’s Inbox/u });
    expect(app.queryAllByRole('button', { name: /First/u })).toStrictEqual([]);
    alert.mockRestore();
    await app.unmount();
  });

  it('scrolls the list while an account is dragged at its edge, but not while a handle is only held there', async () => {
    expect.hasAssertions();
    const alex = syntheticMailboxes['alex@example.invalid'];
    const other = syntheticMailboxes['other@example.invalid'];
    const snapshot = {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      mailboxes: JSON.stringify([
        { id: alex, address: 'alex@example.invalid', state: 'connected' },
        { id: other, address: 'other@example.invalid', state: 'connected' },
      ]),
    } satisfies RegistrationSnapshot;
    const registration = {
      getSnapshot: () => ({ snapshot, busy: false, failed: false }),
      subscribe: () => () => undefined,
    };
    const mailboxes = createMailboxes(
      syntheticConnections({
        [alex]: createSyntheticGmail(),
        [other]: createSyntheticGmail({ address: 'other@example.invalid' }),
      }),
      registration,
    );
    await mailboxes.load();
    const store = preferences()();
    await store.load();
    const arrangeMailboxes = jest.fn(() => Promise.resolve(true));
    // Animation frames run only when the test steps them.
    const frames = new Map<number, FrameRequestCallback>();
    let requested = 0;
    jest
      .spyOn(globalThis, 'requestAnimationFrame')
      .mockImplementation((frame) => {
        requested += 1;
        frames.set(requested, frame);
        return requested;
      });
    jest.spyOn(globalThis, 'cancelAnimationFrame').mockImplementation((id) => {
      frames.delete(Number(id));
    });
    const step = async (count: number) => {
      for (let index = 0; index < count; index += 1) {
        const [id, frame] = frames.entries().next().value!;
        frames.delete(id);
        await act(() => {
          frame(0);
        });
      }
    };
    const scrollTo = jest
      .spyOn(ScrollView.prototype, 'scrollTo')
      .mockReturnValue(undefined);
    const connections = mailboxesOf(snapshot);
    const tree = (order: typeof connections) => (
      <AccountContext
        value={{ ...account, mailboxes: order, arrangeMailboxes }}>
        <InboxPreferencesContext value={store}>
          <InboxProvider mailboxes={mailboxes}>
            <CommandPaletteProvider>
              <Mailboxes
                view={{}}
                onView={ignore}
                onProfile={ignore}
              />
            </CommandPaletteProvider>
          </InboxProvider>
        </InboxPreferencesContext>
      </AccountContext>
    );
    const app = await render(tree(connections));
    await fireEvent.press(app.getByRole('button', { name: 'Edit' }));
    // A 300pt list of 1000pt; Alex's account, with its folders, 260pt above the other's 52pt.
    const list = () =>
      app
        .root!.queryAll((node) => node.props.scrollEventThrottle === 16)
        .at(0)!;
    await fireEvent(list(), 'layout', {
      nativeEvent: { layout: { x: 0, y: 0, width: 370, height: 300 } },
    });
    await fireEvent(list(), 'contentSizeChange', 370, 1000);
    for (const [name, height] of [
      ['Gmail · alex@example.invalid', 260],
      ['Gmail · other@example.invalid', 52],
    ] as const) {
      await fireEvent(app.getByRole('button', { name }), 'layout', {
        nativeEvent: { layout: { x: 0, y: 0, width: 370, height } },
      });
    }
    const handle = () =>
      app
        .getByRole('button', { name: 'Gmail · alex@example.invalid' })
        .queryAll((node) => node.props.onResponderGrant !== undefined)
        .at(0)!;

    // Held 10pt above the bottom edge, the handle scrolls nothing and its release moves nothing.
    await fireEvent(handle(), 'responderGrant', touch(290));
    await fireEvent(handle(), 'responderMove', touch(292));
    expect(frames.size).toBe(0);
    await fireEvent(handle(), 'responderRelease', touch(292));
    expect(arrangeMailboxes).not.toHaveBeenCalled();

    // Dragged 10pt there, the list scrolls until Alex's account passes the other's middle.
    await fireEvent(handle(), 'responderGrant', touch(280));
    await fireEvent(handle(), 'responderMove', touch(290));
    await step(2);
    const scrolls = list().props.scrollEnabled;
    await fireEvent(handle(), 'responderRelease', touch(290));
    expect({
      scrolls,
      scrolled: scrollTo.mock.calls.length,
      arranged: arrangeMailboxes.mock.calls,
    }).toStrictEqual({
      scrolls: false,
      scrolled: 2,
      arranged: [[defaultProfile, [other, alex], [alex, other]]],
    });

    // Another device's order, arriving mid-drag, ends it: the list stops and scrolls again.
    scrollTo.mockClear();
    await fireEvent(handle(), 'responderGrant', touch(280));
    await fireEvent(handle(), 'responderMove', touch(290));
    await step(1);
    await app.rerender(tree(connections.toReversed()));
    expect([
      frames.size,
      scrollTo.mock.calls.length,
      list().props.scrollEnabled,
    ]).toStrictEqual([0, 1, true]);
    jest.restoreAllMocks();
    await app.unmount();
  });
});
