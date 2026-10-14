import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type { Platform } from 'react-native';

import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { mailboxesOf } from '@private-email/mail-core/registration';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-session';
import {
  act,
  fireEvent,
  render,
  screen,
  within,
} from '@testing-library/react-native';
import { useState } from 'react';
import { Dimensions } from 'react-native';

import { CommandPaletteProvider } from '../src/command-palette.tsx';
import { Composer } from '../src/composer.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
import { AccountContext } from '../src/registration-gate.tsx';

// Set the device boundary before the reader's platform-specific modules load.
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's platform adapter boundary.
jest.mock('react-native/Libraries/Utilities/Platform', () => {
  const { default: platform } = jest.requireActual<{
    default: typeof Platform;
  }>('react-native/Libraries/Utilities/Platform');
  return { __esModule: true, default: { ...platform, isPad: true } };
});

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- The palette clears the status bar itself; this host has no inset.
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, left: 0, right: 0, bottom: 0 }),
}));

const alex = syntheticMailboxes['alex@example.invalid'];
// A persistent reader notice must scroll with content, outside the fixed toolbar.
function isScrollable(
  element: ReturnType<typeof screen.getByText> | null,
): boolean {
  return (
    element !== null &&
    (element.props.onScroll !== undefined || isScrollable(element.parent))
  );
}

const ignore = () => undefined;

function Reader({
  inbox,
  drafts,
  message,
}: {
  readonly inbox: ReturnType<typeof createGmailInbox>;
  readonly drafts: ReturnType<typeof createDrafts>;
  readonly message: string;
}) {
  const [composing, setComposing] = useState<string>();
  return (
    <InboxProvider
      drafts={drafts}
      mailboxes={singleMailbox(inbox, alex)}>
      <CommandPaletteProvider>
        {composing === undefined ? (
          <MessageDetail
            mailbox={alex}
            id={message}
            onClose={ignore}
            onCompose={setComposing}
          />
        ) : (
          <Composer
            id={composing}
            onClose={ignore}
            onRebind={setComposing}
          />
        )}
      </CommandPaletteProvider>
    </InboxProvider>
  );
}

describe('iPad reader', () => {
  /* oxlint-disable vitest/max-expects -- One reader journey covers Labels, the saved-only notice and Reply All. */
  it.each([320, 1024])(
    'keeps direct response actions and the palette in the fixed header at %i points',
    async (width) => {
      expect.hasAssertions();
      const window = Dimensions.get('window');
      Dimensions.set({ window: { ...window, width, height: 768 } });
      const snapshot: RegistrationSnapshot = {
        kind: 'connected',
        productAccountId: 'synthetic-product-account',
        signInProvider: 'google',
        mailboxes: JSON.stringify([
          { id: alex, address: 'alex@example.invalid', state: 'connected' },
        ]),
      };
      const account = { snapshot, busy: false, failed: false };
      const registration = {
        getSnapshot: () => account,
        subscribe: () => ignore,
      };
      const storage = createSyntheticDrafts(() => 'synthetic-product-account');
      const drafts = createDrafts(storage.native, registration);
      const gmail = createSyntheticGmail({ messages: 0 });
      const message = gmail.deliver({
        from: 'Maya Chen <maya@example.invalid>',
        headers: {
          To: 'Alex <alex@example.invalid>, Bob <bob@example.invalid>',
        },
        subject: 'iPad plans',
        content: { text: 'Shall we meet on Friday?' },
      });
      const inbox = createGmailInbox(gmail.native);
      try {
        await render(
          <AccountContext
            value={{
              mailboxes: mailboxesOf(snapshot),
              openAccount: ignore,
              authorizeMailbox: () => Promise.resolve(),
              refreshInbox: (load) => load(),
            }}>
            <Reader
              inbox={inbox}
              drafts={drafts}
              message={message}
            />
          </AccountContext>,
        );
        await act(inbox.load);
        await screen.findByText('Shall we meet on Friday?');
        expect(
          screen.getByRole('header', { name: 'iPad plans' }),
        ).toBeVisible();
        // The subject text itself stays selectable inside the accessible header.
        expect(screen.getByText('iPad plans')).toHaveProp('selectable', true);
        expect(screen.queryByRole('button', { name: /^Back/u })).toBeNull();
        const commands = screen.getByRole('button', {
          name: 'Open Command Palette',
        });
        expect({ scrollable: isScrollable(commands) }).toStrictEqual({
          scrollable: false,
        });
        await fireEvent.press(commands);
        const palette = within(screen.getByTestId('command-palette'));
        expect(
          palette.getByRole('header', {
            name: 'Selected Message · iPad plans',
          }),
        ).toBeVisible();
        expect(
          palette.getByRole('button', { name: 'Reply All' }),
        ).toBeEnabled();
        expect(palette.getByRole('button', { name: 'Archive' })).toBeEnabled();
        await fireEvent.press(palette.getByRole('button', { name: 'Cancel' }));
        await fireEvent.press(screen.getByRole('button', { name: 'Labels' }));
        expect(
          screen.getByText('This Gmail mailbox has no labels of its own yet.'),
        ).toBeVisible();
        expect(screen.getByTestId('reader-panels')).toHaveStyle({
          position: 'absolute',
        });
        await fireEvent.press(
          screen.getByRole('button', { name: 'Hide labels' }),
        );
        const { openMailbox } = gmail.native;
        gmail.native.openMailbox = async () => ({
          ...(await openMailbox()),
          availability: 'retry',
        });
        await act(inbox.load);
        expect(
          isScrollable(
            screen.getByText(
              'Organizing mail waits until Gmail can be checked again. Try again to reconnect.',
            ),
          ),
        ).toBe(true);
        const create = jest
          .spyOn(drafts, 'create')
          .mockRejectedValueOnce(new TypeError('Synthetic host failure'));
        try {
          await fireEvent.press(
            screen.getByRole('button', { name: 'Reply All' }),
          );
          expect(
            isScrollable(
              await screen.findByText(
                'A reply or forward could not be started. Try again.',
              ),
            ),
          ).toBe(true);
          expect(screen.getByRole('alert')).toBeVisible();
        } finally {
          create.mockRestore();
        }
        await fireEvent.press(
          screen.getByRole('button', { name: 'Reply All' }),
        );
        await expect(screen.findByLabelText('Subject')).resolves.toHaveProp(
          'value',
          'Re: iPad plans',
        );
        expect(draftsOf(drafts.getSnapshot())[0]).toMatchObject({
          response: { kind: 'replyAll' },
          to: [
            { name: 'Maya Chen', address: 'maya@example.invalid' },
            { name: 'Bob', address: 'bob@example.invalid' },
          ],
        });
      } finally {
        await act(() => {
          Dimensions.set({ window });
        });
      }
    },
  );
  /* oxlint-enable vitest/max-expects */
});
