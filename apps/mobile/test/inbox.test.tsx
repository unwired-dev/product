import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { makeMockInboxStorage } from '@private-email/mail-core/mock-storage';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createRegistration } from '@private-email/mail-core/registration';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { useState } from 'react';
import { Clipboard, Linking } from 'react-native';

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
    // The detail downloads the body; the row keeps Gmail's snippet.
    await expect(screen.findByText('Synthetic body.')).resolves.toBeVisible();
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

  it('reads message bodies from Gmail or this device and opens links only after confirmation', async () => {
    expect.hasAssertions();
    const openURL = jest.spyOn(Linking, 'openURL').mockResolvedValue(true);
    const gmail = createSyntheticGmail();
    gmail.deliver({
      from: 'Maya Chen <maya@example.invalid>',
      subject: 'Garden plan',
      content: {
        html: '<p>See <a href="https://example.invalid/plan">the plan</a>.</p><img src="https://example.invalid/pixel.gif">',
      },
    });
    const store = createGmailInbox(gmail.native);
    function Journey() {
      const [selectedId, setSelectedId] = useState<string>();
      return (
        <InboxProvider store={store}>
          <Inbox
            onSelect={setSelectedId}
            selectedId={selectedId}
          />
          <MessageDetail id={selectedId} />
        </InboxProvider>
      );
    }
    await render(<Journey />);
    await fireEvent.press(
      await screen.findByRole('button', { name: /Garden plan/u }),
    );
    // The sanitized document renders in an isolated WebKit view, hidden until measured.
    const webview = await screen.findByTestId('message-webview');
    expect(webview.props).toMatchObject({
      javaScriptEnabled: false,
      incognito: true,
      allowsLinkPreview: false,
      cacheEnabled: false,
      originWhitelist: ['*'],
      setSupportMultipleWindows: false,
    });
    expect(webview.props.source.html).toContain("default-src 'none'");
    expect(screen.getByLabelText('Opening message')).toBeVisible();
    await act(async () => {
      fireEvent(webview, 'contentSizeChange', {
        nativeEvent: { contentSize: { width: 320, height: 480 } },
      });
      await Promise.resolve();
    });
    expect(screen.queryByLabelText('Opening message')).toBeNull();
    expect(
      screen.getByText('Images in this message are not loaded.'),
    ).toBeVisible();
    // Only the app's own initial document loads; a chosen link is cancelled and confirmed.
    expect(
      webview.props.onShouldStartLoadWithRequest({
        url: 'about:blank',
        navigationType: 'other',
      }),
    ).toBe(true);
    let started: unknown = undefined;
    await act(async () => {
      started = webview.props.onShouldStartLoadWithRequest({
        url: 'about:blank#unwired-link-0',
        navigationType: 'click',
      });
      await Promise.resolve();
    });
    expect([started]).toStrictEqual([false]);
    expect(screen.getByText('Open this link in your browser?')).toBeVisible();
    expect(screen.getByText('https://example.invalid/plan')).toBeVisible();
    expect(openURL).not.toHaveBeenCalled();
    await fireEvent.press(screen.getByRole('button', { name: 'Open link' }));
    expect(openURL).toHaveBeenCalledWith('https://example.invalid/plan');
    expect(screen.queryByText('Open this link in your browser?')).toBeNull();
    // Keyboard access reaches the same confirmation.
    const keyboardLink = screen.getByRole('link', {
      name: 'Open link: the plan',
    });
    expect(keyboardLink.props.focusable).toBe(true);
    await fireEvent.press(keyboardLink);
    expect(screen.getByText('Open this link in your browser?')).toBeVisible();
    await fireEvent.press(screen.getByRole('button', { name: 'Cancel' }));
    // A WebKit failure falls back to the readable text, never to unsanitized HTML.
    await act(async () => {
      fireEvent(webview, 'error', { nativeEvent: {} });
      await Promise.resolve();
    });
    expect(screen.queryByTestId('message-webview')).toBeNull();
    expect(screen.getByRole('link', { name: 'the plan' })).toBeVisible();

    // Without Gmail, a saved body still opens and another one says it needs downloading.
    gmail.deliver({ subject: 'Not downloaded yet' });
    await act(store.load);
    gmail.fail({ code: 'unavailable' }, { code: 'unavailable' });
    await fireEvent.press(
      screen.getByRole('button', { name: /Not downloaded yet/u }),
    );
    await expect(
      screen.findByText(
        'This message is not saved on this device, and Gmail could not be reached to download it.',
      ),
    ).resolves.toBeVisible();
    await fireEvent.press(screen.getByRole('button', { name: /Garden plan/u }));
    await expect(
      screen.findByTestId('message-webview'),
    ).resolves.toBeOnTheScreen();
    await fireEvent.press(
      screen.getByRole('button', { name: /Not downloaded yet/u }),
    );
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Try again' }));
    });
    await expect(screen.findByText('Synthetic body.')).resolves.toBeVisible();

    // A queued confirmation must not hand off the previous owner's destination.
    await fireEvent.press(screen.getByRole('button', { name: /Garden plan/u }));
    await fireEvent.press(
      screen.getByRole('link', { name: 'Open link: the plan' }),
    );
    const previousOwnerConfirmation = screen.getByRole('button', {
      name: 'Open link',
    });
    openURL.mockClear();
    await act(async () => {
      store.forget();
      await fireEvent.press(previousOwnerConfirmation);
    });
    expect(openURL).not.toHaveBeenCalled();
  });

  it('explains a deceptive link and offers copying it instead of opening it', async () => {
    expect.hasAssertions();
    const openURL = jest.spyOn(Linking, 'openURL').mockResolvedValue(true);
    // oxlint-disable-next-line typescript/no-deprecated -- The reader copies through core Clipboard.
    const copy = jest.spyOn(Clipboard, 'setString').mockReturnValue(undefined);
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      subject: 'Account notice',
      content: {
        html: '<p>Sign in at <a href="https://PHISH.invalid:443">https://bank.invalid</a></p>',
      },
    });
    const store = createGmailInbox(gmail.native);
    await render(
      <InboxProvider store={store}>
        <MessageDetail id={id} />
      </InboxProvider>,
    );
    await act(store.load);
    const webview = await screen.findByTestId('message-webview');
    await act(async () => {
      webview.props.onShouldStartLoadWithRequest({
        url: 'about:blank#unwired-link-0',
        navigationType: 'click',
      });
      await Promise.resolve();
    });
    expect(
      screen.getByText('Check this link before opening it:'),
    ).toBeVisible();
    expect(
      screen.getByText('• The link text shows a different address.'),
    ).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Open link' })).toBeNull();
    await fireEvent.press(screen.getByRole('button', { name: 'Copy link' }));
    expect(copy).toHaveBeenCalledWith('https://PHISH.invalid:443');
    expect(openURL).not.toHaveBeenCalled();
  });
  /* oxlint-enable vitest/max-expects */
});
