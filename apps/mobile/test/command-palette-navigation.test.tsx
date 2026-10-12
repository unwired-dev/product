import type { NativeModules as NativeModulesType } from 'react-native';

import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { createRegistration } from '@private-email/mail-core/registration';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
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
import { useEffect, useState, useSyncExternalStore } from 'react';
import { Text } from 'react-native';

import { CommandPalette, useCommandScope } from '../src/command-palette.tsx';
import { InboxCommands } from '../src/inbox-commands.tsx';
import {
  InboxProvider,
  ProfileScope,
  useComposerNavigation,
} from '../src/mailbox.tsx';
import { AccountContext } from '../src/registration-gate.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name rather than a dynamic import.
jest.mock('react-native', () => {
  const native = jest.requireActual<{
    readonly NativeModules: typeof NativeModulesType;
  }>('react-native');
  native.NativeModules.UnwiredCommandPalette = {
    hintSeen: false,
    markHintSeen: jest.fn(),
  };
  return native;
});

describe('command palette pending navigation', () => {
  /* oxlint-disable vitest/max-expects -- Each journey checks palette opening, availability, recovery and retirement together. */
  it.each([
    { destination: 'inbox', labels: ['Go to Inbox'], expected: 'inbox' },
    { destination: 'settings', labels: ['Settings'], expected: 'settings' },
    {
      destination: 'mailbox',
      labels: ['Inbox', 'alex@example.invalid'],
      expected: syntheticMailboxes['alex@example.invalid'],
    },
  ] as const)(
    'does not navigate to a retired Profile after $destination waits for composer exit',
    async ({ labels, expected }) => {
      expect.hasAssertions();
      const session = createMockRegistrationSession('registration-success');
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
                id: syntheticMailboxes['alex@example.invalid'],
                address: 'alex@example.invalid',
                state: 'connected',
              },
              {
                id: syntheticMailboxes['other@example.invalid'],
                address: 'other@example.invalid',
                state: 'connected',
              },
            ]),
          }),
      });
      const mailboxes = createMailboxes(
        syntheticConnections({
          [syntheticMailboxes['alex@example.invalid']]: createSyntheticGmail(),
          [syntheticMailboxes['other@example.invalid']]: createSyntheticGmail({
            address: 'other@example.invalid',
          }),
        }),
        registration,
      );
      let release: () => void = () => undefined;
      // oxlint-disable-next-line promise/avoid-new -- Hold the public composer-exit boundary across a Profile replacement.
      const pending = new Promise<boolean>((resolve) => {
        release = () => resolve(true);
      });
      let finishing = false;
      function PendingComposer({ profile }: { readonly profile: string }) {
        useCommandScope(profile);
        const navigation = useComposerNavigation();
        useEffect(
          () =>
            navigation.register(() => {
              finishing = true;
              return pending;
            }),
          [navigation],
        );
        return null;
      }
      function Destinations({
        profile,
        navigate,
      }: {
        readonly profile: string;
        readonly navigate: (route: string) => void;
      }) {
        const connections = useSyncExternalStore(
          mailboxes.subscribe,
          mailboxes.getSnapshot,
        );
        return (
          <AccountContext
            value={{
              mailboxes: [],
              openAccount: () => navigate(`${profile}:settings`),
              authorizeMailbox: () => Promise.resolve(),
              refreshInbox: (load) => load(),
            }}>
            <InboxCommands
              scope={undefined}
              hasSelection={false}
              selectionMailbox={undefined}
              selectionMessage={undefined}
              stars={false}
              mailboxes={connections}
              onInbox={() => navigate(`${profile}:inbox`)}
              onScope={(scope) => navigate(`${profile}:${scope}`)}
            />
          </AccountContext>
        );
      }
      function App({ profile }: { readonly profile: string }) {
        const [route, setRoute] = useState('newer route');
        return (
          <CommandPalette>
            <InboxProvider mailboxes={mailboxes}>
              <PendingComposer profile={profile} />
              <ProfileScope profile={profile}>
                <Destinations
                  profile={profile}
                  navigate={setRoute}
                />
              </ProfileScope>
              <Text>{route}</Text>
            </InboxProvider>
          </CommandPalette>
        );
      }
      const open = () =>
        fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
          nativeEvent: { key: 'open' },
        });
      const choose = async () => {
        await open();
        for (const name of labels) {
          await fireEvent.press(screen.getByRole('button', { name }));
        }
      };
      try {
        await registration.restore();
        await mailboxes.load();
        expect(mailboxes.getSnapshot()).toHaveLength(2);
        const app = await render(<App profile="work" />);
        await choose();
        await waitFor(() => expect(finishing).toBe(true));
        await app.rerender(<App profile="default" />);
        await act(async () => {
          release();
          await pending;
        });
        expect(screen.getByText('newer route')).toBeVisible();
        await choose();
        await waitFor(() => {
          expect(screen.getByText(`default:${expected}`)).toBeVisible();
        });
        expect(screen.queryByLabelText('Command Palette')).toBeNull();
      } finally {
        release();
        await screen.unmount();
        await registration.deviceRemoved();
      }
    },
  );
  /* oxlint-enable vitest/max-expects */
});
