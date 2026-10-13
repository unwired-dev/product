import { ok } from 'node:assert/strict';

import type { NativeModules as NativeModulesType } from 'react-native';

import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import {
  createRegistration,
  mailboxesOf,
} from '@private-email/mail-core/registration';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
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
import { useState } from 'react';
import { Text } from 'react-native';

import {
  CommandPalette,
  UnavailableCommands,
} from '../src/command-palette.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
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

function ReaderDestination({
  mailbox,
  message,
}: {
  readonly mailbox: string;
  readonly message: string;
}) {
  const [draft, setDraft] = useState<string | undefined>();
  return draft === undefined ? (
    <MessageDetail
      id={message}
      mailbox={mailbox}
      onCompose={setDraft}
    />
  ) : (
    <Text accessibilityRole="header">Composer for {draft}</Text>
  );
}

describe.each(['Reply', 'Reply All', 'Forward'])(
  'pending %s Account ownership',
  (label) => {
    it.each([
      { entry: 'button', nextAccount: 'replacement', expectedDestinations: 0 },
      { entry: 'palette', nextAccount: 'replacement', expectedDestinations: 0 },
      { entry: 'button', nextAccount: 'original', expectedDestinations: 1 },
      { entry: 'palette', nextAccount: 'original', expectedDestinations: 1 },
    ] as const)(
      'keeps a pending $entry response within its Account after $nextAccount context arrives',
      async ({ entry, nextAccount, expectedDestinations }) => {
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
        const storage = createSyntheticDrafts(
          () => 'synthetic-product-account',
        );
        const drafts = createDrafts(storage.native, registration);
        await drafts.load();
        const connection = syntheticMailboxes['alex@example.invalid'];
        const gmail = createSyntheticGmail({ messages: 0 });
        const message = gmail.deliver({
          content: { text: 'Keep this response with its original Account.' },
        });
        const mailboxes = createMailboxes(
          syntheticConnections({ [connection]: { native: gmail.native } }),
          registration,
        );
        await mailboxes.load();
        const [mailbox] = mailboxes.getSnapshot();
        ok(mailbox, 'Expected a ready mailbox for the response');
        const senders = mailboxesOf(registration.getSnapshot().snapshot);
        const view = (productAccountId: string) => (
          <CommandPalette>
            <UnavailableCommands />
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
                <ReaderDestination
                  message={message}
                  mailbox={mailbox.id}
                />
              </InboxProvider>
            </AccountContext>
          </CommandPalette>
        );
        const press = () =>
          fireEvent.press(screen.getByRole('button', { name: label }));
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
            expect(screen.getByRole('button', { name: label })).toBeEnabled();
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
          await waitFor(() => {
            expect(
              screen.queryAllByRole('header', { name: /^Composer for /u }),
            ).toHaveLength(expectedDestinations);
            expect(draftsOf(drafts.getSnapshot())).toHaveLength(
              expectedDestinations,
            );
          });
        } finally {
          storage.release();
          await screen.unmount();
          await registration.deviceRemoved();
        }
      },
    );
  },
);
