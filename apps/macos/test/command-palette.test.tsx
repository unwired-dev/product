import type { PaletteCommand } from '@private-email/mail-core/command-palette';

import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { createRegistration } from '@private-email/mail-core/registration';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import { syntheticConnections } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import {
  createMockRegistrationSession,
  syntheticMailboxes,
} from '@private-email/mail-core/testing/registration-session';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';
import { createRef, use, useState } from 'react';
import { Platform, Pressable, Text, TextInput } from 'react-native';

import { CommandPalette, Commands } from '../src/command-palette.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
import { AccountContext, RegistrationGate } from '../src/registration-gate.tsx';

function Harness({
  commands,
}: {
  readonly commands: readonly PaletteCommand[];
}) {
  return (
    <CommandPalette>
      <Commands commands={commands} />
      <Text>Current draft</Text>
    </CommandPalette>
  );
}

function SettingsEntry() {
  const account = use(AccountContext);
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel="Account"
      onPress={account?.openAccount}>
      <Text>Inbox content</Text>
    </Pressable>
  );
}

function MailboxCommands() {
  const account = use(AccountContext);
  return (
    <Commands
      commands={[
        {
          id: 'mailbox',
          label: 'Mailboxes',
          group: 'navigation',
          choices: (account?.mailboxes ?? []).map((mailbox) => ({
            id: mailbox.id,
            label: mailbox.address ?? mailbox.id,
            group: 'navigation' as const,
            onRun: () => false,
          })),
        },
      ]}
    />
  );
}

