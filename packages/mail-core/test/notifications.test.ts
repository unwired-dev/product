import type { Registration } from '@private-email/mail-core/registration';

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
  createNotifications,
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

const unused = () => Promise.reject(new Error('Not used here'));

describe('notification settings', () => {
  const read = (badgeSoundOff: readonly string[]) => ({
    authorization: 'authorized',
    previews: true,
    badge: 'inbox',
    sound: 'default',
    badgeSoundOff,
  });

  it('saves a choice while the system permission prompt waits', async () => {
    expect.hasAssertions();
    const prompt = Promise.withResolvers<unknown>();
    const notifications = createNotifications(
      {
        notificationSettings: () => Promise.resolve(read([])),
        postNotifications: unused,
        requestNotifications: () => prompt.promise,
        setNotificationPreviews: unused,
        setNotificationBadge: () => Promise.resolve(read(['saved'])),
        setNotificationSound: unused,
        setNotificationProfile: unused,
        setBadgeCount: unused,
        openNotificationSettings: unused,
      },
      () => english,
    );
    const asked = notifications.request();
    await notifications.setBadge('inbox');
    const saved = notifications.getSnapshot()?.badgeSoundOff;
    prompt.resolve(read([]));
    await asked;
    expect(saved).toStrictEqual(['saved']);
  });

  it('reads the settings only once a pending choice is saved', async () => {
    expect.hasAssertions();
    // The device's saved choices; a read reports them as they were when it started.
    let off: readonly string[] = [];
    const saved = Promise.withResolvers<null>();
    const notifications = createNotifications(
      {
        notificationSettings: () => {
          const seen = off;
          return saved.promise.then(() => read(seen));
        },
        postNotifications: unused,
        requestNotifications: unused,
        setNotificationPreviews: unused,
        setNotificationBadge: unused,
        setNotificationSound: unused,
        setNotificationProfile: async () => {
          await saved.promise;
          off = ['default'];
          return read(off);
        },
        setBadgeCount: unused,
        openNotificationSettings: unused,
      },
      () => english,
    );
    const choice = notifications.setProfileBadgeSound(
      'account',
      'default',
      false,
    );
    const refresh = notifications.load();
    saved.resolve(null);
    await Promise.all([choice, refresh]);
    expect(notifications.getSnapshot()?.badgeSoundOff).toStrictEqual([
      'default',
    ]);
  });
});

