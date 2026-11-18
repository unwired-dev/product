import type { Platform } from 'react-native';

import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { act, render, renderHook, screen } from '@testing-library/react-native';

import { CommandPaletteProvider } from '../src/command-palette.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { useSidebarToggle } from '../src/sidebar-toggle.tsx';
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
});
