import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { makeMockInboxStorage } from '@private-email/mail-core/mock-storage';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createRegistration } from '@private-email/mail-core/registration';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { act, fireEvent, render, within } from '@testing-library/react-native';
import { AccessibilityInfo, View } from 'react-native';

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

function holdingListing(
  native: ReturnType<typeof createSyntheticGmail>['native'],
) {
  let cacheOnly = false;
  let release: () => void = () => undefined;
  // oxlint-disable-next-line promise/avoid-new -- Explicit provider suspension, released by the journey.
  const listing = new Promise<void>((resolve) => {
    release = resolve;
  });
  return {
    release,
    becomeCacheOnly: () => {
      cacheOnly = true;
    },
    native: {
      ...native,
      openMailbox: async () => ({
        ...(await native.openMailbox()),
        ...(cacheOnly ? { availability: 'retry' } : {}),
      }),
      gmailRequest: async (...args: Parameters<typeof native.gmailRequest>) => {
        if (args[0] === 'messages') {
          await listing;
        }
        return native.gmailRequest(...args);
      },
    },
  };
}

describe('mac windows over a connected Gmail mailbox', () => {
  it('keeps confirmations window-local and rejects queued links after replacing a message', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    gmail.deliver({
      subject: 'Garden plan',
      content: { html: '<a href="https://example.invalid/plan">the plan</a>' },
    });
    gmail.deliver({
      subject: 'Not downloaded yet',
      content: { text: 'Synthetic body.' },
    });
    gmail.deliver({
      subject: 'Other window',
      content: {
        html: '<a href="https://example.invalid/other">other plan</a>',
      },
    });
    jest.replaceProperty(
      jest.requireMock<{ inbox: typeof inbox }>('../src/private-storage.ts'),
      'inbox',
      createGmailInbox(gmail.native),
    );
    const app = await render(
      <Windows
        first
        second
      />,
    );
    const first = within(app.getByTestId('inbox-window-first'));
    const second = within(app.getByTestId('inbox-window-second'));
    await fireEvent.press(
      await first.findByRole('button', { name: /Garden plan/u }),
    );
    const gardenView = await first.findByTestId('message-webview');
    const queuedChoice = gardenView.props.onShouldStartLoadWithRequest;
    await fireEvent.press(
      await first.findByRole('link', { name: 'Open link: the plan' }),
    );
    expect(first.getByText('https://example.invalid/plan')).toBeVisible();
    expect(second.queryByText('https://example.invalid/plan')).toBeNull();
    await fireEvent.press(
      await second.findByRole('button', { name: /Other window/u }),
    );
    await fireEvent.press(
      await second.findByRole('link', { name: 'Open link: other plan' }),
    );
    await fireEvent.press(
      first.getByRole('button', { name: /Not downloaded yet/u }),
    );
    await expect(first.findByText('Synthetic body.')).resolves.toBeVisible();
    await act(() => {
      queuedChoice({
        url: 'about:blank#unwired-link-0',
        navigationType: 'click',
      });
    });
    expect({
      firstDestination: first.queryByText('https://example.invalid/plan'),
      firstConfirmation: first.queryByText('Open this link in your browser?'),
    }).toStrictEqual({ firstDestination: null, firstConfirmation: null });
    await app.rerender(
      <Windows
        first={false}
        second
      />,
    );
    expect(
      within(app.getByTestId('inbox-window-second')).getByText(
        'https://example.invalid/other',
      ),
    ).toBeVisible();
  });

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
    // Both windows can read the legacy cache while its missing labels are fetched again.
    await createGmailInbox(gmail.native).load();
    await gmail.native.commitMailbox(
      { address: 'alex@example.invalid', generation: '0' },
      gmail.commits.length,
      String(gmail.commits.at(-1)).replaceAll(/,"labels":\[[^\]]*\]/gu, ''),
    );
    const held = holdingListing(gmail.native);
    const store = createGmailInbox(held.native);
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
    for (const window of [first, second]) {
      expect(window.queryByRole('button', { name: 'Archive' })).toBeNull();
      expect(window.queryByRole('button', { name: 'Labels' })).toBeNull();
      expect(window.getByRole('button', { name: maya })).toHaveProp(
        'accessibilityActions',
        [],
      );
    }
    await act(async () => {
      held.release();
      await store.load();
    });
    expect(first.getByRole('button', { name: 'Labels' })).toBeVisible();
    expect(second.getByRole('button', { name: 'Labels' })).toBeVisible();
    // Archiving in one window closes its reader and updates the other, which keeps its selection;
    // Undo from either window brings the message back to both.
    await act(async () => {
      await fireEvent.press(first.getByRole('button', { name: 'Archive' }));
    });
    expect(first.getByText('Select a message to start reading.')).toBeVisible();
    expect(second.queryByRole('button', { name: maya })).toBeNull();
    expect(second.getByText('oliver@example.invalid')).toBeVisible();
    expect(
      second.getByLabelText('Archived: “A little more room to think”.'),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(second.getByRole('button', { name: 'Undo' }));
    });
    expect(first.getByRole('button', { name: maya })).toBeVisible();
    expect(second.getByRole('button', { name: maya })).toBeVisible();
    expect(
      gmail.modifies.map(({ add, remove }) => [add, remove]),
    ).toStrictEqual([
      [[], ['INBOX']],
      [['INBOX'], []],
    ]);

    // A VoiceOver row action that removes the selected message closes that reader too; Undo keeps
    // it closed, the other window keeps its selection, and the outcome is announced once.
    const announce = jest.mocked(AccessibilityInfo.announceForAccessibility);
    await fireEvent.press(first.getByRole('button', { name: maya }));
    expect(first.getByText('maya@example.invalid')).toBeVisible();
    await act(async () => {
      await fireEvent(
        first.getByRole('button', { name: maya }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'trash' } },
      );
    });
    expect(first.getByText('Select a message to start reading.')).toBeVisible();
    expect(second.getByText('oliver@example.invalid')).toBeVisible();
    // Each outcome is announced once although both windows show it.
    expect(announce.mock.calls).toStrictEqual([
      ['Archived: “A little more room to think”.'],
      ['Moved back to the Inbox: “A little more room to think”.'],
      ['Moved to Trash: “A little more room to think”.'],
    ]);
    // Each successful notice is text and requests no separate live-region announcement.
    for (const window of [first, second]) {
      const status = window.getByLabelText(
        'Moved to Trash: “A little more room to think”.',
      );
      expect(status).toHaveProp('accessibilityRole', 'text');
      expect(status).not.toHaveProp('accessibilityLiveRegion');
    }
    await act(async () => {
      await fireEvent.press(first.getByRole('button', { name: 'Undo' }));
    });
    expect(first.getByRole('button', { name: maya })).toBeVisible();
    expect(first.getByText('Select a message to start reading.')).toBeVisible();
    expect(second.getByText('oliver@example.invalid')).toBeVisible();
    // The same action again is a new outcome with the same words, and is announced again.
    await act(async () => {
      await fireEvent(
        second.getByRole('button', { name: maya }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'trash' } },
      );
    });
    expect(second.getByText('oliver@example.invalid')).toBeVisible();
    expect(announce).toHaveBeenCalledTimes(5);
    expect(announce).toHaveBeenLastCalledWith(
      'Moved to Trash: “A little more room to think”.',
    );
    await act(async () => {
      await fireEvent.press(second.getByRole('button', { name: 'Undo' }));
    });
    expect(second.getByRole('button', { name: maya })).toBeVisible();

    // A refusal keeps its alert semantics while sharing one explicit announcement.
    gmail.failModify({ status: 400 });
    await act(async () => {
      await fireEvent(
        second.getByRole('button', { name: oliver }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'star' } },
      );
    });
    const refusal =
      'Gmail could not star “Saturday, by the river?”. The Inbox shows it as Gmail has it.';
    for (const window of [first, second]) {
      const status = window.getByRole('alert', { name: refusal });
      expect(status).toBeVisible();
      expect(status).not.toHaveProp('accessibilityLiveRegion');
    }
    expect(
      announce.mock.calls.filter(([message]) => message === refusal),
    ).toStrictEqual([[refusal]]);

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
    // The failed save is visible in both windows after Archive closes its reader, announced once.
    held.becomeCacheOnly();
    await act(async () => {
      await fireEvent.press(second.getByRole('button', { name: 'Archive' }));
    });
    const unsaved =
      'The request to archive “Saturday, by the river?” could not be saved. Showing mail saved on this device. Try again to reconnect, then repeat the change.';
    for (const window of [first, second]) {
      expect(window.getByRole('alert', { name: unsaved })).toBeVisible();
      expect(window.queryByRole('button', { name: 'Undo' })).toBeNull();
    }
    expect(
      second.getByText('Select a message to start reading.'),
    ).toBeVisible();
    expect(
      announce.mock.calls.filter(([message]) => message === unsaved),
    ).toStrictEqual([[unsaved]]);
  });

  it('hands a device found removed while organizing to the account page explanation', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({
      from: 'Maya Chen <maya@example.invalid>',
      subject: 'A little more room to think',
    });
    const connected = {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      privateSync: 'ready',
      providerSubject: 'synthetic-google-subject',
      address: 'alex@example.invalid',
    } as const;
    // After native code purges this device, restore finds it signed out.
    const restored: Array<typeof connected | { kind: 'signed-out' }> = [
      connected,
    ];
    const registration = createRegistration({
      restore: () => Promise.resolve(restored.at(-1)),
      authorizeGmail: () => Promise.resolve(connected),
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
    // As the app composes them: the Inbox hands a removal to the registration store.
    jest.replaceProperty(
      jest.requireMock<{ inbox: typeof inbox }>('../src/private-storage.ts'),
      'inbox',
      createGmailInbox(gmail.native, {
        removed: () => {
          void registration.deviceRemoved();
        },
      }),
    );
    const app = await render(
      <RegistrationGate
        store={registration}
        preview={false}>
        <InboxWindow windowId="first" />
      </RegistrationGate>,
    );
    const row = await app.findByRole('button', { name: maya });
    restored.push({ kind: 'signed-out' });
    gmail.failModify({ code: 'mailbox-revoked' });
    await act(async () => {
      await fireEvent(row, 'accessibilityAction', {
        nativeEvent: { actionName: 'star' },
      });
    });
    await expect(
      app.findByText('This device was removed'),
    ).resolves.toBeVisible();
    expect(app.queryByText('A little more room to think')).toBeNull();
    expect(app.queryByText(/stored data has been kept/u)).toBeNull();
  });
  /* oxlint-enable vitest/max-expects */
});
