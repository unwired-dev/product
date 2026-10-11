import * as Schema from 'effect/Schema';

import type { NativeWakes } from '../src/freshness.ts';
import type { GmailInboxState } from '../src/gmail-inbox.ts';
import type { Mailboxes } from '../src/mailboxes.ts';

import { createFreshness, followWakes, pushCovers } from '../src/freshness.ts';
import { createMailboxes } from '../src/mailboxes.ts';
import {
  createRegistration,
  RegistrationSnapshotSchema,
} from '../src/registration.ts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '../src/testing/gmail-mailbox.ts';
import {
  createMockRegistrationSession,
  syntheticMailboxes,
} from '../src/testing/registration-session.ts';

const alex = syntheticMailboxes['alex@example.invalid'];
const other = syntheticMailboxes['other@example.invalid'];

const subjects = (mailboxes: Mailboxes, id: string) => {
  const state: GmailInboxState | undefined = mailboxes
    .getSnapshot()
    .find((mailbox) => mailbox.id === id)?.state;
  return state?.kind === 'ready'
    ? state.messages.map(({ subject }) => subject)
    : [];
};

// A Product Account with Alex's and Other's mailboxes, each backed by its own controlled Gmail.
async function twoMailboxes(messages = 0, connectOther = true) {
  const gmail = {
    alex: createSyntheticGmail({ address: 'alex@example.invalid', messages }),
    other: createSyntheticGmail({ address: 'other@example.invalid' }),
  };
  const session = createMockRegistrationSession('registration-success').native;
  let online = true;
  let cacheOnly = false;
  const nativeRegistration = {
    ...session,
    restore: async () => {
      const snapshot = Schema.decodeUnknownSync(RegistrationSnapshotSchema)(
        await session.restore(),
      );
      cacheOnly = !online;
      return snapshot.kind === 'connected' && cacheOnly
        ? {
            ...snapshot,
            mailboxes: JSON.stringify([
              { id: alex, address: 'alex@example.invalid', state: 'cached' },
              { id: other, address: 'other@example.invalid', state: 'cached' },
            ]),
          }
        : snapshot;
    },
  };
  const registration = createRegistration({
    ...nativeRegistration,
    restore: () => nativeRegistration.restore(),
  });
  await registration.register('google');
  await registration.addMailbox();
  if (connectOther) {
    await registration.addMailbox('gmail', true);
  }
  const native = syntheticConnections({
    [alex]: {
      native: {
        ...gmail.alex.native,
        openMailbox: async () => ({
          ...(await gmail.alex.native.openMailbox()),
          ...(cacheOnly ? { availability: 'retry' } : {}),
        }),
      },
    },
    [other]: gmail.other,
  });
  const launch = () => {
    const mailboxes = createMailboxes(native, registration);
    return {
      mailboxes,
      freshness: createFreshness(mailboxes, registration.refreshInbox),
    };
  };
  return {
    gmail,
    registration,
    nativeRegistration,
    launch,
    setOnline: (next: boolean) => {
      online = next;
    },
  };
}

// The host's APNs queue: wakes wait until JavaScript reads them, and each completes once.
function hostWakes(routes: () => Promise<unknown>) {
  const waiting: unknown[] = [];
  let reader: PromiseWithResolvers<unknown> | undefined = undefined;
  const completed: Array<readonly [string, string]> = [];
  const native: NativeWakes = {
    nextWake: async () => {
      if (waiting.length > 0) {
        return waiting.shift();
      }
      reader = Promise.withResolvers<unknown>();
      return reader.promise;
    },
    mailboxRoutes: routes,
    completeWake: (id, result) => {
      completed.push([id, result]);
    },
  };
  return {
    native,
    completed,
    deliver: (wake: unknown) => {
      const pending = reader;
      reader = undefined;
      if (pending === undefined) {
        waiting.push(wake);
        return;
      }
      pending.resolve(wake);
    },
  };
}

