import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import {
  createMockRegistrationSession,
  syntheticMailboxes,
} from '@private-email/mail-core/testing/registration-session';
import {
  BackgroundTaskResult,
  BackgroundTaskStatus,
  getStatusAsync,
  registerTaskAsync,
} from 'expo-background-task';
import { defineTask } from 'expo-task-manager';
import { TurboModuleRegistry } from 'react-native';

import type { scheduleGmailFreshness as ScheduleGmailFreshness } from '../src/freshness.ts';
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
  /* oxlint-disable vitest/max-expects -- One journey checks headless startup and native scheduling failures end to end. */
  it('defines Gmail refresh on a headless entry, restores its saved mailbox and keeps foreground startup usable when scheduling or refresh fails', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession(
      'registration-success',
    ).native;
    await session.signIn('google');
    await session.addMailbox(false);
    const gmail = createSyntheticGmail();
    gmail.deliver({ subject: 'Arrived while terminated' });
    const id = syntheticMailboxes['alex@example.invalid'];
    const native = {
      getConstants: () => ({}),
      ...session,
      ...syntheticConnections({ [id]: gmail }),
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
      jest
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
    } finally {
      bridge.mockRestore();
      output.mockRestore();
    }
  });
});
