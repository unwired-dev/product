import { ok } from 'node:assert/strict';

import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type { AppStateStatus } from 'react-native';

import { createDrafts, draftOf } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import {
  createSyntheticDrafts,
  createSyntheticProductSync as createServer,
} from '@private-email/mail-core/testing/drafts';
import { syntheticConnections } from '@private-email/mail-core/testing/gmail-mailbox';
import { act, render, waitFor } from '@testing-library/react-native';
import { AppState, View } from 'react-native';

import { InboxProvider } from '../src/mailbox.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

const alex = { id: 'connection-alex', address: 'alex@example.invalid' };
const snapshot: RegistrationSnapshot = {
  kind: 'connected',
  productAccountId: 'account-a',
  signInProvider: 'google',
  mailboxes: JSON.stringify([{ ...alex, state: 'connected' }]),
};

describe('automatic Draft synchronization', () => {
  it.each(['active', 'background'] as const)(
    'logs a rejected automatic Draft pass on %s and permits later synchronization',
    async (state) => {
      expect.hasAssertions();
      jest.useFakeTimers();
      try {
        const registration = {
          getSnapshot: () => ({ snapshot, busy: false, failed: false }),
          subscribe: () => () => undefined,
        };
        const server = createServer();
        const device = async () => {
          const storage = createSyntheticDrafts(() => 'account-a', { server });
          ok(storage.sync, 'Expected a synchronization boundary');
          const drafts = createDrafts(storage.native, registration, {
            native: storage.sync,
            delay: 60_000,
          });
          await drafts.load();
          await drafts.sync();
          return drafts;
        };
        const phone = await device();
        const receiver = await device();
        const id = await phone.create(alex);
        ok(id, 'Expected a Draft');
        await phone.sync();
        await receiver.sync();
        const before = draftOf(phone.getSnapshot(), id);
        ok(before, 'Expected the authored Draft');
        const listenersBefore = jest.mocked(AppState.addEventListener).mock
          .calls.length;
        const view = await render(
          <InboxProvider
            drafts={receiver}
            mailboxes={createMailboxes(syntheticConnections({}), registration)}>
            <View />
          </InboxProvider>,
        );
        await receiver.sync();
        await phone.update(
          { ...before, subject: 'Edited on the phone' },
          before,
        );
        await phone.sync();
        let thrown = false;
        const unsubscribe = receiver.subscribe(() => {
          thrown = true;
          throw new Error('Private authored content');
        });
        const log = jest.spyOn(console, 'error').mockReturnValue(undefined);
        try {
          await act(async () => {
            for (const [, activate] of jest
              .mocked(AppState.addEventListener)
              .mock.calls.slice(listenersBefore)) {
              activate(state);
            }
          });
          await waitFor(() => {
            expect({
              thrown,
              logged: log.mock.calls.flat().join(' '),
            }).toMatchObject({
              thrown: true,
              logged: expect.stringContaining('Draft synchronization failed:'),
            });
          });
          expect(log.mock.calls.flat().join(' ')).not.toContain(
            'Private authored content',
          );
          unsubscribe();
          await receiver.sync();
          expect(draftOf(receiver.getSnapshot(), id)?.subject).toBe(
            'Edited on the phone',
          );
        } finally {
          unsubscribe();
          log.mockRestore();
          await view.unmount();
        }
      } finally {
        jest.clearAllTimers();
        jest.useRealTimers();
      }
    },
  );

  it('starts one automatic pass per app transition however many windows are open', async () => {
    expect.hasAssertions();
    jest.useFakeTimers();
    const registration = {
      getSnapshot: () => ({ snapshot, busy: false, failed: false }),
      subscribe: () => () => undefined,
    };
    const server = createServer();
    const storage = createSyntheticDrafts(() => 'account-a', { server });
    ok(storage.sync, 'Expected a synchronization boundary');
    const drafts = createDrafts(storage.native, registration, {
      native: storage.sync,
      delay: 60_000,
    });
    await drafts.load();
    await drafts.sync();
    const phoneStorage = createSyntheticDrafts(() => 'account-a', { server });
    ok(phoneStorage.sync, 'Expected a synchronization boundary');
    const phone = createDrafts(phoneStorage.native, registration, {
      native: phoneStorage.sync,
      delay: 60_000,
    });
    await phone.load();
    await phone.sync();
    const id = await phone.create(alex);
    ok(id, 'Expected a Draft');
    await phone.sync();
    const pulls = jest.spyOn(storage.sync, 'pullDrafts');
    const background = jest.spyOn(drafts, 'syncInBackground');
    // Substitute only the platform's dispatch/removal boundary; synchronization runs for real.
    const listeners = new Set<(state: AppStateStatus) => void>();
    const lifecycle = jest
      .spyOn(AppState, 'addEventListener')
      .mockImplementation((_event, listener) => {
        listeners.add(listener);
        return {
          remove: () => {
            listeners.delete(listener);
          },
        };
      });
    const mailboxes = createMailboxes(syntheticConnections({}), registration);
    const window = () => (
      <InboxProvider
        drafts={drafts}
        mailboxes={mailboxes}>
        <View />
      </InboxProvider>
    );
    const first = await render(window());
    const second = await render(window());
    try {
      await drafts.sync();
      const transition = async (
        state: 'active' | 'background',
        subject: string,
      ) => {
        const before = draftOf(phone.getSnapshot(), id);
        ok(before, 'Expected the phone Draft');
        await phone.update({ ...before, subject }, before);
        await phone.sync();
        pulls.mockClear();
        background.mockClear();
        await act(async () => {
          for (const listener of listeners) {
            listener(state);
          }
          // Drain the real host-facing action without requesting another pass.
          await Promise.all(background.mock.results.map(({ value }) => value));
        });
        await waitFor(() => {
          expect(draftOf(drafts.getSnapshot(), id)?.subject).toBe(subject);
        });
        // oxlint-disable-next-line vitest/prefer-called-once -- Jest has no toHaveBeenCalledOnce matcher.
        expect(pulls).toHaveBeenCalledTimes(1);
      };
      await transition('active', 'Two windows');
      await first.unmount();
      await transition('background', 'One window');
      await second.unmount();
      expect(listeners.size).toBe(0);
      const reopened = await render(window());
      try {
        await drafts.sync();
        await transition('active', 'Reopened');
      } finally {
        await reopened.unmount();
      }
      expect(listeners.size).toBe(0);
    } finally {
      await first.unmount();
      await second.unmount();
      pulls.mockRestore();
      background.mockRestore();
      lifecycle.mockRestore();
      jest.clearAllTimers();
      jest.useRealTimers();
    }
  });
});
