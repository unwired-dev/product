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

describe.each([
  {
    change: 'Profile replacement',
    account: 'original-account',
    profile: 'default',
    pendingRoute: () => 'newer route',
  },
  {
    change: 'Account replacement',
    account: 'replacement-account',
    profile: 'work',
    pendingRoute: () => 'newer route',
  },
  {
    change: 'same-Account context update',
    account: 'original-account',
    profile: 'work',
    pendingRoute: (destination: string) => `work:${destination}`,
  },
])(
  'command palette pending navigation after $change',
  ({ account: nextAccount, profile: nextProfile, pendingRoute }) => {
    it.each([
      { destination: 'inbox', labels: ['Go to Inbox'], expected: 'inbox' },
      {
        destination: 'settings',
        labels: ['Open Settings'],
        expected: 'settings',
      },
      {
        destination: 'mailbox',
        labels: ['Inbox', 'alex@example.invalid'],
        expected: syntheticMailboxes['alex@example.invalid'],
      },
    ] as const)(
      'keeps $destination navigation within its owning Account and Profile',
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
        // oxlint-disable-next-line promise/avoid-new -- Hold the public composer-exit boundary across an Account or Profile update.
        const pending = new Promise<boolean>((resolve) => {
          release = () => resolve(true);
        });
        let finishing = false;
        function PendingComposer({ owner }: { readonly owner: string }) {
          useCommandScope(owner);
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
          accountId,
          profile,
          navigate,
        }: {
          readonly accountId: string;
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
                productAccountId: accountId,
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
        function App({
          accountId,
          profile,
        }: {
          readonly accountId: string;
          readonly profile: string;
        }) {
          const [route, setRoute] = useState('newer route');
          return (
            <CommandPalette>
              <InboxProvider mailboxes={mailboxes}>
                <PendingComposer owner={`${accountId}/${profile}`} />
                <ProfileScope profile={profile}>
                  <Destinations
                    accountId={accountId}
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
          const app = await render(
            <App
              accountId="original-account"
              profile="work"
            />,
          );
          await choose();
          await waitFor(() => expect(finishing).toBe(true));
          await app.rerender(
            <App
              accountId={nextAccount}
              profile={nextProfile}
            />,
          );
          await act(async () => {
            release();
            await pending;
          });
          expect(screen.getByText(pendingRoute(expected))).toBeVisible();
          await choose();
          await waitFor(() => {
            expect(screen.getByText(`${nextProfile}:${expected}`)).toBeVisible();
          });
          expect(screen.queryByLabelText('Command Palette')).toBeNull();
        } finally {
          release();
          await screen.unmount();
          await registration.deviceRemoved();
        }
      },
    );
  },
);
