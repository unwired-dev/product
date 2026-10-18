import type { View as NativeView } from 'react-native';
import type { SplitHostCommands } from 'react-native-screens/experimental';

import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { useRef } from 'react';
import { Pressable, Text } from 'react-native';

import { BackNavigation } from '../src/back-navigation.tsx';
import { MailNavigation } from '../src/mail-navigation.tsx';

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

function Mail() {
  const navigation = useRef<SplitHostCommands>(null);
  return (
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
      supplementary={
        <BackNavigation onBack={() => navigation.current?.show('primary')}>
          <Text>Inbox messages</Text>
        </BackNavigation>
      }
    />
  );
}

it('keeps Mailboxes beneath Inbox and uses its Back action after a native pop', async () => {
  expect.hasAssertions();
  await render(<Mail />);
  expect({
    inbox: screen.getByText('Inbox messages'),
    visibleMailboxes: screen.queryByText('Mailboxes'),
    retainedMailboxes: screen.getByText('Mailboxes', {
      includeHiddenElements: true,
    }),
  }).toMatchObject({
    inbox: expect.anything(),
    visibleMailboxes: null,
    retainedMailboxes: expect.anything(),
  });
  await act(async () => {
    await fireEvent(screen.getByTestId('inbox-screen'), 'dismissed', {
      nativeEvent: { dismissCount: 1 },
    });
  });
  expect({
    mailboxes: screen.getByText('Mailboxes'),
    inbox: screen.queryByText('Inbox messages'),
  }).toMatchObject({ mailboxes: expect.anything(), inbox: null });
  await fireEvent.press(screen.getByRole('button', { name: 'All inboxes' }));
  expect(screen.getByText('Inbox messages')).toBeVisible();
});
