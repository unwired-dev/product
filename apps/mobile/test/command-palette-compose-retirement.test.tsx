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
import { useState } from 'react';

import { CommandPalette, useCommandScope } from '../src/command-palette.tsx';
import { Composer, DraftList } from '../src/composer.tsx';
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

// Capture queued native input at the same composite-fiber boundary used by fireEvent.
const queuedPress = () => {
  let fiber = screen.getByLabelText('New Message').unstable_fiber;
  while (fiber !== null) {
    const handler = fiber.memoizedProps?.onPress;
    if (typeof handler === 'function') {
      return () => {
        handler();
      };
    }
    fiber = fiber.return;
  }
  throw new Error('Expected a rendered New Message handler');
};

function Scope({ id }: { readonly id: string }) {
  useCommandScope(id);
  return null;
}

function Destination({ scope }: { readonly scope: string | undefined }) {
  const [composing, setComposing] = useState<string | undefined>();
  return (
    <>
      <DraftList
        scope={scope}
        onCompose={setComposing}
      />
      {composing === undefined ? null : (
        <Composer
          id={composing}
          onClose={() => {
            setComposing(undefined);
          }}
          onRebind={setComposing}
        />
      )}
    </>
  );
}

describe('New Message busy state after scope retirement', () => {
  /* oxlint-disable vitest/max-expects -- Each retirement journey covers overlapping creation, stale completion, replacement editing and retained Draft ownership. */
  it.each([
    { entry: 'button', replacement: 'Account' },
    { entry: 'palette', replacement: 'Account' },
    { entry: 'button', replacement: 'mailbox' },
    { entry: 'palette', replacement: 'mailbox' },
  ] as const)(
    'allows $entry creation in a replacement $replacement without stale completion releasing it',
    async ({ entry, replacement }) => {
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
      const original = Promise.withResolvers<void>();
      const replacementResult = Promise.withResolvers<void>();
      const create = drafts.create;
      // Hold completion after real persistence to control the two racing owners.
      const pending = jest
        .spyOn(drafts, 'create')
        .mockImplementationOnce(async (...args) => {
          const result = await create(...args);
          await original.promise;
          return result;
        })
        .mockImplementationOnce(async (...args) => {
          const result = await create(...args);
          await replacementResult.promise;
          return result;
        });
      const view = (productAccountId: string, scope?: string) => (
        <CommandPalette>
          <Scope id={JSON.stringify([productAccountId, scope])} />
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
              <Destination scope={scope} />
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
        const retiredPress = queuedPress();
        await begin[entry]();
        await waitFor(() => {
          expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
        });
        await app.rerender(
          view(
            replacement === 'Account' ? 'replacement' : 'original',
            replacement === 'mailbox'
              ? syntheticMailboxes['alex@example.invalid']
              : undefined,
          ),
        );
        await waitFor(() => {
          expect(
            screen.getByRole('button', { name: 'New Message' }),
          ).toBeEnabled();
        });
        // Scope retirement alone retains the already persisted Draft.
        expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
        const replacementPress = queuedPress();
        await begin[entry]();
        await waitFor(() => {
          expect(draftsOf(drafts.getSnapshot())).toHaveLength(2);
        });
        await act(async () => {
          retiredPress();
        });
        expect(pending).toHaveBeenCalledTimes(2);
        await act(async () => {
          original.resolve();
          await pending.mock.results[0]?.value;
        });
        // A later creation supersedes the first empty Draft through the real coordinator.
        await waitFor(() => {
          expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
        });
        expect(
          screen.queryByRole('button', {
            name: 'Close',
            includeHiddenElements: true,
          }),
        ).not.toBeOnTheScreen();
        expect(
          screen.getByRole('button', { name: 'New Message' }),
        ).toBeDisabled();
        // Bypass the palette's own busy guard with input queued by the replacement Inbox.
        await act(async () => {
          replacementPress();
        });
        expect(pending).toHaveBeenCalledTimes(2);
        await act(async () => {
          replacementResult.resolve();
          await pending.mock.results[1]?.value;
        });
        expect(await screen.findByLabelText('Subject')).toHaveProp('value', '');
        await fireEvent.changeText(
          screen.getByLabelText('Subject'),
          'Replacement Draft',
        );
        await act(async () => {
          await drafts.save();
        });
        expect(draftsOf(drafts.getSnapshot())).toMatchObject([
          { subject: 'Replacement Draft', from: 'alex@example.invalid' },
        ]);
        expect(
          screen.getByRole('button', { name: 'New Message' }),
        ).toBeEnabled();
      } finally {
        original.resolve();
        replacementResult.resolve();
        pending.mockRestore();
        await screen.unmount();
        await registration.deviceRemoved();
      }
    },
  );
  /* oxlint-enable vitest/max-expects */
});
