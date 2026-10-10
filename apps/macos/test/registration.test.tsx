import type {
  Registration,
  RegistrationSnapshot,
} from '@private-email/mail-core/registration';
import type { SyntheticAddress } from '@private-email/mail-core/testing/registration-session';

import { english } from '@private-email/localization';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import {
  createRegistration,
  mailboxesOf,
} from '@private-email/mail-core/registration';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import {
  createMockRegistrationSession,
  createSyntheticAccount,
  syntheticEnrollmentCode,
  syntheticMailboxes,
  syntheticRecoveryKey,
  syntheticRenewedRecoveryKey,
  syntheticReplacementRecoveryKey,
  syntheticSecondTrustedDevice,
  syntheticTrustedDevice,
} from '@private-email/mail-core/testing/registration-session';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';
import { useContext, useMemo, useState } from 'react';
import { AppState, Pressable, Text } from 'react-native';

import type { Selection } from '../src/inbox.tsx';
import type { MailboxList } from '../src/private-storage.ts';

import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
import { AccountContext, RegistrationGate } from '../src/registration-gate.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// The connection list native code reports for one connected synthetic mailbox.
const connectedTo = (address: SyntheticAddress) =>
  JSON.stringify([
    { id: syntheticMailboxes[address], address, state: 'connected' },
  ]);
const alex = syntheticMailboxes['alex@example.invalid'];

// Whether a synthetic Gmail request from `connection` is an online search of Alex's mailbox.
const asksAlex = (
  connection: string,
  query: ReadonlyArray<readonly [string, string]>,
) => connection === alex && query.some(([name]) => name === 'q');

// Whether a synthetic Gmail request downloads a full message, as recent-body prefetch does.
const downloadsBody = (query: ReadonlyArray<readonly [string, string]>) =>
  query.some(([name, value]) => name === 'format' && value === 'full');

// The app's Inbox composition: one controlled Gmail mailbox per connection of `registration`.
const gmailMailboxes = (
  registration: Pick<Registration, 'subscribe' | 'getSnapshot'>,
  connections: Parameters<typeof syntheticConnections>[0],
) => createMailboxes(syntheticConnections(connections), registration);

// The Inbox a connected account opens, over a synthetic Gmail mailbox per connection.
function ConnectedInbox() {
  const account = useContext(AccountContext);
  const listed = JSON.stringify(account?.mailboxes ?? []);
  const mailboxes = useMemo(() => {
    const connections = mailboxesOf({ mailboxes: listed });
    return gmailMailboxes(
      {
        subscribe: () => () => undefined,
        getSnapshot: () => ({
          snapshot: {
            kind: 'connected',
            productAccountId: 'synthetic-product-account',
            signInProvider: 'google',
            mailboxes: listed,
          },
          busy: false,
          failed: false,
        }),
      },
      Object.fromEntries(
        connections.map(({ id, address }) => [
          id,
          createSyntheticGmail({ address, messages: 2 }),
        ]),
      ),
    );
  }, [listed]);
  return (
    <InboxProvider mailboxes={mailboxes}>
      <Inbox
        onSelect={() => undefined}
        selected={undefined}
      />
    </InboxProvider>
  );
}

const openAccount = async () => {
  const account = await screen.findByRole('button', { name: 'Account' });
  await act(async () => {
    await fireEvent.press(account);
  });
};

// Hosts without another device of the account never enroll, approve or recover one.
const noEnrollment = {
  recoverWithRecoveryKey: () =>
    Promise.reject(new Error('No device to recover')),
  approveEnrollment: () => Promise.reject(new Error('No device to approve')),
  declineEnrollment: () => Promise.reject(new Error('No device to decline')),
  revokeTrustedDevice: () => Promise.reject(new Error('No device to remove')),
  confirmRevocation: () => Promise.reject(new Error('No device to remove')),
  cancelRevocation: () => Promise.reject(new Error('No device to remove')),
  refreshPrivateSync: () => Promise.reject(new Error('No private sync')),
  signOut: () => Promise.reject(new Error('Not signing out')),
  deleteProductAccount: () => Promise.reject(new Error('Not deleting')),
  removeMailbox: () => Promise.reject(new Error('Not removing a mailbox')),
};