describe('command palette interactions', () => {
  it('keeps the Mac launcher inside supported Inbox and Settings screens', async () => {
    const device = jest.replaceProperty(Platform, 'OS', 'macos');
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    const connected = {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      privateSync: 'ready',
      mailboxes: JSON.stringify([
        {
          id: syntheticMailboxes['alex@example.invalid'],
          address: 'alex@example.invalid',
          state: 'connected',
        },
      ]),
    } as const;
    let restore = (): Promise<unknown> =>
      Promise.resolve({ kind: 'signed-out' });
    const registration = createRegistration({
      ...session.native,
      restore: () => restore(),
    });
    try {
      await render(
        <CommandPalette>
          <RegistrationGate
            store={registration}
            preview={false}>
            <SettingsEntry />
          </RegistrationGate>
        </CommandPalette>,
      );
      await act(async () => {
        await registration.restoreOnce();
      });
      const open = () =>
        fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
          nativeEvent: { key: 'open' },
        });
      const unavailable = async () => {
        expect(screen.getByTestId('command-palette-host')).toHaveProp(
          'enabled',
          false,
        );
        expect(
          screen.queryByRole('button', { name: 'Open Command Palette' }),
        ).toBeNull();
        await open();
        expect(screen.queryByLabelText('Command Palette')).toBeNull();
      };
      await unavailable();
      restore = () =>
        Promise.resolve({
          kind: 'mailbox-needed',
          productAccountId: connected.productAccountId,
          signInProvider: 'google',
        });
      await act(async () => {
        await registration.resume();
      });
      expect(
        screen.getByRole('header', { name: 'Connect your mail' }),
      ).toBeVisible();
      await unavailable();
      restore = () =>
        Promise.reject(Object.assign(new Error('Locked'), { code: 'locked' }));
      await act(async () => {
        await registration.resume();
      });
      expect(
        screen.getByRole('header', { name: 'Unlock your device' }),
      ).toBeVisible();
      await unavailable();
      restore = () => Promise.resolve(connected);
      await act(async () => {
        await registration.resume();
      });
      expect(screen.getByRole('button', { name: 'Account' })).toBeVisible();
      expect(screen.getByTestId('command-palette-host')).toHaveProp(
        'enabled',
        true,
      );
      expect(
        screen.getByRole('button', { name: 'Open Command Palette' }),
      ).toBeVisible();
      await open();
      expect(screen.getByRole('button', { name: 'Reply All' })).toBeDisabled();
      expect(
        screen.getByRole('button', { name: 'Reply All' }),
      ).toHaveTextContent('Select a message');
      await fireEvent.press(
        screen.getByRole('button', { name: 'Cancel commands' }),
      );
      await fireEvent.press(screen.getByRole('button', { name: 'Account' }));
      await open();
      expect(screen.getByRole('button', { name: 'Go to Inbox' })).toBeEnabled();
      expect(screen.getByRole('button', { name: 'Reply All' })).toBeDisabled();
    } finally {
      await screen.unmount();
      restore = () => Promise.resolve({ kind: 'signed-out' });
      await registration.deviceRemoved();
      device.restore();
    }
  });

  it('returns from an IMAP folder to Inbox while opening and cancelling preserve the folder', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.deliver('INBOX', { subject: 'Incoming IMAP message' });
    imap.addFolder('Archive');
    imap.deliver('Archive', { subject: 'Archived IMAP message' });
    const session = createMockRegistrationSession('registration-success');
    const connection = 'imap-connection';
    const registration = createRegistration({
      ...session.native,
      restore: () =>
        Promise.resolve({
          kind: 'connected',
          productAccountId: 'synthetic-product-account',
          signInProvider: 'google',
          privateSync: 'ready',
          mailboxes: JSON.stringify([
            {
              id: connection,
              address: 'alex@example.invalid',
              state: 'connected',
              provider: 'imap',
              imap: {
                host: 'imap.example.invalid',
                port: 993,
                username: 'alex',
              },
            },
          ]),
        }),
    });
    const connections = createMailboxes(
      syntheticConnections({}, { [connection]: imap.native }),
      registration,
    );
    const mailboxes = {
      ...connections,
      getSnapshot: connections.getConnections,
    };
    function SelectedInbox() {
      const [selection, setSelection] =
        useState<Parameters<typeof Inbox>[0]['selected']>();
      return (
        <>
          <Inbox
            onSelect={setSelection}
            selected={selection}
          />
          <MessageDetail
            id={selection?.id}
            mailbox={selection?.mailbox}
            onClose={() => {
              setSelection(undefined);
            }}
          />
        </>
      );
    }
    try {
      await render(
        <CommandPalette>
          <RegistrationGate
            store={registration}
            preview={false}>
            <InboxProvider mailboxes={mailboxes}>
              <SelectedInbox />
            </InboxProvider>
          </RegistrationGate>
        </CommandPalette>,
      );
      await screen.findByText('Incoming IMAP message');
      await fireEvent.press(screen.getByRole('button', { name: 'Archive' }));
      await screen.findByText('Archived IMAP message');
      const open = () =>
        fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
          nativeEvent: { key: 'open' },
        });
      await open();
      await fireEvent.press(
        screen.getByRole('button', { name: 'Cancel commands' }),
      );
      expect(screen.getByText('Archived IMAP message')).toBeVisible();
      await open();
      await fireEvent.press(
        screen.getByRole('button', { name: 'Go to Inbox' }),
      );
      await expect(
        screen.findByText('Incoming IMAP message'),
      ).resolves.toBeVisible();
      expect(screen.queryByText('Archived IMAP message')).toBeNull();
      expect(screen.queryByLabelText('Command Palette')).toBeNull();
      await fireEvent.press(screen.getByText('Incoming IMAP message'));
      await open();
      for (const name of ['Reply', 'Reply All', 'Forward']) {
        const command = screen.getByRole('button', { name });
        expect(command).toBeDisabled();
        expect(command).toHaveTextContent('Unavailable for this mailbox');
      }
      expect(
        screen.getByRole('button', { name: 'Mark as unread' }),
      ).toHaveTextContent('This message is already unread.');
      await fireEvent.press(
        screen.getByRole('button', { name: 'Mark as read' }),
      );
      await open();
      await waitFor(() => {
        expect(
          screen.getByRole('button', { name: 'Mark as unread' }),
        ).toBeEnabled();
      });
      expect(
        screen.getByRole('button', { name: 'Mark as read' }),
      ).toHaveTextContent('This message is already read.');
      expect(screen.getByRole('button', { name: 'Archive' })).toBeDisabled();
      await fireEvent.press(screen.getByRole('button', { name: 'Move…' }));
      await fireEvent.press(screen.getByRole('button', { name: 'Archive' }));
      expect(screen.queryByLabelText('Command Palette')).toBeNull();
      await fireEvent.press(screen.getByRole('button', { name: 'Archive' }));
      await expect(
        screen.findByText('Incoming IMAP message'),
      ).resolves.toBeVisible();
    } finally {
      await screen.unmount();
      await registration.deviceRemoved();
    }
  });

  it('retires a captured mailbox picker when its Product Account locks or is removed', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    const connected = {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      privateSync: 'ready',
      mailboxes: JSON.stringify([
        {
          id: syntheticMailboxes['alex@example.invalid'],
          address: 'alex@example.invalid',
          state: 'connected',
        },
      ]),
    } as const;
    let restore = (): Promise<unknown> => Promise.resolve(connected);
    const registration = createRegistration({
      ...session.native,
      restore: () => restore(),
    });
    await registration.restoreOnce();
    try {
      await render(
        <CommandPalette>
          <RegistrationGate
            store={registration}
            preview={false}>
            <MailboxCommands />
          </RegistrationGate>
        </CommandPalette>,
      );
      await fireEvent(
        screen.getByTestId('command-palette-host'),
        'commandKey',
        {
          nativeEvent: { key: 'open' },
        },
      );
      await fireEvent.press(screen.getByRole('button', { name: 'Mailboxes' }));
      expect(
        screen.getByRole('button', { name: 'alex@example.invalid' }),
      ).toBeVisible();
      restore = () =>
        Promise.reject(Object.assign(new Error('Locked'), { code: 'locked' }));
      await act(async () => {
        await registration.resume();
      });
      expect([
        screen.queryByLabelText('Command Palette'),
        screen.queryByRole('button', { name: 'alex@example.invalid' }),
      ]).toStrictEqual([null, null]);
      expect(screen.getByTestId('command-palette-host')).toHaveProp(
        'enabled',
        false,
      );
      restore = () => Promise.resolve(connected);
      await act(async () => {
        await registration.resume();
      });
      await fireEvent(
        screen.getByTestId('command-palette-host'),
        'commandKey',
        {
          nativeEvent: { key: 'open' },
        },
      );
      await fireEvent.press(screen.getByRole('button', { name: 'Mailboxes' }));
      restore = () => Promise.resolve({ kind: 'signed-out' });
      await act(async () => {
        await registration.deviceRemoved();
      });
      expect([
        screen.queryByLabelText('Command Palette'),
        screen.queryByRole('button', { name: 'alex@example.invalid' }),
      ]).toStrictEqual([null, null]);
    } finally {
      restore = () => Promise.resolve({ kind: 'signed-out' });
      await registration.deviceRemoved();
    }
  });

  it.each([
    ['success', false],
    ['failure', false],
    ['success', true],
    ['failure', true],
  ] as const)(
    'retires a pending command when its Account locks, outcome=%s, reopened=%s',
    async (outcome, reopened) => {
      expect.hasAssertions();
      const session = createMockRegistrationSession('registration-success');
      const connected = {
        kind: 'connected',
        productAccountId: 'synthetic-product-account',
        signInProvider: 'google',
        privateSync: 'ready',
        mailboxes: JSON.stringify([
          {
            id: syntheticMailboxes['alex@example.invalid'],
            address: 'alex@example.invalid',
            state: 'connected',
          },
        ]),
      } as const;
      let restore = (): Promise<unknown> => Promise.resolve(connected);
      const registration = createRegistration({
        ...session.native,
        restore: () => restore(),
      });
      let complete: (value: undefined) => void = () => undefined;
      let fail: (reason: unknown) => void = () => undefined;
      // oxlint-disable-next-line promise/avoid-new -- Settle the old command after its account scope retires.
      const completion = new Promise<undefined>((resolve, reject) => {
        complete = resolve;
        fail = reject;
      });
      const input = createRef<TextInput>();
      await registration.restoreOnce();
      try {
        await render(
          <CommandPalette>
            <TextInput
              ref={input}
              accessibilityLabel="Previous input"
            />
            <RegistrationGate
              store={registration}
              preview={false}>
              <Commands
                commands={[
                  {
                    id: 'compose',
                    label: 'Held command',
                    group: 'app',
                    onRun: () => completion,
                  },
                ]}
              />
            </RegistrationGate>
          </CommandPalette>,
        );
        const previous = input.current;
        if (previous === null) {
          throw new Error('Previous input did not mount');
        }
        const focus = jest.spyOn(previous, 'focus');
        const focused = jest
          .spyOn(TextInput.State, 'currentlyFocusedInput')
          .mockReturnValue(previous);
        try {
          const open = () =>
            fireEvent(
              screen.getByTestId('command-palette-host'),
              'commandKey',
              { nativeEvent: { key: 'open' } },
            );
          await open();
          await fireEvent.press(
            screen.getByRole('button', { name: 'Held command' }),
          );
          restore = () =>
            Promise.reject(
              Object.assign(new Error('Locked'), { code: 'locked' }),
            );
          await act(async () => {
            await registration.resume();
          });
          expect(screen.queryByLabelText('Command Palette')).toBeNull();
          expect(screen.getByTestId('command-palette-host')).toHaveProp(
            'presentation',
            'retired',
          );
          await fireEvent(
            screen.getByTestId('command-palette-host'),
            'commandKey',
            {
              nativeEvent: { key: 'escape' },
            },
          );
          expect(focus).not.toHaveBeenCalled();
          expect(screen.getByTestId('command-palette-host')).toHaveProp(
            'presentation',
            'retired',
          );
          if (reopened) {
            restore = () => Promise.resolve(connected);
            await act(async () => {
              await registration.resume();
            });
            await open();
          }
          await act(async () => {
            if (outcome === 'failure') {
              fail(new Error('Old command failed'));
            } else {
              complete(undefined);
            }
            await completion.catch(() => undefined);
          });
          expect(focus).not.toHaveBeenCalled();
          if (!reopened) {
            restore = () => Promise.resolve(connected);
            await act(async () => {
              await registration.resume();
            });
            await open();
          }
          expect(screen.getByLabelText('Command Palette')).toHaveProp(
            'value',
            '',
          );
          expect(
            screen.getByRole('button', { name: 'Held command' }),
          ).toBeEnabled();
          expect(
            screen.queryByText('The command could not finish. Try again.'),
          ).toBeNull();
        } finally {
          focused.mockRestore();
          focus.mockRestore();
        }
      } finally {
        complete(undefined);
        await screen.unmount();
        restore = () => Promise.resolve({ kind: 'signed-out' });
        await registration.deviceRemoved();
      }
    },
  );

  it('advances every queued arrow event and backs out of the current picker before React commits', async () => {
    expect.hasAssertions();
    const executed: string[] = [];
    await render(
      <Harness
        commands={[
          {
            id: 'move',
            label: 'Move',
            group: 'selection',
            choices: ['Action A', 'Action B', 'Action C'].map((label) => ({
              id: label,
              label,
              group: 'selection' as const,
              onRun: () => {
                executed.push(label);
              },
            })),
          },
        ]}
      />,
    );
    await fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
      nativeEvent: { key: 'open' },
    });
    await fireEvent.changeText(
      screen.getByLabelText('Command Palette'),
      'Move',
    );
    const host = screen.getByTestId('command-palette-host');
    await fireEvent.press(screen.getByRole('button', { name: 'Move' }));
    await act(async () => {
      host.props.onCommandKey({ nativeEvent: { key: 'down' } });
      host.props.onCommandKey({ nativeEvent: { key: 'down' } });
      host.props.onCommandKey({ nativeEvent: { key: 'enter' } });
    });
    expect(executed).toStrictEqual(['Action C']);
    await fireEvent(host, 'commandKey', { nativeEvent: { key: 'open' } });
    await fireEvent.changeText(
      screen.getByLabelText('Command Palette'),
      'Move',
    );
    await fireEvent.press(screen.getByRole('button', { name: 'Move' }));
    await act(async () => {
      host.props.onCommandKey({ nativeEvent: { key: 'escape' } });
      host.props.onCommandKey({ nativeEvent: { key: 'escape' } });
    });
    expect(screen.queryByLabelText('Command Palette')).toBeNull();
  });

  it('executes the current query when native typing and Enter arrive before React commits', async () => {
    expect.hasAssertions();
    const executed: string[] = [];
    await render(
      <Harness
        commands={['Archive', 'Compose'].map((label) => ({
          id: label.toLowerCase(),
          label,
          group: 'selection' as const,
          onRun: () => {
            executed.push(label);
          },
        }))}
      />,
    );
    await fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
      nativeEvent: { key: 'open' },
    });
    const field = screen.getByLabelText('Command Palette');
    const host = screen.getByTestId('command-palette-host');
    await act(async () => {
      field.props.onChangeText('Compose');
      host.props.onCommandKey({ nativeEvent: { key: 'enter' } });
    });
    expect(executed).toStrictEqual(['Compose']);
  });

  it('keeps unavailable commands visible in Settings and creates a real Draft through Compose', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    const connected = {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      privateSync: 'ready',
      mailboxes: JSON.stringify([
        {
          id: syntheticMailboxes['alex@example.invalid'],
          address: 'alex@example.invalid',
          state: 'connected',
        },
      ]),
    } as const;
    const registration = createRegistration({
      ...session.native,
      restore: async () => connected,
    });
    await registration.restoreOnce();
    const native = createSyntheticDrafts(() => connected.productAccountId);
    const drafts = createDrafts(native.native, registration);
    let opened: string | undefined = undefined;
    try {
      await drafts.load();
      const app = await render(
        <CommandPalette>
          <RegistrationGate
            store={registration}
            drafts={drafts}
            preview={false}
            onCompose={(id) => {
              opened = id;
            }}>
            <SettingsEntry />
          </RegistrationGate>
        </CommandPalette>,
      );
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Account' }),
      );
      await fireEvent(
        screen.getByTestId('command-palette-host'),
        'commandKey',
        { nativeEvent: { key: 'open' } },
      );
      for (const name of [
        'Star',
        'Remove star',
        'Move to Trash',
        'Report spam',
      ]) {
        const command = screen.getByRole('button', { name });
        expect(command).toBeDisabled();
        expect(command).toHaveTextContent('Select a message');
      }
      await fireEvent.changeText(
        screen.getByLabelText('Command Palette'),
        'answer',
      );
      expect(screen.getByRole('button', { name: 'Reply' })).toBeDisabled();
      expect(screen.getByRole('button', { name: 'Reply All' })).toBeDisabled();
      await fireEvent.changeText(
        screen.getByLabelText('Command Palette'),
        'compose',
      );
      await fireEvent.press(
        screen.getByRole('button', { name: 'New Message' }),
      );
      expect(opened).toBeDefined();
      const state = drafts.getSnapshot();
      expect(draftsOf(state).map(({ id }) => id)).toStrictEqual([opened]);
      expect(screen.getByText('Inbox content')).toBeVisible();
      expect(screen.queryByLabelText('Command Palette')).toBeNull();
      await app.unmount();
    } finally {
      await registration.deviceRemoved();
    }
  });

  it('opens by a native shortcut, picks a destination, returns with Escape and resets after dismissal', async () => {
    expect.hasAssertions();
    let moved = false;
    const commands: readonly PaletteCommand[] = [
      {
        id: 'move',
        label: 'Move…',
        keywords: 'folder',
        group: 'selection',
        target: 'mail/1',
        choices: [
          {
            id: 'travel',
            label: 'Travel',
            group: 'selection',
            onRun: () => {
              moved = true;
            },
          },
        ],
      },
    ];
    await render(<Harness commands={commands} />);
    await fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
      nativeEvent: { key: 'open' },
    });
    await fireEvent.changeText(
      screen.getByLabelText('Command Palette'),
      'fldr',
    );
    await fireEvent.press(screen.getByRole('button', { name: 'Move…' }));
    expect(Number(moved)).toBe(0);
    expect(screen.getByRole('button', { name: 'Travel' })).toBeVisible();
    await fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
      nativeEvent: { key: 'escape' },
    });
    await fireEvent.press(screen.getByRole('button', { name: 'Move…' }));
    await fireEvent.press(screen.getByRole('button', { name: 'Travel' }));
    expect(moved).toBe(true);
    expect(screen.getByTestId('command-palette-host')).toHaveProp(
      'presentation',
      'dismissed',
    );
    await fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
      nativeEvent: { key: 'open' },
    });
    expect(screen.getByLabelText('Command Palette')).toHaveProp('value', '');
    await fireEvent.press(
      screen.getByRole('button', { name: 'Cancel commands' }),
    );
    expect(screen.getByText('Current draft')).toBeVisible();
    expect(screen.getByTestId('command-palette-host')).toHaveProp(
      'presentation',
      'dismissed',
    );
  });

  it('keeps an open palette from applying an action to a changed selection and prevents double execution', async () => {
    expect.hasAssertions();
    let executions = 0;
    let finish: (() => void) | undefined = undefined;
    // oxlint-disable-next-line promise/avoid-new -- Keep the action pending while duplicate input arrives.
    const completion = new Promise<undefined>((resolve) => {
      finish = () => resolve(undefined);
    });
    const command = {
      id: 'archive',
      label: 'Archive',
      group: 'selection' as const,
      target: 'mail/1',
      onRun: () => {
        executions += 1;
        return completion;
      },
    };
    const app = await render(<Harness commands={[command]} />);
    await fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
      nativeEvent: { key: 'open' },
    });
    await app.rerender(
      <Harness commands={[{ ...command, target: 'mail/2' }]} />,
    );
    expect(screen.getByRole('button', { name: 'Archive' })).toBeDisabled();
    await fireEvent.press(screen.getByRole('button', { name: 'Archive' }));
    expect(executions).toBe(0);
    await fireEvent.press(
      screen.getByRole('button', { name: 'Cancel commands' }),
    );
    await fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
      nativeEvent: { key: 'open' },
    });
    await fireEvent.press(screen.getByRole('button', { name: 'Archive' }));
    await fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
      nativeEvent: { key: 'enter' },
    });
    expect(executions).toBe(1);
    await act(async () => {
      finish?.();
    });
    expect(screen.queryByLabelText('Command Palette')).toBeNull();
  });

  it('does not dismiss a new palette when a previously dismissed action finishes', async () => {
    expect.hasAssertions();
    let finish: (() => void) | undefined = undefined;
    // oxlint-disable-next-line promise/avoid-new -- Completion must occur after the palette is reopened.
    const completion = new Promise<undefined>((resolve) => {
      finish = () => resolve(undefined);
    });
    await render(
      <Harness
        commands={[
          {
            id: 'compose',
            label: 'Compose',
            group: 'app',
            onRun: () => completion,
          },
        ]}
      />,
    );
    const host = screen.getByTestId('command-palette-host');
    await fireEvent(host, 'commandKey', { nativeEvent: { key: 'open' } });
    await fireEvent.press(screen.getByRole('button', { name: 'Compose' }));
    await fireEvent.press(
      screen.getByRole('button', { name: 'Cancel commands' }),
    );
    await fireEvent(host, 'commandKey', { nativeEvent: { key: 'open' } });
    await act(async () => {
      finish?.();
    });
    expect(screen.getByLabelText('Command Palette')).toHaveProp('value', '');
    expect(screen.getByRole('button', { name: 'Compose' })).toBeEnabled();
  });
});
