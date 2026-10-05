import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { makeMockInboxStorage } from '@private-email/mail-core/mock-storage';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createRegistration } from '@private-email/mail-core/registration';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { useState } from 'react';

import type { inbox } from '../src/private-storage.ts';

import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
import { RegistrationGate } from '../src/registration-gate.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  inbox: undefined,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

function InboxJourney() {
  const [selectedId, setSelectedId] = useState<string>();
  return (
    <InboxProvider>
      <Inbox
        onSelect={setSelectedId}
        selectedId={selectedId}
      />
      <MessageDetail id={selectedId} />
    </InboxProvider>
  );
}

describe('preview Inbox', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Each test owns a fresh native-boundary store.
  beforeEach(() => {
    jest.replaceProperty(
      jest.requireMock<{ inbox: typeof inbox }>('../src/private-storage.ts'),
      'inbox',
      createPersistentInbox(
        makeMockInboxStorage(),
        createMockMailSession('open-read-relaunch').mail.list,
      ),
    );
  });

  it('opens the activated message and exposes its selected state', async () => {
    expect.hasAssertions();
    await render(<InboxJourney />);
    const message = await screen.findByRole('button', {
      name: 'Unread. Oliver Park. Saturday, by the river?',
    });
    await fireEvent.press(message);
    expect(
      screen.getByRole('header', { name: 'Saturday, by the river?' }),
    ).toBeVisible();
    expect(message).toBeSelected();
    expect(screen.getByText('oliver@example.com')).toBeVisible();
    expect(screen.queryByText('maya@example.com')).toBeNull();
  });

  it('moves selection to the next activated message without mixing message bodies', async () => {
    expect.hasAssertions();
    await render(<InboxJourney />);
    const first = await screen.findByRole('button', {
      name: 'Unread. Maya Chen. A little more room to think',
    });
    await fireEvent.press(first);
    await fireEvent.press(
      screen.getByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    );
    expect(first).not.toBeSelected();
    expect(
      screen.getByRole('header', { name: 'Saturday, by the river?' }),
    ).toBeVisible();
    expect(
      screen.queryByText(/Could we spend the first ten minutes/u),
    ).toBeNull();
  });

  it('does not show another message when a route contains an unknown identifier', async () => {
    expect.hasAssertions();
    await render(
      <InboxProvider>
        <MessageDetail id="not-in-this-mailbox" />
      </InboxProvider>,
    );
    await expect(
      screen.findByRole('header', { name: 'Message unavailable' }),
    ).resolves.toBeVisible();
    expect(screen.queryByText('maya@example.com')).toBeNull();
  });

  it('commits a read change and recovers it after the view remounts', async () => {
    expect.hasAssertions();
    const app = await render(<InboxJourney />);
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Unread. Maya Chen. A little more room to think',
      }),
    );
    await fireEvent.press(screen.getByRole('button', { name: 'Mark as read' }));
    await expect(
      screen.findByRole('button', { name: 'Mark as unread' }),
    ).resolves.toBeVisible();
    await app.unmount();
    await render(<InboxJourney />);
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Maya Chen. A little more room to think',
      }),
    );
    expect(
      screen.getByRole('button', { name: 'Mark as unread' }),
    ).toBeVisible();
  });

  it('offers recovery from locked storage on the compact message screen', async () => {
    expect.hasAssertions();
    const storage = makeMockInboxStorage();
    let currentOpen: () => Promise<unknown> = () =>
      Promise.reject(Object.assign(new Error('locked'), { code: 'locked' }));
    const store = createPersistentInbox({
      ...storage,
      open: () => currentOpen(),
    });
    await render(
      <InboxProvider store={store}>
        <MessageDetail id="studio-review" />
      </InboxProvider>,
    );
    await expect(screen.findByRole('alert')).resolves.toHaveTextContent(
      /Private storage is locked/u,
    );
    expect(screen.queryByText('maya@example.com')).toBeNull();
    currentOpen = () => storage.open('[]');
    await fireEvent.press(screen.getByRole('button', { name: 'Try again' }));
    await expect(screen.findByText('maya@example.com')).resolves.toBeVisible();
  });
});

describe('connected Gmail Inbox', () => {
  /* oxlint-disable vitest/max-expects -- One journey proves the synchronized list and its recovery states. */
  it('shows synchronized metadata and recovers from lost Gmail permission and connectivity', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
      snippet: 'Coffee first, then the long way home?',
    });
    const store = createGmailInbox(gmail.native);
    const connected = {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      privateSync: 'ready',
      providerSubject: 'synthetic-google-subject',
      address: 'alex@example.invalid',
    } as const;
    const authorizeGmail = jest.fn(() => Promise.resolve(connected));
    const registration = createRegistration({
      restore: () => Promise.resolve(connected),
      authorizeGmail,
      signIn: () => Promise.reject(new Error('Not signing in')),
      link: () => Promise.reject(new Error('Not linking')),
      confirmRecoveryKey: () => Promise.reject(new Error('No key')),
      recoverWithRecoveryKey: () => Promise.reject(new Error('No key')),
      approveEnrollment: () => Promise.reject(new Error('No device')),
      declineEnrollment: () => Promise.reject(new Error('No device')),
      revokeTrustedDevice: () => Promise.reject(new Error('No device')),
      refreshPrivateSync: () => Promise.reject(new Error('No sync')),
      signOut: () => Promise.reject(new Error('Not signing out')),
      deleteProductAccount: () => Promise.reject(new Error('Not deleting')),
    });
    function Connected() {
      const [selectedId, setSelectedId] = useState<string>();
      return (
        <RegistrationGate
          store={registration}
          preview={false}>
          <InboxProvider store={store}>
            <Inbox
              onSelect={setSelectedId}
              selectedId={selectedId}
            />
            <MessageDetail id={selectedId} />
          </InboxProvider>
        </RegistrationGate>
      );
    }
    await render(<Connected />);
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    );
    expect(screen.getByText('alex@example.invalid')).toBeVisible();
    expect(screen.getByText('oliver@example.invalid')).toBeVisible();
    // The row and the detail both show Gmail's snippet; message content is not downloaded.
    expect(
      screen.getAllByText('Coffee first, then the long way home?'),
    ).toHaveLength(2);
    // Read state belongs to Gmail; this slice shows it without changing it.
    expect(screen.queryByRole('button', { name: 'Mark as read' })).toBeNull();

    gmail.fail({ status: 401 });
    gmail.deliver({ subject: 'Arrives after permission returns' });
    await act(store.load);
    expect(
      screen.getByText('Gmail needs your permission again to show new mail.'),
    ).toBeVisible();
    expect(screen.queryByText(/Arrives after permission/u)).toBeNull();
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Allow Gmail access' }),
      );
    });
    expect(authorizeGmail).toHaveBeenCalledWith(false);
    await expect(
      screen.findByText('Arrives after permission returns'),
    ).resolves.toBeVisible();

    gmail.fail({ code: 'unavailable' });
    await act(store.load);
    expect(
      screen.getByText(
        'Gmail could not be reached. Showing mail saved on this device.',
      ),
    ).toBeVisible();
    expect(
      screen.getByRole('header', { name: 'Saturday, by the river?' }),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Try again' }));
    });
    expect(screen.queryByText(/could not be reached/u)).toBeNull();
  });
  /* oxlint-enable vitest/max-expects */
});
