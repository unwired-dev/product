import { createRegistration } from '@private-email/mail-core/registration';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-vault';
import { createSyntheticVault } from '@private-email/mail-core/testing/registration-vault';
import { waitFor } from '@testing-library/react-native';
import {
  BackgroundTaskResult,
  BackgroundTaskStatus,
  getStatusAsync,
  registerTaskAsync,
} from 'expo-background-task';
import { defineTask } from 'expo-task-manager';
import { AppState, TurboModuleRegistry } from 'react-native';

import type {
  pollGmailWhileActive as PollGmailWhileActive,
  scheduleGmailFreshness as ScheduleGmailFreshness,
} from '../src/freshness.ts';
import type {
  gmailMailboxes as HostMailboxes,
  registration as HostRegistration,
} from '../src/registration.ts';

// Substitute the native scheduler and app registration: no React views mount on this launch.
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name.
jest.mock('expo-router/entry', () => ({}));
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name.
jest.mock('expo-task-manager', () => ({ defineTask: jest.fn() }));
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name.
jest.mock('expo-background-task', () => ({
  BackgroundTaskResult: { Success: 1, Failed: 2 },
  BackgroundTaskStatus: { Available: 2, Restricted: 1 },
  getStatusAsync: jest.fn(),
  registerTaskAsync: jest.fn(),
}));

