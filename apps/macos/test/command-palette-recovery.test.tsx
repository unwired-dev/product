import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { createRegistration } from '@private-email/mail-core/registration';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';
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

import { CommandPalette } from '../src/command-palette.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
import { RegistrationGate } from '../src/registration-gate.tsx';

describe('command palette mailbox recovery', () => {
  it.each(['gmail', 'microsoft-graph'] as const)(
    'shows selected %s storage prerequisites and recovers its palette actions',
    async (provider) => {
      expect.hasAssertions();
      const fixture =
        provider === 'gmail'
          ? createSyntheticGmail({
              address: 'alex@example.invalid',
              messages: 1,
            })
          : createSyntheticGraph({
              address: 'alex@example.invalid',
              messages: 1,
            });
      let openMailbox = fixture.native.openMailbox;
      const session = createMockRegistrationSession('registration-success');
      const connection = syntheticMailboxes['alex@example.invalid'];
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
                provider,
              },
            ]),
          }),
      });
      const connections = createMailboxes(
        syntheticConnections({
          [connection]: {
            native: { ...fixture.native, openMailbox: () => openMailbox() },
          },
        }),
        registration,
      );
      const mailboxes = {
        ...connections,
        getSnapshot: connections.getConnections,
      };
      const nativeDrafts = createSyntheticDrafts(
        () => 'synthetic-product-account',
      );
      const drafts = createDrafts(nativeDrafts.native, registration);
      let opened: string | undefined;
      function SelectedReader() {
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
              onCompose={(id) => {
                opened = id;
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
              <InboxProvider
                mailboxes={mailboxes}
                drafts={drafts}>
                <SelectedReader />
              </InboxProvider>
            </RegistrationGate>
          </CommandPalette>,
        );
        await fireEvent.press(await screen.findByText('Synthetic message 0'));
        const inbox = connections.getSnapshot()[0]?.inbox;
        if (inbox === undefined) {
          throw new Error('Expected the selected mailbox');
        }
        await act(() => inbox.forget());
        const open = () =>
          fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
            nativeEvent: { key: 'open' },
          });
        await open();
        for (const name of ['Archive', 'Reply', 'Reply All', 'Forward']) {
          const command = screen.getByRole('button', { name });
          expect(command).toBeDisabled();
          expect(command).toHaveTextContent('Loading message');
        }
        for (const [code, reason] of [
          [
            'locked',
            'Private storage is locked. Unlock your device and try again.',
          ],
          [
            'unavailable',
            'Private storage could not be opened or saved. Your stored data has been kept.',
          ],
        ] as const) {
          openMailbox = () =>
            Promise.reject(
              Object.assign(new Error('Storage unavailable'), { code }),
            );
          await act(inbox.load);
          for (const name of ['Archive', 'Reply', 'Reply All', 'Forward']) {
            const command = screen.getByRole('button', { name });
            expect(command).toBeDisabled();
            expect(command).toHaveTextContent(reason);
          }
        }
        openMailbox = fixture.native.openMailbox;
        await act(inbox.load);
        await waitFor(() => {
          for (const name of ['Reply', 'Reply All', 'Forward']) {
            expect(screen.getByRole('button', { name })).toBeEnabled();
          }
        });
        await act(() => inbox.forget());
        for (const name of ['Reply', 'Reply All', 'Forward']) {
          const command = screen.getByRole('button', { name });
          expect(command).toBeDisabled();
          expect(command).toHaveTextContent('Loading message');
        }
        await act(inbox.load);
        await waitFor(() => {
          for (const name of ['Reply', 'Reply All', 'Forward']) {
            expect(screen.getByRole('button', { name })).toBeEnabled();
          }
        });
        await fireEvent.press(screen.getByRole('button', { name: 'Reply' }));
        expect(opened).toBeDefined();
        expect(
          draftsOf(drafts.getSnapshot()).map(({ id }) => id),
        ).toStrictEqual([opened]);
        expect(screen.queryByLabelText('Command Palette')).toBeNull();
        await open();
        expect(screen.getByRole('button', { name: 'Archive' })).toBeEnabled();
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
          expect(
            screen.getByRole('button', { name: 'Mark as read' }),
          ).toHaveTextContent('This message is already read.');
        });
        if (provider === 'gmail') {
          expect(
            screen.getByRole('button', { name: 'Remove star' }),
          ).toHaveTextContent('This message has no star.');
          await fireEvent.press(screen.getByRole('button', { name: 'Star' }));
          await open();
          await waitFor(() => {
            expect(
              screen.getByRole('button', { name: 'Remove star' }),
            ).toBeEnabled();
            expect(
              screen.getByRole('button', { name: 'Star' }),
            ).toHaveTextContent('This message already has a star.');
          });
        }
        await fireEvent.press(
          screen.getByRole('button', { name: 'Cancel commands' }),
        );
        await act(() => inbox.forget());
        openMailbox = async () => ({
          ...(await fixture.native.openMailbox()),
          availability: 'retry' as const,
        });
        await act(inbox.load);
        expect(inbox.getSnapshot()).toMatchObject({
          kind: 'ready',
          organize: false,
          sync: 'retry',
        });
        await open();
        for (const name of [
          'Archive',
          'Move…',
          'Mark as read',
          'Mark as unread',
          'Move to Trash',
          'Report spam',
        ]) {
          const command = screen.getByRole('button', { name });
          expect(command).toBeDisabled();
          expect(command).toHaveTextContent('Try again to reconnect.');
          expect(command).not.toHaveTextContent('Unavailable for this mailbox');
        }
      } finally {
        await screen.unmount();
        await registration.deviceRemoved();
      }
    },
  );
});
