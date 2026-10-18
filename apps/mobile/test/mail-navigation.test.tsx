import type { View as NativeView } from 'react-native';
import type { SplitHostCommands } from 'react-native-screens/experimental';

import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { makeMockInboxStorage } from '@private-email/mail-core/testing/mock-storage';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { useRef } from 'react';
import { Pressable, Text } from 'react-native';

import type { mailboxes } from '../src/private-storage.ts';

import { MailNavigation } from '../src/mail-navigation.tsx';
import { InboxProvider } from '../src/mailbox.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Substitute only URL delivery; the native destination composition is real.
jest.mock('expo-router', () => {
  const { View } = jest.requireActual<{ View: typeof NativeView }>(
    'react-native',
  );
  return {
    Navigator: View,
    Slot: View,
    useGlobalSearchParams: () => ({}),
  };
});

// oxlint-disable-next-line vitest/prefer-import-in-mock -- The real Inbox store uses synthetic native storage.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Native inset measurement is outside this component journey.
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, left: 0, right: 0, bottom: 0 }),
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- The native safe-area host has no insets in Jest.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

function Mail() {
  const navigation = useRef<SplitHostCommands>(null);
  return (
    <InboxProvider>
      <MailNavigation
        ref={navigation}
        composer={null}
        topColumnForCollapsing="supplementary"
        primary={
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="All inboxes"
            onPress={() => navigation.current?.show('supplementary')}>
            <Text>Mailboxes</Text>
          </Pressable>
        }
        inbox={{
          selected: undefined,
          onSelect: () => undefined,
          onBack: () => navigation.current?.show('primary'),
        }}
      />
    </InboxProvider>
  );
}

describe('phone mail navigation', () => {
  /* oxlint-disable vitest/max-expects -- One native/button Back journey checks retained state and its scroll bridge. */
  it('retains search and filters through native and button Back while Mailboxes remains the predecessor', async () => {
    expect.hasAssertions();
    const fixture = createPersistentInbox(
      makeMockInboxStorage(),
      createMockMailSession('open-read-relaunch').mail.list,
    );
    jest.replaceProperty(
      jest.requireMock<{ mailboxes: typeof mailboxes }>(
        '../src/private-storage.ts',
      ),
      'mailboxes',
      singleMailbox(fixture, 'preview'),
    );
    await render(<Mail />);
    await screen.findByRole('button', {
      name: 'Unread. Oliver Park. Saturday, by the river?',
    });
    expect(screen.queryByText('Mailboxes')).toBeNull();
    expect(
      screen.getByText('Mailboxes', { includeHiddenElements: true }),
    ).toBeDefined();
    await fireEvent.press(screen.getByRole('togglebutton', { name: 'Filter' }));
    await fireEvent.press(screen.getByRole('button', { name: 'Search' }));
    await fireEvent.changeText(
      screen.getByLabelText('Search senders and subjects'),
      'Oliver',
    );
    await screen.findByRole('button', {
      name: 'Unread. Oliver Park. Saturday, by the river?',
    });
    await act(async () => {
      await fireEvent(screen.getByTestId('inbox-screen'), 'dismissed', {
        nativeEvent: { dismissCount: 1 },
      });
    });
    expect(screen.getByText('Mailboxes')).toBeVisible();
    expect(screen.queryByLabelText('Search senders and subjects')).toBeNull();
    await fireEvent.press(screen.getByRole('button', { name: 'All inboxes' }));
    expect(screen.getByLabelText('Search senders and subjects')).toHaveProp(
      'value',
      'Oliver',
    );
    await fireEvent.press(screen.getByRole('button', { name: 'Close Search' }));
    expect(screen.getByRole('togglebutton', { name: 'Filter' })).toHaveProp(
      'accessibilityState',
      { checked: true },
    );
    await fireEvent.scroll(screen.getByLabelText('Inbox messages'), {
      nativeEvent: {
        contentOffset: { x: 0, y: 120 },
        contentSize: { width: 390, height: 1000 },
        layoutMeasurement: { width: 390, height: 400 },
      },
    });
    await fireEvent.press(
      screen.getByRole('button', { name: 'Back to Mailboxes' }),
    );
    await fireEvent.press(screen.getByRole('button', { name: 'All inboxes' }));
    expect(screen.getByLabelText('Inbox messages')).toHaveProp(
      'contentOffset',
      {
        x: 0,
        y: 120,
      },
    );
    expect(screen.getByRole('togglebutton', { name: 'Filter' })).toHaveProp(
      'accessibilityState',
      { checked: true },
    );
  });
  /* oxlint-enable vitest/max-expects */
});