describe('headless Gmail freshness', () => {
  /* oxlint-disable vitest/max-expects -- One journey checks headless refresh, scheduler failures and active/background/disposal transitions through the real stores. */
  it('restores mail and settles a push wake on a headless entry, handles scheduling failures and polls real mail only while active', async () => {
    expect.hasAssertions();
    const { vault } = createSyntheticVault();
    const flow = createRegistration(vault);
    await flow.register('google');
    await flow.addMailbox();
    const gmail = createSyntheticGmail();
    gmail.deliver({ subject: 'Arrived while terminated' });
    const id = syntheticMailboxes['alex@example.invalid'];
    // The host's APNs queue: the entry reads each wake and completes it with its outcome.
    const pushedWake = Promise.withResolvers<unknown>();
    const replaced = Promise.withResolvers<unknown>();
    const completeWake = jest.fn<undefined, [string, string]>();
    const native = {
      getConstants: () => ({}),
      ...vault,
      ...syntheticConnections({ [id]: gmail }),
      nextWake: jest
        .fn<Promise<unknown>, []>()
        .mockReturnValueOnce(pushedWake.promise)
        .mockReturnValueOnce(replaced.promise)
        .mockResolvedValue(null),
      mailboxRoutes: async () => ({
        routes: { 'route-alex': id },
        complete: true,
      }),
      completeWake,
    };
    const bridge = jest
      .spyOn(TurboModuleRegistry, 'getEnforcing')
      .mockReturnValue(native);
    const output = jest.spyOn(console, 'error').mockReturnValue(undefined);
    try {
      // The entry must define the task without requiring or rendering _layout.
      jest.requireActual('../index.js');
      const definition = jest
        .mocked(defineTask)
        .mock.calls.find(
          ([name]) => name === 'dev.unwired.mail.gmail-freshness',
        );
      expect(definition).toBeDefined();
      const execute = definition?.[1];
      await expect(
        execute?.({
          data: undefined,
          error: null,
          executionInfo: {
            taskName: 'dev.unwired.mail.gmail-freshness',
            eventId: 'synthetic-event',
          },
        }),
      ).resolves.toBe(BackgroundTaskResult.Success);

      const { gmailMailboxes } = jest.requireActual<{
        readonly gmailMailboxes: typeof HostMailboxes;
      }>('../src/registration.ts');
      const state = gmailMailboxes.getSnapshot()[0]?.state;
      expect(state).toMatchObject({
        kind: 'ready',
        messages: [
          expect.objectContaining({ subject: 'Arrived while terminated' }),
        ],
      });

      // A push wake that launched the app synchronizes its routed mailbox and completes once.
      const pushed = gmail.deliver({ subject: 'Pushed while suspended' });
      pushedWake.resolve({
        id: 'wake-1',
        hint: { provider: 'gmail', routeId: 'route-alex', historyId: '42' },
      });
      await waitFor(() => {
        expect(completeWake).toHaveBeenCalledWith('wake-1', 'synchronized');
      });
      expect(gmailMailboxes.getSnapshot()[0]?.state).toMatchObject({
        kind: 'ready',
        messages: expect.arrayContaining([
          expect.objectContaining({ id: pushed }),
        ]),
      });
      // The host replaced this reader; nothing more is followed.
      replaced.resolve(null);

      const { scheduleGmailFreshness } = jest.requireActual<{
        readonly scheduleGmailFreshness: typeof ScheduleGmailFreshness;
      }>('../src/freshness.ts');
      jest
        .mocked(getStatusAsync)
        .mockResolvedValue(BackgroundTaskStatus.Restricted);
      await scheduleGmailFreshness();
      expect(registerTaskAsync).not.toHaveBeenCalled();
      jest
        .mocked(getStatusAsync)
        .mockResolvedValue(BackgroundTaskStatus.Available);
      jest
        .mocked(registerTaskAsync)
        .mockRejectedValueOnce(new Error('private payload'));
      await expect(scheduleGmailFreshness()).resolves.toBeUndefined();
      expect(output.mock.calls).toStrictEqual([
        ['Gmail background task registration failed'],
      ]);
      await scheduleGmailFreshness();
      expect(registerTaskAsync).toHaveBeenLastCalledWith(
        'dev.unwired.mail.gmail-freshness',
        { minimumInterval: 15 },
      );

      // A failed opportunity reports failure without handing TaskManager the raw rejection.
      const { registration } = jest.requireActual<{
        readonly registration: typeof HostRegistration;
      }>('../src/registration.ts');
      const failedRefresh = jest
        .spyOn(registration, 'refreshInbox')
        .mockRejectedValueOnce(new Error('private payload'));
      await expect(
        execute?.({
          data: undefined,
          error: null,
          executionInfo: {
            taskName: 'dev.unwired.mail.gmail-freshness',
            eventId: 'synthetic-failure',
          },
        }),
      ).resolves.toBe(BackgroundTaskResult.Failed);
      expect(output.mock.calls).toStrictEqual([
        ['Gmail background task registration failed'],
        ['Gmail background refresh failed'],
      ]);
      failedRefresh.mockRestore();

      // No AppState transition is needed when the UI starts already active.
      jest.useFakeTimers();
      const initial = AppState.currentState;
      AppState.currentState = 'active';
      const listenersBefore = jest.mocked(AppState.addEventListener).mock.calls
        .length;
      const { pollGmailWhileActive } = jest.requireActual<{
        readonly pollGmailWhileActive: typeof PollGmailWhileActive;
      }>('../src/freshness.ts');
      const change = (state: 'active' | 'background') => {
        for (const [, listener] of jest
          .mocked(AppState.addEventListener)
          .mock.calls.slice(listenersBefore)) {
          listener(state);
        }
      };
      const stop = pollGmailWhileActive();
      try {
        const first = gmail.deliver({
          subject: 'Arrived while Inbox stayed open',
        });
        await jest.advanceTimersByTimeAsync(5 * 60_000 - 1);
        expect(gmailMailboxes.getSnapshot()[0]?.state).toMatchObject({
          kind: 'ready',
          messages: expect.not.arrayContaining([
            expect.objectContaining({ id: first }),
          ]),
        });
        await jest.advanceTimersByTimeAsync(1);
        expect(gmailMailboxes.getSnapshot()[0]?.state).toMatchObject({
          kind: 'ready',
          messages: expect.arrayContaining([
            expect.objectContaining({ id: first }),
          ]),
        });
        // Repeated active reports must not create another timer.
        change('active');
        const second = gmail.deliver({ subject: 'Next active poll' });
        await jest.advanceTimersByTimeAsync(5 * 60_000);
        expect(gmailMailboxes.getSnapshot()[0]?.state).toMatchObject({
          kind: 'ready',
          messages: expect.arrayContaining([
            expect.objectContaining({ id: second }),
          ]),
        });
        change('background');
        const background = gmail.deliver({
          subject: 'Wait for another opportunity',
        });
        await jest.advanceTimersByTimeAsync(30 * 60_000);
        expect(gmailMailboxes.getSnapshot()[0]?.state).toMatchObject({
          kind: 'ready',
          messages: expect.not.arrayContaining([
            expect.objectContaining({ id: background }),
          ]),
        });
        change('active');
        await jest.advanceTimersByTimeAsync(5 * 60_000);
        expect(gmailMailboxes.getSnapshot()[0]?.state).toMatchObject({
          kind: 'ready',
          messages: expect.arrayContaining([
            expect.objectContaining({ id: background }),
          ]),
        });
        stop();
        const disposed = gmail.deliver({
          subject: 'Stopped poll cannot restart',
        });
        change('active');
        await jest.advanceTimersByTimeAsync(5 * 60_000);
        expect(gmailMailboxes.getSnapshot()[0]?.state).toMatchObject({
          kind: 'ready',
          messages: expect.not.arrayContaining([
            expect.objectContaining({ id: disposed }),
          ]),
        });
      } finally {
        stop();
        AppState.currentState = initial;
        jest.useRealTimers();
      }
    } finally {
      bridge.mockRestore();
      output.mockRestore();
    }
  });
});
