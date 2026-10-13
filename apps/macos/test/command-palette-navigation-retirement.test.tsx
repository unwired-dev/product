import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';
import { useEffect, useState } from 'react';
import { Text } from 'react-native';

import { CommandPalette, useCommandScope } from '../src/command-palette.tsx';
import { InboxCommands } from '../src/inbox-commands.tsx';
import {
  InboxProvider,
  ProfileScope,
  useComposerNavigation,
} from '../src/mailbox.tsx';
import { AccountContext } from '../src/registration-gate.tsx';

function Finishing({
  owner,
  finish,
}: {
  readonly owner: string;
  readonly finish: () => Promise<boolean>;
}) {
  useCommandScope(owner);
  const navigation = useComposerNavigation();
  useEffect(() => navigation.register(finish), [navigation, finish]);
  return null;
}

function App({
  account,
  profile,
  finish,
}: {
  readonly account: string;
  readonly profile: string;
  readonly finish: () => Promise<boolean>;
}) {
  const [route, setRoute] = useState('original route');
  return (
    <CommandPalette>
      <AccountContext
        value={{
          productAccountId: account,
          mailboxes: [],
          openAccount: () => setRoute(`${account}/${profile}/settings`),
          authorizeMailbox: () => Promise.resolve(),
          refreshInbox: (load) => load(),
        }}>
        <InboxProvider>
          <ProfileScope profile={profile}>
            <Finishing
              owner={`${account}/${profile}`}
              finish={finish}
            />
            <InboxCommands
              scope={undefined}
              hasSelection={false}
              selectionMailbox={undefined}
              selectionMessage={undefined}
              stars={false}
              mailboxes={[]}
              onInbox={() => setRoute(`${account}/${profile}/inbox`)}
              onScope={(scope) => setRoute(`${account}/${profile}/${scope}`)}
            />
          </ProfileScope>
          <Text>{route}</Text>
        </InboxProvider>
      </AccountContext>
    </CommandPalette>
  );
}

const chooseInbox = async () => {
  await fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
    nativeEvent: { key: 'open' },
  });
  await fireEvent.press(screen.getByRole('button', { name: 'Go to Inbox' }));
};

describe('composer exit ownership across command scopes', () => {
  it.each([
    { change: 'Profile', account: 'original', profile: 'personal' },
    { change: 'Account', account: 'replacement', profile: 'work' },
  ])(
    'navigates in a replacement $change before the old composer finishes',
    async ({ account, profile }) => {
      expect.hasAssertions();
      let release: () => void = () => undefined;
      // oxlint-disable-next-line promise/avoid-new -- Keep the retired composer exit pending while the replacement scope navigates.
      const pending = new Promise<boolean>((resolve) => {
        release = () => resolve(true);
      });
      const finish = jest.fn(() => pending);
      try {
        const app = await render(
          <App
            account="original"
            profile="work"
            finish={finish}
          />,
        );
        await chooseInbox();
        await waitFor(() => expect(finish).toHaveBeenCalledTimes(1));
        await app.rerender(
          <App
            account={account}
            profile={profile}
            finish={() => Promise.resolve(true)}
          />,
        );
        await chooseInbox();
        await waitFor(() => {
          expect(screen.getByText(`${account}/${profile}/inbox`)).toBeVisible();
        });
        expect(screen.queryByLabelText('Command Palette')).toBeNull();
        await act(async () => {
          release();
          await pending;
        });
        expect(screen.getByText(`${account}/${profile}/inbox`)).toBeVisible();
      } finally {
        release();
        await screen.unmount();
      }
    },
  );
});
