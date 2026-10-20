import assert from 'node:assert/strict';

import type {
  Registration,
  SignInProvider,
} from '@private-email/mail-core/registration';
import type {
  RegistrationScenario,
  SyntheticRegistrationScenario,
} from '@private-email/mail-core/testing/registration-scenarios';
import type { TurboModule } from 'react-native';

import { english } from '@private-email/localization';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { createNotifications } from '@private-email/mail-core/notifications';
import {
  createRegistration,
  mailboxesOf,
} from '@private-email/mail-core/registration';
import { createRemoteContentSettings } from '@private-email/mail-core/remote-content';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import {
  createRegistrationScenario,
  syntheticSecondTrustedDevice,
  syntheticTrustedDevice,
} from '@private-email/mail-core/testing/registration-scenarios';
import {
  removeTrustedDevice,
  syntheticMailboxes,
} from '@private-email/mail-core/testing/registration-vault';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';
import { useContext, useMemo, useState } from 'react';
import {
  Alert,
  AppState,
  DeviceEventEmitter,
  Pressable,
  Text,
  TurboModuleRegistry,
  View,
} from 'react-native';

import type { Selection } from '../src/inbox.tsx';
import type { MailboxList } from '../src/private-storage.ts';
import type { MailboxView } from '../src/sidebar.tsx';

import { CommandBar, CommandPaletteProvider } from '../src/command-palette.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
import { NotificationsContext } from '../src/notification-settings.tsx';
import { AccountContext, RegistrationGate } from '../src/registration-gate.tsx';
import { openSettings } from '../src/settings-window.ts';
import { Mailboxes } from '../src/sidebar.tsx';
import {
  MacWindows,
  closeSettings,
  commandComma,
  inboxFocused,
  reopenSettingsWhileClosing,
  settingsOpen,
  settingsWindow,
} from './settings-window.tsx';
import { started } from './started.ts';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// The Enrollment Code a Pending Device shows.
const enrollmentCodeOf = (store: Registration) => {
  const { snapshot } = store.getSnapshot();
  assert.ok(snapshot.kind === 'device-pending');
  assert.ok(snapshot.enrollmentCode !== undefined);
  return snapshot.enrollmentCode;
};

// The replacement Recovery Key a prepared removal shows.
const replacementKeyOf = (store: Registration) => {
  const { snapshot } = store.getSnapshot();
  assert.ok(snapshot.kind !== 'signed-out');
  assert.ok(snapshot.revocationRecoveryKey !== undefined);
  return snapshot.revocationRecoveryKey;
};

// A connection saved before SMTP receives only.
const savedBeforeSmtp = ({ device }: SyntheticRegistrationScenario) => {
  for (const connection of device.record?.connections ?? []) {
    delete connection.smtp;
  }
};

// The four characters of a Recovery Key that confirm it: its end, without separators.
const lastFour = (key: string) => key.replaceAll('-', '').slice(-4);

// The Recovery Key this device holds for its Product Account's current keys.
const recoveryKeyOf = (synthetic: SyntheticRegistrationScenario) => {
  const key = synthetic.device.productSync.vault?.recoveryKey;
  assert.ok(key !== undefined);
  return key;
};

// A Google Product Account another window of this process signed in to, before the test's store
// opens it; its Recovery Key is confirmed unless the journey needs it pending.
const signedIn = async ({
  scenario = 'registration-success',
  confirmKey = true,
}: Readonly<{
  scenario?: RegistrationScenario;
  confirmKey?: boolean;
}> = {}) => {
  const synthetic = await createRegistrationScenario(scenario);
  const setup = createRegistration(synthetic.vault);
  await setup.register('google');
  if (confirmKey) {
    await setup.confirmRecoveryKey(lastFour(recoveryKeyOf(synthetic)));
  }
  return { synthetic, setup };
};

// Connects an IMAP mailbox with the password the synthetic server accepts, sending through
// smtp.example.invalid; returns its connection.
const connectImap = async (
  { synthetic, setup }: Awaited<ReturnType<typeof signedIn>>,
  mailbox: Readonly<{ address: string; host: string; username: string }>,
) => {
  await setup.connectImap({
    ...mailbox,
    port: 993,
    password: synthetic.imap.password,
    smtp: {
      host: 'smtp.example.invalid',
      port: 465,
      security: 'tls',
      username: mailbox.username,
    },
  });
  const connection = mailboxesOf(setup.getSnapshot().snapshot).find(
    ({ address }) => address === mailbox.address,
  )?.id;
  assert.ok(connection !== undefined);
  return connection;
};

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
      <Shell
        onSelect={() => undefined}
        selected={undefined}
      />
    </InboxProvider>
  );
}

// The Mailboxes column beside the message list, as the window composes them.
function Shell(props: Omit<Parameters<typeof Inbox>[0], 'view' | 'onView'>) {
  const [view, setView] = useState<MailboxView>({});
  return (
    <>
      <Mailboxes
        view={view}
        onView={setView}
      />
      <Inbox
        {...props}
        onView={setView}
        view={view}
      />
    </>
  );
}

// The native Commands… menu, whose Command-P names the key window to every window's JavaScript.
const commandMenu = () => {
  const get = TurboModuleRegistry.get.bind(TurboModuleRegistry);
  // The windows whose first responder the palette asked AppKit to keep, and to restore.
  const focus = { saved: [] as string[], restored: [] as string[] };
  const menu: TurboModule &
    Readonly<{
      addListener: () => void;
      removeListeners: () => void;
      saveFocus: (window: string) => void;
      restoreFocus: (window: string) => void;
    }> = {
    addListener: () => undefined,
    removeListeners: () => undefined,
    saveFocus: (window) => {
      focus.saved.push(window);
    },
    restoreFocus: (window) => {
      focus.restored.push(window);
    },
  };
  const module = jest
    .spyOn(TurboModuleRegistry, 'get')
    // The Settings window's methods of the same module stay as the test host provides them.
    .mockImplementation((name) =>
      name === 'UnwiredCommands' ? { ...get(name), ...menu } : get(name),
    );
  return {
    choose: async (windowId: string) => {
      await act(async () => {
        DeviceEventEmitter.emit('openCommandPalette', {
          window: `inbox-window-${windowId}`,
        });
        await Promise.resolve();
      });
    },
    focus,
    restore: () => {
      module.mockRestore();
    },
  };
};

// A window's gate whose screens show only its Command Palette bar, as the window composes them.
// Another window of the app signs in or out; this one learns of it at its next restore.
const renderBarWindow = async (initially: 'connected' | 'signed-out') => {
  const synthetic = await createRegistrationScenario('registration-success');
  const elsewhere = createRegistration(synthetic.vault);
  const connect = async (provider: SignInProvider) => {
    await elsewhere.register(provider);
    await elsewhere.confirmRecoveryKey(lastFour(recoveryKeyOf(synthetic)));
    await elsewhere.addMailbox();
  };
  if (initially === 'connected') {
    await connect('google');
  }
  const store = createRegistration(synthetic.vault);
  await render(
    <CommandPaletteProvider windowId="bar">
      <RegistrationGate
        store={started(store)}
        preview={false}>
        <CommandBar />
      </RegistrationGate>
    </CommandPaletteProvider>,
  );
  const restore = async () => {
    await act(async () => {
      await store.restore();
    });
  };
  return {
    connect: async (provider: SignInProvider) => {
      await connect(provider);
      await restore();
    },
    signOut: async () => {
      await elsewhere.signOut();
      await restore();
    },
  };
};

// Welcome comes first; its Continue opens Sign In and its sign-in actions.
const continueToSignIn = async () => {
  await act(async () => {
    await fireEvent.press(
      await screen.findByRole('button', { name: 'Continue' }),
    );
  });
};

const openAccount = async () => {
  const account = await screen.findByRole('button', { name: 'Account' });
  await act(async () => {
    await fireEvent.press(account);
  });
};

// Opens a destination from the account page's Settings sidebar.
const settings = async (destination: string) => {
  const item = await screen.findByRole('button', { name: destination });
  await act(async () => {
    await fireEvent.press(item);
  });
};

