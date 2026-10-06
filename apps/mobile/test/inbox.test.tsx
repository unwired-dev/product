import { gmailAction } from '@private-email/mail-core/gmail-actions';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { makeMockInboxStorage } from '@private-email/mail-core/mock-storage';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createRegistration } from '@private-email/mail-core/registration';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';
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

// The connected Inbox and reader, as the app composes them, over a controlled Gmail store.
function connectedMessage(store: ReturnType<typeof createGmailInbox>) {
  const state = store.getSnapshot();
  if (state.kind !== 'ready' || state.messages[0] === undefined) {
    throw new Error('Expected connected mail');
  }
  return state.messages[0];
}

function renderConnected(
  createStore: (
    registration: ReturnType<typeof createRegistration>,
  ) => ReturnType<typeof createGmailInbox>,
  // Set once another device has removed this one; restore then reports the purged device.
  removed?: Readonly<{ current: boolean }>,
) {
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
    restore: () =>
      Promise.resolve(
        removed?.current === true ? { kind: 'signed-out' } : connected,
      ),
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
  const store = createStore(registration);
  function Connected() {
    const [selectedId, setSelectedId] = useState<string>();
    return (
      <RegistrationGate
        store={registration}
        preview={false}>
        <InboxProvider store={store}>
          <Inbox
            onClose={() => {
              setSelectedId(undefined);
            }}
            onSelect={setSelectedId}
            selectedId={selectedId}
          />
          <MessageDetail
            id={selectedId}
            onClose={() => {
              setSelectedId(undefined);
            }}
          />
        </InboxProvider>
      </RegistrationGate>
    );
  }
  return { authorizeGmail, rendered: render(<Connected />) };
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
    const store = createGmailInbox(gmail.native);
    const { authorizeGmail, rendered } = renderConnected(() => store);
    await rendered;
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

  it('organizes mail from the reader and the row, keeping an offline archive until Undo', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const travel = gmail.createLabel('Travel');
    const other = gmail.deliver({ subject: 'Tickets for Lisbon' });
    const oliver = gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
    });
    const store = createGmailInbox(gmail.native);
    await renderConnected(() => store).rendered;
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    );
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
  });

  it('names the exhausted action and resolves it through Retry and Discard controls', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const store = createGmailInbox(gmail.native);
    await renderConnected(() => store).rendered;
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
    // As the app composes them: the Inbox hands a removal to the registration store.
    await renderConnected(
      (registration) =>
        createGmailInbox(gmail.native, {
          removed: () => {
            void registration.deviceRemoved();
          },
        }),
      removed,
    ).rendered;
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
  /* oxlint-enable vitest/max-expects */
});
