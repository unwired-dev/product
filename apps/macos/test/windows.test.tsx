import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { makeMockInboxStorage } from '@private-email/mail-core/mock-storage';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createRegistration } from '@private-email/mail-core/registration';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { act, fireEvent, render, within } from '@testing-library/react-native';
import { View } from 'react-native';

import type { inbox } from '../src/private-storage.ts';

import { RegistrationGate } from '../src/registration-gate.tsx';
import { PreviewWindow as InboxWindow } from '../src/window.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  inbox: undefined,
}));

const maya = 'Unread. Maya Chen. A little more room to think';
const oliver = 'Unread. Oliver Park. Saturday, by the river?';

function Windows({
  first,
  second,
}: {
  readonly first: boolean;
  readonly second: boolean;
}) {
  return (
    <View>
      {first ? (
        <InboxWindow
          key="first"
          windowId="first"
        />
      ) : null}
      {second ? (
        <InboxWindow
          key="second"
          windowId="second"
        />
      ) : null}
    </View>
  );
}

describe('mac window selection with the shared mock mailbox', () => {
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

  it('keeps selections independent and preserves the remaining window when another closes', async () => {
    expect.hasAssertions();
    const app = await render(
      <Windows
        first
        second
      />,
    );
    const first = within(app.getByTestId('inbox-window-first'));
    const second = within(app.getByTestId('inbox-window-second'));
    await fireEvent.press(await first.findByRole('button', { name: maya }));
    await fireEvent.press(await second.findByRole('button', { name: oliver }));
    expect(first.getByText('maya@example.com')).toBeVisible();
    expect(second.getByText('oliver@example.com')).toBeVisible();
    await app.rerender(
      <Windows
        first={false}
        second
      />,
    );
    expect(app.getByText('oliver@example.com')).toBeVisible();
    await app.rerender(
      <Windows
        first
        second
      />,
    );
    const reopened = within(app.getByTestId('inbox-window-first'));
    await expect(
      reopened.findByText('Select a message to start reading.'),
    ).resolves.toBeVisible();
    expect(
      within(app.getByTestId('inbox-window-second')).getByText(
        'oliver@example.com',
      ),
    ).toBeVisible();
  });

  it('can read the same fixture after all views unmount, without carrying a closed selection', async () => {
    expect.hasAssertions();
    const app = await render(
      <Windows
        first
        second={false}
      />,
    );
    await fireEvent.press(await app.findByRole('button', { name: maya }));
    expect(app.getByText('maya@example.com')).toBeVisible();
    await app.rerender(
      <Windows
        first={false}
        second={false}
      />,
    );
    await app.rerender(
      <Windows
        first={false}
        second
      />,
    );
    await expect(
      app.findByText('Select a message to start reading.'),
    ).resolves.toBeVisible();
    await fireEvent.press(await app.findByRole('button', { name: oliver }));
    expect(app.getByText('oliver@example.com')).toBeVisible();
    expect(app.queryByText('maya@example.com')).toBeNull();
  });

  it('shares committed read state while each window keeps its selection', async () => {
    expect.hasAssertions();
    const app = await render(
      <Windows
        first
        second
      />,
    );
    const first = within(app.getByTestId('inbox-window-first'));
    const second = within(app.getByTestId('inbox-window-second'));
    await fireEvent.press(await first.findByRole('button', { name: maya }));
    await fireEvent.press(await second.findByRole('button', { name: oliver }));
    await fireEvent.press(first.getByRole('button', { name: 'Mark as read' }));
    await second.findByRole('button', {
      name: 'Maya Chen. A little more room to think',
    });
    expect(first.getByText('maya@example.com')).toBeVisible();
    expect(second.getByText('oliver@example.com')).toBeVisible();
    await fireEvent.press(second.getByRole('button', { name: 'Mark as read' }));
    await expect(
      first.findByRole('button', {
        name: 'Oliver Park. Saturday, by the river?',
      }),
    ).resolves.toBeVisible();
    await app.rerender(
      <Windows
        first={false}
        second={false}
      />,
    );
    await app.rerender(
      <Windows
        first
        second={false}
      />,
    );
    await expect(
      app.findByRole('button', {
        name: 'Maya Chen. A little more room to think',
      }),
    ).resolves.toBeVisible();
    expect(app.getByText('Select a message to start reading.')).toBeVisible();
  });
});

describe('mac windows over a connected Gmail mailbox', () => {
  /* oxlint-disable vitest/max-expects -- One journey proves both windows across the synchronization states. */
  it('shares the synchronized Inbox and its recovery states while each window keeps its selection', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({
      from: 'Maya Chen <maya@example.invalid>',
      subject: 'A little more room to think',
      snippet: 'Notes for Thursday',
    });
    gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
      snippet: 'Coffee first',
    });
    const store = createGmailInbox(gmail.native);
    jest.replaceProperty(
      jest.requireMock<{ inbox: typeof inbox }>('../src/private-storage.ts'),
      'inbox',
      store,
    );
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
    const app = await render(
      <View>
        {['first', 'second'].map((windowId) => (
          <RegistrationGate
            key={windowId}
            store={registration}
            preview={false}>
            <InboxWindow windowId={windowId} />
          </RegistrationGate>
        ))}
      </View>,
    );
    const first = within(await app.findByTestId('inbox-window-first'));
    const second = within(app.getByTestId('inbox-window-second'));
    await fireEvent.press(await first.findByRole('button', { name: maya }));
    await fireEvent.press(await second.findByRole('button', { name: oliver }));
    expect(first.getByText('maya@example.invalid')).toBeVisible();
    expect(second.getByText('oliver@example.invalid')).toBeVisible();
    // Each window reads its own message's body; a body another window opened is not read again.
    await expect(first.findByText('Synthetic body.')).resolves.toBeVisible();
    await expect(second.findByText('Synthetic body.')).resolves.toBeVisible();
    await fireEvent.press(second.getByRole('button', { name: maya }));
    expect(second.getByText('maya@example.invalid')).toBeVisible();
    expect(second.getByText('Synthetic body.')).toBeVisible();
    expect(
      gmail.requests.filter(({ query }) => query.get('format') === 'full'),
    ).toHaveLength(2);
    await fireEvent.press(second.getByRole('button', { name: oliver }));
    // Read state belongs to Gmail; this slice shows it without changing it.
    expect(first.queryByRole('button', { name: 'Mark as read' })).toBeNull();

    gmail.fail({ status: 401 });
    await act(store.load);
    expect(
      second.getByRole('button', { name: 'Allow Gmail access' }),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(
        first.getByRole('button', { name: 'Allow Gmail access' }),
      );
      await Promise.resolve();
    });
    expect(authorizeGmail).toHaveBeenCalledWith(false);
    gmail.fail({ code: 'unavailable' });
    await act(store.load);
    expect(
      first.getByLabelText(
        'Gmail could not be reached. Showing mail saved on this device.',
      ),
    ).toBeVisible();
    expect(second.getByText('oliver@example.invalid')).toBeVisible();
  });
  /* oxlint-enable vitest/max-expects */
});