describe('the App Icon Badge across Product Accounts', () => {
  const settings = {
    authorization: 'authorized',
    previews: true,
    badge: 'inbox',
    sound: 'default',
    badgeSoundOff: [],
  };
  const signedOut = Schema.decodeSync(RegistrationSnapshotSchema)({
    kind: 'signed-out',
  });

  it.each(['before', 'after'])(
    'clears the signed-out count when the old write settles %s the next settings',
    async (order) => {
      expect.hasAssertions();
      let snapshot = connected([], 'a');
      let connections: ReadonlyArray<{
        profile: string;
        state: { kind: string; messages?: Array<{ unread: boolean }> };
      }> = [
        {
          profile: defaultProfile,
          state: {
            kind: 'ready',
            messages: [{ unread: true }, { unread: true }],
          },
        },
      ];
      const listeners = new Set<() => void>();
      const changed = () => {
        for (const listener of listeners) {
          listener();
        }
      };
      const nextRead = Promise.withResolvers<unknown>();
      const oldWrite = Promise.withResolvers<unknown>();
      const badges: number[] = [];
      const reads = vi
        .fn<() => Promise<unknown>>()
        .mockResolvedValueOnce(settings)
        .mockResolvedValueOnce(settings)
        .mockReturnValueOnce(nextRead.promise);
      const notifications = createNotifications(
        {
          notificationSettings: reads,
          postNotifications: unused,
          requestNotifications: unused,
          setNotificationPreviews: unused,
          setNotificationBadge: unused,
          setNotificationSound: unused,
          setNotificationProfile: unused,
          setBadgeCount: vi
            .fn<(count: number) => Promise<unknown>>()
            .mockImplementationOnce((count) => {
              badges.push(count);
              return oldWrite.promise;
            })
            .mockImplementation((count) => {
              badges.push(count);
              return Promise.resolve(null);
            }),
          openNotificationSettings: unused,
        },
        () => english,
      );
      notifications.followBadge({
        registration: {
          getSnapshot: () => ({ snapshot, busy: false, failed: false }),
          subscribe: (listener) => {
            listeners.add(listener);
            return () => listeners.delete(listener);
          },
        },
        mailboxes: {
          getConnections: () => connections,
          subscribe: () => () => undefined,
        },
      });
      await vi.waitFor(() => {
        expect(badges).toStrictEqual([2]);
      });
      // Account A signs out while its write of 2 runs.
      snapshot = signedOut;
      connections = [];
      changed();
      await vi.waitFor(() => {
        expect(reads).toHaveBeenCalledTimes(2);
      });
      // Account B signs in; its Inbox is still loading.
      snapshot = connected([], 'b');
      connections = [{ profile: defaultProfile, state: { kind: 'loading' } }];
      changed();
      await vi.waitFor(() => {
        expect(reads).toHaveBeenCalledTimes(3);
      });
      const settle = {
        before: () => {
          oldWrite.resolve(null);
          nextRead.resolve(settings);
        },
        after: () => {
          nextRead.resolve(settings);
          oldWrite.resolve(null);
        },
      }[order];
      settle?.();
      await vi.waitFor(() => {
        expect(badges.at(-1)).toBe(0);
      });
    },
  );

  it('tries the refused sign-out clear again once the next settings are read', async () => {
    expect.hasAssertions();
    let snapshot = connected([], 'a');
    let connections: ReadonlyArray<{
      profile: string;
      state: { kind: string; messages?: Array<{ unread: boolean }> };
    }> = [
      {
        profile: defaultProfile,
        state: { kind: 'ready', messages: [{ unread: true }] },
      },
    ];
    const listeners = new Set<() => void>();
    const changed = () => {
      for (const listener of listeners) {
        listener();
      }
    };
    const nextRead = Promise.withResolvers<unknown>();
    const applied: number[] = [];
    const reads = vi
      .fn<() => Promise<unknown>>()
      .mockResolvedValueOnce(settings)
      .mockResolvedValueOnce(settings)
      .mockReturnValueOnce(nextRead.promise);
    const accept = async (count: number) => {
      applied.push(count);
      return null;
    };
    const refuse = () => Promise.reject(new Error('refused'));
    let respond: (count: number) => Promise<unknown> = accept;
    const notifications = createNotifications(
      {
        notificationSettings: reads,
        postNotifications: unused,
        requestNotifications: unused,
        setNotificationPreviews: unused,
        setNotificationBadge: unused,
        setNotificationSound: unused,
        setNotificationProfile: unused,
        setBadgeCount: (count) => respond(count),
        openNotificationSettings: unused,
      },
      () => english,
    );
    notifications.followBadge({
      registration: {
        getSnapshot: () => ({ snapshot, busy: false, failed: false }),
        subscribe: (listener) => {
          listeners.add(listener);
          return () => listeners.delete(listener);
        },
      },
      mailboxes: {
        getConnections: () => connections,
        subscribe: () => () => undefined,
      },
    });
    await vi.waitFor(() => {
      expect(applied).toStrictEqual([1]);
    });
    // The system refuses the clear at sign-out and again when account B signs in.
    respond = refuse;
    snapshot = signedOut;
    connections = [];
    changed();
    snapshot = connected([], 'b');
    connections = [{ profile: defaultProfile, state: { kind: 'loading' } }];
    changed();
    await vi.waitFor(() => {
      expect(reads).toHaveBeenCalledTimes(3);
    });
    respond = accept;
    nextRead.resolve(settings);
    await vi.waitFor(() => {
      expect(applied).toStrictEqual([1, 0]);
    });
  });
});

describe('the Badge and sound choices after a launch that signed out', () => {
  it('shows none read at launch once another Product Account signs in', async () => {
    expect.hasAssertions();
    const signedOut = Schema.decodeSync(RegistrationSnapshotSchema)({
      kind: 'signed-out',
    });
    let state: ReturnType<Registration['getSnapshot']> = {
      snapshot: signedOut,
      busy: false,
      failed: false,
      restoring: true,
    };
    const listeners = new Set<() => void>();
    const changed = () => {
      for (const listener of listeners) {
        listener();
      }
    };
    const settings = (badgeSoundOff: readonly string[]) => ({
      authorization: 'authorized',
      previews: true,
      badge: 'inbox',
      sound: 'default',
      badgeSoundOff,
    });
    const nextRead = Promise.withResolvers<unknown>();
    const reads = vi
      .fn<() => Promise<unknown>>()
      .mockResolvedValueOnce(settings([defaultProfile]))
      .mockReturnValueOnce(nextRead.promise);
    const notifications = createNotifications(
      {
        notificationSettings: reads,
        postNotifications: unused,
        requestNotifications: unused,
        setNotificationPreviews: unused,
        setNotificationBadge: unused,
        setNotificationSound: unused,
        setNotificationProfile: unused,
        setBadgeCount: () => Promise.resolve(null),
        openNotificationSettings: unused,
      },
      () => english,
    );
    notifications.followBadge({
      registration: {
        getSnapshot: () => state,
        subscribe: (listener) => {
          listeners.add(listener);
          return () => listeners.delete(listener);
        },
      },
      mailboxes: {
        getConnections: () => [],
        subscribe: () => () => undefined,
      },
    });
    await vi.waitFor(() => {
      expect(notifications.getSnapshot()?.badgeSoundOff).toStrictEqual([
        defaultProfile,
      ]);
    });
    // The restore finds the stored Product Account revoked and purges it; another signs in.
    state = { snapshot: signedOut, busy: false, failed: false };
    changed();
    state = { snapshot: connected([], 'b'), busy: false, failed: false };
    changed();
    expect(notifications.getSnapshot()).toBeUndefined();
    nextRead.resolve(settings([]));
    await vi.waitFor(() => {
      expect(notifications.getSnapshot()?.badgeSoundOff).toStrictEqual([]);
    });
  });
});

