import type { createHost } from '@private-email/mail-core/host';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type { defineTask as DefineTask } from 'expo-task-manager';
import type {
  AppState as AppStateModule,
  TurboModuleRegistry as TurboModules,
} from 'react-native';

/* oxlint-disable vitest/max-expects -- Each application journey verifies one delivery opportunity end to end. */
import { draftOf } from '@private-email/mail-core/drafts';
import { undoSendWindow } from '@private-email/mail-core/outbox';
import { createRegistration } from '@private-email/mail-core/registration';
import {
  createSyntheticDrafts,
  createSyntheticProductSync,
} from '@private-email/mail-core/testing/drafts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import {
  createSyntheticVault,
  syntheticMailboxes,
} from '@private-email/mail-core/testing/registration-vault';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name.
jest.mock('@private-email/mail-core/registration-mode', () => ({
  previewInbox: true,
}));
// The system scheduler: each journey runs the delivery task the entry defines.
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name.
jest.mock('expo-task-manager', () => ({ defineTask: jest.fn() }));
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name.
jest.mock('expo-background-task', () => ({
  BackgroundTaskResult: { Success: 1, Failed: 2 },
  BackgroundTaskStatus: { Available: 2, Restricted: 1 },
  getStatusAsync: jest.fn(async () => 2),
  registerTaskAsync: jest.fn(),
}));

// Each journey loads the mobile entry afresh.
jest.setTimeout(10_000);

type Lifecycle = 'active' | 'inactive' | 'background';

const present = <T,>(value: T | undefined): T => {
  if (value === undefined) {
    throw new Error('Expected a value');
  }
  return value;
};
const ownerOf = (snapshot: RegistrationSnapshot) =>
  'productAccountId' in snapshot ? snapshot.productAccountId : undefined;

// Loads the mobile entry's delivery wiring over synthetic storage, Gmail and background time, the
// way the native bridge grants it: one hold at a time, ended by release, denial or expiry.
const journey = async (
  initial: Lifecycle,
  run: (journey: {
    host: ReturnType<typeof createHost>;
    gmail: ReturnType<typeof createSyntheticGmail>;
    change: (state: Lifecycle) => void;
    send: () => Promise<string>;
    holds: jest.Mock;
    releases: jest.Mock;
    end: (released: unknown) => void;
    deliver: () => Promise<unknown>;
    lock: (locked: boolean) => void;
  }) => Promise<void>,
  grant?: (end: (released: unknown) => void) => void,
) => {
  jest.resetModules();
  // Each journey loads a fresh entry, so it shares the React Native module that entry receives.
  const { AppState, TurboModuleRegistry } = jest.requireActual<{
    AppState: typeof AppStateModule;
    TurboModuleRegistry: typeof TurboModules;
  }>('react-native');
  const { vault } = createSyntheticVault();
  const registered = createRegistration(vault);
  await registered.register('google');
  await registered.addMailbox();
  const { snapshot } = registered.getSnapshot();
  const storage = createSyntheticDrafts(() => ownerOf(snapshot), {
    server: createSyntheticProductSync(),
  });
  const gmail = createSyntheticGmail();
  const connection = syntheticMailboxes['alex@example.invalid'];
  const endings: Array<(released: unknown) => void> = [];
  const end = (released: unknown) => {
    for (const resolve of endings.splice(0)) {
      resolve(released);
    }
  };
  const holds = jest.fn(
    () =>
      // oxlint-disable-next-line promise/avoid-new -- Native background time ends only when released, denied or expired.
      new Promise<unknown>((resolve) => {
        endings.push(resolve);
        grant?.(end);
      }),
  );
  const releases = jest.fn(() => {
    end(true);
  });
  const background = { holdDelivery: holds, releaseDelivery: releases };
  const bridge = jest
    .spyOn(TurboModuleRegistry, 'getEnforcing')
    .mockReturnValue({
      getConstants: () => ({}),
      ...vault,
      ...storage.native,
      ...storage.sync,
      ...storage.delivery,
      ...syntheticConnections({ [connection]: gmail }),
      ...background,
    });
  const previous = AppState.currentState;
  AppState.currentState = initial;
  jest.useFakeTimers();
  try {
    const host = jest.requireActual<ReturnType<typeof createHost>>(
      '../src/registration.ts',
    );
    try {
      const firstListener = jest.mocked(AppState.addEventListener).mock.calls
        .length;
      jest.requireActual('../src/delivery.ts');
      const { defineTask } = jest.requireMock<{
        defineTask: typeof DefineTask;
      }>('expo-task-manager');
      const [, execute] = present(
        jest
          .mocked(defineTask)
          .mock.calls.find(([name]) => name === 'dev.unwired.mail.outbox'),
      );
      const deliver = async () =>
        execute({
          data: undefined,
          error: null,
          executionInfo: {
            taskName: 'dev.unwired.mail.outbox',
            eventId: 'synthetic-event',
          },
        });
      const change = (state: Lifecycle) => {
        AppState.currentState = state;
        for (const [, listener] of jest
          .mocked(AppState.addEventListener)
          .mock.calls.slice(firstListener)) {
          listener(state);
        }
      };
      await host.registration.restoreOnce();
      await host.drafts.load();
      const send = async () => {
        const id = present(
          await host.drafts.create({
            id: connection,
            address: 'alex@example.invalid',
          }),
        );
        const draft = present(draftOf(host.drafts.getSnapshot(), id));
        await host.drafts.update(
          { ...draft, to: [{ address: 'sam@example.invalid' }] },
          draft,
        );
        const current = present(draftOf(host.drafts.getSnapshot(), id));
        await expect(host.outbox.send(() => current)).resolves.toBeUndefined();
        return id;
      };
      await run({
        host,
        gmail,
        change,
        send,
        holds,
        releases,
        end,
        deliver,
        lock: storage.setLocked,
      });
    } finally {
      host.outbox.dispose();
    }
  } finally {
    AppState.currentState = previous;
    jest.useRealTimers();
    bridge.mockRestore();
  }
};

