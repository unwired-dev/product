import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { act, fireEvent, render, screen } from '@testing-library/react-native';

import { CommandPaletteProvider } from '../src/command-palette.tsx';
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

describe('iPhone Mailboxes', () => {
  it('shows a connection that needs sign-in beside its header and in a banner above its folders', async () => {
    expect.hasAssertions();
    const address = 'alex@example.invalid';
    const gmail = createSyntheticGmail({ address });
    gmail.deliver({ subject: 'Saved Inbox message' });
    const inbox = createInboxStore(gmail.native);
    await inbox.load();
    // The refusal is used up, so the next synchronization succeeds as after signing in.
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
    expect(screen.getByRole('header', { name: header })).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Sign In…' })).toBeNull();

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

    await fireEvent.press(screen.getByRole('button', { name: 'Sign In…' }));
    expect(authorizeMailbox).toHaveBeenCalledWith(address);
    expect(screen.getByRole('header', { name: header })).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Sign In…' })).toBeNull();
  });
});