describe('keeping Gmail fresh through application lifecycles', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one lifecycle path end to end. */
  it('keeps synchronizing after the last window closes, stops on Quit and resumes from its checkpoint after relaunch', async () => {
    expect.hasAssertions();
    vi.useFakeTimers();
    const { gmail, launch, setOnline } = await twoMailboxes();
    gmail.alex.deliver({ subject: 'Before closing' });
    const { mailboxes, freshness } = launch();
    // The window that opened the Inbox closes; nothing subscribes to the mailboxes any more.
    const closeWindow = mailboxes.subscribe(() => undefined);
    await mailboxes.load();
    // A failed verification leaves the native mailbox cache-only until registration verifies again.
    setOnline(false);
    await freshness.refresh();
    const offlineRequests = gmail.alex.requests.length;
    await mailboxes.load();
    expect(gmail.alex.requests).toHaveLength(offlineRequests);
    closeWindow();
    const stop = freshness.keepAlive(5);

    setOnline(true);
    gmail.alex.deliver({ subject: 'While no window is open' });
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    expect(subjects(mailboxes, alex)).toStrictEqual([
      'While no window is open',
      'Before closing',
    ]);
    // A reopened window shows the committed mail at once, without asking Gmail.
    const requests = gmail.alex.requests.length;
    const reopened = mailboxes.subscribe(() => undefined);
    expect(subjects(mailboxes, alex)[0]).toBe('While no window is open');
    expect(gmail.alex.requests).toHaveLength(requests);
    reopened();

    // Quit: nothing reads Gmail afterwards.
    stop();
    gmail.alex.deliver({ subject: 'After Quit' });
    await vi.advanceTimersByTimeAsync(30 * 60_000);
    expect(gmail.alex.requests).toHaveLength(requests);

    // Relaunch reads only the history after the committed checkpoint; it lists nothing again.
    const relaunched = launch();
    await relaunched.freshness.refresh();
    expect(subjects(relaunched.mailboxes, alex)).toStrictEqual([
      'After Quit',
      'While no window is open',
      'Before closing',
    ]);
    expect(
      gmail.alex.requests.slice(requests).map(({ path }) => path),
    ).not.toContain('messages');
    vi.useRealTimers();
  });

  it('catches up in the foreground after a suspended synchronization and a missed wake, without duplicates', async () => {
    expect.hasAssertions();
    const { gmail, launch } = await twoMailboxes(120);
    // The operating system suspends a background synchronization after its first page.
    gmail.alex.failPage('50', { code: 'unavailable' });
    const background = launch();
    await background.freshness.refresh();
    expect(subjects(background.mailboxes, alex)).toHaveLength(50);

    // The process ends; a wake hint for the next arrival never reaches the device.
    gmail.alex.deliver({ subject: 'Wake never delivered' });
    const foreground = launch();
    await foreground.freshness.refresh();
    const caughtUp = subjects(foreground.mailboxes, alex);
    expect(caughtUp).toHaveLength(121);
    expect(new Set(caughtUp).size).toBe(121);
    expect(caughtUp[0]).toBe('Wake never delivered');
    // The listing resumed from its committed page rather than starting again.
    expect(
      gmail.alex.requests
        .filter(({ path }) => path === 'messages')
        .map(({ query }) => query.get('pageToken')),
    ).toStrictEqual([null, '50', '50', '100']);
  });

  it.each([
    {
      outcome: 'synchronized',
      invalidate: () => undefined,
      arrivals: ['Routed arrival'],
      reads: true,
    },
    {
      outcome: 'ignored',
      invalidate: (routes: Map<string, string>) => {
        routes.delete('route-alex');
      },
      arrivals: [],
      reads: false,
    },
  ])(
    'keeps newly revealed unrelated mail unloaded during a $outcome wake, then catches up in foreground',
    async ({ outcome, invalidate, arrivals, reads }) => {
      expect.hasAssertions();
      const { gmail, nativeRegistration, launch } = await twoMailboxes(
        0,
        false,
      );
      const { mailboxes, freshness } = launch();
      await mailboxes.load();
      gmail.alex.deliver({ subject: 'Routed arrival' });
      gmail.other.deliver({ subject: 'Unrouted arrival' });
      const routes = new Map([['route-alex', alex]]);
      const { restore } = nativeRegistration;
      vi.spyOn(nativeRegistration, 'restore').mockImplementationOnce(
        async () => {
          // Verification learns another eligible connection that was absent from this store.
          await nativeRegistration.addMailbox('gmail', true);
          invalidate(routes);
          return restore();
        },
      );
      const requests = gmail.alex.requests.length;
      await expect(
        freshness.wake({ provider: 'gmail', routeId: 'route-alex' }, (id) =>
          routes.get(id),
        ),
      ).resolves.toBe(outcome);
      expect(gmail.other.requests).toHaveLength(0);
      expect(subjects(mailboxes, other)).toStrictEqual([]);
      expect(subjects(mailboxes, alex)).toStrictEqual(arrivals);
      expect(gmail.alex.requests.length > requests).toBe(reads);
      await freshness.refresh();
      expect(subjects(mailboxes, other)).toStrictEqual(['Unrouted arrival']);
      expect(subjects(mailboxes, alex)).toStrictEqual(['Routed arrival']);
    },
  );

  it('wakes only the routed mailbox, keeps nothing from the hint, and ignores unknown and removed routes', async () => {
    expect.hasAssertions();
    const output = vi.spyOn(console, 'error');
    const logs = vi.spyOn(console, 'log');
    const { gmail, registration, nativeRegistration, launch } =
      await twoMailboxes();
    const { mailboxes, freshness } = launch();
    await mailboxes.load();
    const routes = new Map([
      ['route-alex', alex],
      ['route-other', other],
    ]);
    const route = (id: string) => routes.get(id);
    gmail.alex.deliver({ subject: 'For Alex' });
    gmail.other.deliver({ subject: 'For Other' });
    const otherRequests = gmail.other.requests.length;

    const hint = {
      aps: { 'content-available': 1 },
      provider: 'gmail',
      routeId: 'route-alex',
      historyId: '987654321',
      emailAddress: 'alex@example.invalid',
    };
    await expect(freshness.wake(hint, route)).resolves.toBe('synchronized');
    expect(subjects(mailboxes, alex)).toStrictEqual(['For Alex']);
    expect(subjects(mailboxes, other)).toStrictEqual([]);
    expect(gmail.other.requests).toHaveLength(otherRequests);
    // The hint's history ID is neither committed nor logged; synchronization used the checkpoint.
    expect(gmail.alex.commits.join('\n')).not.toContain('987654321');
    expect(
      [...output.mock.calls, ...logs.mock.calls].flat().join('\n'),
    ).not.toMatch(/987654321|route-alex/u);

    const alexRequests = gmail.alex.requests.length;
    await expect(
      freshness.wake({ provider: 'gmail', routeId: 'route-unknown' }, route),
    ).resolves.toBe('ignored');
    await expect(
      freshness.wake({ provider: 'outlook', routeId: 'route-alex' }, route),
    ).resolves.toBe('ignored');
    await expect(freshness.wake('route-alex', route)).resolves.toBe('ignored');
    expect(gmail.alex.requests).toHaveLength(alexRequests);

    // Route revocation while verification is suspended invalidates this queued wake.
    const { restore } = nativeRegistration;
    const { promise: held, resolve: release } =
      Promise.withResolvers<undefined>();
    vi.spyOn(nativeRegistration, 'restore').mockImplementationOnce(async () => {
      await held;
      return restore();
    });
    const queued = freshness.wake(hint, route);
    routes.delete('route-alex');
    release(undefined);
    await expect(queued).resolves.toBe('ignored');
    expect(gmail.alex.requests).toHaveLength(alexRequests);

    // A removed mailbox's route reads nothing.
    await registration.removeMailbox(other);
    await expect(
      freshness.wake({ provider: 'gmail', routeId: 'route-other' }, route),
    ).resolves.toBe('ignored');
    expect(gmail.other.requests).toHaveLength(otherRequests);
    expect(subjects(mailboxes, other)).toStrictEqual([]);
  });

  it('settles each host wake once through the native route lookup, failing closed', async () => {
    expect.hasAssertions();
    const output = vi.spyOn(console, 'error').mockReturnValue(undefined);
    const { gmail, launch } = await twoMailboxes();
    const { mailboxes, freshness } = launch();
    await mailboxes.load();
    let lookup = async (): Promise<unknown> => ({
      routes: { 'route-alex': alex },
      complete: true,
    });
    const host = hostWakes(async () => lookup());
    const following = followWakes(freshness, host.native);
    const settled = async (count: number) =>
      vi.waitFor(() => {
        expect(host.completed).toHaveLength(count);
      });

    gmail.alex.deliver({ subject: 'Pushed to Alex' });
    gmail.other.deliver({ subject: 'Not routed' });
    const otherRequests = gmail.other.requests.length;
    host.deliver({
      id: 'wake-1',
      hint: {
        provider: 'gmail',
        routeId: 'route-alex',
        historyId: '987654321',
      },
    });
    await settled(1);
    expect(host.completed[0]).toStrictEqual(['wake-1', 'synchronized']);
    expect(subjects(mailboxes, alex)).toStrictEqual(['Pushed to Alex']);
    expect(gmail.other.requests).toHaveLength(otherRequests);

    // Unknown and inherited names route nothing.
    host.deliver({
      id: 'wake-2',
      hint: { provider: 'gmail', routeId: 'route-other' },
    });
    host.deliver({
      id: 'wake-3',
      hint: { provider: 'gmail', routeId: 'toString' },
    });
    await settled(3);
    expect(host.completed.slice(1)).toStrictEqual([
      ['wake-2', 'ignored'],
      ['wake-3', 'ignored'],
    ]);

    // A failed or unreadable route lookup completes the wake as failed, logging nothing private.
    lookup = () => Promise.reject(new Error('private alex@example.invalid'));
    host.deliver({ id: 'wake-4', hint: { provider: 'gmail', routeId: 'x' } });
    await settled(4);
    lookup = async () => ({ routes: { 'route-alex': 7 }, complete: true });
    host.deliver({ id: 'wake-5', hint: { provider: 'gmail', routeId: 'x' } });
    await settled(5);
    expect(host.completed.slice(3)).toStrictEqual([
      ['wake-4', 'failed'],
      ['wake-5', 'failed'],
    ]);
    expect(output.mock.calls.flat().join('\n')).not.toMatch(
      /alex@example|987654321/u,
    );

    // A reader the host replaced stops following.
    host.deliver(null);
    await expect(following).resolves.toBeUndefined();
    output.mockRestore();
  });

  it('rechecks a native route after verification removes it without removing the mailbox', async () => {
    expect.hasAssertions();
    const { gmail, nativeRegistration, launch } = await twoMailboxes();
    const { mailboxes, freshness } = launch();
    await mailboxes.load();
    let routes: Record<string, string> = { 'route-alex': alex };
    const host = hostWakes(async () => ({ routes, complete: true }));
    const { restore } = nativeRegistration;
    vi.spyOn(nativeRegistration, 'restore').mockImplementationOnce(async () => {
      routes = {};
      return restore();
    });
    gmail.alex.deliver({ subject: 'Removed route reads nothing' });
    const requests = gmail.alex.requests.length;
    const following = followWakes(freshness, host.native);
    host.deliver({
      id: 'removed-route',
      hint: { provider: 'gmail', routeId: 'route-alex' },
    });
    await vi.waitFor(() => {
      expect(host.completed).toStrictEqual([['removed-route', 'ignored']]);
    });
    expect(gmail.alex.requests).toHaveLength(requests);
    host.deliver(null);
    await following;
  });

  it('does not start refreshing when stopped during an asynchronous coverage lookup', async () => {
    expect.hasAssertions();
    vi.useFakeTimers();
    const { gmail, launch } = await twoMailboxes();
    const { mailboxes, freshness } = launch();
    await mailboxes.load();
    const requests = gmail.alex.requests.length;
    const coverage = Promise.withResolvers<boolean>();
    const lookupStarted = Promise.withResolvers<undefined>();
    const covered = () => {
      lookupStarted.resolve(undefined);
      return coverage.promise;
    };
    const stop = freshness.keepAlive(5, covered);
    try {
      await vi.advanceTimersByTimeAsync(5 * 60_000);
      await lookupStarted.promise;
      stop();
      coverage.resolve(false);
      await vi.advanceTimersByTimeAsync(5 * 60_000);
      expect(gmail.alex.requests).toHaveLength(requests);
    } finally {
      stop();
      vi.useRealTimers();
    }
  });

  it('skips the interval only while wakes cover every usable mailbox', async () => {
    expect.hasAssertions();
    vi.useFakeTimers();
    const { gmail, launch } = await twoMailboxes();
    const { mailboxes, freshness } = launch();
    await mailboxes.load();
    let routes: unknown = { routes: { 'route-alex': alex }, complete: true };
    const host = hostWakes(async () => routes);
    const stop = freshness.keepAlive(5, async () => pushCovers(host.native));

    gmail.alex.deliver({ subject: 'Left to its wake' });
    const requests = gmail.alex.requests.length;
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    expect(gmail.alex.requests).toHaveLength(requests);
    expect(subjects(mailboxes, alex)).toStrictEqual([]);

    // A mailbox without a current route, or an unreadable lookup, brings the interval back.
    routes = { routes: {}, complete: false };
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    expect(subjects(mailboxes, alex)).toStrictEqual(['Left to its wake']);
    routes = 'unreadable';
    gmail.alex.deliver({ subject: 'Polled again' });
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    expect(subjects(mailboxes, alex)[0]).toBe('Polled again');
    stop();
    vi.useRealTimers();
  });
});