describe('a queued App Icon Badge count', () => {
  it('applies no queued zero once the Inbox can no longer be counted', async () => {
    expect.hasAssertions();
    type Connection = {
      profile: string;
      state: { kind: string; messages?: Array<{ unread: boolean }> };
    };
    const ready = (unread: number): Connection => ({
      profile: defaultProfile,
      state: {
        kind: 'ready',
        messages: Array.from({ length: unread }, () => ({ unread: true })),
      },
    });
    let connections: readonly Connection[] = [ready(2)];
    const listeners = new Set<() => void>();
    const changed = () => {
      for (const listener of listeners) {
        listener();
      }
    };
    const heldWrite = Promise.withResolvers<unknown>();
    const badges: number[] = [];
    const notifications = createNotifications(
      {
        notificationSettings: () =>
          Promise.resolve({
            authorization: 'authorized',
            previews: true,
            badge: 'inbox',
            sound: 'default',
            badgeSoundOff: [],
          }),
        postNotifications: unused,
        requestNotifications: unused,
        setNotificationPreviews: unused,
        setNotificationBadge: unused,
        setNotificationSound: unused,
        setNotificationProfile: unused,
        setBadgeCount: vi
          .fn<(count: number) => Promise<unknown>>()
          .mockImplementationOnce((count) => {
            badges.push(count);
            return heldWrite.promise;
          })
          .mockImplementation((count) => {
            badges.push(count);
            return Promise.resolve(null);
          }),
        openNotificationSettings: unused,
      },
      () => english,
    );
    const snapshot = connected([], 'a');
    notifications.followBadge({
      registration: {
        getSnapshot: () => ({ snapshot, busy: false, failed: false }),
        subscribe: () => () => undefined,
      },
      mailboxes: {
        getConnections: () => connections,
        subscribe: (listener) => {
          listeners.add(listener);
          return () => listeners.delete(listener);
        },
      },
    });
    await vi.waitFor(() => {
      expect(badges).toStrictEqual([2]);
    });
    // The messages are read while 2 is written, then the Inbox loads again.
    connections = [ready(0)];
    changed();
    connections = [{ profile: defaultProfile, state: { kind: 'loading' } }];
    changed();
    heldWrite.resolve(null);
    await notifications.load();
    expect(badges).toStrictEqual([2]);
  });
});

describe('posting a New Mail Notification', () => {
  it('checks the Profile the connection is in as it posts, after a move meanwhile', async () => {
    expect.hasAssertions();
    const posted: unknown[] = [];
    let profile = 'shown';
    const notifications = createNotifications(
      {
        notificationSettings: () =>
          Promise.resolve({
            authorization: 'authorized',
            previews: true,
            badge: 'off',
            sound: 'default',
          }),
        postNotifications: (messages) => {
          posted.push(...messages);
          return Promise.resolve();
        },
        requestNotifications: unused,
        setNotificationPreviews: unused,
        setNotificationBadge: unused,
        setNotificationSound: unused,
        setNotificationProfile: unused,
        setBadgeCount: unused,
        openNotificationSettings: unused,
      },
      () => english,
    );
    await notifications.arrived(
      {
        account: 'account',
        connection: 'work',
        epoch: 'epoch',
        address: 'alex@example.invalid',
        profile: () => profile,
      },
      [
        {
          id: 'message',
          sender: 'Sam',
          address: 'sam@example.invalid',
          subject: 'Moved meanwhile',
        },
      ],
      {
        settle: () => {
          // The connection moves to a Profile that hides it as the preferences settle.
          queueMicrotask(() => {
            profile = 'hidden';
          });
          return Promise.resolve();
        },
        eligible: (current) => current === 'shown',
      },
    );
    expect(posted).toStrictEqual([]);
  });
});
