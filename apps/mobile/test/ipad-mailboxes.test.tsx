import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type { Platform } from 'react-native';

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
  renderHook,
  screen,
  waitFor,
  within,
} from '@testing-library/react-native';

import type { MailboxView } from '../src/sidebar.tsx';

import { CommandPaletteProvider } from '../src/command-palette.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxPreferencesContext } from '../src/list-density.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { AccountContext } from '../src/registration-gate.tsx';
import {
  SidebarToggleContext,
  useSidebarToggle,
} from '../src/sidebar-toggle.tsx';
import { Mailboxes } from '../src/sidebar.tsx';

// Set the device boundary before the sidebar's platform-specific modules load.
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's platform adapter boundary.
jest.mock('react-native/Libraries/Utilities/Platform', () => {
  const { default: platform } = jest.requireActual<{
    default: typeof Platform;
  }>('react-native/Libraries/Utilities/Platform');
  return { __esModule: true, default: { ...platform, isPad: true } };
});

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- The sidebar clears the status bar itself; this host has no inset.
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

// All Inboxes over Alex's shown account and another the Profile hides, neither loaded yet: Alex's
// in `state`, the other in `otherState`. Unless `read`, the preferences are not read yet and hide
// nothing.
async function hiddenAccount(
  state: 'connected' | 'authorization' = 'connected',
  otherState = state,
  read = true,
) {
  const alex = syntheticMailboxes['alex@example.invalid'];
  const other = syntheticMailboxes['other@example.invalid'];
  const snapshot = {
    kind: 'connected',
    productAccountId: 'synthetic-product-account',
    signInProvider: 'google',
    mailboxes: JSON.stringify([
      { id: alex, address: 'alex@example.invalid', state },
      { id: other, address: 'other@example.invalid', state: otherState },
    ]),
  } satisfies RegistrationSnapshot;
  const registration = {
    getSnapshot: () => ({ snapshot, busy: false, failed: false }),
    subscribe: () => () => undefined,
  };
  const shown = createSyntheticGmail({ address: 'alex@example.invalid' });
  const hidden = createSyntheticGmail({ address: 'other@example.invalid' });
  const mailboxes = createMailboxes(
    syntheticConnections({ [alex]: shown, [other]: hidden }),
    registration,
  );
  const kept = { revision: 0, document: null as string | null };
  // Reading the preferences waits for `reads.held`, then fails while `reads.fail` is set.
  const reads = { fail: false, held: Promise.resolve() };
  const store = createInboxPreferences(
    {
      openInboxPreferences: async () => {
        await reads.held;
        if (reads.fail) {
          throw new Error('Preferences unreadable');
        }
        return { owner: 'synthetic-product-account', ...kept };
      },
      commitInboxPreferences: (owner, expectedRevision, document) => {
        Object.assign(kept, { revision: expectedRevision + 1, document });
        return Promise.resolve({ owner, revision: kept.revision });
      },
    },
    registration,
  );
  if (read) {
    await store.load();
    await store.showSection(defaultProfile, other, false);
  }
  const tree = (view: MailboxView) => (
    <AccountContext value={{ ...account, mailboxes: mailboxesOf(snapshot) }}>
      <InboxPreferencesContext value={store}>
        <InboxProvider mailboxes={mailboxes}>
          <CommandPaletteProvider>
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
  return { alex, other, shown, hidden, mailboxes, store, reads, tree };
}

describe('iPad Mailboxes', () => {
  it('hides Mailboxes again after a swipe shows them over the Portrait default', async () => {
    expect.hasAssertions();
    const { result } = await renderHook(() => useSidebarToggle(true, true));
    // UIKit places the columns; then Portrait asks for the list beside the reader alone.
    await act(() => {
      result.current.follow('twoBesideSecondary');
    });
    expect(result.current.displayMode).toBe('oneBesideSecondary');
    await act(() => {
      result.current.follow('oneBesideSecondary');
    });
    // A swipe from the leading edge shows Mailboxes, so Hide Sidebar asks UIKit for a change.
    await act(() => {
      result.current.follow('twoBesideSecondary');
    });
    expect(result.current.displayMode).toBe('twoBesideSecondary');
    await act(() => {
      result.current.value?.toggle();
    });
    expect(result.current.displayMode).toBe('oneBesideSecondary');
  });

  it('hides Mailboxes again when a rotation returns to Portrait after Show Sidebar', async () => {
    expect.hasAssertions();
    const { result, rerender } = await renderHook(
      ({ portrait }: { portrait: boolean }) => useSidebarToggle(true, portrait),
      { initialProps: { portrait: true } },
    );
    await act(() => {
      result.current.follow('oneBesideSecondary');
    });
    await act(() => {
      result.current.value?.toggle();
    });
    expect(result.current.displayMode).toBe('twoBesideSecondary');
    await rerender({ portrait: false });
    expect(result.current.displayMode).toBe('automatic');
    await rerender({ portrait: true });
    expect(result.current.displayMode).toBe('oneBesideSecondary');
  });

  it('hides Mailboxes in Landscape at the largest text sizes, and shows them in the list’s place', async () => {
    expect.hasAssertions();
    const { result, rerender } = await renderHook(
      ({ largeText }: { largeText: boolean }) =>
        useSidebarToggle(true, false, largeText),
      { initialProps: { largeText: true } },
    );
    const state = () => ({
      displayMode: result.current.displayMode,
      inList: result.current.inList,
      shown: result.current.value?.shown,
    });
    await act(() => {
      result.current.follow('twoBesideSecondary');
    });
    expect(state()).toStrictEqual({
      displayMode: 'oneBesideSecondary',
      inList: false,
      shown: false,
    });
    // Show Sidebar keeps the list's column beside the reader and shows Mailboxes in it.
    await act(() => {
      result.current.value?.toggle();
    });
    expect(state()).toStrictEqual({
      displayMode: 'oneBesideSecondary',
      inList: true,
      shown: true,
    });
    // Choosing a Mailbox there shows its list again.
    await act(() => {
      result.current.hideInList();
    });
    expect(state()).toMatchObject({ inList: false });
    // At the usual sizes Landscape shows all three columns again.
    await rerender({ largeText: false });
    expect(state().displayMode).toBe('automatic');
  });

  it('shows a connection that needs sign-in beside its header and in the list subtitle', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({ subject: 'Saved Inbox message' });
    const inbox = createInboxStore(gmail.native);
    await inbox.load();
    await render(
      <InboxProvider mailboxes={singleMailbox(inbox, 'alex@example.invalid')}>
        <CommandPaletteProvider>
          <Mailboxes
            view={{}}
            onView={ignore}
            onProfile={ignore}
          />
          <Inbox
            onClose={ignore}
            onSelect={ignore}
            onView={ignore}
            selected={undefined}
            view={{}}
          />
        </CommandPaletteProvider>
      </InboxProvider>,
    );
    const header = 'Gmail · alex@example.invalid';
    expect(screen.getByRole('header', { name: header })).toBeVisible();

    gmail.fail({ status: 401 });
    await act(inbox.load);
    expect(
      screen.getByRole('header', {
        name: `${header}, Gmail needs your permission again to show new mail.`,
      }),
    ).toBeVisible();
    // The Inbox row keeps its unread count, and the subtitle names the connection after it.
    expect(
      screen.getByRole('button', { name: 'Inbox. In alex@example.invalid' }),
    ).toHaveAccessibilityValue({ text: '1 unread' });
    expect(screen.getByText('1 unread · Gmail needs sign-in')).toBeVisible();
  });

  it('leaves a hidden account out of the All Inboxes subtitle, Filters and search, and names the Inbox shown', async () => {
    expect.hasAssertions();
    const { alex, other, shown, hidden, mailboxes, store, tree } =
      await hiddenAccount();
    await mailboxes.load();
    const app = await render(tree({}));
    // While the hidden account is still checking its server, the shown one has no mail.
    const request = hidden.native.gmailRequest;
    const held = Promise.withResolvers<undefined>();
    hidden.native.gmailRequest = async (...args) => {
      await held.promise;
      return request(...args);
    };
    let synchronized = Promise.resolve();
    await act(async () => {
      synchronized = mailboxes.load();
      await Promise.resolve();
    });
    await screen.findByText('No Mail');
    shown.deliver({ subject: 'Shown' });
    let delivered = Promise.resolve();
    await act(async () => {
      delivered = mailboxes.load();
      await Promise.resolve();
    });
    await screen.findByText('Shown');
    // Its one shown account names the scope, and the hidden one leaves the status as it is.
    await expect(
      screen.findByText(/^alex@example\.invalid · 1 unread · Updated/u),
    ).resolves.toBeVisible();

    await fireEvent.press(screen.getByRole('togglebutton', { name: 'Filter' }));
    await fireEvent.press(
      screen.getByRole('button', { name: 'Filtered by Unread' }),
    );
    expect(screen.getByRole('header', { name: 'Filters' })).toBeVisible();
    expect(screen.queryAllByText(/other@example\.invalid/u)).toStrictEqual([]);
    await fireEvent.press(
      screen.getByRole('button', { name: 'Apply Filters' }),
    );
    await fireEvent.press(screen.getByRole('togglebutton', { name: 'Filter' }));
    held.resolve(undefined);
    await act(() => Promise.all([synchronized, delivered]));

    // Searching the mail servers from All Inboxes names the one account it searches.
    const searching = Promise.withResolvers<undefined>();
    const search = shown.native.gmailRequest;
    shown.native.gmailRequest = async (...args) => {
      await searching.promise;
      return search(...args);
    };
    const field = screen.getByLabelText('Search senders and subjects');
    await fireEvent(field, 'focus');
    await fireEvent.changeText(field, 'Shown');
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Search Mail Servers for “Shown”',
      }),
    );
    await expect(
      screen.findByText('Searching alex@example.invalid…'),
    ).resolves.toBeVisible();
    await act(async () => {
      searching.resolve(undefined);
      await Promise.resolve();
    });

    // Shown again, the other account leaves Alex's own Inbox named as the scope.
    await act(() => store.showSection(defaultProfile, other, true));
    await app.rerender(tree({ mailbox: alex }));
    await fireEvent.press(screen.getByRole('button', { name: 'Close Search' }));
    await expect(
      screen.findByText(/^alex@example\.invalid · 1 unread/u),
    ).resolves.toBeVisible();
    await app.unmount();
  });

  it('answers search and settles a refresh in All Inboxes while a hidden account first lists', async () => {
    expect.hasAssertions();
    const { shown, hidden, mailboxes, tree } = await hiddenAccount();
    const request = hidden.native.gmailRequest;
    const held = Promise.withResolvers<undefined>();
    hidden.native.gmailRequest = async (...args) => {
      await held.promise;
      return request(...args);
    };
    shown.deliver({ subject: 'Shown' });
    const app = await render(tree({}));
    let first = Promise.resolve();
    await act(async () => {
      first = mailboxes.load();
      await Promise.resolve();
    });
    await screen.findByText('Shown');
    // Search answers once the shown account has listed.
    const field = screen.getByLabelText('Search senders and subjects');
    await fireEvent(field, 'focus');
    await fireEvent.changeText(field, 'Nothing like this');
    await screen.findByText('No Results');
    await fireEvent.press(screen.getByRole('button', { name: 'Close Search' }));
    // Pulling down lists the shown account's new mail and settles once it has.
    shown.deliver({ subject: 'Pulled' });
    await act(async () => {
      fireEvent(screen.getByLabelText('Inbox messages'), 'refresh');
    });
    await screen.findByText('Pulled');
    await waitFor(() => {
      expect(screen.getByLabelText('Inbox messages')).toHaveProp(
        'refreshing',
        false,
      );
    });
    held.resolve(undefined);
    await act(() => first);
    await app.unmount();
  });

  it.each(['connected', 'authorization'] as const)(
    'shows No Mail and answers search in All Inboxes with every account hidden, none listed, while %s',
    async (state) => {
      expect.hasAssertions();
      const { alex, shown, hidden, mailboxes, store, tree } =
        await hiddenAccount(state);
      await store.showSection(defaultProfile, alex, false);
      const held = Promise.withResolvers<undefined>();
      for (const gmail of [shown, hidden]) {
        const request = gmail.native.gmailRequest;
        gmail.native.gmailRequest = async (...args) => {
          await held.promise;
          return request(...args);
        };
      }
      const app = await render(tree({}));
      let first = Promise.resolve();
      await act(async () => {
        first = mailboxes.load();
        await Promise.resolve();
      });
      await expect(screen.findByText('No Mail')).resolves.toBeOnTheScreen();
      const field = screen.getByLabelText('Search senders and subjects');
      await fireEvent(field, 'focus');
      await fireEvent.changeText(field, 'Nothing like this');
      await expect(screen.findByText('No Results')).resolves.toBeOnTheScreen();
      held.resolve(undefined);
      await act(() => first);
      await app.unmount();
    },
  );

  it('takes no loading or No Mail from a hidden account while the only shown one waits for sign-in, nor after a failed reread', async () => {
    expect.hasAssertions();
    const { hidden, mailboxes, store, reads, tree } = await hiddenAccount(
      'authorization',
      'connected',
    );
    const request = hidden.native.gmailRequest;
    const held = Promise.withResolvers<undefined>();
    hidden.native.gmailRequest = async (...args) => {
      await held.promise;
      return request(...args);
    };
    const app = await render(tree({}));
    let first = Promise.resolve();
    await act(async () => {
      first = mailboxes.load();
      await Promise.resolve();
    });
    await expect(
      screen.findByText(/needs your permission again/u),
    ).resolves.toBeOnTheScreen();
    const loading = screen.queryByLabelText('Loading Inbox');
    held.resolve(undefined);
    await act(() => first);
    const empty = screen.queryByText('No Mail');
    reads.fail = true;
    await act(() => store.load());
    expect({
      loading,
      empty,
      reread: screen.queryByText('No Mail'),
    }).toStrictEqual({ loading: null, empty: null, reread: null });
    await app.unmount();
  });

  it('shows Loading Inbox while the preferences are first read, and Try Again once a read fails', async () => {
    expect.hasAssertions();
    const { shown, mailboxes, store, reads, tree } = await hiddenAccount(
      'connected',
      'connected',
      false,
    );
    shown.deliver({ subject: 'Shown' });
    await mailboxes.load();
    const held = Promise.withResolvers<undefined>();
    Object.assign(reads, { fail: true, held: held.promise });
    const app = await render(tree({}));
    let first = Promise.resolve();
    await act(async () => {
      first = store.load();
      await Promise.resolve();
    });
    expect(screen.getByLabelText('Loading Inbox')).toBeOnTheScreen();
    held.resolve(undefined);
    await act(() => first);
    await expect(
      screen.findByText(/^Which accounts All Inboxes shows couldn’t be read/u),
    ).resolves.toBeOnTheScreen();
    expect(screen.getByRole('button', { name: 'Try Again' })).toBeEnabled();
    // Pulling down reads the preferences again and synchronizes the accounts they show.
    reads.fail = false;
    shown.deliver({ subject: 'Arrived' });
    await act(async () => {
      fireEvent(screen.getByLabelText('Inbox messages'), 'refresh');
    });
    await expect(screen.findByText('Arrived')).resolves.toBeOnTheScreen();
    await app.unmount();
  });

  it('answers search widened from an account’s Inbox once Try Again reads the preferences a read failed', async () => {
    expect.hasAssertions();
    const { alex, shown, hidden, mailboxes, store, reads, tree } =
      await hiddenAccount('connected', 'connected', false);
    shown.deliver({ subject: 'From Alex’s Inbox' });
    hidden.deliver({ subject: 'From the other account' });
    reads.fail = true;
    const app = await render(tree({ mailbox: alex }));
    await act(() => store.load());
    await act(() => mailboxes.load());
    await screen.findByText('From Alex’s Inbox');
    const field = screen.getByLabelText('Search senders and subjects');
    await fireEvent(field, 'focus');
    await fireEvent.changeText(field, 'other account');
    await fireEvent.press(screen.getByRole('tab', { name: 'All Mailboxes' }));
    // Which Inboxes the search covers is unknown, so it has not answered and offers Try Again.
    const unread = screen.queryByText('No Results');
    reads.fail = false;
    await fireEvent.press(screen.getByRole('button', { name: 'Try Again' }));
    await screen.findByText('From the other account');
    expect(unread).toBeNull();
    await app.unmount();
  });

  it('synchronizes the accounts the preferences show when pulled while they are first read', async () => {
    expect.hasAssertions();
    const { shown, mailboxes, reads, tree } = await hiddenAccount(
      'connected',
      'connected',
      false,
    );
    const held = Promise.withResolvers<undefined>();
    reads.held = held.promise;
    const app = await render(tree({}));
    await act(() => mailboxes.load());
    shown.deliver({ subject: 'Arrived' });
    await act(async () => {
      fireEvent(screen.getByLabelText('Inbox messages'), 'refresh');
      await Promise.resolve();
    });
    await act(() => {
      held.resolve(undefined);
    });
    await expect(screen.findByText('Arrived')).resolves.toBeOnTheScreen();
    await app.unmount();
  });

  it('drops a leaving row of an account hidden while it leaves All Inboxes', async () => {
    expect.hasAssertions();
    // Animation frames would finish the motion between inputs.
    const frames = jest
      .spyOn(globalThis, 'requestAnimationFrame')
      .mockReturnValue(0);
    const { alex, shown, mailboxes, store, tree } = await hiddenAccount();
    shown.deliver({ subject: 'Leaving' });
    const app = await render(tree({}));
    await act(() => mailboxes.load());
    await act(async () => {
      await fireEvent(
        await screen.findByRole('button', { name: /Leaving/u }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'archive' } },
      );
    });
    // Rows still on screen only while they leave, hidden from VoiceOver and touch.
    const leaving = () =>
      screen.queryAllByText('Leaving', { includeHiddenElements: true }).length;
    const archived = leaving();
    await act(() => store.showSection(defaultProfile, alex, false));
    expect([archived, leaving()]).toStrictEqual([1, 0]);
    await app.unmount();
    frames.mockRestore();
  });

  it('keeps Edit Favorites from the Command Palette closed while the preferences are unread, even once read', async () => {
    expect.hasAssertions();
    const inbox = createInboxStore(
      createSyntheticGmail({ address: 'alex@example.invalid' }).native,
    );
    await inbox.load();
    const read = Promise.withResolvers<undefined>();
    const store = createInboxPreferences(
      {
        openInboxPreferences: async () => {
          await read.promise;
          return {
            owner: 'synthetic-product-account',
            revision: 0,
            document: null,
          };
        },
        commitInboxPreferences: () => Promise.reject(new Error('Unused')),
      },
      {
        getSnapshot: () => ({
          snapshot: {
            kind: 'connected',
            productAccountId: 'synthetic-product-account',
            signInProvider: 'google',
            mailboxes: '[]',
          } satisfies RegistrationSnapshot,
          busy: false,
          failed: false,
        }),
      },
    );
    const loaded = store.load();
    await render(
      <AccountContext value={account}>
        <InboxPreferencesContext value={store}>
          <InboxProvider
            mailboxes={singleMailbox(inbox, 'alex@example.invalid')}>
            <CommandPaletteProvider>
              <SidebarToggleContext value={{ shown: true, toggle: ignore }}>
                <Mailboxes
                  view={{}}
                  onView={ignore}
                  onProfile={ignore}
                />
                <Inbox
                  onClose={ignore}
                  onSelect={ignore}
                  onView={ignore}
                  selected={undefined}
                  view={{}}
                />
              </SidebarToggleContext>
            </CommandPaletteProvider>
          </InboxProvider>
        </InboxPreferencesContext>
      </AccountContext>,
    );
    await fireEvent.press(
      screen.getByRole('button', { name: 'Open Command Palette' }),
    );
    await fireEvent.press(
      within(screen.getByTestId('command-palette')).getByRole('button', {
        name: 'Edit Favorites',
      }),
    );
    await act(async () => {
      read.resolve(undefined);
      await loaded;
    });
    expect(screen.queryByRole('button', { name: 'Done' })).toBeNull();
  });

  it('offers Edit Favorites in the Command Palette only while the sidebar shows', async () => {
    expect.hasAssertions();
    const inbox = createInboxStore(
      createSyntheticGmail({ address: 'alex@example.invalid' }).native,
    );
    await inbox.load();
    const window = (shown: boolean) => (
      <AccountContext value={account}>
        <InboxProvider mailboxes={singleMailbox(inbox, 'alex@example.invalid')}>
          <CommandPaletteProvider>
            <SidebarToggleContext value={{ shown, toggle: ignore }}>
              <Mailboxes
                view={{}}
                onView={ignore}
                onProfile={ignore}
              />
              <Inbox
                onClose={ignore}
                onSelect={ignore}
                onView={ignore}
                selected={undefined}
                view={{}}
              />
            </SidebarToggleContext>
          </CommandPaletteProvider>
        </InboxProvider>
      </AccountContext>
    );
    const palette = async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Open Command Palette' }),
      );
      return within(screen.getByTestId('command-palette'));
    };
    const app = await render(window(false));
    const hidden = await palette();
    expect(hidden.queryByRole('button', { name: 'Edit Favorites' })).toBeNull();
    await app.unmount();

    await render(window(true));
    const shown = await palette();
    await fireEvent.press(
      shown.getByRole('button', { name: 'Edit Favorites' }),
    );
    expect(screen.getByRole('button', { name: 'Done' })).toBeVisible();
    expect(
      screen.getByRole('button', { name: 'Spam' }),
    ).toHaveAccessibilityValue({ text: 'Shown' });
  });
});
