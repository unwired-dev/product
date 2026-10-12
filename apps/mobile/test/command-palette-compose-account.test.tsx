import type { NativeModules as NativeModulesType } from 'react-native';

import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import {
  createRegistration,
  mailboxesOf,
} from '@private-email/mail-core/registration';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import { syntheticConnections } from '@private-email/mail-core/testing/gmail-mailbox';
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

import { CommandPalette } from '../src/command-palette.tsx';
import { DraftList } from '../src/composer.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
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

it.each([
  { entry: 'button', nextAccount: 'replacement', expectedCalls: 0 },
  { entry: 'palette', nextAccount: 'replacement', expectedCalls: 0 },
  { entry: 'button', nextAccount: 'original', expectedCalls: 1 },
  { entry: 'palette', nextAccount: 'original', expectedCalls: 1 },
] as const)(
  'keeps pending $entry New Message within its Account after $nextAccount context arrives',
  async ({ entry, nextAccount, expectedCalls }) => {
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
          ]),
        }),
    });
    await registration.restoreOnce();
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await drafts.load();
    const mailboxes = createMailboxes(syntheticConnections({}), registration);
    const senders = mailboxesOf(registration.getSnapshot().snapshot);
    const opened = jest.fn();
    const view = (productAccountId: string) => (
      <CommandPalette>
        <AccountContext
          value={{
            productAccountId,
            mailboxes: senders,
            openAccount: () => undefined,
            authorizeMailbox: () => Promise.resolve(),
            refreshInbox: (load) => load(),
          }}>
          <InboxProvider
            drafts={drafts}
            mailboxes={mailboxes}>
            <DraftList
              scope={undefined}
              onCompose={opened}
            />
          </InboxProvider>
        </AccountContext>
      </CommandPalette>
    );
    const press = () =>
      fireEvent.press(screen.getByRole('button', { name: 'New Message' }));
    const begin = {
      button: press,
      palette: async () => {
        await fireEvent(
          screen.getByTestId('command-palette-host'),
          'commandKey',
          { nativeEvent: { key: 'open' } },
        );
        await press();
      },
    };
    try {
      const app = await render(view('original'));
      await waitFor(() => {
        expect(
          screen.getByRole('button', { name: 'New Message' }),
        ).toBeEnabled();
      });
      storage.hold();
      await begin[entry]();
      await waitFor(() => {
        expect(drafts.getSnapshot()).toMatchObject({
          kind: 'ready',
          save: 'saving',
        });
      });
      await app.rerender(view(nextAccount));
      await act(async () => {
        storage.release();
        await drafts.save();
      });
      expect(opened).toHaveBeenCalledTimes(expectedCalls);
      expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
    } finally {
      storage.release();
      await screen.unmount();
      await registration.deviceRemoved();
    }
  },
);