describe('product registration', () => {
  it('keeps IMAP provider navigation blocked while another mailbox authorization is pending', async () => {
    expect.hasAssertions();
    const account = await signedIn();
    await account.setup.addMailbox();
    const { vault } = account.synthetic;
    let finish: () => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Hold native authorization while trying the IMAP provider row.
    const authorization = new Promise<void>((resolve) => {
      finish = resolve;
    });
    const store = createRegistration({
      ...vault,
      signInMailbox: async (...request) => {
        await authorization;
        return vault.signInMailbox(...request);
      },
    });
    const view = await render(
      <MacWindows store={store}>
        <RegistrationGate
          store={started(store)}
          preview={false}>
          <ConnectedInbox />
        </RegistrationGate>
      </MacWindows>,
    );
    const press = async (name: string) => {
      await act(async () => {
        await fireEvent.press(await screen.findByRole('button', { name }));
      });
    };
    try {
      await openAccount();
      await settings('Email Accounts');
      await press('Add an IMAP mailbox');
      await press('Add another Gmail mailbox');
      await press('iCloud Mail');
      expect(screen.queryByRole('header', { name: 'iCloud Mail' })).toBeNull();
      expect(
        screen.getByRole('button', { name: 'iCloud Mail' }),
      ).toBeDisabled();
      await act(async () => {
        finish();
      });
      await press('iCloud Mail');
      expect(screen.getByRole('header', { name: 'iCloud Mail' })).toBeVisible();
    } finally {
      await act(async () => {
        finish();
      });
      await view.unmount();
    }
  });

  it.each([
    {
      host: 'imap.example.invalid',
      saved: savedBeforeSmtp,
      smtpPassword: '',
      sendingPassword: {},
      canConnect: false,
      confirmKey: true,
      inboxActions: [],
    },
    {
      host: 'imap.fastmail.com',
      saved: () => undefined,
      smtpPassword: 'separate-smtp-password',
      sendingPassword: { password: 'separate-smtp-password' },
      canConnect: true,
      confirmKey: false,
      inboxActions: ['Open Inbox'],
    },
  ])(
    'repairs $host from its Inbox refusal, retaining separate SMTP setup',
    async ({
      host,
      saved,
      smtpPassword,
      sendingPassword,
      canConnect: expectedConnect,
      confirmKey,
      inboxActions,
    }) => {
      expect.hasAssertions();
      const imap = createSyntheticImap();
      imap.deliver('INBOX', { subject: 'Saved IMAP message' });
      imap.addFolder('Archive');
      imap.deliver('Archive', { subject: 'Private archived message' });
      const account = await signedIn({ confirmKey });
      const { synthetic } = account;
      const connection = await connectImap(account, {
        address: 'alex@example.invalid',
        host,
        username: 'alex',
      });
      saved(synthetic);
      const setups: unknown[] = [];
      const store = createRegistration({
        ...synthetic.vault,
        connectImap: (setup) => {
          setups.push(setup);
          return synthetic.vault.connectImap(setup);
        },
      });
      const connections = createMailboxes(
        syntheticConnections({}, { [connection]: imap.native }),
        store,
      );
      const mailboxes = {
        ...connections,
        getSnapshot: connections.getConnections,
      };
      await render(
        <MacWindows store={store}>
          <RegistrationGate
            store={started(store)}
            preview={false}>
            <InboxProvider mailboxes={mailboxes}>
              <Shell
                onSelect={() => undefined}
                selected={undefined}
              />
            </InboxProvider>
          </RegistrationGate>
        </MacWindows>,
      );
      // The Inbox remains usable with setup deferred; repair must still open Email Accounts.
      for (const name of inboxActions) {
        await act(async () => {
          await fireEvent.press(await screen.findByRole('button', { name }));
        });
      }
      await expect(
        screen.findByText('Saved IMAP message'),
      ).resolves.toBeVisible();
      await act(async () => {
        await fireEvent.press(
          screen.getByRole('button', {
            name: 'Archive. In alex@example.invalid',
          }),
        );
      });
      await expect(
        screen.findByText('Private archived message'),
      ).resolves.toBeVisible();
      imap.server.failure = 'locked';
      await act(async () => {
        await mailboxes.load();
      });
      expect(screen.queryByText('Private archived message')).toBeNull();
      imap.server.failure = undefined;
      await act(async () => {
        await mailboxes.load();
      });
      await expect(
        screen.findByText('Private archived message'),
      ).resolves.toBeVisible();
      imap.server.failure = 'gmail-unavailable';
      await act(async () => {
        await mailboxes.load();
      });
      const repair = 'Enter the password for alex@example.invalid again';
      await act(async () => {
        await fireEvent.press(screen.getByRole('button', { name: repair }));
      });
      // The Inbox's repair opens Settings on Email Accounts, where its form is.
      await screen.findByRole('header', { name: 'Email Accounts' });
      await act(async () => {
        await fireEvent.press(
          settingsWindow().getByRole('button', { name: repair }),
        );
      });
      await fireEvent.changeText(
        screen.getByLabelText('Password'),
        'replacement-password',
      );
      // A manual server saved before SMTP sets up sending as its password is entered again.
      const canConnect =
        screen.queryByRole('button', { name: 'Connect' }) !== null;
      await fireEvent.changeText(
        screen.getByLabelText('SMTP server'),
        'smtp.example.invalid',
      );
      await fireEvent.changeText(
        screen.getByLabelText('SMTP password, same as incoming if blank'),
        smtpPassword,
      );
      const credentialGuidance = screen.getAllByText(
        'Same as incoming if blank.',
      ).length;
      // The person changed the password at the mail server, and any separate SMTP password.
      synthetic.imap.password = 'replacement-password';
      Object.assign(synthetic.imap.smtp, sendingPassword);
      imap.server.failure = undefined;
      await act(async () => {
        await fireEvent.press(screen.getByRole('button', { name: 'Connect' }));
      });
      expect({
        canConnect,
        credentialGuidance,
        setups,
        failure: store.getSnapshot().imapFailure,
        password: screen.queryByLabelText('Password'),
        state: mailboxesOf(store.getSnapshot().snapshot)[0]?.state,
      }).toStrictEqual({
        canConnect: expectedConnect,
        credentialGuidance: 2,
        setups: [
          expect.objectContaining({
            password: 'replacement-password',
            smtp: {
              host: 'smtp.example.invalid',
              port: 465,
              security: 'tls',
              username: 'alex',
              ...sendingPassword,
            },
          }),
        ],
        failure: undefined,
        password: null,
        state: 'connected',
      });
    },
  );

  it('labels only INBOX as the Inbox and keeps preset guidance when repairing an iCloud password', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap({
      address: 'alex@icloud.example.invalid',
    });
    imap.deliver('INBOX', { subject: 'Saved IMAP message' });
    imap.addFolder('Primary', ['inbox']);
    const account = await signedIn();
    const connection = await connectImap(account, {
      address: 'alex@icloud.example.invalid',
      host: 'imap.mail.me.com',
      username: 'alex@icloud.example.invalid',
    });
    const store = createRegistration(account.synthetic.vault);
    const connections = createMailboxes(
      syntheticConnections({}, { [connection]: imap.native }),
      store,
    );
    const mailboxes = {
      ...connections,
      getSnapshot: connections.getConnections,
    };
    await render(
      <MacWindows store={store}>
        <RegistrationGate
          store={started(store)}
          preview={false}>
          <InboxProvider mailboxes={mailboxes}>
            <Shell
              onSelect={() => undefined}
              selected={undefined}
            />
          </InboxProvider>
        </RegistrationGate>
      </MacWindows>,
    );
    // A folder with the inbox role keeps its own name beside the reserved INBOX.
    await expect(
      screen.findByRole('button', {
        name: 'Primary. In alex@icloud.example.invalid',
      }),
    ).resolves.toBeVisible();
    expect(
      screen.getAllByRole('button', {
        name: 'Inbox. In alex@icloud.example.invalid',
      }),
    ).toHaveLength(1);
    await openAccount();
    await settings('Email Accounts');
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', {
          name: 'Enter the password for alex@icloud.example.invalid again',
        }),
      );
    });
    // Repair names the provider and its app-specific password while keeping the saved endpoint.
    expect(screen.getByRole('header', { name: 'iCloud Mail' })).toBeVisible();
    expect(
      screen.getByText(
        "iCloud Mail requires an app-specific password, which you create in your account's security settings. Your usual password does not work.",
      ),
    ).toBeVisible();
  });

  it('keeps a failed folder warning on its exact sidebar row through navigation and recovery, and retires removed folders', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves the warning, the fallback and a recreated folder. */
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.deliver('INBOX', { subject: 'Saved IMAP message' });
    imap.addFolder('Archive');
    imap.addFolder('2026');
    imap.addFolder('Archive\n2026');
    imap.deliver('Archive\n2026', { subject: 'Private archived message' });
    const account = await signedIn();
    const connection = await connectImap(account, {
      address: 'alex@example.invalid',
      host: 'imap.example.invalid',
      username: 'alex',
    });
    const store = createRegistration(account.synthetic.vault);
    const connections = createMailboxes(
      syntheticConnections({}, { [connection]: imap.native }),
      store,
    );
    const mailboxes = {
      ...connections,
      getSnapshot: connections.getConnections,
    };
    await render(
      <RegistrationGate
        store={started(store)}
        preview={false}>
        <InboxProvider mailboxes={mailboxes}>
          <Shell
            onSelect={() => undefined}
            selected={undefined}
          />
        </InboxProvider>
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Archive\n2026. In alex@example.invalid',
        }),
      );
    });
    await expect(
      screen.findByText('Private archived message'),
    ).resolves.toBeVisible();
    // The list heading names the chosen folder, which matters where the sidebar is hidden.
    expect(screen.getByRole('header', { name: 'Archive\n2026' })).toBeVisible();
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Inbox. In alex@example.invalid' }),
      );
    });
    const [mailbox] = mailboxes.getSnapshot();
    assert.ok(mailbox);
    assert.ok('openFolder' in mailbox.inbox);
    const { inbox } = mailbox;
    const beforeFolderFailure = inbox.getSnapshot();
    imap.server.failure = 'offline';
    // A folder update must reach the sidebar even when its Inbox snapshot is unchanged.
    await act(async () => {
      await inbox.openFolder('Archive\n2026');
    });
    expect(inbox.getSnapshot()).toBe(beforeFolderFailure);
    expect(
      screen.getByRole('button', {
        name: 'Archive\n2026. In alex@example.invalid',
      }).props.accessibilityValue?.text,
    ).toBe(
      'Folders could not be listed. Try again when the mail server can be reached.',
    );
    // An unreachable server keeps the cached folder visible and says it could not be refreshed.
    imap.server.failure = 'offline';
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', {
          name: 'Archive\n2026. In alex@example.invalid',
        }),
      );
    });
    expect(screen.getByText('Private archived message')).toBeVisible();
    const unlisted =
      'Folders could not be listed. Try again when the mail server can be reached.';
    expect(screen.getByRole('alert')).toHaveTextContent(unlisted);
    // The failed folder keeps its warning in the sidebar after the person moves to the Inbox.
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Inbox. In alex@example.invalid' }),
      );
    });
    expect([
      screen.queryByRole('alert'),
      screen.getByRole('button', {
        name: 'Archive\n2026. In alex@example.invalid',
      }).props.accessibilityValue?.text,
      screen.getByRole('button', { name: 'Archive. In alex@example.invalid' })
        .props.accessibilityValue?.text,
      screen.getByRole('button', { name: '2026. In alex@example.invalid' })
        .props.accessibilityValue?.text,
    ]).toStrictEqual([null, unlisted, undefined, undefined]);
    // A first read that fails has no cached rows, but its warning must survive an Inbox reload.
    await act(async () => {
      await inbox.openFolder('2026');
      await mailboxes.load();
    });
    expect(
      screen.getByRole('button', { name: '2026. In alex@example.invalid' })
        .props.accessibilityValue?.text,
    ).toBe(unlisted);
    // A successful read clears that folder's warning without hiding its cached mail.
    imap.server.failure = undefined;
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', {
          name: 'Archive\n2026. In alex@example.invalid',
        }),
      );
    });
    expect([
      screen.queryByRole('alert'),
      screen.getByRole('button', {
        name: 'Archive\n2026. In alex@example.invalid',
      }).props.accessibilityValue?.text,
    ]).toStrictEqual([null, undefined]);
    expect(screen.getByText('Private archived message')).toBeVisible();
    // A folder the refreshed listing no longer offers is not shown from its stale cache.
    imap.server.failure = undefined;
    imap.removeFolder('Archive\n2026');
    await act(async () => {
      await mailboxes.load();
    });
    await expect(
      screen.findByText('Saved IMAP message'),
    ).resolves.toBeVisible();
    expect(screen.queryByText('Private archived message')).toBeNull();
    // Recreating that name does not restore a discarded choice or expose the old cached rows.
    imap.addFolder('Archive\n2026');
    imap.renumber('Archive\n2026');
    imap.deliver('Archive\n2026', { subject: 'New archived message' });
    await act(async () => {
      await mailboxes.load();
    });
    expect(screen.getByText('Saved IMAP message')).toBeVisible();
    expect(screen.queryByText('Private archived message')).toBeNull();
    expect(screen.queryByText('New archived message')).toBeNull();
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', {
          name: 'Archive\n2026. In alex@example.invalid',
        }),
      );
    });
    await expect(
      screen.findByText('New archived message'),
    ).resolves.toBeVisible();
    expect(screen.queryByText('Private archived message')).toBeNull();
  });
  /* oxlint-enable vitest/max-expects */

  it('organizes IMAP mail from the reader with Undo and Move to, and searches its folders at the server', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves read state, archive with Undo, Move to and search. */
    expect.hasAssertions();
    const imap = createSyntheticImap();
    const invoice = imap.deliver('INBOX', { subject: 'Quarterly invoice' });
    const lunch = imap.deliver('INBOX', { subject: 'Team lunch' });
    imap.addFolder('Archived Mail', ['archive']);
    imap.addFolder('Projects');
    imap.deliver('Projects', { subject: 'Filed invoice' });
    const account = await signedIn();
    const connection = await connectImap(account, {
      address: 'alex@example.invalid',
      host: 'imap.example.invalid',
      username: 'alex',
    });
    const store = createRegistration(account.synthetic.vault);
    const connections = createMailboxes(
      syntheticConnections({}, { [connection]: imap.native }),
      store,
    );
    const mailboxes = {
      ...connections,
      getSnapshot: connections.getConnections,
    };
    function Organizing() {
      const [selected, setSelected] = useState<Selection>();
      return (
        <InboxProvider mailboxes={mailboxes}>
          <Shell
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
      );
    }
    await render(
      <RegistrationGate
        store={started(store)}
        preview={false}>
        <Organizing />
      </RegistrationGate>,
    );
    const press = async (name: string | RegExp) => {
      await act(async () => {
        await fireEvent.press(await screen.findByRole('button', { name }));
      });
    };

    // Reading never marks a message read; the reader's action does, at the server.
    await press(/Quarterly invoice/u);
    await expect(
      screen.findByRole('header', { name: 'Quarterly invoice' }),
    ).resolves.toBeVisible();
    await press('Mark as read');
    await waitFor(() => {
      expect(imap.server.changes).toStrictEqual([`read INBOX ${invoice}`]);
    });

    // Archive moves it to the folder the server declares, closes the reader and offers Undo.
    await press('Archive');
    await waitFor(() => {
      expect(
        screen.queryByRole('header', { name: 'Quarterly invoice' }),
      ).toBeNull();
    });
    expect(imap.server.changes.at(-1)).toBe(
      `move INBOX ${invoice} Archived Mail`,
    );
    await expect(
      screen.findByText('Archived: “Quarterly invoice”.'),
    ).resolves.toBeVisible();
    expect(
      screen.queryByRole('button', { name: /Quarterly invoice/u }),
    ).toBeNull();
    await press('Undo');
    await expect(
      screen.findByRole('button', { name: /Quarterly invoice/u }),
    ).resolves.toBeVisible();
    expect(imap.server.changes.at(-1)).toBe('move Archived Mail 1 INBOX');

    // Move to lists the mailbox's other folders.
    await press(/Team lunch/u);
    await press('Folders');
    imap.server.loseReply = true;
    await press('Move to Projects');
    await waitFor(() => {
      expect(imap.server.changes.at(-1)).toBe(`move INBOX ${lunch} Projects`);
    });
    expect(screen.queryByRole('header', { name: 'Team lunch' })).toBeNull();

    await expect(
      screen.findByText(
        'The mail server has not confirmed where “Team lunch” moved. Check its folders, then discard this change to continue. It will not be sent again.',
      ),
    ).resolves.toBeVisible();
    await press('Discard change');
    expect(
      imap.server.changes.filter(
        (change) => change === `move INBOX ${lunch} Projects`,
      ),
    ).toHaveLength(1);

    // The server searches the Inbox and the other folders when asked.
    await act(async () => {
      await fireEvent.changeText(
        await screen.findByLabelText('Search senders and subjects'),
        'invoice',
      );
    });
    await press('Search mail servers for “invoice”');
    await expect(
      screen.findByRole('header', { name: 'From mail servers' }),
    ).resolves.toBeVisible();
    await waitFor(() => {
      expect(
        screen.getAllByRole('button', { name: /Filed invoice/u }),
      ).toHaveLength(1);
    });
    expect(imap.server.reads).toContain('search INBOX,Archived Mail,Projects');
  });
  /* oxlint-enable vitest/max-expects */

  it('opens saved Gmail mail offline and verifies registration before retrying', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 2 });
    await createGmailInbox(gmail.native).load();
    const other = createSyntheticGmail({
      address: 'other@example.invalid',
      messages: 0,
    });
    const { synthetic, setup } = await signedIn();
    await setup.addMailbox();
    await setup.addMailbox('gmail', true);
    const connected = setup.getSnapshot().snapshot;
    // Google cannot be reached, so both mailboxes open from what this device saved.
    synthetic.google.refreshFailure = 'offline';
    let openMailbox: () => Promise<unknown> = async () => ({
      ...(await gmail.native.openMailbox()),
      availability: 'retry',
    });
    const store = createRegistration(synthetic.vault);
    const mailboxes = gmailMailboxes(store, {
      [alex]: { native: { ...gmail.native, openMailbox: () => openMailbox() } },
      [syntheticMailboxes['other@example.invalid']]: other,
    });
    await render(
      <MacWindows store={store}>
        <RegistrationGate
          store={started(store)}
          preview={false}>
          <InboxProvider mailboxes={mailboxes}>
            <Shell
              onSelect={() => undefined}
              selected={undefined}
            />
          </InboxProvider>
        </RegistrationGate>
      </MacWindows>,
    );
    await expect(
      screen.findByText('Synthetic message 1'),
    ).resolves.toBeVisible();
    const unreachable =
      'Gmail could not be reached. Showing mail saved on this device.';
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Inbox. In other@example.invalid' }),
      );
    });
    // The unselected mailbox still explains its problem beside its Inbox row.
    expect([
      screen.getByRole('button', { name: 'Inbox. In alex@example.invalid' })
        .props.accessibilityState?.selected,
      screen.getByRole('button', { name: 'Inbox. In alex@example.invalid' })
        .props.accessibilityValue?.text,
      screen.queryByText(/Gmail could not be reached/u),
    ]).toStrictEqual([false, unreachable, null]);
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Inbox. In alex@example.invalid' }),
      );
    });
    await openAccount();
    expect(
      settingsWindow().getByText(
        /could not be verified\. Mail saved on this device is available/u,
      ),
    ).toBeVisible();
    await closeSettings();
    gmail.deliver({ subject: 'After verification' });
    synthetic.google.refreshFailure = undefined;
    ({ openMailbox } = gmail.native);
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Try again' }));
    });
    await expect(
      screen.findByText('After verification'),
    ).resolves.toBeVisible();
    expect({
      snapshot: store.getSnapshot().snapshot,
      problem: screen.getByRole('button', {
        name: 'Inbox. In alex@example.invalid',
      }).props.accessibilityValue?.text,
    }).toStrictEqual({ snapshot: connected, problem: '2 unread' });
  });

  /* oxlint-disable vitest/max-expects -- One journey proves the palette bar, Settings navigation and the way back. */
  it('opens one Settings window from the Inbox and its palette, and returns to the Inbox from it', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 2 });
    const { synthetic, setup } = await signedIn();
    await setup.addMailbox();
    const store = createRegistration(synthetic.vault);
    const mailboxes = gmailMailboxes(store, {
      [alex]: { native: gmail.native },
    });
    const menu = commandMenu();
    try {
      await render(
        <MacWindows store={store}>
          <CommandPaletteProvider windowId="account">
            <RegistrationGate
              store={started(store)}
              preview={false}>
              <InboxProvider mailboxes={mailboxes}>
                <Shell
                  onSelect={() => undefined}
                  selected={undefined}
                />
              </InboxProvider>
            </RegistrationGate>
          </CommandPaletteProvider>
        </MacWindows>,
      );
      await expect(
        screen.findByText('Synthetic message 1'),
      ).resolves.toBeVisible();
      await openAccount();
      const selected = () =>
        settingsWindow()
          .getAllByRole('button', { selected: true })
          .map(({ props }) => props.accessibilityLabel);
      // Settings opens on Account & Devices; another sidebar destination selects itself and shows
      // only its title and groups, beneath the window's own Command Palette bar.
      expect(selected()).toStrictEqual(['Account & Devices']);
      await settings('Email Accounts');
      expect({
        selected: selected(),
        headers: settingsWindow()
          .getAllByRole('header')
          .map(({ props }) => props.accessibilityLabel),
        // The Inbox window keeps its mail beside Settings.
        inbox: screen.getByText('Synthetic message 1'),
      }).toStrictEqual({
        selected: ['Email Accounts'],
        headers: [
          'Accounts',
          'Automation',
          'Application',
          'Email Accounts',
          'Mailbox Connections',
        ],
        inbox: expect.anything(),
      });
      expect(
        settingsWindow().queryByRole('button', { name: 'Open Inbox' }),
      ).toBeNull();
      // The Inbox palette's Account command reaches the same window, which keeps its place.
      await menu.choose('account');
      await act(async () => {
        await fireEvent.press(screen.getByRole('button', { name: 'Account' }));
      });
      expect({
        windows: screen.getAllByTestId('settings-window'),
        selected: selected(),
      }).toStrictEqual({
        windows: [expect.anything()],
        selected: ['Email Accounts'],
      });
      // Command-P in the Settings window opens its own palette, whose Inbox command brings an
      // Inbox window forward.
      await act(async () => {
        DeviceEventEmitter.emit('openCommandPalette', {
          window: 'settings-window',
        });
        await Promise.resolve();
      });
      await act(async () => {
        await fireEvent.press(
          settingsWindow().getByRole('button', { name: 'Inbox' }),
        );
      });
      expect({
        palette: screen.queryByPlaceholderText('Type a command'),
        focused: inboxFocused(),
        settings: settingsOpen(),
      }).toStrictEqual({ palette: null, focused: 1, settings: true });
      await closeSettings();
      expect(screen.getByText('Synthetic message 1')).toBeVisible();
    } finally {
      menu.restore();
    }
  });
  /* oxlint-enable vitest/max-expects */

  it('turns a mailbox’s New Mail Notifications on from Settings, asking for permission the first time', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const { synthetic, setup } = await signedIn();
    await setup.addMailbox();
    const store = createRegistration(synthetic.vault);
    const mailboxes = gmailMailboxes(store, {
      [alex]: { native: gmail.native },
    });
    const device = { authorization: 'undetermined', previews: false };
    const requests: string[] = [];
    const notifications = createNotifications(
      {
        notificationSettings: () => Promise.resolve({ ...device }),
        requestNotifications: () => {
          requests.push('permission');
          device.authorization = 'authorized';
          return Promise.resolve({ ...device });
        },
        setNotificationPreviews: (previews) => {
          device.previews = previews;
          return Promise.resolve({ ...device });
        },
        openNotificationSettings: () => Promise.resolve(null),
        postNotifications: () => Promise.resolve(null),
        // No notification is ever opened here.
        nextOpenedNotification: () => Promise.resolve(null),
      },
      () => english,
    );
    await render(
      <NotificationsContext value={notifications}>
        <MacWindows store={store}>
          <CommandPaletteProvider windowId="account">
            <RegistrationGate
              store={started(store)}
              preview={false}>
              <InboxProvider mailboxes={mailboxes}>
                <Shell
                  onSelect={() => undefined}
                  selected={undefined}
                />
              </InboxProvider>
            </RegistrationGate>
          </CommandPaletteProvider>
        </MacWindows>
      </NotificationsContext>,
    );
    await openAccount();
    await settings('Notifications');
    const mailbox = await settingsWindow().findByRole('switch', {
      name: 'Gmail · alex@example.invalid',
    });
    // Off until turned on, with generic content by default.
    expect({
      mailbox: mailbox.props.value,
      previews: settingsWindow().getByRole('switch', {
        name: 'Show Sender and Subject',
      }).props.value,
    }).toStrictEqual({ mailbox: false, previews: false });
    await act(async () => {
      await fireEvent(mailbox, 'valueChange', true);
    });
    await expect(settingsWindow().findByText('Allowed')).resolves.toBeVisible();
    expect({
      requests,
      notifying: mailboxesOf(store.getSnapshot().snapshot).map(
        ({ notifications: on }) => on,
      ),
      shown: settingsWindow().getByRole('switch', {
        name: 'Gmail · alex@example.invalid',
      }).props.value,
    }).toStrictEqual({
      requests: ['permission'],
      notifying: [true],
      shown: true,
    });
  });

  it('brings the open Settings window to a requested destination and opens afresh after closing', async () => {
    expect.hasAssertions();
    const { synthetic, setup } = await signedIn();
    await setup.addMailbox();
    const store = createRegistration(synthetic.vault);
    // A repair, such as an IMAP password, names its destination.
    function Repair() {
      const account = useContext(AccountContext);
      return (
        <Pressable
          accessibilityRole="button"
          onPress={() => {
            account?.openAccount('mailboxes');
          }}>
          <Text>Repair</Text>
        </Pressable>
      );
    }
    await render(
      <MacWindows store={store}>
        <RegistrationGate
          store={started(store)}
          preview={false}>
          <ConnectedInbox />
          <Repair />
        </RegistrationGate>
      </MacWindows>,
    );
    const title = () =>
      settingsWindow()
        .getAllByRole('header')
        .map(({ props }) => props.accessibilityLabel)
        .find((header) =>
          ['Account & Devices', 'Email Accounts', 'Language'].includes(
            String(header),
          ),
        );
    await openAccount();
    await settings('Language');
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Repair' }));
    });
    const repaired = title();
    await openAccount();
    const kept = title();
    await closeSettings();
    await commandComma();
    expect({ repaired, kept, reopened: title() }).toStrictEqual({
      repaired: 'Email Accounts',
      kept: 'Email Accounts',
      reopened: 'Account & Devices',
    });
  });

  it('keeps a replacement Settings destination after the closing root renders it and tears down', async () => {
    expect.hasAssertions();
    const { synthetic, setup } = await signedIn();
    await setup.addMailbox();
    const store = started(createRegistration(synthetic.vault));
    await store.restoreOnce();
    await render(<MacWindows store={store}>{null}</MacWindows>);
    await act(async () => {
      openSettings('account-synthetic-product-subject', 'language');
    });
    await reopenSettingsWhileClosing(() => {
      openSettings('account-synthetic-product-subject', 'mailboxes');
    });
    expect(
      settingsWindow().getByRole('header', { name: 'Email Accounts' }),
    ).toBeVisible();
  });

  it("asks AppKit to keep the window's focused control on opening and restore it on closing", async () => {
    expect.hasAssertions();
    const menu = commandMenu();
    try {
      await renderBarWindow('connected');
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Open Command Palette' }),
      );
      expect(menu.focus.saved).toStrictEqual(['inbox-window-bar']);
      await fireEvent(
        screen.getByPlaceholderText('Type a command'),
        'keyDown',
        {
          nativeEvent: { key: 'Escape' },
        },
      );
      expect(screen.queryByPlaceholderText('Type a command')).toBeNull();
      expect(menu.focus.restored).toStrictEqual(['inbox-window-bar']);
    } finally {
      menu.restore();
    }
  });

  it('hands focus back to the Command Palette button that opened the palette', async () => {
    expect.hasAssertions();
    const menu = commandMenu();
    const focus = jest.spyOn(View.prototype, 'focus');
    try {
      await renderBarWindow('connected');
      const button = await screen.findByRole('button', {
        name: 'Open Command Palette',
      });
      await fireEvent(button, 'focus');
      await fireEvent.press(button);
      focus.mockClear();
      await fireEvent(
        screen.getByPlaceholderText('Type a command'),
        'keyDown',
        {
          nativeEvent: { key: 'Escape' },
        },
      );
      expect(menu.focus.restored).toStrictEqual([]);
      expect(
        focus.mock.contexts.map((view: View) => view.props.accessibilityLabel),
      ).toStrictEqual(['Open Command Palette']);
    } finally {
      focus.mockRestore();
      menu.restore();
    }
  });

  it('leaves Command-P without effect while setup shows no Command Palette bar', async () => {
    expect.hasAssertions();
    const menu = commandMenu();
    try {
      const window = await renderBarWindow('signed-out');
      await expect(
        screen.findByRole('header', { name: 'Your mail,\non your devices.' }),
      ).resolves.toBeVisible();
      await menu.choose('bar');
      expect(screen.queryByPlaceholderText('Type a command')).toBeNull();
      // Nor does the Inbox's bar open later with the commands of that press.
      await window.connect('google');
      await expect(
        screen.findByRole('button', { name: 'Open Command Palette' }),
      ).resolves.toBeVisible();
      expect(screen.queryByPlaceholderText('Type a command')).toBeNull();
    } finally {
      menu.restore();
    }
  });

  it('drops an open Command Palette when the gate replaces the screen of its window', async () => {
    expect.hasAssertions();
    const menu = commandMenu();
    try {
      const window = await renderBarWindow('connected');
      await expect(
        screen.findByRole('button', { name: 'Open Command Palette' }),
      ).resolves.toBeVisible();
      await menu.choose('bar');
      expect(screen.getByPlaceholderText('Type a command')).toBeVisible();
      await window.signOut();
      await expect(
        screen.findByRole('header', { name: 'Your mail,\non your devices.' }),
      ).resolves.toBeVisible();
      // This device gave up the Google account's keys, so the Apple account opens here instead.
      await window.connect('apple');
      await expect(
        screen.findByRole('button', { name: 'Open Command Palette' }),
      ).resolves.toBeVisible();
      expect(screen.queryByPlaceholderText('Type a command')).toBeNull();
    } finally {
      menu.restore();
    }
  });

  it('waits for registration verification before loading Gmail on activation', async () => {
    expect.hasAssertions();
    const listenersBeforeRender = jest.mocked(AppState.addEventListener).mock
      .calls.length;
    const { synthetic, setup } = await signedIn();
    await setup.addMailbox();
    const { vault } = synthetic;
    let finish: () => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Hold the native restore read to prove foreground ordering.
    const resumed = new Promise<void>((resolve) => {
      finish = resolve;
    });
    // The next verification waits on its first native read until released.
    let hold: Promise<void> | undefined = undefined;
    let prematureReads = 0;
    const gmail = createSyntheticGmail({ messages: 1 });
    let openMailbox = () => gmail.native.openMailbox();
    const store = createRegistration({
      ...vault,
      registration: async () => {
        const held = hold;
        hold = undefined;
        await held;
        return vault.registration();
      },
    });
    const mailboxes = gmailMailboxes(store, {
      [alex]: { native: { ...gmail.native, openMailbox: () => openMailbox() } },
    });
    await render(
      <RegistrationGate
        store={started(store)}
        preview={false}>
        <InboxProvider mailboxes={mailboxes}>
          <Shell
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
    hold = resumed;
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
      finish();
    });
    await expect(
      screen.findByText('After foreground verification'),
    ).resolves.toBeVisible();
  });

  it('retains setup after declined consent and connects a reselected Gmail account after remount', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-declined');
    const first = await render(
      <RegistrationGate
        store={started(createRegistration(synthetic.vault))}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await continueToSignIn();
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Connect your mail' }),
    ).resolves.toBeVisible();
    expect(
      screen.queryByRole('header', { name: 'Account & Devices' }),
    ).toBeNull();
    // A build that cannot authorize Microsoft mail never offers it.
    expect(
      screen.queryByRole('button', { name: 'Microsoft 365 and Outlook' }),
    ).toBeNull();
    await first.unmount();
    await render(
      <RegistrationGate
        store={started(createRegistration(synthetic.vault))}
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
      screen.findByRole('header', { name: 'Account & Devices' }),
    ).resolves.toBeVisible();
    expect(
      screen.getByText('other@example.invalid is connected on this device.'),
    ).toBeVisible();
  });

  it('offers interactive sign-in to recover a retained account after interruption', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario(
      'registration-interrupted',
    );
    await createRegistration(synthetic.vault).register('google');
    // The relaunched host's first mailbox authorization is interrupted.
    const store = createRegistration(synthetic.relaunch());
    await render(
      <RegistrationGate
        store={started(store)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Gmail' }),
      );
    });
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Sign in again with Google',
        }),
      );
    });
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Gmail' }),
      );
    });
    await expect(
      screen.findByText('alex@example.invalid is connected on this device.'),
    ).resolves.toBeVisible();
  });

  it('continues Apple sign-in into separate Gmail authorization and keeps the relay address as contact information', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves the provider choice and the Gmail grant. */
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-declined');
    await render(
      <RegistrationGate
        store={started(createRegistration(synthetic.vault))}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await continueToSignIn();
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Apple' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Connect your mail' }),
    ).resolves.toBeVisible();
    expect(
      screen.getByText(/Signing in with Apple does not give access to mail/u),
    ).toBeVisible();
    expect(
      screen.getByText(
        'Signed in with Apple. Contact email: relay@privaterelay.example.invalid.',
      ),
    ).toBeVisible();
    // A provider row opens its IMAP form in place; Cancel returns to the providers.
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'iCloud Mail' }),
      );
    });
    expect(screen.getByRole('header', { name: 'iCloud Mail' })).toBeVisible();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Cancel' }));
    });
    expect(screen.queryByRole('header', { name: 'iCloud Mail' })).toBeNull();
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
    await settings('Email Accounts');
    expect(
      screen.getByRole('button', { name: 'Add another Gmail mailbox' }),
    ).toBeVisible();
    expect(
      screen.queryByRole('button', { name: 'Add a Microsoft mailbox' }),
    ).toBeNull();
  });

  it('connects Microsoft mail as the first mailbox after Apple sign-in, without Gmail, and reads its Inbox', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves the provider choice, connection and Inbox. */
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
    const graph = createSyntheticGraph();
    graph.deliver({
      from: { name: 'Rowan Hale', address: 'rowan@example.invalid' },
      subject: 'Garden plans',
    });
    const mailboxes = gmailMailboxes(store, {
      [syntheticMailboxes['casey@example.invalid']]: graph,
    });
    await render(
      <RegistrationGate
        store={started(store)}
        microsoft
        preview={false}>
        <InboxProvider mailboxes={mailboxes}>
          <Shell
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
    await press('Continue');
    await press('Sign in with Apple');
    // Sign-in alone asks no provider for mail; the person chooses one.
    await expect(
      screen.findByRole('header', { name: 'Connect your mail' }),
    ).resolves.toBeVisible();
    expect(screen.getByRole('button', { name: 'Gmail' })).toBeVisible();
    await press('Microsoft 365 and Outlook');
    await expect(
      screen.findByText('casey@example.invalid is connected on this device.'),
    ).resolves.toBeVisible();
    await settings('Email Accounts');
    expect(
      screen.getByRole('button', { name: 'Add a Microsoft mailbox' }),
    ).toBeVisible();
    await settings('Account & Devices');
    await act(async () => {
      await fireEvent.changeText(
        await screen.findByLabelText('Last four characters'),
        lastFour(recoveryKeyOf(synthetic)),
      );
    });
    await press('Confirm Recovery Key');
    await expect(
      screen.findByRole('button', {
        name: 'Unread. Rowan Hale. Garden plans',
      }),
    ).resolves.toBeVisible();
    expect(screen.getByText('Encrypted on this device')).toBeVisible();
    expect(screen.queryByText('Gmail · Encrypted on this device')).toBeNull();
  });

  it('chooses remote image policies for this device and each mailbox, and clears remote content', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-declined');
    const saved: string[] = [];
    const remoteContent = createRemoteContentSettings({
      remoteContentSettings: () => Promise.resolve({ settings: null }),
      setRemoteContentSettings: (settings) => {
        saved.push(settings);
        return Promise.resolve(null);
      },
      clearRemoteContent: () => Promise.resolve(null),
    });
    await remoteContent.load();
    await render(
      <RegistrationGate
        store={started(createRegistration(synthetic.vault))}
        preview={false}
        remoteContent={remoteContent}>
        {null}
      </RegistrationGate>,
    );
    const press = async (name: string) => {
      await act(async () => {
        await fireEvent.press(await screen.findByRole('button', { name }));
      });
    };
    await press('Continue');
    await press('Sign in with Apple');
    await press('Choose another Google mailbox');
    await settings('Privacy & Data');
    const choice = (name: string) => screen.getByRole('radio', { name });
    expect(choice('On this device: Ask')).toBeChecked();
    expect(
      choice('Remote images for other@example.invalid: Use device setting'),
    ).toBeChecked();
    await act(async () => {
      await fireEvent.press(choice('On this device: Always load'));
    });
    await act(async () => {
      await fireEvent.press(
        choice('Remote images for other@example.invalid: Never'),
      );
    });
    expect(
      choice('Remote images for other@example.invalid: Never'),
    ).toBeChecked();
    expect(saved.at(-1)).toBe(
      '{"policy":"always","overrides":{"synthetic-connection-other":"never"}}',
    );
    await press('Clear remote content');
    // The confirmation appears only after the native clear resolved.
    expect(
      screen.getByText('Remote content saved on this device was removed.'),
    ).toBeVisible();
  });

  /* oxlint-disable vitest/max-expects -- One journey proves adding, switching, reauthorizing and removing mailboxes. */
  it('adds, switches, reauthorizes and removes Gmail mailboxes without mixing their mail', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
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
      <MacWindows store={store}>
        <RegistrationGate
          store={started(store)}
          preview={false}>
          <InboxProvider mailboxes={mailboxes}>
            <Shell
              onSelect={() => undefined}
              selected={undefined}
            />
          </InboxProvider>
        </RegistrationGate>
      </MacWindows>,
    );
    const press = async (name: string) => {
      await act(async () => {
        await fireEvent.press(await screen.findByRole('button', { name }));
      });
    };
    await press('Continue');
    await press('Sign in with Google');
    await press('Gmail');
    await act(async () => {
      await fireEvent.changeText(
        await screen.findByLabelText('Last four characters'),
        lastFour(recoveryKeyOf(synthetic)),
      );
    });
    await press('Confirm Recovery Key');
    // One mailbox: its rows need no mailbox name.
    await expect(
      screen.findByRole('button', { name: 'Unread. Maya Chen. Only for Alex' }),
    ).resolves.toBeVisible();
    await openAccount();
    await settings('Email Accounts');
    await press('Add another Gmail mailbox');
    await settings('Account & Devices');
    expect(
      screen.getByText(
        'alex@example.invalid, other@example.invalid are connected on this device.',
      ),
    ).toBeVisible();
    // Adding a mailbox that is already connected authorizes it again; nothing is duplicated.
    synthetic.choose('alex@example.invalid');
    await settings('Email Accounts');
    await press('Add another Gmail mailbox');
    expect(settingsWindow().getAllByText('alex@example.invalid')).toHaveLength(
      1,
    );
    await closeSettings();
    // Both mailboxes together, newest first, each row naming its own mailbox.
    const unified = await screen.findAllByRole('button', { name: /^Unread/u });
    expect(unified.map((row) => row.props.accessibilityLabel)).toStrictEqual([
      'Unread. Maya Chen. Only for Alex. In alex@example.invalid',
      'Unread. Maya Chen. Only for Other. In other@example.invalid',
    ]);
    await press('Inbox. In other@example.invalid');
    expect(
      screen.getByRole('button', { name: 'Inbox. In other@example.invalid' }),
    ).toBeSelected();
    expect(screen.queryByText('Only for Alex')).toBeNull();
    expect(screen.getByText('Only for Other')).toBeVisible();
    await press('All inboxes');

    // Alex's grant is refused at the next verification; Other's mail stays available.
    synthetic.expire('alex@example.invalid');
    await act(store.resume);
    expect(screen.queryByText('Only for Alex')).toBeNull();
    expect(screen.getByText('Only for Other')).toBeVisible();
    expect(
      screen.getByText(
        'alex@example.invalid: Gmail needs your permission again to show new mail.',
      ),
    ).toBeVisible();
    // Mac standalone text exposes its live-region semantics on the accessible wrapper.
    expect(
      screen.getByLabelText(
        'alex@example.invalid: Gmail needs your permission again to show new mail.',
      ),
    ).toHaveProp('accessibilityLiveRegion', 'polite');
    // The sidebar keeps the connection listed with its problem beside it, and offers the grant.
    expect(
      screen.getByRole('button', {
        name: 'Allow Gmail access for alex@example.invalid',
      }),
    ).toBeVisible();
    const alexRow = () =>
      screen.getByRole('button', { name: 'Inbox. In alex@example.invalid' });
    expect(alexRow()).toHaveAccessibilityValue({
      text: 'Gmail needs your permission again',
    });
    await press('Inbox. In alex@example.invalid');
    await expect(screen.findByText('Only for Alex')).resolves.toBeVisible();
    expect(alexRow()).toHaveAccessibilityValue({ text: '1 unread' });
    // A chosen mailbox stays chosen while its grant lapses, so nothing else is shown or sent from.
    await press('Inbox. In alex@example.invalid');
    synthetic.expire('alex@example.invalid');
    await act(store.resume);
    expect([
      alexRow().props.accessibilityState?.selected,
      screen.getByRole('button', { name: 'All inboxes' }).props
        .accessibilityState?.selected,
      screen.queryByText('Only for Other'),
    ]).toStrictEqual([true, false, null]);
    await press('Allow Gmail access for alex@example.invalid');
    await expect(screen.findByText('Only for Alex')).resolves.toBeVisible();
    expect(alexRow().props.accessibilityState?.selected).toBe(true);
    await press('All inboxes');

    // Removal asks first, then removes only that mailbox's mail from this device.
    await openAccount();
    await settings('Email Accounts');
    await press('Remove other@example.invalid');
    expect(
      screen.getByText(
        /Removing other@example\.invalid deletes its Gmail access/u,
      ),
    ).toBeVisible();
    await press('Remove other@example.invalid');
    expect(screen.queryByText('other@example.invalid')).toBeNull();
    await closeSettings();
    await expect(
      screen.findByRole('button', { name: 'Unread. Maya Chen. Only for Alex' }),
    ).resolves.toBeVisible();
    expect(screen.queryByText('Only for Other')).toBeNull();
    expect(gmail.other.modifies).toStrictEqual([]);
  });
  /* oxlint-enable vitest/max-expects */

  it('searches saved senders and subjects across mailboxes, shows saved bodies, and keeps only the current answer', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
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
          <Shell
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
      <MacWindows store={store}>
        <RegistrationGate
          store={started(store)}
          preview={false}>
          <Searching list={mailboxes} />
        </RegistrationGate>
      </MacWindows>,
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
    await press('Continue');
    await press('Sign in with Google');
    await press('Gmail');
    await act(async () => {
      await fireEvent.changeText(
        await screen.findByLabelText('Last four characters'),
        lastFour(recoveryKeyOf(synthetic)),
      );
    });
    await press('Confirm Recovery Key');
    await openAccount();
    await settings('Email Accounts');
    await press('Add another Gmail mailbox');
    await closeSettings();
    // A result searched while prefetch is still downloading its body becomes saved once the body
    // is, without a new query or selection.
    await search('studio');
    await waitFor(() => {
      expect(rows()).toStrictEqual([
        'Unread. Maya Chen. Studio review. In alex@example.invalid. Downloads from the mail server when opened',
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
        'Unread. Oliver Park. Café on Saturday. In alex@example.invalid. Downloads from the mail server when opened',
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
    await press('Inbox. In alex@example.invalid');
    await waitFor(() => {
      expect(rows()).toStrictEqual([
        'Unread. Maya Chen. Studio review. In alex@example.invalid. Saved on this device',
      ]);
    });
    await press('All inboxes');

    // A result opens through the reader; once its body is saved, the result says so.
    await search('cafe');
    await press(
      'Unread. Oliver Park. Café on Saturday. In alex@example.invalid. Downloads from the mail server when opened',
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
    await settings('Email Accounts');
    await press('Remove other@example.invalid');
    await press('Remove other@example.invalid');
    await closeSettings();
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
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
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
          <Shell
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
      <MacWindows store={store}>
        <RegistrationGate
          store={started(store)}
          preview={false}>
          <Searching />
        </RegistrationGate>
      </MacWindows>,
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
    await press('Continue');
    await press('Sign in with Google');
    await press('Gmail');
    await act(async () => {
      await fireEvent.changeText(
        await screen.findByLabelText('Last four characters'),
        lastFour(recoveryKeyOf(synthetic)),
      );
    });
    await press('Confirm Recovery Key');
    await openAccount();
    await settings('Email Accounts');
    await press('Add another Gmail mailbox');
    await closeSettings();

    // Saved results come first; Gmail is searched only when asked, across both mailboxes.
    await search('studio');
    await waitFor(() => {
      expect(rows()).toHaveLength(1);
    });
    expect(
      gmail.alex.requests.filter(({ query }) => query.has('q')),
    ).toStrictEqual([]);
    await press('Search mail servers for “studio”');
    await expect(
      screen.findByRole('header', { name: 'From mail servers' }),
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
    await press('Inbox. In alex@example.invalid');
    await press('Search mail servers for “studio”');
    await waitFor(() => {
      expect(rows()).toHaveLength(3);
    });
    expect(
      rows().filter((row) => row.includes('other@example.invalid')),
    ).toHaveLength(0);
    await press('All inboxes');
    await expect(
      screen.findByRole('button', { name: 'Search mail servers for “studio”' }),
    ).resolves.toBeVisible();
    expect(
      screen.queryByRole('header', { name: 'From mail servers' }),
    ).toBeNull();
    await press('Search mail servers for “studio”');
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
      screen.findByRole('button', { name: 'Search mail servers for “maya”' }),
    ).resolves.toBeVisible();
    expect(
      screen.queryByRole('header', { name: 'From mail servers' }),
    ).toBeNull();
    gmail.other.fail({ code: 'unavailable' });
    await press('Search mail servers for “maya”');
    await expect(
      screen.findByText(
        'other@example.invalid: The mail server could not be reached. Mail saved on this device is still shown.',
      ),
    ).resolves.toBeVisible();
    await waitFor(() => {
      expect(rows()).toHaveLength(3);
    });
    // The header reports the unreachable server instead of a result count.
    expect(screen.getByText(/ · Offline$/u)).toBeVisible();
    // Asking again searches every mailbox afresh.
    await press('Search mail servers again');
    await waitFor(() => {
      expect(rows()).toHaveLength(4);
    });
    expect(screen.queryByText(/Gmail could not be reached/u)).toBeNull();
    expect(screen.queryByText(/ · Offline$/u)).toBeNull();

    // A reply for a query that changed meanwhile is never shown.
    let release: () => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Hold one search, released by the journey.
    holding = new Promise((resolve) => {
      release = resolve;
    });
    const stale = holding;
    await search('archive');
    await press('Search mail servers for “archive”');
    await expect(
      screen.findByLabelText('Searching mail servers'),
    ).resolves.toBeVisible();
    await search('plans');
    await act(async () => {
      release();
      await stale;
    });
    await expect(
      screen.findByRole('button', { name: 'Search mail servers for “plans”' }),
    ).resolves.toBeVisible();
    expect(
      screen.queryByRole('header', { name: 'From mail servers' }),
    ).toBeNull();
    // Returning to the old query must not revive its completed, stale request.
    await search('archive');
    await expect(
      screen.findByRole('button', {
        name: 'Search mail servers for “archive”',
      }),
    ).resolves.toBeVisible();
    expect(
      screen.queryByRole('header', { name: 'From mail servers' }),
    ).toBeNull();
    await search('plans');
    // Only the saved result remains.
    expect(rows()).toStrictEqual([
      'Unread. Oliver Park. Plans. In other@example.invalid. Downloads from the mail server when opened',
    ]);
    await press(
      'Unread. Oliver Park. Plans. In other@example.invalid. Downloads from the mail server when opened',
    );
    await waitFor(() => {
      expect(gmail.alex.savedFiles.size).toBe(0);
    });
  });
  /* oxlint-enable vitest/max-expects */

  it('links Google from account settings and keeps both sign-in methods after remount', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-link');
    // Apple suggests no Google account; the person chooses Alex's.
    synthetic.choose('alex@example.invalid');
    const first = await render(
      <RegistrationGate
        store={started(createRegistration(synthetic.vault))}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await continueToSignIn();
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Apple' }),
      );
    });
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Gmail' }),
      );
    });
    await expect(
      screen.findByText('alex@example.invalid is connected on this device.'),
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
        store={started(createRegistration(synthetic.vault))}
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
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
    await render(
      <RegistrationGate
        store={started(store)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await continueToSignIn();
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

  it('recovers an unverifiable Apple account through a Google link made on another device without new Gmail consent', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-link');
    synthetic.choose('alex@example.invalid');
    const setup = createRegistration(synthetic.vault);
    await setup.register('apple');
    await setup.confirmRecoveryKey(lastFour(recoveryKeyOf(synthetic)));
    await setup.addMailbox();
    // Another Trusted Device of the account links Google; this device's saved receipt predates it.
    const other = synthetic.otherDevice();
    const elsewhere = createRegistration(other.vault);
    await elsewhere.register('apple');
    await elsewhere.recoverWithRecoveryKey(recoveryKeyOf(synthetic));
    await elsewhere.link('google');
    // Apple can no longer verify this device's sign-in.
    synthetic.apple.state = 'revoked';
    const store = createRegistration({
      ...synthetic.vault,
      signInMailbox: () =>
        Promise.reject(new Error('Gmail consent must not restart')),
    });
    await render(
      <MacWindows store={store}>
        <RegistrationGate
          store={started(store)}
          preview={false}>
          <ConnectedInbox />
        </RegistrationGate>
      </MacWindows>,
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
      screen.findByText('alex@example.invalid is connected on this device.'),
    ).resolves.toBeVisible();
    expect(screen.queryByRole('alert')).toBeNull();
    expect(store.getSnapshot().snapshot).toMatchObject({
      productAccountId: 'account-synthetic-apple-subject',
      signInProvider: 'google',
    });
  });

  /* oxlint-disable vitest/max-expects -- One journey proves setup confirmation and the Inbox it opens. */
  it('presents the Recovery Key until its final group is confirmed, then shows the encrypted mailbox list', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
    await render(
      <MacWindows store={store}>
        <RegistrationGate
          store={started(store)}
          preview={false}>
          <ConnectedInbox />
        </RegistrationGate>
      </MacWindows>,
    );
    await continueToSignIn();
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Gmail' }),
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
    expect(screen.getByText(recoveryKeyOf(synthetic))).toBeVisible();
    await act(async () => {
      await fireEvent.changeText(
        entry,
        // Separators and case are ignored, as in native confirmation.
        [...lastFour(recoveryKeyOf(synthetic)).toLowerCase()].join(' '),
      );
    });
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Confirm Recovery Key' }),
      );
    });
    // Confirmed setup opens the synchronized Gmail Inbox; Settings stays reachable.
    await expect(
      screen.findByRole('button', {
        name: 'Unread. Maya Chen. Synthetic message 0',
      }),
    ).resolves.toBeVisible();
    // The heading's subtitle names the connected mailbox beside its unread count.
    expect(screen.getByText(/^alex@example\.invalid · /u)).toBeVisible();
    await openAccount();
    await expect(
      screen.findByRole('header', { name: 'Private sync is on' }),
    ).resolves.toBeVisible();
    expect(screen.queryByText(recoveryKeyOf(synthetic))).toBeNull();
    await closeSettings();
    await expect(
      screen.findByRole('button', { name: 'Account' }),
    ).resolves.toBeVisible();
  });

  /* oxlint-enable vitest/max-expects */
  /* oxlint-disable vitest/max-expects -- One journey proves both devices' sides of an approval. */
  it('unlocks a new device only after a trusted device approves the code it shows', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-success');
    const trusted = createRegistration(synthetic.vault);
    // Another installation of the same account, with its own Keychain.
    const other = synthetic.otherDevice();
    const added = createRegistration(other.vault);
    const enrollmentCode = () => enrollmentCodeOf(added);
    const show = (store: typeof trusted) =>
      render(
        <RegistrationGate
          store={started(store)}
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
    await press('Continue');
    await press('Sign in with Google');
    await press('Gmail');
    await expect(
      screen.findByText('Encrypted mailbox list: alex@example.invalid.'),
    ).resolves.toBeVisible();
    await view.unmount();

    // Signing in on another device makes it a Pending Device: no private data, mailbox or links.
    view = await show(added);
    await press('Continue');
    await press('Sign in with Google');
    await expect(
      screen.findByRole('header', { name: 'Add this device' }),
    ).resolves.toBeVisible();
    expect(
      screen.getByRole('header', { name: 'Approve this device' }),
    ).toBeVisible();
    expect(screen.getByTestId('enrollment-code')).toHaveTextContent(
      enrollmentCode().replaceAll('-', ' '),
    );
    expect(screen.getByTestId('enrollment-code')).toHaveProp(
      'accessibilityLabel',
      enrollmentCode(),
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
        enrollmentCode().toLowerCase().replaceAll('-', ' '),
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
      screen.getByRole('header', { name: 'Connect your mail' }),
    ).toBeVisible();
    expect(screen.getByRole('button', { name: 'Gmail' })).toBeVisible();
  });

  it('unlocks a new device with the Recovery Key after a wrong key changes nothing, and offers no reset', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-success');
    const lost = createRegistration(synthetic.vault);
    // Another installation of the same account, with its own Keychain.
    const other = synthetic.otherDevice();
    const added = createRegistration(other.vault);
    const show = (store: typeof lost) =>
      render(
        <RegistrationGate
          store={started(store)}
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
    await press('Continue');
    await press('Sign in with Google');
    await press('Gmail');
    await expect(
      screen.findByText('Encrypted mailbox list: alex@example.invalid.'),
    ).resolves.toBeVisible();
    await view.unmount();

    // A new device offers the Recovery Key beside approval, and explains that losing both
    // leaves the encrypted data locked; nothing offers to reset it.
    view = await show(added);
    await press('Continue');
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
      // The code this device shows is not the Recovery Key.
      await fireEvent.changeText(entry, enrollmentCodeOf(added));
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
        recoveryKeyOf(synthetic).toLowerCase().replaceAll('-', ' '),
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
    expect(screen.getByRole('button', { name: 'Gmail' })).toBeVisible();
    await view.unmount();
    await show(added);
    await expect(
      screen.findByRole('header', { name: 'Private sync is on' }),
    ).resolves.toBeVisible();
  });

  /* oxlint-enable vitest/max-expects */

  it('replaces a request that is no longer available and clears the code typed for it', async () => {
    expect.hasAssertions();
    const { synthetic, setup } = await signedIn();
    await setup.addMailbox();
    const store = createRegistration(synthetic.vault);
    // A minute later, another device of the account signs in and waits for approval.
    const requestFrom = async () => {
      synthetic.sync.clock += 60_000;
      const other = synthetic.otherDevice();
      const requesting = createRegistration(other.vault);
      await requesting.register('google');
      return requesting;
    };
    await store.restoreOnce();
    await render(
      <MacWindows store={store}>
        <RegistrationGate
          store={started(store)}
          preview={false}>
          <ConnectedInbox />
        </RegistrationGate>
      </MacWindows>,
    );
    await openAccount();
    const press = async (name: string) => {
      await act(async () => {
        await fireEvent.press(
          await settingsWindow().findByRole('button', { name }),
        );
      });
    };
    const requesting = await requestFrom();
    await press('Check for a new device');
    await act(async () => {
      await fireEvent.changeText(
        settingsWindow().getByLabelText('Code from the new device'),
        enrollmentCodeOf(requesting),
      );
    });
    // Meanwhile that device was unlocked with the Recovery Key, which handled its request.
    await requesting.recoverWithRecoveryKey(recoveryKeyOf(synthetic));
    await press('Approve device');
    expect(settingsWindow().getByRole('alert')).toHaveTextContent(
      /no longer available/u,
    );
    await requestFrom();
    await press('Check for a new device');
    expect(
      settingsWindow().getByLabelText('Code from the new device'),
    ).toHaveProp('value', '');
  });

  it("starts the open Settings window afresh on the replacement Product Account's pending setup", async () => {
    expect.hasAssertions();
    const { synthetic, setup } = await signedIn();
    await setup.addMailbox();
    const store = createRegistration(synthetic.vault);
    await render(
      <MacWindows store={store}>
        <RegistrationGate
          store={started(store)}
          preview={false}>
          <ConnectedInbox />
        </RegistrationGate>
      </MacWindows>,
    );
    await act(async () => {
      openSettings('account-synthetic-product-subject', 'mailboxes');
    });
    expect(
      screen.getByRole('header', { name: 'Email Accounts' }),
    ).toBeVisible();
    // Foreground verification discovers another Product Account with an unconfirmed key, which
    // another window signed in to after signing out.
    await setup.signOut();
    await setup.register('apple');
    await setup.addMailbox();
    await act(async () => {
      await store.resume();
    });
    // The Inbox window opens the pending setup too.
    expect({
      settings: settingsWindow().getByRole('header', {
        name: 'Account & Devices',
      }),
      keys: screen
        .getAllByTestId('recovery-key')
        .map((key) => key.props.children),
    }).toStrictEqual({
      settings: expect.anything(),
      keys: [expect.anything(), expect.anything()],
    });
    expect(settingsWindow().getByTestId('recovery-key')).toHaveTextContent(
      recoveryKeyOf(synthetic),
    );
    expect(screen.queryByRole('header', { name: 'Email Accounts' })).toBeNull();
  });

  it('verifies activation with only Settings open and closes it after account removal', async () => {
    expect.hasAssertions();
    const { synthetic, setup } = await signedIn();
    await setup.addMailbox();
    const store = started(createRegistration(synthetic.vault));
    await store.restoreOnce();
    const listenersBeforeRender = jest.mocked(AppState.addEventListener).mock
      .calls.length;
    await render(<MacWindows store={store}>{null}</MacWindows>);
    await commandComma();
    expect(
      settingsWindow().getByRole('header', { name: 'Account & Devices' }),
    ).toBeVisible();
    await setup.signOut();
    await act(async () => {
      for (const [, activate] of jest
        .mocked(AppState.addEventListener)
        .mock.calls.slice(listenersBeforeRender)) {
        activate('active');
      }
      await Promise.resolve();
    });
    await waitFor(() => {
      expect(screen.queryByTestId('settings-window')).toBeNull();
    });
  });

  it('shows a locked state instead of onboarding after a locked launch and restores the account once active', async () => {
    expect.hasAssertions();
    const listenersBeforeRender = jest.mocked(AppState.addEventListener).mock
      .calls.length;
    const { synthetic, setup } = await signedIn({ confirmKey: false });
    await setup.addMailbox();
    const { vault } = synthetic;
    // Protected storage cannot be read until the device is unlocked.
    let registration: typeof vault.registration = () =>
      Promise.reject(Object.assign(new Error('locked'), { code: 'locked' }));
    await render(
      <RegistrationGate
        store={started(
          createRegistration({
            ...vault,
            registration: () => registration(),
          }),
        )}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await expect(
      screen.findByRole('header', { name: 'Unlock your device' }),
    ).resolves.toBeVisible();
    expect([
      screen.queryByText('Your mail,\non your devices.'),
      screen.queryByRole('button'),
      screen.queryByRole('alert'),
    ]).toStrictEqual([null, null, null]);
    ({ registration } = vault);
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
      screen.findByText('alex@example.invalid is connected on this device.'),
    ).resolves.toBeVisible();
    // Google now refuses the saved grant, so the next verification cannot open the account.
    synthetic.google.refreshFailure = 'invalid-grant';
    await act(async () => {
      for (const [, activate] of jest
        .mocked(AppState.addEventListener)
        .mock.calls.slice(listenersBeforeRender)) {
        activate('active');
      }
      await Promise.resolve();
    });
    await expect(
      screen.findByRole('header', { name: 'Connect your mail' }),
    ).resolves.toBeVisible();
    expect(
      screen.queryByText('alex@example.invalid is connected on this device.'),
    ).toBeNull();
  });

  // Mocked journey: the deterministic Mock Mail Session stands in for native preparation and
  // activation; native and Convex evidence of the protocol is separate.
  /* oxlint-disable vitest/max-expects -- One journey proves the explanation, cancellation, renewal and removal. */
  it('retires a native device-removal confirmation when its account view closes', async () => {
    expect.hasAssertions();
    const nativeAlert = jest.spyOn(Alert, 'alert').mockReturnValue(undefined);
    try {
      const { synthetic } = await signedIn({
        scenario: 'registration-revocation',
      });
      const store = createRegistration(synthetic.vault);
      const view = await render(
        <RegistrationGate
          store={started(store)}
          preview={false}>
          {null}
        </RegistrationGate>,
      );
      const remove = english('revocation.remove', {
        name: syntheticTrustedDevice.name,
      });
      await expect(
        screen.findByRole('button', { name: remove }),
      ).resolves.toBeVisible();
      await act(async () => {
        await fireEvent.press(screen.getByRole('button', { name: remove }));
      });
      const confirm = nativeAlert.mock.lastCall?.[2]?.find(
        ({ style }) => style === 'destructive',
      )?.onPress;
      expect(confirm).toBeDefined();
      const before = store.getSnapshot();
      await view.unmount();
      await act(async () => {
        confirm?.();
      });
      expect(store.getSnapshot()).toBe(before);
    } finally {
      nativeAlert.mockRestore();
    }
  });

  it('removes another trusted device only after its replacement Recovery Key is confirmed', async () => {
    expect.hasAssertions();
    const nativeAlert = jest.spyOn(Alert, 'alert').mockReturnValue(undefined);
    try {
      const synthetic = await createRegistrationScenario(
        'registration-revocation',
      );
      const store = createRegistration(synthetic.vault);
      await render(
        <RegistrationGate
          store={started(store)}
          preview={false}>
          {null}
        </RegistrationGate>,
      );
      await continueToSignIn();
      await act(async () => {
        await fireEvent.press(
          await screen.findByRole('button', { name: 'Sign in with Google' }),
        );
      });
      expect(screen.queryByRole('button', { name: 'Remove iPad' })).toBeNull();
      await act(async () => {
        await fireEvent.changeText(
          screen.getByLabelText('Last four characters'),
          lastFour(recoveryKeyOf(synthetic)),
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
        expect(nativeAlert.mock.lastCall?.[0]).toBe(
          english('revocation.confirmTitle', { name }),
        );
        expect(nativeAlert.mock.lastCall?.[1]).toMatch(
          /only then is iPad removed.*cannot be erased remotely/u,
        );
        const choices = nativeAlert.mock.lastCall?.[2];
        expect(choices?.find(({ style }) => style === 'cancel')?.text).toBe(
          english('revocation.cancel'),
        );
        await act(async () => {
          choices?.find(({ style }) => style === 'destructive')?.onPress?.();
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
      const replacementKey = () => replacementKeyOf(store);
      await prepare();
      // Prepared, not removed: the replacement key waits for confirmation instead of the list.
      expect(screen.getByRole('header', { name: proposal })).toBeVisible();
      expect(screen.getByTestId('revocation-recovery-key')).toHaveTextContent(
        replacementKey(),
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
      const replacement = replacementKey();
      await confirm(lastFour(recoveryKeyOf(synthetic)));
      expect(screen.getByRole('alert')).toHaveTextContent(
        english('revocation.mismatch'),
      );
      expect(screen.getByTestId('revocation-recovery-key')).toHaveTextContent(
        replacement,
      );
      // Another device changed the account: a fresh key must be saved and confirmed again.
      synthetic.changeAccount();
      await confirm(lastFour(replacement));
      expect(screen.getByRole('alert')).toHaveTextContent(
        english('revocation.renewed'),
      );
      const renewed = replacementKey();
      expect(renewed).not.toBe(replacement);
      expect(screen.getByTestId('revocation-recovery-key')).toHaveTextContent(
        renewed,
      );
      expect(screen.getByLabelText(entry)).toHaveProp('value', '');
      await confirm(lastFour(renewed));
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
    } finally {
      nativeAlert.mockRestore();
    }
  });

  /* oxlint-enable vitest/max-expects */

  // Mocked presentation evidence; hosted native tests prove actual epoch catch-up and key custody.
  /* oxlint-disable vitest/max-expects -- One journey covers successive removals, relaunch and lost-key recovery. */
  it('continues through successive removals and requires fresh enrollment after losing this device key', async () => {
    expect.hasAssertions();
    const nativeAlert = jest.spyOn(Alert, 'alert').mockReturnValue(undefined);
    try {
      const { synthetic } = await signedIn({
        scenario: 'registration-revocation',
      });
      const firstKey = recoveryKeyOf(synthetic);
      synthetic.addSecondTrustedDevice();
      const store = createRegistration(synthetic.vault);
      const show = () =>
        render(
          <RegistrationGate
            store={started(store)}
            preview={false}>
            {null}
          </RegistrationGate>,
        );
      let view = await show();
      await expect(
        screen.findByRole('header', { name: 'Private sync is on' }),
      ).resolves.toBeVisible();
      const removals = [
        syntheticTrustedDevice.name,
        syntheticSecondTrustedDevice.name,
      ];
      // Each removal's replacement Recovery Key, which becomes the account's current one.
      let latestKey = firstKey;
      for (const name of removals) {
        const remove = english('revocation.remove', { name });
        await act(async () => {
          await fireEvent.press(screen.getByRole('button', { name: remove }));
        });
        await act(async () => {
          nativeAlert.mock.lastCall?.[2]
            ?.find(({ style }) => style === 'destructive')
            ?.onPress?.();
        });
        const key = replacementKeyOf(store);
        expect(key).not.toBe(latestKey);
        latestKey = key;
        expect(screen.getByTestId('revocation-recovery-key')).toHaveTextContent(
          key,
        );
        await act(async () => {
          await fireEvent.changeText(
            screen.getByLabelText(english('revocation.label')),
            lastFour(key),
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
      synthetic.loseDeviceKey();
      await act(async () => {
        await store.resume();
      });
      await expect(
        screen.findByTestId('enrollment-code'),
      ).resolves.toHaveTextContent(
        enrollmentCodeOf(store).replaceAll('-', ' '),
      );
      expect(
        screen.getByRole('header', { name: 'Approve this device' }),
      ).toBeVisible();
      expect(
        screen.queryByRole('header', { name: 'Private sync is on' }),
      ).toBeNull();
      await act(async () => {
        await fireEvent.changeText(
          screen.getByLabelText('Recovery Key'),
          firstKey,
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
          latestKey,
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
    } finally {
      nativeAlert.mockRestore();
    }
  });
  /* oxlint-enable vitest/max-expects */

  // Mocked presentation: native separately proves exact replay and retention without a receipt.
  /* oxlint-disable vitest/max-expects -- One journey covers keyless routing, Cancel retention and Confirm settlement. */
  it.each([
    { kind: 'mailbox-needed', mailbox: () => Promise.resolve() },
    {
      kind: 'connected',
      mailbox: async ({ setup }: Awaited<ReturnType<typeof signedIn>>) => {
        await setup.addMailbox();
      },
    },
    {
      kind: 'cached',
      // Gmail cannot be reached, so the mailbox opens from what this device saved.
      mailbox: async ({
        synthetic,
        setup,
      }: Awaited<ReturnType<typeof signedIn>>) => {
        await setup.addMailbox();
        synthetic.google.refreshFailure = 'offline';
      },
    },
  ])(
    'keeps a retained removal proposal confirmable after this device loses its key ($kind)',
    async ({ kind, mailbox }) => {
      expect.hasAssertions();
      const account = await signedIn({ scenario: 'registration-revocation' });
      const { synthetic, setup } = account;
      await mailbox(account);
      await setup.revokeTrustedDevice(syntheticTrustedDevice.id);
      const replacement = replacementKeyOf(setup);
      // The removal was sent but never reached the backend, so it stays to be sent again.
      synthetic.sync.failActivationBeforeCommit = true;
      await setup.confirmRevocation(lastFour(replacement));
      // This device then loses its encryption key.
      synthetic.device.productSync.deviceKey = false;
      synthetic.device.productSync.deviceKeyName = undefined;
      const store = createRegistration(synthetic.vault);
      await render(
        <RegistrationGate
          store={started(store)}
          preview={false}>
          {null}
        </RegistrationGate>,
      );
      await expect(
        screen.findByTestId('revocation-recovery-key'),
      ).resolves.toHaveTextContent(replacement);
      expect(store.getSnapshot().snapshot).toMatchObject({
        kind,
        privateSync: 'enrollment-needed',
      });
      const remove = english('revocation.remove', {
        name: english('revocation.device'),
      });
      expect(screen.getByRole('button', { name: remove })).toBeOnTheScreen();
      expect(
        screen.queryByRole('button', {
          name: english('revocation.remove', {
            name: syntheticTrustedDevice.name,
          }),
        }),
      ).toBeNull();
      expect(
        screen.getByRole('button', { name: english('recovery.unlock') }),
      ).toBeOnTheScreen();
      await act(async () => {
        await fireEvent.press(
          screen.getByRole('button', { name: english('revocation.cancel') }),
        );
      });
      expect(screen.getByRole('alert')).toHaveTextContent(
        english('revocation.unconfirmed'),
      );
      expect(screen.getByTestId('revocation-recovery-key')).toHaveTextContent(
        replacement,
      );
      await act(async () => {
        await fireEvent.changeText(
          screen.getByLabelText(english('revocation.label')),
          lastFour(replacement),
        );
      });
      await act(async () => {
        await fireEvent.press(screen.getByRole('button', { name: remove }));
      });
      await expect(
        screen.findByTestId('enrollment-code'),
      ).resolves.toHaveTextContent(
        enrollmentCodeOf(store).replaceAll('-', ' '),
      );
      expect(screen.queryByTestId('revocation-recovery-key')).toBeNull();
    },
  );
  /* oxlint-enable vitest/max-expects */

  // Mocked journey: native outcomes after a lost reply and after another device's removal.
  it('keeps an unconfirmed removal proposal, then explains a superseded one without its key', async () => {
    expect.hasAssertions();
    const { synthetic, setup } = await signedIn({
      scenario: 'registration-revocation',
    });
    await setup.revokeTrustedDevice(syntheticTrustedDevice.id);
    const replacement = replacementKeyOf(setup);
    const { snapshot } = setup.getSnapshot();
    assert.ok(snapshot.kind !== 'signed-out');
    // The removal's request is lost before it reaches the backend, so no reply confirms it.
    synthetic.sync.failActivationBeforeCommit = true;
    await render(
      <RegistrationGate
        store={started(createRegistration(synthetic.vault))}
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
          lastFour(replacement),
        );
      });
      await act(async () => {
        await fireEvent.press(screen.getByRole('button', { name: remove }));
      });
    };
    await expect(
      screen.findByTestId('revocation-recovery-key'),
    ).resolves.toHaveTextContent(replacement);
    await confirm();
    expect(screen.getByRole('alert')).toHaveTextContent(
      english('revocation.unconfirmed'),
    );
    expect(screen.getByTestId('revocation-recovery-key')).toHaveTextContent(
      replacement,
    );
    // Another device removes the iPad first.
    removeTrustedDevice(
      synthetic.sync,
      snapshot.productAccountId,
      syntheticTrustedDevice.id,
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
    const synthetic = await createRegistrationScenario('registration-revoked');
    const store = createRegistration(synthetic.vault);
    await render(
      <RegistrationGate
        store={started(store)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await continueToSignIn();
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
    const code = enrollmentCodeOf(store);
    expect(screen.getByTestId('enrollment-code')).toHaveTextContent(
      code.replaceAll('-', ' '),
    );
    expect(screen.getByTestId('enrollment-code')).toHaveProp(
      'accessibilityLabel',
      code,
    );
    expect(screen.queryByRole('button', { name: 'Gmail' })).toBeNull();
    // Leaving the Pending Device returns to Welcome.
    const signOut = { name: english('accountRemoval.signOut') };
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', signOut));
    });
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', signOut));
    });
    await expect(
      screen.findByRole('header', { name: 'Your mail,\non your devices.' }),
    ).resolves.toBeVisible();
    expect(screen.queryByTestId('enrollment-code')).toBeNull();
  });

  /* oxlint-enable vitest/max-expects */

  /* oxlint-disable vitest/max-expects -- Each journey proves the explanation, cancellation and outcome. */
  it('signs this device out only after confirmation and keeps nothing of the account', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
    await render(
      <MacWindows store={store}>
        <RegistrationGate
          store={started(store)}
          preview={false}>
          <ConnectedInbox />
        </RegistrationGate>
      </MacWindows>,
    );
    await continueToSignIn();
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Gmail' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: english('accountRemoval.title') }),
    ).resolves.toBeVisible();
    await act(async () => {
      await fireEvent.changeText(
        screen.getByLabelText('Last four characters'),
        lastFour(recoveryKeyOf(synthetic)),
      );
    });
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Confirm Recovery Key' }),
      );
    });
    const recoveryKey = recoveryKeyOf(synthetic);
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
    // Settings closes with the account it showed.
    await expect(
      screen.findByRole('header', { name: 'Your mail,\non your devices.' }),
    ).resolves.toBeVisible();
    expect(screen.queryByTestId('settings-window')).toBeNull();
    expect(screen.queryByText('Signed in with Google.')).toBeNull();
    expect(screen.queryByText(recoveryKey)).toBeNull();
  });

  it.each([
    {
      removalPending: 'sign-out',
      // The backend cannot be reached to unregister this device.
      interrupt: async ({
        synthetic,
        setup,
      }: Awaited<ReturnType<typeof signedIn>>) => {
        synthetic.backend.unregisterFailure = 'offline';
        await setup.signOut();
        synthetic.backend.unregisterFailure = undefined;
      },
      title: 'Finish signing out',
      action: english('accountRemoval.signOut'),
      result: 'Your mail,\non your devices.',
    },
    {
      removalPending: 'deletion',
      // The backend deletes the account, but its reply is lost.
      interrupt: async ({
        synthetic,
        setup,
      }: Awaited<ReturnType<typeof signedIn>>) => {
        synthetic.backend.loseReply = true;
        await setup.deleteProductAccount();
        synthetic.backend.loseReply = false;
      },
      title: 'Confirm account deletion',
      action: english('accountRemoval.deletePermanently'),
      result: 'Product Account deleted',
    },
  ])(
    'resumes a pending $removalPending after relaunch without offering mailbox or sign-in work',
    async ({ removalPending, interrupt, title, action, result }) => {
      expect.hasAssertions();
      const account = await signedIn();
      await interrupt(account);
      const store = createRegistration(account.synthetic.relaunch());
      await render(
        <RegistrationGate
          store={started(store)}
          preview={false}>
          {null}
        </RegistrationGate>,
      );
      await expect(
        screen.findByRole('header', {
          name: title,
        }),
      ).resolves.toBeVisible();
      expect(store.getSnapshot().snapshot).toMatchObject({ removalPending });
      expect(screen.queryByRole('button', { name: 'Gmail' })).toBeNull();
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
    const synthetic = await createRegistrationScenario('registration-success');
    await render(
      <RegistrationGate
        store={started(createRegistration(synthetic.vault))}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await continueToSignIn();
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
    // The backend cannot be reached for the first deletion.
    synthetic.backend.offline = true;
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', permanently));
    });
    await expect(
      screen.findByRole('alert', { name: english('accountRemoval.deletion') }),
    ).resolves.toBeVisible();
    expect(screen.getByText('Signed in with Google.')).toBeVisible();
    synthetic.backend.offline = false;
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
