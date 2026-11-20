import {
  createRegistration,
  mailboxesOf,
} from '@private-email/mail-core/registration';
import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';

import type { NativeWakes } from '../src/freshness.ts';
import type { GmailInboxState } from '../src/inbox-store.ts';
import type { Mailboxes } from '../src/mailboxes.ts';
import type { NativeRegistrationVault } from '../src/registration-flow.ts';

import { createFreshness, followWakes, pushCovers } from '../src/freshness.ts';
import { createMailboxes } from '../src/mailboxes.ts';
import { createRegistrationFlow } from '../src/registration-flow.ts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '../src/testing/gmail-mailbox.ts';
import { createRegistrationScenario } from '../src/testing/registration-scenarios.ts';
import { syntheticMailboxes } from '../src/testing/registration-vault.ts';

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

// Each connection's state in the registration snapshot.
const NativeAccess = Schema.Struct({
  mailboxes: Schema.Array(
    Schema.Struct({ id: Schema.String, access: Schema.String }),
  ),
});

const states = (registration: ReturnType<typeof createRegistration>) => {
  const { snapshot } = registration.getSnapshot();
  return Object.fromEntries(
    mailboxesOf(snapshot).map(({ id, state }) => [id, state]),
  );
};

// Loads every mailbox and waits for its Historical Metadata Backfill, which reads in the background.
const loaded = async (mailboxes: Mailboxes) => {
  await mailboxes.load();
  await vi.waitFor(() => {
    for (const { state } of mailboxes.getSnapshot()) {
      expect(state?.kind === 'ready' && state.history?.complete).toBe(true);
    }
  });
};