describe('product registration', () => {
  it('opens saved Gmail mail offline and verifies registration before retrying', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 2 });
    await createGmailInbox(gmail.native).load();
    const session = createMockRegistrationSession('registration-success');
    const connected = {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      mailboxes: connectedTo('alex@example.invalid'),
      privateSync: 'ready',
    } as const;
    let snapshot: unknown = { ...connected, kind: 'cached' };
    let openMailbox: () => Promise<unknown> = async () => ({
      ...(await gmail.native.openMailbox()),
      availability: 'retry',
    });
    const store = createRegistration({
      ...session.native,
      restore: () => Promise.resolve(snapshot),
    });
    const mailboxes = gmailMailboxes(store, {
      [alex]: { native: { ...gmail.native, openMailbox: () => openMailbox() } },
    });
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        <InboxProvider mailboxes={mailboxes}>
          <Inbox
            onSelect={() => undefined}
            selected={undefined}
          />
        </InboxProvider>
      </RegistrationGate>,
    );
    await expect(
      screen.findByText('Synthetic message 1'),
    ).resolves.toBeVisible();
    expect(
      screen.getByText(
        'Gmail could not be reached. Showing mail saved on this device.',
      ),
    ).toBeVisible();
    await openAccount();
    expect(
      screen.getByRole('header', { name: 'Saved Gmail Inbox' }),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Open Inbox' }));
    });
    gmail.deliver({ subject: 'After verification' });
    snapshot = connected;
    ({ openMailbox } = gmail.native);
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Try again' }));
    });
    await expect(
      screen.findByText('After verification'),
    ).resolves.toBeVisible();
    expect(store.getSnapshot().snapshot).toStrictEqual(connected);
  });

  it('waits for registration verification before loading Gmail on activation', async () => {
    expect.hasAssertions();
    const listenersBeforeRender = jest.mocked(AppState.addEventListener).mock
      .calls.length;
    const connected = {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      mailboxes: connectedTo('alex@example.invalid'),
    } as const;
    let finish: (snapshot: unknown) => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Hold the native restore response to prove foreground ordering.
    const resumed = new Promise<unknown>((resolve) => {
      finish = resolve;
    });
    let restore = () => Promise.resolve<unknown>(connected);
    let prematureReads = 0;
    const gmail = createSyntheticGmail({ messages: 1 });
    let openMailbox = () => gmail.native.openMailbox();
    const store = createRegistration({
      ...noEnrollment,
      ...createMockRegistrationSession('registration-success').native,
      restore: () => restore(),
    });
    const mailboxes = gmailMailboxes(store, {
      [alex]: { native: { ...gmail.native, openMailbox: () => openMailbox() } },
    });
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        <InboxProvider mailboxes={mailboxes}>
          <Inbox
            onSelect={() => undefined}
            selected={undefined}
          />
        </InboxProvider>
      </RegistrationGate>,
    );
    await expect(
      screen.findByText('Synthetic message 0'),
    ).resolves.toBeVisible();
    gmail.deliver({ subject: 'After foreground verification' });
    restore = () => resumed;
    openMailbox = () => {
      prematureReads += 1;
      return Promise.reject(
        Object.assign(new Error('Not verified'), { code: 'gmail-unavailable' }),
      );
    };
    await act(async () => {
      for (const [, activate] of jest
        .mocked(AppState.addEventListener)
        .mock.calls.slice(listenersBeforeRender)) {
        activate('active');
      }
      await Promise.resolve();
    });
    expect(prematureReads).toBe(0);
    await act(async () => {
      ({ openMailbox } = gmail.native);
      finish(connected);
    });
    await expect(
      screen.findByText('After foreground verification'),
    ).resolves.toBeVisible();
  });

  it('retains setup after declined consent and connects a reselected Gmail account after remount', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-declined');
    const first = await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Connect your Gmail' }),
    ).resolves.toBeVisible();
    expect(
      screen.queryByRole('header', { name: 'Gmail connected' }),
    ).toBeNull();
    await first.unmount();
    await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Choose another Google mailbox',
        }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Gmail connected' }),
    ).resolves.toBeVisible();
    expect(
      screen.getByText('other@example.invalid is connected on this device.'),
    ).toBeVisible();
  });

  it('offers interactive sign-in to recover a retained account after interruption', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    await session.native.signIn('google');
    let addMailbox: (chooseAccount: boolean) => Promise<unknown> = () =>
      Promise.reject(new Error('Synthetic identity needs sign-in'));
    const store = createRegistration({
      ...session.native,
      signIn: (provider) => {
        ({ addMailbox } = session.native);
        return session.native.signIn(provider);
      },
      addMailbox: (chooseAccount) => addMailbox(chooseAccount),
    });
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Authorize Gmail' }),
      );
    });
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Sign in again with Google',
        }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Gmail connected' }),
    ).resolves.toBeVisible();
  });

  it('continues Apple sign-in into separate Gmail authorization and keeps the relay address as contact information', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-declined');
    await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Apple' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Connect your Gmail' }),
    ).resolves.toBeVisible();
    expect(
      screen.getByText(/Signing in with Apple does not give access to mail/u),
    ).toBeVisible();
    expect(
      screen.getByText(
        'Signed in with Apple. Contact email: relay@privaterelay.example.invalid.',
      ),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Choose another Google mailbox',
        }),
      );
    });
    // The connected mailbox comes from the Gmail grant, never the Apple address.
    await expect(
      screen.findByText('other@example.invalid is connected on this device.'),
    ).resolves.toBeVisible();
    expect(
      screen.getByRole('button', { name: 'Add another Gmail mailbox' }),
    ).toBeVisible();
  });

  /* oxlint-disable vitest/max-expects -- One journey proves adding, switching, reauthorizing and removing mailboxes. */
  it('adds, switches, reauthorizes and removes Gmail mailboxes without mixing their mail', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    const store = createRegistration(session.native);
    const gmail = {
      alex: createSyntheticGmail({ address: 'alex@example.invalid' }),
      other: createSyntheticGmail({ address: 'other@example.invalid' }),
    };
    gmail.alex.deliver({ subject: 'Only for Alex', at: Date.UTC(2026, 8, 2) });
    gmail.other.deliver({
      subject: 'Only for Other',
      at: Date.UTC(2026, 8, 1),
    });
    const mailboxes = gmailMailboxes(store, {
      [alex]: gmail.alex,
      [syntheticMailboxes['other@example.invalid']]: gmail.other,
    });
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        <InboxProvider mailboxes={mailboxes}>
          <Inbox
            onSelect={() => undefined}
            selected={undefined}
          />
        </InboxProvider>
      </RegistrationGate>,
    );
    const press = async (name: string) => {
      await act(async () => {
        await fireEvent.press(await screen.findByRole('button', { name }));
      });
    };
    await press('Sign in with Google');
    await act(async () => {
      await fireEvent.changeText(
        await screen.findByLabelText('Last four characters'),
        syntheticRecoveryKey.slice(-4),
      );
    });
    await press('Confirm Recovery Key');
    // One mailbox: its rows need no mailbox name.
    await expect(
      screen.findByRole('button', { name: 'Unread. Maya Chen. Only for Alex' }),
    ).resolves.toBeVisible();
    await openAccount();
    await press('Add another Gmail mailbox');
    expect(
      screen.getByText(
        'alex@example.invalid, other@example.invalid are connected on this device.',
      ),
    ).toBeVisible();
    // Adding a mailbox that is already connected authorizes it again; nothing is duplicated.
    session.choose('alex@example.invalid');
    await press('Add another Gmail mailbox');
    expect(screen.getAllByText('alex@example.invalid')).toHaveLength(1);
    await press('Open Inbox');
    // Both mailboxes together, newest first, each row naming its own mailbox.
    const unified = await screen.findAllByRole('button', { name: /^Unread/u });
    expect(unified.map((row) => row.props.accessibilityLabel)).toStrictEqual([
      'Unread. Maya Chen. Only for Alex. In alex@example.invalid',
      'Unread. Maya Chen. Only for Other. In other@example.invalid',
    ]);
    await press('other@example.invalid');
    expect(
      screen.getByRole('button', { name: 'other@example.invalid' }),
    ).toBeSelected();
    expect(screen.queryByText('Only for Alex')).toBeNull();
    expect(screen.getByText('Only for Other')).toBeVisible();
    await press('All inboxes');

    // Alex's grant is refused at the next verification; Other's mail stays available.
    session.expire('alex@example.invalid');
    await act(store.resume);
    expect(screen.queryByText('Only for Alex')).toBeNull();
    expect(screen.getByText('Only for Other')).toBeVisible();
    expect(
      screen.getByText(
        'alex@example.invalid: Gmail needs your permission again to show new mail.',
      ),
    ).toBeVisible();
    await press('Allow Gmail access for alex@example.invalid');
    await expect(screen.findByText('Only for Alex')).resolves.toBeVisible();

    // Removal asks first, then removes only that mailbox's mail from this device.
    await openAccount();
    await press('Remove other@example.invalid');
    expect(
      screen.getByText(
        /Removing other@example\.invalid deletes its Gmail access/u,
      ),
    ).toBeVisible();
    await press('Remove other@example.invalid');
    expect(screen.queryByText('other@example.invalid')).toBeNull();
    await press('Open Inbox');
    await expect(
      screen.findByRole('button', { name: 'Unread. Maya Chen. Only for Alex' }),
    ).resolves.toBeVisible();
    expect(screen.queryByText('Only for Other')).toBeNull();
    expect(gmail.other.modifies).toStrictEqual([]);
  });
  /* oxlint-enable vitest/max-expects */

  it('searches saved senders and subjects across mailboxes, shows saved bodies, and keeps only the current answer', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    const store = createRegistration(session.native);
    const gmail = {
      alex: createSyntheticGmail({ address: 'alex@example.invalid' }),
      other: createSyntheticGmail({ address: 'other@example.invalid' }),
    };
    // Recent mail, so prefetch saves single-part bodies and leaves the multipart one on demand.
    const now = Date.now();
    gmail.alex.deliver({
      from: 'Maya Chen <maya@example.invalid>',
      subject: 'Studio review',
      at: now - 120_000,
      content: { text: 'Notes', single: true },
    });
    const cafe = gmail.alex.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Café on Saturday',
      at: now - 180_000,
      content: { text: 'Coffee', html: '<p>Coffee</p>' },
    });
    gmail.other.deliver({
      from: 'Maya Chen <maya@example.invalid>',
      subject: 'Invoice',
      at: now - 60_000,
      content: { text: 'Invoice', single: true },
    });
    // Holds Alex's next saved-body lookup until released.
    let holding: Promise<void> | undefined = undefined;
    let release: () => void = () => undefined;
    const connections = syntheticConnections({
      [alex]: gmail.alex,
      [syntheticMailboxes['other@example.invalid']]: gmail.other,
    });
    // Holds Alex's recent-body prefetch download until released.
    let releasePrefetch: () => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Explicit prefetch suspension, released by the journey.
    const prefetch = new Promise<void>((resolve) => {
      releasePrefetch = resolve;
    });
    const mailboxes = createMailboxes(
      {
        ...connections,
        gmailRequest: async (path, query, mailbox) => {
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Only Alex's body download waits.
          if (mailbox.connection === alex && downloadsBody(query)) {
            await prefetch;
          }
          return connections.gmailRequest(path, query, mailbox);
        },
        listMessageBodies: async (mailbox, ids) => {
          const held = holding;
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Only a held lookup waits.
          if (held !== undefined && mailbox.connection === alex) {
            holding = undefined;
            await held;
          }
          return connections.listMessageBodies(mailbox, ids);
        },
      },
      store,
    );
    const opened: Selection[] = [];
    function Searching({ list }: { readonly list: MailboxList }) {
      const [selected, setSelected] = useState<Selection>();
      return (
        <InboxProvider mailboxes={list}>
          <Inbox
            onSelect={(selection) => {
              opened.push(selection);
              setSelected(selection);
            }}
            selected={selected}
          />
          <MessageDetail
            id={selected?.id}
            mailbox={selected?.mailbox}
          />
          <Pressable
            accessibilityRole="button"
            onPress={() => {
              setSelected(undefined);
            }}>
            <Text>Close reader</Text>
          </Pressable>
        </InboxProvider>
      );
    }
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        <Searching list={mailboxes} />
      </RegistrationGate>,
    );
    const press = async (name: string) => {
      await act(async () => {
        await fireEvent.press(await screen.findByRole('button', { name }));
      });
    };
    const search = async (query: string) => {
      await act(async () => {
        await fireEvent.changeText(
          await screen.findByLabelText('Search senders and subjects'),
          query,
        );
      });
    };
    const rows = () =>
      screen
        .queryAllByRole('button', { name: /^Unread/u })
        .map((row) => row.props.accessibilityLabel);
    await press('Sign in with Google');
    await act(async () => {
      await fireEvent.changeText(
        await screen.findByLabelText('Last four characters'),
        syntheticRecoveryKey.slice(-4),
      );
    });
    await press('Confirm Recovery Key');
    await openAccount();
    await press('Add another Gmail mailbox');
    await press('Open Inbox');
    // A result searched while prefetch is still downloading its body becomes saved once the body
    // is, without a new query or selection.
    await search('studio');
    await waitFor(() => {
      expect(rows()).toStrictEqual([
        'Unread. Maya Chen. Studio review. In alex@example.invalid. Downloads from Gmail when opened',
      ]);
    });
    await act(async () => {
      releasePrefetch();
      await prefetch;
    });
    await waitFor(() => {
      expect(rows()).toStrictEqual([
        'Unread. Maya Chen. Studio review. In alex@example.invalid. Saved on this device',
      ]);
    });
    await waitFor(() => {
      expect(gmail.alex.bodyCommits).toHaveLength(2);
    });
    await waitFor(() => {
      expect(gmail.other.bodyCommits).toHaveLength(1);
    });
    const requests = gmail.alex.requests.length + gmail.other.requests.length;

    // Every word matches a sender name, address or subject, ignoring case and accents, across
    // both mailboxes newest first; each result says whether its body is on this device.
    await search('maya');
    await waitFor(() => {
      expect(rows()).toStrictEqual([
        'Unread. Maya Chen. Invoice. In other@example.invalid. Saved on this device',
        'Unread. Maya Chen. Studio review. In alex@example.invalid. Saved on this device',
      ]);
    });
    await search('CAFE oliver');
    await waitFor(() => {
      expect(rows()).toStrictEqual([
        'Unread. Oliver Park. Café on Saturday. In alex@example.invalid. Downloads from Gmail when opened',
      ]);
    });
    await search('nothing like this');
    await expect(
      screen.findByText(
        'No mail saved on this device matches “nothing like this”.',
      ),
    ).resolves.toBeVisible();
    // Searching asks Gmail nothing.
    expect(gmail.alex.requests.length + gmail.other.requests.length).toBe(
      requests,
    );

    // A slower answer for an earlier query never replaces the current one.
    // oxlint-disable-next-line promise/avoid-new -- Hold one lookup, released by the journey.
    holding = new Promise((resolve) => {
      release = resolve;
    });
    const stale = holding;
    await search('studio');
    await search('invoice');
    await waitFor(() => {
      expect(rows()).toStrictEqual([
        'Unread. Maya Chen. Invoice. In other@example.invalid. Saved on this device',
      ]);
    });
    await act(async () => {
      release();
      await stale;
    });
    expect(rows()).toStrictEqual([
      'Unread. Maya Chen. Invoice. In other@example.invalid. Saved on this device',
    ]);

    // One mailbox's view searches only its own mail.
    await search('maya');
    await press('alex@example.invalid');
    await waitFor(() => {
      expect(rows()).toStrictEqual([
        'Unread. Maya Chen. Studio review. In alex@example.invalid. Saved on this device',
      ]);
    });
    await press('All inboxes');

    // A result opens through the reader; once its body is saved, the result says so.
    await search('cafe');
    await press(
      'Unread. Oliver Park. Café on Saturday. In alex@example.invalid. Downloads from Gmail when opened',
    );
    expect(opened).toStrictEqual([{ mailbox: alex, id: cafe }]);
    await screen.findByRole('header', { name: 'Café on Saturday' });
    const body = await screen.findByTestId('message-webview');
    await act(async () => {
      await fireEvent(body, 'contentSizeChange', {
        nativeEvent: { contentSize: { width: 320, height: 120 } },
      });
    });
    await waitFor(() => {
      expect(
        screen.getByRole('header', { name: 'Café on Saturday' }),
      ).toBeVisible();
      expect(body.props.source.html).toContain('Coffee');
      expect(screen.getByLabelText('Message')).toBeVisible();
    });
    await press('Close reader');
    await waitFor(() => {
      expect(rows()).toStrictEqual([
        'Unread. Oliver Park. Café on Saturday. In alex@example.invalid. Saved on this device',
      ]);
    });

    // A removed mailbox's mail leaves the results.
    await openAccount();
    await press('Remove other@example.invalid');
    await press('Remove other@example.invalid');
    await press('Open Inbox');
    await search('maya');
    await waitFor(() => {
      expect(rows()).toStrictEqual([
        'Unread. Maya Chen. Studio review. Saved on this device',
      ]);
    });
  });

  /* oxlint-disable vitest/max-expects -- One journey proves asking, reading, failures and stale answers. */
  it('searches Gmail online when asked, opens a result, keeps saved results through an outage, and drops a stale answer', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    const store = createRegistration(session.native);
    const gmail = {
      alex: createSyntheticGmail({ address: 'alex@example.invalid' }),
      other: createSyntheticGmail({ address: 'other@example.invalid' }),
    };
    gmail.alex.deliver({
      from: 'Maya Chen <maya@example.invalid>',
      subject: 'Studio review',
      at: Date.UTC(2026, 8, 3),
    });
    // Only Gmail still has this one: it left the Inbox.
    const archived = gmail.alex.deliver({
      from: 'Maya Chen <maya@example.invalid>',
      subject: 'Studio archive',
      at: Date.UTC(2026, 8, 1),
      content: { text: 'Archived studio notes' },
    });
    gmail.alex.archive(archived);
    gmail.other.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Plans',
      at: Date.UTC(2026, 8, 2),
      content: { text: 'Meet Maya at the studio', single: true },
    });
    const connections = syntheticConnections({
      [alex]: gmail.alex,
      [syntheticMailboxes['other@example.invalid']]: gmail.other,
    });
    // Holds Alex's next online search until released.
    let holding: Promise<void> | undefined = undefined;
    const mailboxes = createMailboxes(
      {
        ...connections,
        gmailRequest: async (path, query, mailbox) => {
          const held = holding;
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Only a held search waits.
          if (held !== undefined && asksAlex(mailbox.connection, query)) {
            holding = undefined;
            await held;
          }
          return connections.gmailRequest(path, query, mailbox);
        },
      },
      store,
    );
    function Searching() {
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
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        <Searching />
      </RegistrationGate>,
    );
    const press = async (name: string) => {
      await act(async () => {
        await fireEvent.press(await screen.findByRole('button', { name }));
      });
    };
    const search = async (query: string) => {
      await act(async () => {
        await fireEvent.changeText(
          await screen.findByLabelText('Search senders and subjects'),
          query,
        );
      });
    };
    const rows = () =>
      screen
        .queryAllByRole('button', { name: /^Unread/u })
        .map((row) => row.props.accessibilityLabel);
    await press('Sign in with Google');
    await act(async () => {
      await fireEvent.changeText(
        await screen.findByLabelText('Last four characters'),
        syntheticRecoveryKey.slice(-4),
      );
    });
    await press('Confirm Recovery Key');
    await openAccount();
    await press('Add another Gmail mailbox');
    await press('Open Inbox');

    // Saved results come first; Gmail is searched only when asked, across both mailboxes.
    await search('studio');
    await waitFor(() => {
      expect(rows()).toHaveLength(1);
    });
    expect(
      gmail.alex.requests.filter(({ query }) => query.has('q')),
    ).toStrictEqual([]);
    await press('Search Gmail for “studio”');
    await expect(
      screen.findByRole('header', { name: 'From Gmail' }),
    ).resolves.toBeVisible();
    await waitFor(() => {
      expect(rows().slice(1)).toStrictEqual([
        'Unread. Maya Chen. Studio review. In alex@example.invalid',
        'Unread. Oliver Park. Plans. In other@example.invalid',
        'Unread. Maya Chen. Studio archive. In alex@example.invalid',
      ]);
    });
    expect(rows()[0]).toMatch(/^Unread\. Maya Chen\. Studio review\./u);

    // Changing to one mailbox and back discards the online answer even with the same query.
    await press('alex@example.invalid');
    await press('Search Gmail for “studio”');
    await waitFor(() => {
      expect(rows()).toHaveLength(3);
    });
    expect(
      rows().filter((row) => row.includes('other@example.invalid')),
    ).toHaveLength(0);
    await press('All inboxes');
    await expect(
      screen.findByRole('button', { name: 'Search Gmail for “studio”' }),
    ).resolves.toBeVisible();
    expect(screen.queryByRole('header', { name: 'From Gmail' })).toBeNull();
    await press('Search Gmail for “studio”');
    await waitFor(() => {
      expect(rows()).toHaveLength(4);
    });

    // A result outside the Inbox opens through the reader without being saved.
    await press('Unread. Maya Chen. Studio archive. In alex@example.invalid');
    await expect(
      screen.findByRole('header', { name: 'Studio archive' }),
    ).resolves.toBeVisible();
    await waitFor(() => {
      expect(
        gmail.alex.requests
          .filter(({ path }) => path === `messages/${archived}`)
          .map(({ query }) => query.get('format')),
      ).toContain('full');
    });
    expect([...gmail.alex.cachedBodies().keys()]).not.toContain(archived);
    await press('Download notes.txt');
    await expect(
      screen.findByRole('button', { name: 'Open notes.txt' }),
    ).resolves.toBeVisible();
    await press('Open notes.txt');
    await press('Share notes.txt');
    expect(gmail.alex.presentations).toStrictEqual([
      { name: 'notes.txt', action: 'open' },
      { name: 'notes.txt', action: 'share' },
    ]);
    expect(gmail.other.savedFiles.size).toBe(0);

    // A new query drops the earlier answer until Gmail is asked again. One mailbox's outage
    // leaves the other's results and every saved result.
    await search('maya');
    await expect(
      screen.findByRole('button', { name: 'Search Gmail for “maya”' }),
    ).resolves.toBeVisible();
    expect(screen.queryByRole('header', { name: 'From Gmail' })).toBeNull();
    gmail.other.fail({ code: 'unavailable' });
    await press('Search Gmail for “maya”');
    await expect(
      screen.findByText(
        'other@example.invalid: Gmail could not be reached. Mail saved on this device is still shown.',
      ),
    ).resolves.toBeVisible();
    await waitFor(() => {
      expect(rows()).toHaveLength(3);
    });
    // Asking again searches every mailbox afresh.
    await press('Search Gmail again');
    await waitFor(() => {
      expect(rows()).toHaveLength(4);
    });
    expect(screen.queryByText(/Gmail could not be reached/u)).toBeNull();

    // A reply for a query that changed meanwhile is never shown.
    let release: () => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Hold one search, released by the journey.
    holding = new Promise((resolve) => {
      release = resolve;
    });
    const stale = holding;
    await search('archive');
    await press('Search Gmail for “archive”');
    await expect(
      screen.findByLabelText('Searching Gmail'),
    ).resolves.toBeVisible();
    await search('plans');
    await act(async () => {
      release();
      await stale;
    });
    await expect(
      screen.findByRole('button', { name: 'Search Gmail for “plans”' }),
    ).resolves.toBeVisible();
    expect(screen.queryByRole('header', { name: 'From Gmail' })).toBeNull();
    // Returning to the old query must not revive its completed, stale request.
    await search('archive');
    await expect(
      screen.findByRole('button', { name: 'Search Gmail for “archive”' }),
    ).resolves.toBeVisible();
    expect(screen.queryByRole('header', { name: 'From Gmail' })).toBeNull();
    await search('plans');
    // Only the saved result remains.
    expect(rows()).toStrictEqual([
      'Unread. Oliver Park. Plans. In other@example.invalid. Downloads from Gmail when opened',
    ]);
    await press(
      'Unread. Oliver Park. Plans. In other@example.invalid. Downloads from Gmail when opened',
    );
    await waitFor(() => {
      expect(gmail.alex.savedFiles.size).toBe(0);
    });
  });
  /* oxlint-enable vitest/max-expects */

  it('links Google from account settings and keeps both sign-in methods after remount', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-link');
    const first = await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Apple' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Gmail connected' }),
    ).resolves.toBeVisible();
    // The Gmail grant is a Mailbox Connection, not a Linked Sign-In.
    expect(
      screen.getByText(/Only Apple opens this Product Account/u),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Link Google sign-in' }),
      );
    });
    const linked = 'Sign in with Apple or Google to open this Product Account.';
    await expect(screen.findByText(linked)).resolves.toBeVisible();
    await first.unmount();
    await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await expect(screen.findByText(linked)).resolves.toBeVisible();
    expect(
      screen.queryByRole('button', { name: /^Link .* sign-in$/u }),
    ).toBeNull();
  });

  it('explains that an Apple identity owned by another Product Account is not linked', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    const store = createRegistration(session.native);
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    expect(
      screen.getByText(/First verify Google, then sign in with Apple\./u),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Link Apple sign-in' }),
      );
    });
    await expect(
      screen.findByRole('alert', {
        name: /That Apple sign-in already belongs to another Product Account/u,
      }),
    ).resolves.toBeVisible();
  });

  it('forgets the account page choice when the Product Account signs out', async () => {
    expect.hasAssertions();
    const connected = {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      privateSync: 'ready',
      mailboxes: connectedTo('other@example.invalid'),
    } as const;
    const store = createRegistration({
      restore: () => Promise.resolve(connected),
      signIn: () => Promise.resolve(connected),
      addMailbox: () => Promise.resolve(connected),
      authorizeGmail: () => Promise.resolve(connected),
      link: () => Promise.reject(new Error('Not linking')),
      confirmRecoveryKey: () => Promise.reject(new Error('No key')),
      ...noEnrollment,
      signOut: () => Promise.resolve({ kind: 'signed-out' }),
    });
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        <ConnectedInbox />
      </RegistrationGate>,
    );
    await openAccount();
    await act(async () => {
      await store.signOut();
    });
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    // The next sign-in lands where its setup decides, not on the page chosen before.
    await expect(
      screen.findByRole('button', { name: 'Account' }),
    ).resolves.toBeVisible();
  });

  it('shows setup that appears after the person returned to the Inbox', async () => {
    expect.hasAssertions();
    const connected = {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      privateSync: 'ready',
      mailboxes: connectedTo('other@example.invalid'),
    } as const;
    let current: RegistrationSnapshot = connected;
    const store = createRegistration({
      restore: () => Promise.resolve(current),
      signIn: () => Promise.resolve(current),
      addMailbox: () => Promise.resolve(current),
      authorizeGmail: () => Promise.resolve(current),
      link: () => Promise.reject(new Error('Not linking')),
      confirmRecoveryKey: () => Promise.reject(new Error('No key')),
      ...noEnrollment,
    });
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        <ConnectedInbox />
      </RegistrationGate>,
    );
    await openAccount();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Open Inbox' }));
    });
    // Another device asks for approval; the earlier choice of the Inbox does not hide it.
    current = {
      ...connected,
      enrollmentRequest: 'synthetic-request',
      enrollmentDevice: 'iPad',
    };
    await act(async () => {
      await store.restore();
    });
    await expect(
      screen.findByRole('header', { name: 'Approve a new device' }),
    ).resolves.toBeVisible();
    expect(screen.queryByRole('button', { name: 'Account' })).toBeNull();

    // This device can leave its pending approval for later; unchanged setup stays bypassed.
    current = {
      ...connected,
      privateSync: 'enrollment-pending',
      enrollmentCode: '1111 2222 3333',
    };
    await act(async () => {
      await store.resume();
    });
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Open Inbox' }));
    });
    await act(async () => {
      await store.resume();
    });
    await expect(
      screen.findByRole('button', { name: 'Account' }),
    ).resolves.toBeVisible();

    // Expiry renews that request while keeping enrollment-pending: the new code needs attention.
    current = {
      ...current,
      enrollmentCode: '4444 5555 6666',
      enrollmentNotice: 'renewed',
    };
    await act(async () => {
      await store.resume();
    });
    await expect(
      screen.findByRole('header', { name: 'Approve this device' }),
    ).resolves.toBeVisible();
    expect(screen.getByText('4444 5555 6666')).toBeVisible();
  });

  it('recovers an unverifiable Apple account through a Google link made on another device without new Gmail consent', async () => {
    expect.hasAssertions();
    const account = {
      productAccountId: 'synthetic-apple-product-account',
      signInProvider: 'apple',
    } as const;
    const store = createRegistration({
      // This device's saved receipt predates the link.
      restore: () =>
        Promise.resolve({
          kind: 'mailbox-needed',
          ...account,
          reason: 'unavailable',
        }),
      signIn: (provider) =>
        Promise.resolve({
          kind: 'connected',
          ...account,
          signInProvider: provider,
          alternateSignIn: 'apple',
          mailboxes: connectedTo('alex@example.invalid'),
        }),
      addMailbox: () =>
        Promise.reject(new Error('Gmail consent must not restart')),
      authorizeGmail: () =>
        Promise.reject(new Error('Gmail consent must not restart')),
      link: () => Promise.reject(new Error('Not linking')),
      confirmRecoveryKey: () =>
        Promise.reject(new Error('No Recovery Key to confirm')),
      ...noEnrollment,
    });
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        <ConnectedInbox />
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Sign in with Google instead',
        }),
      );
    });
    await openAccount();
    await expect(
      screen.findByRole('header', { name: 'Gmail connected' }),
    ).resolves.toBeVisible();
    expect(screen.queryByRole('alert')).toBeNull();
    expect(store.getSnapshot().snapshot).toMatchObject({
      ...account,
      signInProvider: 'google',
    });
  });

  /* oxlint-disable vitest/max-expects -- One journey proves setup confirmation and the Inbox it opens. */
  it('presents the Recovery Key until its final group is confirmed, then shows the encrypted mailbox list', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        <ConnectedInbox />
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    await expect(
      screen.findByText('Encrypted mailbox list: alex@example.invalid.'),
    ).resolves.toBeVisible();
    const entry = screen.getByLabelText('Last four characters');
    await act(async () => {
      await fireEvent.changeText(entry, '0000');
    });
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Confirm Recovery Key' }),
      );
    });
    expect(screen.getByRole('alert')).toHaveTextContent(
      /does not match the end of your Recovery Key/u,
    );
    expect(screen.getByText(syntheticRecoveryKey)).toBeVisible();
    await act(async () => {
      await fireEvent.changeText(
        entry,
        // Separators and case are ignored, as in native confirmation.
        [...syntheticRecoveryKey.slice(-4).toLowerCase()].join(' '),
      );
    });
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Confirm Recovery Key' }),
      );
    });
    // Confirmed setup opens the synchronized Gmail Inbox; the account page stays reachable.
    await expect(
      screen.findByRole('button', {
        name: 'Unread. Maya Chen. Synthetic message 0',
      }),
    ).resolves.toBeVisible();
    expect(screen.getByText('alex@example.invalid')).toBeVisible();
    await openAccount();
    await expect(
      screen.findByRole('header', { name: 'Private sync is on' }),
    ).resolves.toBeVisible();
    expect(screen.queryByText(syntheticRecoveryKey)).toBeNull();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Open Inbox' }));
    });
    await expect(
      screen.findByRole('button', { name: 'Account' }),
    ).resolves.toBeVisible();
  });

  /* oxlint-enable vitest/max-expects */
  /* oxlint-disable vitest/max-expects -- One journey proves both devices' sides of an approval. */
  it('unlocks a new device only after a trusted device approves the code it shows', async () => {
    expect.hasAssertions();
    const account = createSyntheticAccount();
    const trusted = createRegistration(
      createMockRegistrationSession('registration-success', account).native,
    );
    const added = createRegistration(
      createMockRegistrationSession('registration-enrollment', account).native,
    );
    const show = (store: typeof trusted) =>
      render(
        <RegistrationGate
          store={store}
          preview={false}>
          {null}
        </RegistrationGate>,
      );
    const press = async (name: string) => {
      await act(async () => {
        await fireEvent.press(await screen.findByRole('button', { name }));
      });
    };
    // The first device creates the account keys and synchronizes its mailbox.
    let view = await show(trusted);
    await press('Sign in with Google');
    await expect(
      screen.findByText('Encrypted mailbox list: alex@example.invalid.'),
    ).resolves.toBeVisible();
    await view.unmount();

    // Signing in on another device makes it a Pending Device: no private data, mailbox or links.
    view = await show(added);
    await press('Sign in with Google');
    await expect(
      screen.findByRole('header', { name: 'Add this device' }),
    ).resolves.toBeVisible();
    expect(
      screen.getByRole('header', { name: 'Approve this device' }),
    ).toBeVisible();
    expect(screen.getByTestId('enrollment-code')).toHaveTextContent(
      syntheticEnrollmentCode,
    );
    for (const name of [
      'Check for approval',
      'Unlock with Recovery Key',
      english('accountRemoval.signOut'),
      english('accountRemoval.delete'),
    ]) {
      expect(screen.getByRole('button', { name })).toBeVisible();
    }
    expect(screen.queryByText(/Encrypted mailbox list/u)).toBeNull();
    expect(screen.queryByLabelText('Last four characters')).toBeNull();
    for (const name of ['Link Apple sign-in', 'Check for a new device']) {
      expect(screen.queryByRole('button', { name })).toBeNull();
    }
    await view.unmount();

    // The trusted device approves only with that code; a mistyped one changes nothing.
    view = await show(trusted);
    await press('Check for a new device');
    await expect(
      screen.findByRole('header', { name: 'Approve a new device' }),
    ).resolves.toBeVisible();
    expect(screen.getByText(/Your iPad asked to unlock/u)).toBeVisible();
    const entry = screen.getByLabelText('Code from the new device');
    await act(async () => {
      await fireEvent.changeText(entry, 'H4KP-9QWE-3TRM-7XB3');
    });
    await press('Approve device');
    expect(screen.getByRole('alert')).toHaveTextContent(/code is not valid/u);
    await act(async () => {
      await fireEvent.changeText(
        entry,
        syntheticEnrollmentCode.toLowerCase().replaceAll('-', ' '),
      );
    });
    await press('Approve device');
    expect(
      screen.queryByRole('header', { name: 'Approve a new device' }),
    ).toBeNull();
    expect(screen.queryByRole('alert')).toBeNull();
    await view.unmount();

    // The approved device reads the synchronized mailbox list; Gmail still needs its own grant.
    await show(added);
    await press('Check for approval');
    await expect(
      screen.findByRole('header', { name: 'Private sync is on' }),
    ).resolves.toBeVisible();
    expect(
      screen.getByText('Encrypted mailbox list: alex@example.invalid.'),
    ).toBeVisible();
    expect(screen.queryByTestId('enrollment-code')).toBeNull();
    expect(
      screen.getByRole('header', { name: 'Connect your Gmail' }),
    ).toBeVisible();
    expect(
      screen.getByRole('button', { name: 'Authorize Gmail' }),
    ).toBeVisible();
  });

  it('unlocks a new device with the Recovery Key after a wrong key changes nothing, and offers no reset', async () => {
    expect.hasAssertions();
    const account = createSyntheticAccount();
    const lost = createRegistration(
      createMockRegistrationSession('registration-success', account).native,
    );
    const added = createRegistration(
      createMockRegistrationSession('registration-enrollment', account).native,
    );
    const show = (store: typeof lost) =>
      render(
        <RegistrationGate
          store={store}
          preview={false}>
          {null}
        </RegistrationGate>,
      );
    const press = async (name: string) => {
      await act(async () => {
        await fireEvent.press(await screen.findByRole('button', { name }));
      });
    };
    // The device that created the account keys and saved a mailbox is later lost.
    let view = await show(lost);
    await press('Sign in with Google');
    await expect(
      screen.findByText('Encrypted mailbox list: alex@example.invalid.'),
    ).resolves.toBeVisible();
    await view.unmount();

    // A new device offers the Recovery Key beside approval, and explains that losing both
    // leaves the encrypted data locked; nothing offers to reset it.
    view = await show(added);
    await press('Sign in with Google');
    await expect(
      screen.findByRole('header', { name: 'Use your Recovery Key' }),
    ).resolves.toBeVisible();
    expect(screen.getByTestId('enrollment-code')).toBeVisible();
    expect(
      screen.getByText(/encrypted product data cannot be recovered/u),
    ).toBeVisible();
    expect(screen.queryByRole('button', { name: /reset/iu })).toBeNull();
    const entry = screen.getByLabelText('Recovery Key');
    await act(async () => {
      await fireEvent.changeText(entry, syntheticEnrollmentCode);
    });
    await press('Unlock with Recovery Key');
    expect(screen.getByRole('alert')).toHaveTextContent(
      /does not unlock this Product Account/u,
    );
    expect(
      screen.getByRole('header', { name: 'Approve this device' }),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.changeText(
        entry,
        syntheticRecoveryKey.toLowerCase().replaceAll('-', ' '),
      );
    });
    await press('Unlock with Recovery Key');

    // The device reads the synchronized mailbox list; Gmail still needs its own grant.
    await expect(
      screen.findByRole('header', { name: 'Private sync is on' }),
    ).resolves.toBeVisible();
    expect(
      screen.getByText('Encrypted mailbox list: alex@example.invalid.'),
    ).toBeVisible();
    expect(screen.queryByTestId('enrollment-code')).toBeNull();
    expect(screen.queryByLabelText('Recovery Key')).toBeNull();
    expect(screen.queryByRole('alert')).toBeNull();
    expect(
      screen.getByRole('button', { name: 'Authorize Gmail' }),
    ).toBeVisible();
    await view.unmount();
    await show(added);
    await expect(
      screen.findByRole('header', { name: 'Private sync is on' }),
    ).resolves.toBeVisible();
  });

  /* oxlint-enable vitest/max-expects */

  it('replaces a request that is no longer available and clears the code typed for it', async () => {
    expect.hasAssertions();
    const trusted = {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      privateSync: 'ready',
      mailboxes: connectedTo('alex@example.invalid'),
    } as const;
    let refreshes = 0;
    const store = createRegistration({
      restore: () => Promise.resolve(trusted),
      signIn: () => Promise.reject(new Error('Not signing in')),
      addMailbox: () => Promise.reject(new Error('Not authorizing')),
      authorizeGmail: () => Promise.reject(new Error('Not authorizing')),
      removeMailbox: () => Promise.reject(new Error('Not removing')),
      link: () => Promise.reject(new Error('Not linking')),
      confirmRecoveryKey: () =>
        Promise.reject(new Error('No Recovery Key to confirm')),
      recoverWithRecoveryKey: () =>
        Promise.reject(new Error('No device to recover')),
      // The first request was handled by another trusted device meanwhile.
      approveEnrollment: () =>
        Promise.reject(
          Object.assign(new Error('Request unavailable'), {
            code: 'enrollment-unavailable',
          }),
        ),
      declineEnrollment: () => Promise.reject(new Error('Not declining')),
      revokeTrustedDevice: () => Promise.reject(new Error('Not removing')),
      confirmRevocation: () => Promise.reject(new Error('Not removing')),
      cancelRevocation: () => Promise.reject(new Error('Not removing')),
      signOut: () => Promise.reject(new Error('Not signing out')),
      deleteProductAccount: () => Promise.reject(new Error('Not deleting')),
      refreshPrivateSync: () =>
        Promise.resolve({
          ...trusted,
          enrollmentRequest: `synthetic-request-${(refreshes += 1)}`,
          enrollmentDevice: 'iPad',
        }),
    });
    await store.restoreOnce();
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        <ConnectedInbox />
      </RegistrationGate>,
    );
    await openAccount();
    const press = async (name: string) => {
      await act(async () => {
        await fireEvent.press(await screen.findByRole('button', { name }));
      });
    };
    await press('Check for a new device');
    await act(async () => {
      await fireEvent.changeText(
        screen.getByLabelText('Code from the new device'),
        syntheticEnrollmentCode,
      );
    });
    await press('Approve device');
    expect(screen.getByRole('alert')).toHaveTextContent(/no longer available/u);
    await press('Check for a new device');
    expect(screen.getByLabelText('Code from the new device')).toHaveProp(
      'value',
      '',
    );
  });

  it('shows a locked state instead of onboarding after a locked launch and restores the account once active', async () => {
    expect.hasAssertions();
    const listenersBeforeRender = jest.mocked(AppState.addEventListener).mock
      .calls.length;
    const session = createMockRegistrationSession('registration-success');
    await session.native.signIn('google');
    await session.native.addMailbox(false);
    let restore = (): Promise<unknown> =>
      Promise.reject(Object.assign(new Error('locked'), { code: 'locked' }));
    await render(
      <RegistrationGate
        store={createRegistration({
          ...session.native,
          restore: () => restore(),
        })}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await expect(
      screen.findByRole('header', { name: 'Unlock your device' }),
    ).resolves.toBeVisible();
    expect([
      screen.queryByText('Welcome to Unwired Mail'),
      screen.queryByRole('button'),
      screen.queryByRole('alert'),
    ]).toStrictEqual([null, null, null]);
    ({ restore } = session.native);
    // The React Native Jest preset records AppState listeners on its mock.
    await act(async () => {
      for (const [, activate] of jest
        .mocked(AppState.addEventListener)
        .mock.calls.slice(listenersBeforeRender)) {
        activate('active');
      }
      await Promise.resolve();
    });
    await expect(
      screen.findByRole('header', { name: 'Gmail connected' }),
    ).resolves.toBeVisible();
    restore = () =>
      Promise.resolve({
        kind: 'mailbox-needed',
        productAccountId: 'synthetic-product-account',
        signInProvider: 'google',
        reason: 'unavailable',
      });
    await act(async () => {
      for (const [, activate] of jest
        .mocked(AppState.addEventListener)
        .mock.calls.slice(listenersBeforeRender)) {
        activate('active');
      }
      await Promise.resolve();
    });
    await expect(
      screen.findByRole('header', { name: 'Connect your Gmail' }),
    ).resolves.toBeVisible();
    expect(
      screen.queryByRole('header', { name: 'Gmail connected' }),
    ).toBeNull();
  });

  // Mocked journey: the deterministic Mock Mail Session stands in for native preparation and
  // activation; native and Convex evidence of the protocol is separate.
  /* oxlint-disable vitest/max-expects -- One journey proves the explanation, cancellation, renewal and removal. */
  it('removes another trusted device only after its replacement Recovery Key is confirmed', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-revocation');
    await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    expect(screen.queryByRole('button', { name: 'Remove iPad' })).toBeNull();
    await act(async () => {
      await fireEvent.changeText(
        screen.getByLabelText('Last four characters'),
        syntheticRecoveryKey.slice(-4),
      );
    });
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Confirm Recovery Key' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: english('revocation.title') }),
    ).resolves.toBeVisible();
    const added = english('revocation.added', {
      date: new Intl.DateTimeFormat('en', { dateStyle: 'medium' }).format(
        syntheticTrustedDevice.registeredAt,
      ),
    });
    expect(screen.getByText(added)).toBeVisible();
    const { name } = syntheticTrustedDevice;
    const remove = english('revocation.remove', { name });
    const entry = english('revocation.label');
    const proposal = english('revocation.proposal', { name });
    const prepare = async () => {
      // The first press only explains what removal does and cannot do.
      await act(async () => {
        await fireEvent.press(screen.getByRole('button', { name: remove }));
      });
      expect(
        screen.getByText(english('revocation.confirm', { name })),
      ).toHaveTextContent(
        /only then is iPad removed.*cannot be erased remotely/u,
      );
      await act(async () => {
        await fireEvent.press(screen.getByRole('button', { name: remove }));
      });
    };
    const confirm = async (text: string) => {
      await act(async () => {
        await fireEvent.changeText(screen.getByLabelText(entry), text);
      });
      await act(async () => {
        await fireEvent.press(screen.getByRole('button', { name: remove }));
      });
    };
    await prepare();
    // Prepared, not removed: the replacement key waits for confirmation instead of the list.
    expect(screen.getByRole('header', { name: proposal })).toBeVisible();
    expect(screen.getByTestId('revocation-recovery-key')).toHaveTextContent(
      syntheticReplacementRecoveryKey,
    );
    expect(screen.queryByText(added)).toBeNull();
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: english('revocation.cancel') }),
      );
    });
    // Cancellation changes nothing: the device stays listed and no key is offered.
    expect(screen.queryByTestId('revocation-recovery-key')).toBeNull();
    expect(screen.getByText(added)).toBeVisible();
    expect(
      screen.queryByText(english('revocation.confirm', { name })),
    ).toBeNull();
    await prepare();
    await confirm(syntheticRecoveryKey.slice(-4));
    expect(screen.getByRole('alert')).toHaveTextContent(
      english('revocation.mismatch'),
    );
    expect(screen.getByTestId('revocation-recovery-key')).toHaveTextContent(
      syntheticReplacementRecoveryKey,
    );
    // Another device changed the account: a fresh key must be saved and confirmed again.
    session.changeAccount();
    await confirm(syntheticReplacementRecoveryKey.slice(-4));
    expect(screen.getByRole('alert')).toHaveTextContent(
      english('revocation.renewed'),
    );
    expect(screen.getByTestId('revocation-recovery-key')).toHaveTextContent(
      syntheticRenewedRecoveryKey,
    );
    expect(screen.getByLabelText(entry)).toHaveProp('value', '');
    await confirm(syntheticRenewedRecoveryKey.slice(-4));
    await expect(
      screen.findByText(english('revocation.removed')),
    ).resolves.toBeVisible();
    expect(screen.queryByText(added)).toBeNull();
    expect(screen.queryByTestId('revocation-recovery-key')).toBeNull();
    // The replacement key was confirmed before removal, so nothing else waits for it.
    expect(screen.queryByTestId('recovery-key')).toBeNull();
    expect(
      screen.getByRole('header', { name: 'Private sync is on' }),
    ).toBeVisible();
  });

  /* oxlint-enable vitest/max-expects */

  // Mocked presentation evidence; hosted native tests prove actual epoch catch-up and key custody.
  /* oxlint-disable vitest/max-expects -- One journey covers successive removals, relaunch and lost-key recovery. */
  it('continues through successive removals and requires fresh enrollment after losing this device key', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-revocation');
    await session.native.signIn('google');
    await session.native.confirmRecoveryKey(syntheticRecoveryKey.slice(-4));
    session.addSecondTrustedDevice();
    const store = createRegistration(session.native);
    const show = () =>
      render(
        <RegistrationGate
          store={store}
          preview={false}>
          {null}
        </RegistrationGate>,
      );
    let view = await show();
    await expect(
      screen.findByRole('header', { name: 'Private sync is on' }),
    ).resolves.toBeVisible();
    const removals = [
      [syntheticTrustedDevice.name, syntheticReplacementRecoveryKey],
      [syntheticSecondTrustedDevice.name, syntheticRenewedRecoveryKey],
    ] as const;
    for (const [name, key] of removals) {
      const remove = english('revocation.remove', { name });
      for (let press = 0; press < 2; press += 1) {
        await act(async () => {
          await fireEvent.press(screen.getByRole('button', { name: remove }));
        });
      }
      expect(screen.getByTestId('revocation-recovery-key')).toHaveTextContent(
        key,
      );
      await act(async () => {
        await fireEvent.changeText(
          screen.getByLabelText(english('revocation.label')),
          key.slice(-4),
        );
      });
      await act(async () => {
        await fireEvent.press(screen.getByRole('button', { name: remove }));
      });
      expect(screen.getByText(english('revocation.removed'))).toBeVisible();
      expect(screen.queryByRole('button', { name: remove })).toBeNull();
    }
    // A native restore that already adopted the complete latest ring needs no Recovery Key screen.
    await view.unmount();
    view = await show();
    await expect(
      screen.findByRole('header', { name: 'Private sync is on' }),
    ).resolves.toBeVisible();
    expect(screen.queryByLabelText('Recovery Key')).toBeNull();
    session.loseDeviceKey();
    await act(async () => {
      await store.resume();
    });
    await expect(
      screen.findByTestId('enrollment-code'),
    ).resolves.toHaveTextContent(syntheticEnrollmentCode);
    expect(
      screen.getByRole('header', { name: 'Approve this device' }),
    ).toBeVisible();
    expect(
      screen.queryByRole('header', { name: 'Private sync is on' }),
    ).toBeNull();
    await act(async () => {
      await fireEvent.changeText(
        screen.getByLabelText('Recovery Key'),
        syntheticRecoveryKey,
      );
    });
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Unlock with Recovery Key' }),
      );
    });
    expect(screen.getByRole('alert')).toHaveTextContent(
      /does not unlock this Product Account/u,
    );
    await act(async () => {
      await fireEvent.changeText(
        screen.getByLabelText('Recovery Key'),
        syntheticRenewedRecoveryKey,
      );
    });
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Unlock with Recovery Key' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Private sync is on' }),
    ).resolves.toBeVisible();
    expect(screen.queryByTestId('enrollment-code')).toBeNull();
    await view.unmount();
  });
  /* oxlint-enable vitest/max-expects */

  // Mocked journey: native outcomes after a lost reply and after another device's removal.
  it('keeps an unconfirmed removal proposal, then explains a superseded one without its key', async () => {
    expect.hasAssertions();
    const proposed = {
      kind: 'mailbox-needed',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      privateSync: 'ready',
      trustedDevices: JSON.stringify([syntheticTrustedDevice]),
      revocationDevice: syntheticTrustedDevice.id,
      revocationRecoveryKey: syntheticReplacementRecoveryKey,
    } as const;
    const {
      trustedDevices: _devices,
      revocationDevice: _device,
      revocationRecoveryKey: _key,
      ...discarded
    } = proposed;
    const outcomes: RegistrationSnapshot[] = [
      { ...proposed, revocationNotice: 'unconfirmed' },
      { ...discarded, revocationNotice: 'superseded' },
    ];
    const session = createMockRegistrationSession('registration-revocation');
    await render(
      <RegistrationGate
        store={createRegistration({
          ...session.native,
          restore: () => Promise.resolve(proposed),
          confirmRevocation: () => Promise.resolve(outcomes.shift()),
        })}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    const remove = english('revocation.remove', {
      name: syntheticTrustedDevice.name,
    });
    const confirm = async () => {
      await act(async () => {
        await fireEvent.changeText(
          screen.getByLabelText(english('revocation.label')),
          syntheticReplacementRecoveryKey.slice(-4),
        );
      });
      await act(async () => {
        await fireEvent.press(screen.getByRole('button', { name: remove }));
      });
    };
    await expect(
      screen.findByTestId('revocation-recovery-key'),
    ).resolves.toHaveTextContent(syntheticReplacementRecoveryKey);
    await confirm();
    expect(screen.getByRole('alert')).toHaveTextContent(
      english('revocation.unconfirmed'),
    );
    expect(screen.getByTestId('revocation-recovery-key')).toHaveTextContent(
      syntheticReplacementRecoveryKey,
    );
    await confirm();
    expect(screen.getByRole('alert')).toHaveTextContent(
      english('revocation.superseded'),
    );
    expect(screen.queryByTestId('revocation-recovery-key')).toBeNull();
  });

  /* oxlint-disable vitest/max-expects -- One journey proves removal, the next sign-in and leaving it. */
  it('explains on the next activation that this device was removed, then admits a new sign-in only as a Pending Device', async () => {
    expect.hasAssertions();
    const store = createRegistration(
      createMockRegistrationSession('registration-revoked').native,
    );
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    await expect(
      screen.findByText('Signed in with Google.'),
    ).resolves.toBeVisible();
    await act(async () => {
      await store.resume();
    });
    await expect(
      screen.findByRole('header', { name: 'This device was removed' }),
    ).resolves.toBeVisible();
    expect(screen.getByText(/cannot be erased remotely/u)).toBeVisible();
    expect(screen.queryByText('Signed in with Google.')).toBeNull();
    // A fresh sign-in is a new device, which waits for approval instead of being refused.
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Sign in with Google' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Add this device' }),
    ).resolves.toBeVisible();
    expect(screen.getByTestId('enrollment-code')).toHaveTextContent(
      syntheticEnrollmentCode,
    );
    expect(
      screen.queryByRole('button', { name: 'Authorize Gmail' }),
    ).toBeNull();
    // Leaving the Pending Device returns to Welcome.
    const signOut = { name: english('accountRemoval.signOut') };
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', signOut));
    });
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', signOut));
    });
    await expect(
      screen.findByRole('header', { name: 'Welcome to Unwired Mail' }),
    ).resolves.toBeVisible();
    expect(screen.queryByTestId('enrollment-code')).toBeNull();
  });

  /* oxlint-enable vitest/max-expects */

  /* oxlint-disable vitest/max-expects -- Each journey proves the explanation, cancellation and outcome. */
  it('signs this device out only after confirmation and keeps nothing of the account', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        <ConnectedInbox />
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: english('accountRemoval.title') }),
    ).resolves.toBeVisible();
    await act(async () => {
      await fireEvent.changeText(
        screen.getByLabelText('Last four characters'),
        syntheticRecoveryKey.slice(-4),
      );
    });
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Confirm Recovery Key' }),
      );
    });
    await openAccount();
    const signOut = { name: english('accountRemoval.signOut') };
    // The first press explains what sign-out removes; cancelling keeps the account.
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', signOut));
    });
    expect(
      screen.getByText(english('accountRemoval.signOutConfirm')),
    ).toBeVisible();
    expect(
      screen.queryByRole('button', { name: english('accountRemoval.delete') }),
    ).toBeNull();
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: english('accountRemoval.cancel') }),
      );
    });
    expect(
      screen.queryByText(english('accountRemoval.signOutConfirm')),
    ).toBeNull();
    expect(screen.getByText('Signed in with Google.')).toBeVisible();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', signOut));
    });
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', signOut));
    });
    await expect(
      screen.findByRole('header', { name: 'Welcome to Unwired Mail' }),
    ).resolves.toBeVisible();
    expect(screen.queryByText('Signed in with Google.')).toBeNull();
    expect(screen.queryByText(syntheticRecoveryKey)).toBeNull();
  });

  it.each([
    {
      removalPending: 'sign-out' as const,
      title: 'Finish signing out',
      action: english('accountRemoval.signOut'),
      result: 'Welcome to Unwired Mail',
    },
    {
      removalPending: 'deletion' as const,
      title: 'Confirm account deletion',
      action: english('accountRemoval.deletePermanently'),
      result: 'Product Account deleted',
    },
  ])(
    'resumes a pending $removalPending after relaunch without offering mailbox or sign-in work',
    async ({ removalPending, title, action, result }) => {
      expect.hasAssertions();
      const session = createMockRegistrationSession('registration-success');
      const store = createRegistration({
        ...session.native,
        restore: () =>
          Promise.resolve({
            kind: 'mailbox-needed',
            productAccountId: 'synthetic-product-account',
            signInProvider: 'google',
            privateSync: 'unavailable',
            reason: 'unavailable',
            removalPending,
          }),
        signOut: () => Promise.resolve({ kind: 'signed-out' }),
        deleteProductAccount: () =>
          Promise.resolve({ kind: 'signed-out', notice: 'deleted' }),
      });
      await render(
        <RegistrationGate
          store={store}
          preview={false}>
          {null}
        </RegistrationGate>,
      );
      await expect(
        screen.findByRole('header', {
          name: title,
        }),
      ).resolves.toBeVisible();
      expect(
        screen.queryByRole('button', { name: 'Authorize Gmail' }),
      ).toBeNull();
      expect(
        screen.queryByRole('button', { name: 'Sign in again with Google' }),
      ).toBeNull();
      expect(
        screen.queryByRole('button', {
          name: english('accountRemoval.cancel'),
        }),
      ).toBeNull();
      await act(async () => {
        await fireEvent.press(
          screen.getByRole('button', {
            name: action,
          }),
        );
      });
      await expect(
        screen.findByRole('header', {
          name: result,
        }),
      ).resolves.toBeVisible();
    },
  );

  it('deletes the Product Account only after explicit confirmation, keeping it when deletion fails', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    let deletion: () => Promise<unknown> = () =>
      Promise.reject(new Error('Synthetic deletion offline'));
    await render(
      <RegistrationGate
        store={createRegistration({
          ...session.native,
          deleteProductAccount: () => deletion(),
        })}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', {
          name: english('accountRemoval.delete'),
        }),
      );
    });
    expect(
      screen.getByText(english('accountRemoval.deleteConfirm')),
    ).toBeVisible();
    const permanently = { name: english('accountRemoval.deletePermanently') };
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', permanently));
    });
    await expect(
      screen.findByRole('alert', { name: english('accountRemoval.deletion') }),
    ).resolves.toBeVisible();
    expect(screen.getByText('Signed in with Google.')).toBeVisible();
    deletion = session.native.deleteProductAccount;
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', permanently));
    });
    await expect(
      screen.findByRole('header', { name: 'Product Account deleted' }),
    ).resolves.toBeVisible();
    expect(
      screen.getByText(/Your mail in Gmail is not affected/u),
    ).toBeVisible();
    // A deleted account cannot be reopened.
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Sign in with Google' }),
      );
    });
    expect(
      screen.getByRole('header', { name: 'Product Account deleted' }),
    ).toBeVisible();
  });

  /* oxlint-enable vitest/max-expects */
});