describe('application-owned Outbox execution', () => {
  it('pauses preview delivery through inactive and background opportunities, then sends on activation without a mounted Inbox', async () => {
    expect.hasAssertions();
    await journey(
      'background',
      async ({ host, gmail, change, send, holds }) => {
        const id = await send();
        await jest.advanceTimersByTimeAsync(undoSendWindow + 30_000);
        await host.outbox.process();
        // A headless launch never asks for background time to send.
        expect(holds).not.toHaveBeenCalled();
        expect(gmail.sends).toHaveLength(0);
        change('inactive');
        await host.outbox.process();
        expect(host.drafts.getOutbox()).toMatchObject([
          { id, state: 'waiting' },
        ]);
        change('active');
        await host.outbox.process();
        expect(gmail.sends).toHaveLength(1);
        change('background');
        change('active');
        await host.outbox.process();
        expect(gmail.sends).toHaveLength(1);
        expect(host.drafts.getOutbox()).toStrictEqual([]);
      },
    );
  });

  it('finishes a Send admitted before switching apps within background time, then releases it', async () => {
    expect.hasAssertions();
    await journey(
      'active',
      async ({ host, gmail, change, send, holds, releases }) => {
        await send();
        // oxlint-disable-next-line vitest/prefer-called-once -- Jest has no toHaveBeenCalledOnce matcher.
        expect(holds).toHaveBeenCalledTimes(1);
        change('inactive');
        change('background');
        await jest.advanceTimersByTimeAsync(undoSendWindow - 1000);
        expect(gmail.sends).toHaveLength(0);
        await jest.advanceTimersByTimeAsync(2000);
        expect(gmail.sends).toHaveLength(1);
        expect(host.drafts.getOutbox()).toStrictEqual([]);
        expect(releases).toHaveBeenCalledWith();
        // The released time pauses the backgrounded Outbox; activation sends nothing again.
        change('active');
        await host.outbox.process();
        expect(gmail.sends).toHaveLength(1);
        // oxlint-disable-next-line vitest/prefer-called-once -- Jest has no toHaveBeenCalledOnce matcher.
        expect(holds).toHaveBeenCalledTimes(1);
      },
    );
  });

  it('keeps a Send queued when background time expires before its deadline, then sends it once on activation', async () => {
    expect.hasAssertions();
    await journey(
      'active',
      async ({ host, gmail, change, send, holds, end }) => {
        const id = await send();
        change('background');
        await jest.advanceTimersByTimeAsync(undoSendWindow / 2);
        end(false);
        await jest.advanceTimersByTimeAsync(undoSendWindow);
        await host.outbox.process();
        expect(gmail.sends).toHaveLength(0);
        expect(host.drafts.getOutbox()).toMatchObject([
          { id, state: 'waiting' },
        ]);
        change('active');
        await host.outbox.process();
        expect(gmail.sends).toHaveLength(1);
        expect(holds).toHaveBeenCalledTimes(2);
        expect(host.drafts.getOutbox()).toStrictEqual([]);
      },
    );
  });

  it.each<[string, (end: (released: unknown) => void) => void]>([
    ['denied', (end) => end(false)],
    ['a malformed reply', (end) => end('false')],
    [
      'a failed request',
      () => {
        throw new Error('Background time is unavailable');
      },
    ],
  ])(
    'waits for the next activation when background time ends with %s, without asking again',
    async (_, ending) => {
      expect.hasAssertions();
      const grant = jest
        .fn<unknown, [(released: unknown) => void]>()
        .mockImplementationOnce(ending);
      await journey(
        'active',
        async ({ host, gmail, change, send, holds }) => {
          await send();
          await jest.advanceTimersByTimeAsync(0);
          // oxlint-disable-next-line vitest/prefer-called-once -- Jest has no toHaveBeenCalledOnce matcher.
          expect(holds).toHaveBeenCalledTimes(1);
          change('background');
          await jest.advanceTimersByTimeAsync(undoSendWindow + 1000);
          await host.outbox.process();
          expect(gmail.sends).toHaveLength(0);
          // oxlint-disable-next-line vitest/prefer-called-once -- Jest has no toHaveBeenCalledOnce matcher.
          expect(holds).toHaveBeenCalledTimes(1);
          change('active');
          await host.outbox.process();
          expect(gmail.sends).toHaveLength(1);
        },
        grant,
      );
    },
  );

  it('sends a queued message once in a system delivery task after a headless launch, then releases its time', async () => {
    expect.hasAssertions();
    await journey(
      'background',
      async ({
        host,
        gmail,
        change,
        send,
        holds,
        releases,
        end,
        deliver,
        lock,
      }) => {
        const { registerTaskAsync } = jest.requireMock<{
          registerTaskAsync: jest.Mock;
        }>('expo-background-task');
        expect(registerTaskAsync).toHaveBeenCalledWith(
          'dev.unwired.mail.outbox',
          { minimumInterval: 15 },
        );
        await send();
        await jest.advanceTimersByTimeAsync(undoSendWindow + 1000);
        expect(gmail.sends).toHaveLength(0);
        // A locked device keeps protected Draft storage, and so the Send, waiting.
        lock(true);
        const locked = deliver();
        await jest.advanceTimersByTimeAsync(0);
        end(false);
        await expect(locked).resolves.toBe(1);
        expect(gmail.sends).toHaveLength(0);
        lock(false);
        await expect(deliver()).resolves.toBe(1);
        expect(gmail.sends).toHaveLength(1);
        expect(host.drafts.getOutbox()).toStrictEqual([]);
        expect(releases).toHaveBeenCalledWith();
        // An opportunity with nothing queued asks for no time, and activation sends nothing again.
        await expect(deliver()).resolves.toBe(1);
        change('active');
        await host.outbox.process();
        expect(gmail.sends).toHaveLength(1);
        expect(holds).toHaveBeenCalledTimes(2);
      },
    );
  });

  it('keeps the original deadline when a delivery task expires, and retries an offline Send in a later one', async () => {
    expect.hasAssertions();
    await journey(
      'background',
      async ({ host, gmail, send, holds, end, deliver }) => {
        const id = await send();
        const expiring = deliver();
        await jest.advanceTimersByTimeAsync(undoSendWindow / 2);
        end(false);
        await expect(expiring).resolves.toBe(1);
        await jest.advanceTimersByTimeAsync(undoSendWindow);
        await host.outbox.process();
        expect(gmail.sends).toHaveLength(0);
        expect(host.drafts.getOutbox()).toMatchObject([
          { id, state: 'waiting' },
        ]);
        // No connection: nothing reached Gmail, so the Send stays queued until the time expires.
        gmail.failSend({ code: 'offline' });
        const offline = deliver();
        await jest.advanceTimersByTimeAsync(0);
        expect(host.drafts.getOutbox()).toMatchObject([
          { id, state: 'queued' },
        ]);
        end(false);
        await expect(offline).resolves.toBe(1);
        await jest.advanceTimersByTimeAsync(60_000);
        expect(gmail.sends).toHaveLength(0);
        await expect(deliver()).resolves.toBe(1);
        expect(gmail.sends).toHaveLength(1);
        expect(holds).toHaveBeenCalledTimes(3);
      },
    );
  });

  it('submits once when a delivery task overlaps another and activation', async () => {
    expect.hasAssertions();
    await journey(
      'background',
      async ({ host, gmail, change, send, holds, deliver }) => {
        await send();
        await jest.advanceTimersByTimeAsync(undoSendWindow + 1000);
        gmail.failSend({ code: 'offline' });
        const first = deliver();
        await jest.advanceTimersByTimeAsync(0);
        await expect(deliver()).resolves.toBe(1);
        change('active');
        await jest.advanceTimersByTimeAsync(0);
        await expect(deliver()).resolves.toBe(1);
        await host.outbox.process();
        await expect(first).resolves.toBe(1);
        expect(gmail.sends).toHaveLength(1);
        expect(host.drafts.getOutbox()).toStrictEqual([]);
        // oxlint-disable-next-line vitest/prefer-called-once -- Jest has no toHaveBeenCalledOnce matcher.
        expect(holds).toHaveBeenCalledTimes(1);
      },
    );
  });
});
