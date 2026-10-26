import type { ReactNode, Ref } from 'react';

import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { fireEvent, screen } from '@testing-library/react-native';
import { renderRouter } from 'expo-router/testing-library';

import RootLayout from '../app/_layout.tsx';
import InboxWelcome from '../app/index.tsx';
import MessageRoute from '../app/message/[id].tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Keep this host's installed Reanimated and linking substitutes, which support its CSS API.
jest.mock('expo-router/build/testing-library/mocks', () => ({}));
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Exercise the scenario's actual page instead of the production-inert entry.
jest.mock('../src/categorization-spike.ts', () =>
  jest.requireActual('../src/categorization-spike-page.tsx'),
);
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Substitute only the native mailbox boundary with a real Inbox store.
jest.mock('../src/private-storage.ts', () => ({ mailboxes: undefined }));
// oxlint-disable-next-line vitest/prefer-import-in-mock -- This research build bypasses provider sign-in.
jest.mock('@private-email/mail-core/registration-mode', () => ({
  previewInbox: true,
}));
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Native background execution is outside this routing journey.
jest.mock('../src/freshness.ts', () => ({
  pollGmailWhileActive: jest.fn(),
  scheduleGmailFreshness: jest.fn(),
}));
jest.mock(
  // oxlint-disable-next-line vitest/prefer-import-in-mock -- The library's stand-in for native safe-area measurement.
  'react-native-safe-area-context',
  () => jest.requireActual('react-native-safe-area-context/jest/mock').default,
);
// oxlint-disable-next-line vitest/prefer-import-in-mock -- UIKit supplies column appearance events; Expo Router and the shell remain real.
jest.mock('react-native-screens/experimental', () => {
  const { createElement, useImperativeHandle } = jest.requireActual('react');
  const { View } = jest.requireActual('react-native');
  function Host({
    children,
    ref,
    ...props
  }: {
    readonly children: ReactNode;
    readonly ref: Ref<Readonly<{ show: (column: string) => void }>>;
  }) {
    useImperativeHandle(ref, () => ({ show: jest.fn() }));
    return createElement(View, props, children);
  }
  return { SafeAreaView: View, Split: { Host, Column: View } };
});

async function openSpike() {
  const gmail = createSyntheticGmail();
  gmail.deliver({
    subject: 'Garden plan',
    content: { text: 'Synthetic garden body.' },
  });
  jest.replaceProperty(
    jest.requireMock('../src/private-storage.ts'),
    'mailboxes',
    singleMailbox(createGmailInbox(gmail.native), 'garden'),
  );
  try {
    await renderRouter({
      _layout: RootLayout,
      index: InboxWelcome,
      'message/[id]': MessageRoute,
    });
  } finally {
    // Router's test renderer installs fake timers; the real Effect store uses its own scheduler.
    jest.useRealTimers();
  }
  await expect(
    screen.findByText('Categorization Spike'),
  ).resolves.toBeVisible();
}

describe('categorization spike shell navigation', () => {
  it('opens a selected Inbox message while the spike is showing with the real Router mounted', async () => {
    expect.hasAssertions();
    await openSpike();
    expect(
      screen.getByText('Select a message to start reading.', {
        includeHiddenElements: true,
      }),
    ).not.toBeVisible();
    expect(screen.queryByText('Select a message to start reading.')).toBeNull();
    await fireEvent.press(
      await screen.findByRole('button', { name: /Garden plan/u }),
    );
    await expect(
      screen.findByText('Synthetic garden body.'),
    ).resolves.toBeVisible();
    expect(screen.queryByText('Categorization Spike')).toBeNull();
  });

  it('retires the spike only after the collapsed Inbox column appears', async () => {
    expect.hasAssertions();
    await openSpike();
    // An expanded sidebar appearing beside the spike must leave it open.
    await fireEvent(screen.getByTestId('inbox-column'), 'didAppear');
    expect(screen.getByText('Categorization Spike')).toBeVisible();
    await fireEvent(screen.getByTestId('mail-split'), 'collapse');
    expect(screen.getByText('Categorization Spike')).toBeVisible();
    await fireEvent(screen.getByTestId('inbox-column'), 'didAppear');
    expect(screen.queryByText('Categorization Spike')).toBeNull();
    await expect(
      screen.findByText('Select a message to start reading.'),
    ).resolves.toBeVisible();
  });
});
