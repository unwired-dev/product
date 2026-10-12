import { ok } from 'node:assert/strict';

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
import { createRef } from 'react';
import { TextInput } from 'react-native';

import { CommandPalette, Commands } from '../src/command-palette.tsx';
import { DraftList } from '../src/composer.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { AccountContext } from '../src/registration-gate.tsx';
import { SettingsCompose } from '../src/settings-commands.tsx';

describe('command palette execution', () => {
  /* oxlint-disable vitest/max-expects -- Each journey checks execution prerequisites, focus or held Draft persistence together. */
  it.each([
    { surface: 'inbox', failure: 'locked', reason: /Drafts are locked/u },
    { surface: 'settings', failure: 'locked', reason: /Drafts are locked/u },
    {
      surface: 'inbox',
      failure: 'unavailable',
      reason: /Drafts could not be opened/u,
    },
    {
      surface: 'settings',
      failure: 'unavailable',
      reason: /Drafts could not be opened/u,
    },
  ])(
    'explains New Message prerequisites and recovers in $surface after $failure storage',
    async ({ surface, failure, reason }) => {
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
      let release: () => void = () => undefined;
      // oxlint-disable-next-line promise/avoid-new -- Hold the native Draft read to observe loading before recovery.
      const pending = new Promise<void>((resolve) => {
        release = resolve;
      });
      let refused = true;
      const drafts = createDrafts(
        {
          ...storage.native,
          openDrafts: async () => {
            await pending;
            if (refused) {
              throw Object.assign(new Error('Draft storage unavailable'), {
                code: failure,
              });
            }
            return storage.native.openDrafts();
          },
        },
        registration,
      );
      const mailboxes = createMailboxes(syntheticConnections({}), registration);
      const senders = mailboxesOf(registration.getSnapshot().snapshot);
      const opened = jest.fn();
      const view = (hasSender: boolean) => (
        <CommandPalette>
          <AccountContext
            value={{
              mailboxes: hasSender ? senders : [],
              openAccount: () => undefined,
              authorizeMailbox: () => Promise.resolve(),
              refreshInbox: (load) => load(),
            }}>
            <InboxProvider
              drafts={drafts}
              mailboxes={mailboxes}>
              {surface === 'inbox' ? (
                <DraftList
                  scope={undefined}
                  onCompose={opened}
                />
              ) : (
                <SettingsCompose
                  account="synthetic-product-account"
                  mailboxes={hasSender ? senders : []}
                  profile="default"
                  drafts={drafts}
                  onCompose={opened}
                  onInbox={() => undefined}
                />
              )}
            </InboxProvider>
          </AccountContext>
        </CommandPalette>
      );
      try {
        const app = await render(view(true));
        await waitFor(() => expect(drafts.getSnapshot().kind).toBe('loading'));
        await fireEvent(
          screen.getByTestId('command-palette-host'),
          'commandKey',
          { nativeEvent: { key: 'open' } },
        );
        await fireEvent.changeText(
          screen.getByLabelText('Command Palette'),
          'compose',
        );
        const command = () =>
          screen.getByRole('button', { name: 'New Message' });
        expect(command()).toBeDisabled();
        expect(command()).toHaveTextContent(/Please wait/u);
        await act(async () => {
          release();
          await pending;
        });
        await waitFor(() => expect(command()).toHaveTextContent(reason));
        expect(command()).toBeDisabled();
        await fireEvent.press(command());
        expect(opened).not.toHaveBeenCalled();
        refused = false;
        await act(() => drafts.load());
        await waitFor(() => expect(command()).not.toBeDisabled());
        await app.rerender(view(false));
        expect(command()).toBeDisabled();
        expect(command()).toHaveTextContent(/No eligible sending mailbox/u);
        await app.rerender(view(true));
        expect(command()).not.toBeDisabled();
        expect(screen.getByLabelText('Command Palette')).toHaveProp(
          'value',
          'compose',
        );
        await fireEvent.press(command());
        await waitFor(() => expect(opened).toHaveBeenCalledTimes(1));
        expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
        expect(screen.queryByLabelText('Command Palette')).toBeNull();
      } finally {
        refused = false;
        release();
        await screen.unmount();
        await registration.deviceRemoved();
      }
    },
  );

  it('restores previous focus on cancellation and preserves command destination focus on success', async () => {
    expect.hasAssertions();
    const previousInput = createRef<TextInput>();
    const destinationInput = createRef<TextInput>();
    await render(
      <CommandPalette>
        <TextInput
          ref={previousInput}
          accessibilityLabel="Previous input"
        />
        <TextInput
          ref={destinationInput}
          accessibilityLabel="Destination input"
        />
        <Commands
          commands={[
            {
              id: 'destination',
              label: 'Focus destination',
              group: 'navigation',
              onRun: () => destinationInput.current?.focus(),
            },
          ]}
        />
      </CommandPalette>,
    );
    const previous = previousInput.current;
    const destination = destinationInput.current;
    ok(previous, 'Previous input did not mount');
    ok(destination, 'Destination input did not mount');
    // React Native's mock shares focus across inputs; track the receiver.
    const focus = jest.spyOn(previous, 'focus');
    const focused = jest
      .spyOn(TextInput.State, 'currentlyFocusedInput')
      .mockReturnValue(previous);
    const open = () =>
      fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
        nativeEvent: { key: 'open' },
      });
    try {
      await open();
      focus.mockClear();
      await fireEvent.press(
        screen.getByRole('button', { name: 'Cancel commands' }),
      );
      expect(focus.mock.contexts).toContain(previous);
      expect(screen.getByTestId('command-palette-host')).toHaveProp(
        'presentation',
        'dismissed',
      );
      await open();
      focus.mockClear();
      await fireEvent.press(
        screen.getByRole('button', { name: 'Focus destination' }),
      );
      expect(focus.mock.contexts).toContain(destination);
      expect(focus.mock.contexts).not.toContain(previous);
      expect(screen.queryByLabelText('Command Palette')).toBeNull();
      expect(screen.getByTestId('command-palette-host')).toHaveProp(
        'presentation',
        'completed',
      );
    } finally {
      focused.mockRestore();
      focus.mockRestore();
    }
  });

  it('keeps Settings New Message busy across ordinary dismissal until its real Draft commit settles', async () => {
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
    const commit = jest.fn(storage.native.commitDrafts);
    const drafts = createDrafts(
      { ...storage.native, commitDrafts: commit },
      registration,
    );
    await drafts.load();
    const opened = jest.fn();
    storage.hold();
    try {
      await render(
        <CommandPalette>
          <SettingsCompose
            account="synthetic-product-account"
            mailboxes={mailboxesOf(registration.getSnapshot().snapshot)}
            profile="default"
            drafts={drafts}
            onCompose={opened}
            onInbox={() => undefined}
          />
        </CommandPalette>,
      );
      const open = () =>
        fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
          nativeEvent: { key: 'open' },
        });
      const command = () => screen.getByRole('button', { name: 'New Message' });
      await open();
      await fireEvent.press(command());
      await waitFor(() => expect(commit).toHaveBeenCalledTimes(1));
      await fireEvent.press(
        screen.getByRole('button', { name: 'Cancel commands' }),
      );
      await open();
      expect(command()).toBeDisabled();
      expect(command()).toHaveTextContent(/Please wait/u);
      await fireEvent.press(command());
      await fireEvent(
        screen.getByTestId('command-palette-host'),
        'commandKey',
        {
          nativeEvent: { key: 'enter' },
        },
      );
      expect(commit).toHaveBeenCalledTimes(1);
      expect(opened).not.toHaveBeenCalled();
      await act(async () => {
        storage.release();
      });
      await waitFor(() => expect(opened).toHaveBeenCalledTimes(1));
      expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
      expect(screen.getByLabelText('Command Palette')).toBeVisible();
      expect(command()).toBeEnabled();
      await fireEvent.press(command());
      await waitFor(() => expect(opened).toHaveBeenCalledTimes(2));
      expect(draftsOf(drafts.getSnapshot())).toHaveLength(2);
      expect(screen.queryByLabelText('Command Palette')).toBeNull();
    } finally {
      storage.release();
      await screen.unmount();
      await registration.deviceRemoved();
    }
  });
  /* oxlint-enable vitest/max-expects */
});
