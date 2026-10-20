import { english } from '@private-email/localization';
import * as Schema from 'effect/Schema';

import type {
  NativeNotifications,
  OpenedNotification,
} from '../src/notifications.ts';

import {
  commandTarget,
  createCommandRegistry,
  responseCommands,
  runWhenOffered,
} from '../src/commands.ts';
import { createComposerNavigation } from '../src/composer-navigation.ts';
import {
  followOpenedNotifications,
  openedTarget,
} from '../src/notifications.ts';
import {
  defaultProfile,
  RegistrationSnapshotSchema,
  unavailableProfile,
} from '../src/registration.ts';

const connected = (
  mailboxes: ReadonlyArray<Record<string, string>>,
  account = 'account',
) =>
  Schema.decodeSync(RegistrationSnapshotSchema)({
    kind: 'connected',
    productAccountId: account,
    signInProvider: 'google',
    mailboxes: JSON.stringify(
      mailboxes.map((mailbox) => ({
        provider: 'gmail',
        address: 'alex@example.invalid',
        state: 'connected',
        ...mailbox,
      })),
    ),
  });

// The native event boundary retains taps until an active reader asks for them.
function tapQueue() {
  let pending:
    | { reader: string; resolve: (value: unknown) => void }
    | undefined = undefined;
  const queued: unknown[] = [];
  const send = (value: unknown) => {
    const waiting = pending;
    pending = undefined;
    if (waiting === undefined) {
      queued.push(value);
    } else {
      waiting.resolve(value);
    }
  };
  const restored = Promise.withResolvers<undefined>();
  const rearmed = Promise.withResolvers<undefined>();
  const reads = new Map<string, number>();
  const native: Pick<
    NativeNotifications,
    | 'nextOpenedNotification'
    | 'stopOpenedNotifications'
    | 'restoreOpenedNotification'
  > = {
    nextOpenedNotification: (_window, reader) => {
      const count = (reads.get(reader) ?? 0) + 1;
      reads.set(reader, count);
      if (count > 1) {
        rearmed.resolve(undefined);
      }
      if (queued.length > 0) {
        return Promise.resolve(queued.shift());
      }
      const next = Promise.withResolvers<unknown>();
      pending = { reader, resolve: next.resolve };
      return next.promise;
    },
    stopOpenedNotifications: (_window, reader) => {
      if (pending?.reader === reader) {
        const previous = pending;
        pending = undefined;
        previous.resolve(null);
      }
      return Promise.resolve(null);
    },
    restoreOpenedNotification: (tap) => {
      send(tap);
      restored.resolve(undefined);
      return Promise.resolve(null);
    },
  };
  return { native, send, restored, rearmed };
}

describe('opening a tapped New Mail Notification', () => {
  it('opens its message in the connection’s current Profile, and nothing once the connection or its owner is unknown', () => {
    expect.hasAssertions();
    const opened = {
      account: 'account',
      connection: 'work',
      epoch: 'legacy',
      message: '1a',
    };
    expect(
      openedTarget(connected([{ id: 'work', profile: 'p-work' }]), opened),
    ).toStrictEqual({ id: '1a', mailbox: 'work', profile: 'p-work' });
    expect(openedTarget(connected([{ id: 'work' }]), opened)).toStrictEqual({
      id: '1a',
      mailbox: 'work',
      profile: defaultProfile,
    });
    expect([
      openedTarget(connected([{ id: 'home' }]), opened),
      openedTarget(connected([{ id: 'work' }], 'other'), opened),
      openedTarget(connected([{ id: 'work', epoch: 'recreated' }]), opened),
      openedTarget(
        connected([{ id: 'work', profile: unavailableProfile }]),
        opened,
      ),
    ]).toStrictEqual([undefined, undefined, undefined, undefined]);
  });

  it('guards Draft exits, revalidates delayed targets and returns a tap from a retired reader', async () => {
    expect.hasAssertions();
    const opened: OpenedNotification = {
      account: 'account',
      connection: 'work',
      epoch: 'legacy',
      message: '1a',
    };
    let snapshot = connected([{ id: 'work' }]);
    const navigation = createComposerNavigation();
    const { native, send, restored, rearmed } = tapQueue();
    const decision = Promise.withResolvers<boolean>();
    const asked = Promise.withResolvers<undefined>();
    const unregister = navigation.register(() => {
      asked.resolve(undefined);
      return decision.promise;
    });
    const destinations: unknown[] = [];
    const stop = followOpenedNotifications(native, 'window', {
      snapshot: () => snapshot,
      leave: navigation.leave,
      open: (target) => {
        destinations.push(target);
      },
    });
    send(opened);
    await asked.promise;
    expect(destinations).toStrictEqual([]);
    // The owning shell disappears for authorization while its Draft question is open.
    stop();
    unregister();
    decision.resolve(false);
    await restored.promise;
    expect(destinations).toStrictEqual([]);

    // A remounted shell receives that tap, then the connection disappears during its exit guard.
    const nextDecision = Promise.withResolvers<boolean>();
    const nextAsked = Promise.withResolvers<undefined>();
    const finished = Promise.withResolvers<undefined>();
    const nextUnregister = navigation.register(() => {
      nextAsked.resolve(undefined);
      return nextDecision.promise;
    });
    const stopNext = followOpenedNotifications(native, 'window', {
      snapshot: () => snapshot,
      leave: async () => {
        const result = await navigation.leave();
        finished.resolve(undefined);
        return result;
      },
      open: (target) => {
        destinations.push(target);
      },
    });
    await nextAsked.promise;
    snapshot = connected([]);
    nextDecision.resolve(true);
    await finished.promise;
    await rearmed.promise;
    // Stop waits behind the already-settled guard; a removed target never opens.
    stopNext();
    nextUnregister();
    expect(destinations).toStrictEqual([]);

    snapshot = connected([{ id: 'work', profile: 'p-work' }]);
    const delivered = Promise.withResolvers<undefined>();
    const registry = createCommandRegistry();
    const replies: string[] = [];
    const stopLast = followOpenedNotifications(native, 'window', {
      snapshot: () => snapshot,
      leave: navigation.leave,
      open: (target, reply, current) => {
        destinations.push({ ...target, reply });
        runWhenOffered(registry, {
          id: 'reply',
          target: commandTarget(target.mailbox, { id: target.id, subject: '' })
            .id,
          current,
        });
        delivered.resolve(undefined);
      },
    });
    // The notification's Reply opens the message to reply to it.
    send({ ...opened, action: 'reply' });
    await delivered.promise;
    stopLast();
    // Reconnecting the same mailbox can reuse its IDs but changes the incarnation while Reply waits.
    snapshot = connected([
      { id: 'work', profile: 'p-work', epoch: 'recreated' },
    ]);
    registry.register(
      Symbol('replacement reader'),
      responseCommands(
        english,
        commandTarget('work', { id: '1a', subject: '' }),
        {
          starting: false,
          start: (kind) => {
            replies.push(kind);
            return Promise.resolve();
          },
        },
      ),
    );
    expect(replies).toStrictEqual([]);

    expect(destinations).toStrictEqual([
      { id: '1a', mailbox: 'work', profile: 'p-work', reply: true },
    ]);
  });
});
