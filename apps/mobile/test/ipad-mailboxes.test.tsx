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
    const shown = createSyntheticGmail({ address: 'alex@example.invalid' });
    const hidden = createSyntheticGmail({ address: 'other@example.invalid' });
    const mailboxes = createMailboxes(
      syntheticConnections({ [alex]: shown, [other]: hidden }),
      registration,
    );
    await mailboxes.load();
    const kept = { revision: 0, document: null as string | null };
    const store = createInboxPreferences(
      {
        openInboxPreferences: () =>
          Promise.resolve({ owner: 'synthetic-product-account', ...kept }),
        commitInboxPreferences: (owner, expectedRevision, document) => {
          Object.assign(kept, { revision: expectedRevision + 1, document });
          return Promise.resolve({ owner, revision: kept.revision });
        },
      },
      registration,
    );
    await store.load();
    await store.showSection(defaultProfile, other, false);
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
