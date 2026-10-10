import type { NativeGmailMailbox } from '@private-email/mail-core/gmail-inbox';

import { gmailAction } from '@private-email/mail-core/gmail-actions';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import {
  createMailboxes,
  singleMailbox,
} from '@private-email/mail-core/mailboxes';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createRegistration } from '@private-email/mail-core/registration';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { makeMockInboxStorage } from '@private-email/mail-core/testing/mock-storage';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-session';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';
import { useState } from 'react';
import { AccessibilityInfo, Clipboard, Linking } from 'react-native';

import type { Selection } from '../src/inbox.tsx';
import type { mailboxes } from '../src/private-storage.ts';

import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
import { RegistrationGate } from '../src/registration-gate.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

const preview = 'preview';
const alex = syntheticMailboxes['alex@example.invalid'];

function InboxJourney() {
  const [selected, setSelected] = useState<Selection>();
  return (
    <InboxProvider>
      <Inbox
        onSelect={setSelected}
        selected={selected}
      />
      <MessageDetail
        id={selected?.id}
        mailbox={selected?.mailbox}
      />
    </InboxProvider>
  );
}

describe('preview Inbox', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Each test owns a fresh native-boundary store.
  beforeEach(() => {
    const fixture = createPersistentInbox(
      makeMockInboxStorage(),
      createMockMailSession('open-read-relaunch').mail.list,
    );
    jest.replaceProperty(
      jest.requireMock<{ mailboxes: typeof mailboxes }>(
        '../src/private-storage.ts',
      ),
      'mailboxes',
      singleMailbox(fixture, preview),
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
        <MessageDetail
          id="not-in-this-mailbox"
          mailbox={preview}
        />
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
      <InboxProvider mailboxes={singleMailbox(store, preview)}>
        <MessageDetail
          id="studio-review"
          mailbox={preview}
        />
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

// The connected Inbox and reader, as the app composes them, over a controlled Gmail mailbox.
function connectedMessage(store: ReturnType<typeof createGmailInbox>) {
  const state = store.getSnapshot();
  if (state.kind !== 'ready' || state.messages[0] === undefined) {
    throw new Error('Expected connected mail');
  }
  return state.messages[0];
}

function renderConnected(
  native: NativeGmailMailbox,
  // Set once another device has removed this one; restore then reports the purged device.
  removed?: Readonly<{ current: boolean }>,
) {
  const connected = {
    kind: 'connected',
    productAccountId: 'synthetic-product-account',
    signInProvider: 'google',
    privateSync: 'ready',
    mailboxes: JSON.stringify([
      { id: alex, address: 'alex@example.invalid', state: 'connected' },
    ]),
  } as const;
  const authorizeGmail = jest.fn(() => Promise.resolve(connected));
  const registration = createRegistration({
    restore: () =>
      Promise.resolve(
        removed?.current === true ? { kind: 'signed-out' } : connected,
      ),
    addMailbox: () => Promise.reject(new Error('Not adding')),
    authorizeGmail,
    removeMailbox: () => Promise.reject(new Error('Not removing')),
    signIn: () => Promise.reject(new Error('Not signing in')),
    link: () => Promise.reject(new Error('Not linking')),
    confirmRecoveryKey: () => Promise.reject(new Error('No key')),
    recoverWithRecoveryKey: () => Promise.reject(new Error('No key')),
    approveEnrollment: () => Promise.reject(new Error('No device')),
    declineEnrollment: () => Promise.reject(new Error('No device')),
    revokeTrustedDevice: () => Promise.reject(new Error('No device')),
    confirmRevocation: () => Promise.reject(new Error('No device')),
    cancelRevocation: () => Promise.reject(new Error('No device')),
    refreshPrivateSync: () => Promise.reject(new Error('No sync')),
    signOut: () => Promise.reject(new Error('Not signing out')),
    deleteProductAccount: () => Promise.reject(new Error('Not deleting')),
  });
  // As the app composes them: the Inbox hands a removal to the registration store.
  const mailboxes = createMailboxes(
    syntheticConnections({ [alex]: { native } }),
    registration,
    {
      removed: () => {
        void registration.deviceRemoved();
      },
    },
  );
  function Connected() {
    const [selected, setSelected] = useState<Selection>();
    return (
      <RegistrationGate
        store={registration}
        preview={false}>
        <InboxProvider mailboxes={mailboxes}>
          <Inbox
            onClose={() => {
              setSelected(undefined);
            }}
            onSelect={setSelected}
            selected={selected}
          />
          <MessageDetail
            id={selected?.id}
            mailbox={selected?.mailbox}
            onClose={() => {
              setSelected(undefined);
            }}
          />
        </InboxProvider>
      </RegistrationGate>
    );
  }
  const rendered = render(<Connected />);
  return {
    authorizeGmail,
    rendered,
    // The connected mailbox's Gmail Inbox, once registration has opened it.
    store: () => {
      const inbox = mailboxes.getSnapshot()[0]?.inbox;
      if (inbox === undefined) {
        throw new Error('Expected the connected mailbox');
      }
      return inbox;
    },
  };
}

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
    const connected = renderConnected(gmail.native);
    const { authorizeGmail } = connected;
    await connected.rendered;
    const store = connected.store();
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
    expect(authorizeGmail).toHaveBeenCalledWith(alex);
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

  it('organizes mail from the reader and the row, keeping an offline archive until Undo', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const travel = gmail.createLabel('Travel');
    const other = gmail.deliver({ subject: 'Tickets for Lisbon' });
    const oliver = gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
    });
    // The legacy cache stays readable while its missing labels are fetched again.
    await createGmailInbox(gmail.native).load();
    await gmail.native.commitMailbox(
      { address: 'alex@example.invalid', generation: '0' },
      gmail.commits.length,
      String(gmail.commits.at(-1)).replaceAll(/,"labels":\[[^\]]*\]/gu, ''),
    );
    const held = holdingListing(gmail.native);
    const connected = renderConnected(held.native);
    await connected.rendered;
    const store = connected.store();
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    );
    expect(screen.getByText('oliver@example.invalid')).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Mark as read' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Labels' })).toBeNull();
    expect(
      screen.getByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    ).toHaveProp('accessibilityActions', []);
    await act(async () => {
      held.release();
      await store.load();
    });
    expect(screen.getByRole('button', { name: 'Labels' })).toBeVisible();
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Mark as read' }),
      );
    });
    expect(
      screen.getByRole('button', {
        name: 'Oliver Park. Saturday, by the river?',
      }),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Star' }));
    });
    expect(screen.getByRole('button', { name: 'Remove star' })).toBeVisible();
    // Every outcome is stated, not only removals that can be undone.
    expect(
      screen.getByText('Starred: “Saturday, by the river?”.'),
    ).toBeVisible();
    await fireEvent.press(screen.getByRole('button', { name: 'Labels' }));
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('checkbox', { name: 'Travel', checked: false }),
      );
    });
    expect(
      screen.getByRole('checkbox', { name: 'Travel', checked: true }),
    ).toBeVisible();
    expect(screen.getByText('Labels: Travel')).toBeVisible();
    expect(gmail.labelsOf(oliver)).toStrictEqual(['INBOX', 'STARRED', travel]);

    // Offline, the archive shows at once and closes the reader; Undo puts the message back.
    gmail.failModify({ code: 'unavailable' });
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Archive' }));
    });
    expect(screen.queryByText('Saturday, by the river?')).toBeNull();
    expect(
      screen.getByText('Archived: “Saturday, by the river?”.'),
    ).toBeVisible();
    expect(
      screen.getByText(
        'One change is saved on this device and waits for Gmail.',
      ),
    ).toBeVisible();
    expect(gmail.labelsOf(oliver)).toContain('INBOX');
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Undo' }));
    });
    expect(
      screen.getByRole('button', {
        name: 'Oliver Park. Saturday, by the river?',
      }),
    ).toBeVisible();
    expect(gmail.labelsOf(oliver).toSorted()).toStrictEqual(
      ['STARRED', travel, 'INBOX'].toSorted(),
    );
    expect(screen.queryByText(/waits for Gmail/u)).toBeNull();

    // VoiceOver offers the same actions on each row; removing the open message closes the reader.
    const lisbon = screen.getByRole('button', {
      name: 'Unread. Maya Chen. Tickets for Lisbon',
    });
    await fireEvent.press(lisbon);
    expect(
      screen.getByRole('header', { name: 'Tickets for Lisbon' }),
    ).toBeVisible();
    await act(async () => {
      await fireEvent(lisbon, 'accessibilityAction', {
        nativeEvent: { actionName: 'trash' },
      });
    });
    expect(screen.queryByText('Tickets for Lisbon')).toBeNull();
    expect(
      screen.getByText('Select a message to start reading.'),
    ).toBeVisible();
    expect(
      screen.getByText('Moved to Trash: “Tickets for Lisbon”.'),
    ).toBeVisible();
    await waitFor(() => {
      expect(gmail.labelsOf(other)).toStrictEqual(['UNREAD', 'TRASH']);
    });
    expect(
      screen.getByText('Moved to Trash: “Tickets for Lisbon”.'),
    ).toHaveProp('accessibilityRole', 'text');
    expect(
      screen.getByText('Moved to Trash: “Tickets for Lisbon”.'),
    ).not.toHaveProp('accessibilityLiveRegion');

    // Refusal semantics survive the single explicit announcement path on mobile too.
    gmail.failModify({ status: 400 });
    await act(async () => {
      await fireEvent(
        screen.getByRole('button', {
          name: 'Oliver Park. Saturday, by the river?',
        }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'archive' } },
      );
    });
    const refusal =
      'Gmail could not archive “Saturday, by the river?”. The Inbox shows it as Gmail has it.';
    const status = screen.getByRole('alert', { name: refusal });
    expect(status).toBeVisible();
    expect(status).not.toHaveProp('accessibilityLiveRegion');
    expect(
      jest
        .mocked(AccessibilityInfo.announceForAccessibility)
        .mock.calls.filter(([message]) => message === refusal),
    ).toStrictEqual([[refusal]]);

    // Foreground verification can close saving after the reader offered Archive.
    await fireEvent.press(
      screen.getByRole('button', {
        name: 'Oliver Park. Saturday, by the river?',
      }),
    );
    held.becomeCacheOnly();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Archive' }));
    });
    const unsaved =
      'The request to archive “Saturday, by the river?” could not be saved. Showing mail saved on this device. Try again to reconnect, then repeat the change.';
    expect(screen.getByRole('alert', { name: unsaved })).toBeVisible();
    expect(
      screen.getByText('Select a message to start reading.'),
    ).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Undo' })).toBeNull();
    expect(
      jest
        .mocked(AccessibilityInfo.announceForAccessibility)
        .mock.calls.filter(([message]) => message === unsaved),
    ).toStrictEqual([[unsaved]]);
  });

  it('names the exhausted action and resolves it through Retry and Discard controls', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const connected = renderConnected(gmail.native);
    await connected.rendered;
    const store = connected.store();
    const target = connectedMessage(store);
    gmail.failModify(
      ...Array.from({ length: 5 }, () => ({ code: 'unavailable' })),
    );
    await act(async () => {
      await store.organize(target, gmailAction.star);
    });
    for (const ignored of [0, 1, 2, 3]) {
      void ignored;
      await act(store.load);
    }
    expect(
      screen.getByText(
        /request to star “Synthetic message 0” after five attempts/u,
      ),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Retry change' }),
      );
    });
    await waitFor(() => {
      expect(gmail.labelsOf(target.id)).toContain('STARRED');
    });
    expect(screen.queryByRole('button', { name: 'Retry change' })).toBeNull();
    gmail.failModify(
      ...Array.from({ length: 5 }, () => ({ code: 'unavailable' })),
    );
    const starred = connectedMessage(store);
    await act(async () => {
      await store.organize(starred, gmailAction.unstar);
    });
    for (const ignored of [0, 1, 2, 3]) {
      void ignored;
      await act(store.load);
    }
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Discard change' }),
      );
    });
    await waitFor(() => {
      expect(
        screen.queryByRole('button', { name: 'Discard change' }),
      ).toBeNull();
    });
    expect(gmail.labelsOf(target.id)).toContain('STARRED');
  });

  it('hands a device found removed while organizing to the account page explanation', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
    });
    const removed = { current: false };
    await renderConnected(gmail.native, removed).rendered;
    const row = await screen.findByRole('button', {
      name: 'Unread. Oliver Park. Saturday, by the river?',
    });
    // Native code purges this device when the write's Trusted Device check finds it removed.
    removed.current = true;
    gmail.failModify({ code: 'mailbox-revoked' });
    await act(async () => {
      await fireEvent(row, 'accessibilityAction', {
        nativeEvent: { actionName: 'star' },
      });
    });
    await expect(
      screen.findByText('This device was removed'),
    ).resolves.toBeVisible();
    expect(screen.queryByText('Saturday, by the river?')).toBeNull();
    expect(screen.queryByText(/stored data has been kept/u)).toBeNull();
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
    const mailboxes = singleMailbox(store, alex);
    function Journey() {
      const [selected, setSelected] = useState<Selection>();
      return (
        <InboxProvider mailboxes={mailboxes}>
          <Inbox
            onSelect={setSelected}
            selected={selected}
          />
          <MessageDetail
            id={selected?.id}
            mailbox={selected?.mailbox}
          />
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

    // Input queued for one message and delivered after another opens reveals nothing, and a
    // confirmation hides when its message is replaced.
    await act(store.load);
    await fireEvent.press(
      await screen.findByRole('button', { name: /Garden plan/u }),
    );
    const gardenView = await screen.findByTestId('message-webview');
    const queuedChoice = gardenView.props.onShouldStartLoadWithRequest;
    await fireEvent.press(
      await screen.findByRole('link', { name: 'Open link: the plan' }),
    );
    expect(screen.getByText('https://example.invalid/plan')).toBeVisible();
    await fireEvent.press(
      screen.getByRole('button', { name: /Not downloaded yet/u }),
    );
    await expect(screen.findByText('Synthetic body.')).resolves.toBeVisible();
    expect(screen.queryByText('https://example.invalid/plan')).toBeNull();
    await act(async () => {
      queuedChoice({
        url: 'about:blank#unwired-link-0',
        navigationType: 'click',
      });
      await Promise.resolve();
    });
    expect(screen.queryByText('Open this link in your browser?')).toBeNull();
    expect(screen.queryByText('https://example.invalid/plan')).toBeNull();
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
      <InboxProvider mailboxes={singleMailbox(store, alex)}>
        <MessageDetail
          id={id}
          mailbox={alex}
        />
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