// A Product Account with Alex's and Other's mailboxes, each backed by its own controlled Gmail.
async function twoMailboxes(messages = 0, connectOther = true) {
  const gmail = {
    alex: createSyntheticGmail({ address: 'alex@example.invalid', messages }),
    other: createSyntheticGmail({ address: 'other@example.invalid' }),
  };
  const synthetic = await createRegistrationScenario('registration-success');
  let online = true;
  let cacheOnly = false;
  // Runs once before the next verification reads this device's registration.
  let beforeRead: (() => Promise<void>) | undefined = undefined;
  // Each connection whose grant verification renewed with its provider, in order.
  const verifications: string[] = [];
  const vault: NativeRegistrationVault = {
    ...synthetic.vault,
    registration: async () => {
      const hook = beforeRead;
      beforeRead = undefined;
      await hook?.();
      return synthetic.vault.registration();
    },
    // Offline, verification leaves each saved Inbox cache-only until it verifies again.
    refreshMailbox: (connection) => {
      verifications.push(connection);
      cacheOnly = !online;
      return online
        ? synthetic.vault.refreshMailbox(connection)
        : Promise.reject(
            Object.assign(new Error('Synthetic offline'), { code: 'offline' }),
          );
    },
  };
  const registration = createRegistration(vault);
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
    verifications,
    // The process ends: native code forgets which connections verified.
    end: () => vault.forgetMailboxAccess(),
    // Another Trusted Device revokes this one.
    revoke: () => {
      synthetic.backend.revoked = true;
    },
    // Google stops confirming this device's Product Sign-In.
    refuseSignIn: () => {
      synthetic.google.refreshFailure = 'unavailable';
    },
    // The access native code keeps for each connection.
    access: async () => {
      const { mailboxes } = Schema.decodeUnknownSync(NativeAccess)(
        await vault.registration(),
      );
      return Object.fromEntries(
        mailboxes.map(({ id, access }) => [id, access]),
      );
    },
    // How often native code renewed the Gmail watches, which refreshes each verified grant.
    renewals: () =>
      synthetic.backend.push.filter((step) => step === 'route').length,
    beforeVerification: (hook: () => Promise<void>) => {
      beforeRead = hook;
    },
    // Another window of this process adds a mailbox, outside this store.
    addElsewhere: () =>
      Effect.runPromise(
        createRegistrationFlow(vault).addMailbox('gmail', true),
      ),
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
    await loaded(mailboxes);
    // A failed verification leaves the native mailbox cache-only until registration verifies again.
    setOnline(false);
    await freshness.refresh();
    const offlineRequests = gmail.alex.requests.length;
    await loaded(mailboxes);
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
      const { gmail, beforeVerification, addElsewhere, launch } =
        await twoMailboxes(0, false);
      const { mailboxes, freshness } = launch();
      await loaded(mailboxes);
      gmail.alex.deliver({ subject: 'Routed arrival' });
      gmail.other.deliver({ subject: 'Unrouted arrival' });
      const routes = new Map([['route-alex', alex]]);
      beforeVerification(async () => {
        // Verification learns another eligible connection that was absent from this store.
        await addElsewhere();
        invalidate(routes);
      });
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

  it('shows the other mailboxes’ saved listings after a wake that launched the app, without contacting their provider', async () => {
    expect.hasAssertions();
    const { gmail, registration, verifications, end, launch } =
      await twoMailboxes();
    gmail.other.deliver({ subject: 'Saved for Other' });
    await loaded(launch().mailboxes);
    // The process ends; a wake for Alex launches it again.
    await end();
    verifications.length = 0;
    gmail.alex.deliver({ subject: 'Pushed for Alex' });
    gmail.other.deliver({ subject: 'Not yet read for Other' });
    const otherRequests = gmail.other.requests.length;
    const { mailboxes, freshness } = launch();
    await expect(
      freshness.wake({ provider: 'gmail', routeId: 'route-alex' }, (id) =>
        new Map([['route-alex', alex]]).get(id),
      ),
    ).resolves.toBe('synchronized');
    expect({
      alex: subjects(mailboxes, alex),
      other: subjects(mailboxes, other),
      otherRequests: gmail.other.requests.length - otherRequests,
      verifications,
      states: states(registration),
    }).toStrictEqual({
      alex: ['Pushed for Alex'],
      other: ['Saved for Other'],
      otherRequests: 0,
      verifications: [alex],
      states: { [alex]: 'connected', [other]: 'cached' },
    });
    // The next foreground catch-up verifies every connection and reads the other's mail.
    await freshness.refresh();
    expect({
      other: subjects(mailboxes, other),
      verifications,
      states: states(registration),
    }).toStrictEqual({
      other: ['Not yet read for Other', 'Saved for Other'],
      verifications: [alex, alex, other],
      states: { [alex]: 'connected', [other]: 'connected' },
    });
  });

  it('signs out on a wake that launched a revoked device, without contacting any mail provider', async () => {
    expect.hasAssertions();
    const { gmail, registration, verifications, end, revoke, launch } =
      await twoMailboxes();
    await loaded(launch().mailboxes);
    await end();
    revoke();
    verifications.length = 0;
    const requests = gmail.alex.requests.length + gmail.other.requests.length;
    const { freshness } = launch();
    await expect(
      freshness.wake({ provider: 'gmail', routeId: 'route-alex' }, (id) =>
        new Map([['route-alex', alex]]).get(id),
      ),
    ).resolves.toBe('ignored');
    expect({
      snapshot: registration.getSnapshot().snapshot,
      verifications,
      requests: gmail.alex.requests.length + gmail.other.requests.length,
    }).toStrictEqual({
      snapshot: { kind: 'signed-out', notice: 'revoked' },
      verifications: [],
      requests,
    });
  });

  it('keeps the other mailboxes’ verified access through a wake while the app runs, without renewing their watches', async () => {
    expect.hasAssertions();
    const { registration, verifications, renewals, launch } =
      await twoMailboxes();
    const { mailboxes, freshness } = launch();
    await loaded(mailboxes);
    verifications.length = 0;
    const renewed = renewals();
    await expect(
      freshness.wake({ provider: 'gmail', routeId: 'route-alex' }, (id) =>
        new Map([['route-alex', alex]]).get(id),
      ),
    ).resolves.toBe('synchronized');
    expect({
      verifications,
      renewals: renewals() - renewed,
      states: states(registration),
    }).toStrictEqual({
      verifications: [alex],
      renewals: 0,
      states: { [alex]: 'connected', [other]: 'connected' },
    });
  });

  it('forgets every mailbox’s access when a wake while the app runs finds the Product Sign-In no longer confirms', async () => {
    expect.hasAssertions();
    const { verifications, refuseSignIn, access, launch } =
      await twoMailboxes();
    const { mailboxes, freshness } = launch();
    await loaded(mailboxes);
    verifications.length = 0;
    refuseSignIn();
    await freshness.wake({ provider: 'gmail', routeId: 'route-alex' }, (id) =>
      new Map([['route-alex', alex]]).get(id),
    );
    expect({ verifications, access: await access() }).toStrictEqual({
      verifications: [],
      access: { [alex]: 'unverified', [other]: 'unverified' },
    });
  });

  it('finishes a wake while another mailbox’s synchronization still waits on its provider', async () => {
    expect.hasAssertions();
    const { gmail, launch } = await twoMailboxes();
    const held = Promise.withResolvers<undefined>();
    const request = gmail.other.native.gmailRequest;
    const holding = vi
      .spyOn(gmail.other.native, 'gmailRequest')
      .mockImplementation(async (...args) => {
        await held.promise;
        return request(...args);
      });
    const { mailboxes, freshness } = launch();
    const foreground = mailboxes.load();
    gmail.alex.deliver({ subject: 'Pushed for Alex' });
    await expect(
      freshness.wake({ provider: 'gmail', routeId: 'route-alex' }, (id) =>
        new Map([['route-alex', alex]]).get(id),
      ),
    ).resolves.toBe('synchronized');
    expect(subjects(mailboxes, alex)).toStrictEqual(['Pushed for Alex']);
    held.resolve(undefined);
    await foreground;
    holding.mockRestore();
  });

  it('wakes only the routed mailbox, keeps nothing from the hint, and ignores unknown and removed routes', async () => {
    expect.hasAssertions();
    const output = vi.spyOn(console, 'error');
    const logs = vi.spyOn(console, 'log');
    const { gmail, registration, beforeVerification, launch } =
      await twoMailboxes();
    const { mailboxes, freshness } = launch();
    await loaded(mailboxes);
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
    const { promise: held, resolve: release } =
      Promise.withResolvers<undefined>();
    beforeVerification(async () => {
      await held;
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
    await loaded(mailboxes);
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
    const { gmail, beforeVerification, launch } = await twoMailboxes();
    const { mailboxes, freshness } = launch();
    await loaded(mailboxes);
    let routes: Record<string, string> = { 'route-alex': alex };
    const host = hostWakes(async () => ({ routes, complete: true }));
    beforeVerification(async () => {
      routes = {};
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
    await loaded(mailboxes);
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
    await loaded(mailboxes);
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

  // Alex's Inbox paused until 13:20 by Gmail's usage limit, and an activation whose grant
  // verifications met the same limit, so both saved Inboxes open from their caches (#2502).
  const pausedWhileVerificationLimited = async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-11-20T13:00:00.000Z'));
    const mail = await twoMailboxes();
    const { mailboxes, freshness } = mail.launch();
    await loaded(mailboxes);
    const inbox = () =>
      mailboxes.getSnapshot().find(({ id }) => id === alex)?.state;
    mail.gmail.alex.fail({
      status: 403,
      body: JSON.stringify({
        error: {
          errors: [{ reason: 'rateLimitExceeded' }],
          message: 'Rate limit exceeded. Retry after 2026-11-20T13:20:00.000Z',
        },
      }),
    });
    await mailboxes.load();
    expect(inbox()).toMatchObject({ sync: 'retry', limit: { times: 1 } });
    mail.setOnline(false);
    await freshness.refresh();
    expect(states(mail.registration)).toStrictEqual({
      [alex]: 'cached',
      [other]: 'cached',
    });
    mail.verifications.length = 0;
    return { ...mail, freshness, inbox };
  };

  it("verifies only a paused mailbox at Gmail's time, after its verification met the usage limit", async () => {
    expect.hasAssertions();
    const { registration, verifications, setOnline, inbox } =
      await pausedWhileVerificationLimited();
    setOnline(true);
    await vi.advanceTimersByTimeAsync(20 * 60_000);
    await vi.waitFor(() => {
      expect(inbox()).toMatchObject({ sync: 'current' });
    });
    expect({ verifications, states: states(registration) }).toStrictEqual({
      verifications: [alex],
      states: { [alex]: 'connected', [other]: 'cached' },
    });
    vi.useRealTimers();
  });

  it("ends the pause at Gmail's time when verification still meets the limit, until it verifies again", async () => {
    expect.hasAssertions();
    const { verifications, setOnline, inbox, freshness } =
      await pausedWhileVerificationLimited();
    await vi.advanceTimersByTimeAsync(20 * 60_000);
    await vi.waitFor(() => {
      expect(verifications).toStrictEqual([alex]);
    });
    expect(inbox()).toMatchObject({ sync: 'retry' });
    expect(inbox()).not.toHaveProperty('limit');
    setOnline(true);
    await freshness.refresh();
    expect(inbox()).toMatchObject({ sync: 'current' });
    vi.useRealTimers();
  });
});
