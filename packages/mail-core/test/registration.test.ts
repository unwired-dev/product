import { english } from '@private-email/localization';

import type { NativeRegistrationVault } from '../src/registration-flow.ts';
import type {
  Registration,
  RegistrationSnapshot,
} from '../src/registration.ts';
import type { SyntheticRegistrationScenario } from '../src/testing/registration-scenarios.ts';

import scenarios from '../../../scripts/mock-mail-scenarios.json' with { type: 'json' };
import {
  createRegistration,
  mailboxesOf,
  registrationScreen,
  revocationNotice,
  revocationProposal,
  trustedDevicesOf,
} from '../src/registration.ts';
import {
  createRegistrationScenario,
  registrationScenarios,
  syntheticTrustedDevice,
} from '../src/testing/registration-scenarios.ts';
import {
  removeTrustedDevice,
  syntheticMailboxes,
} from '../src/testing/registration-vault.ts';

// The connection list native code reports for one connected synthetic mailbox.
const connectedTo = (
  address: keyof typeof syntheticMailboxes,
  epoch = 'synthetic-epoch-1',
) =>
  JSON.stringify([
    {
      provider: 'gmail',
      address,
      epoch,
      id: syntheticMailboxes[address],
      state: 'connected',
    },
  ]);

// A Product Account signed in with Google whose suggested Gmail mailbox was then connected.
const connectedAccount = async (vault: NativeRegistrationVault) => {
  const store = createRegistration(vault);
  await store.register('google');
  await store.addMailbox();
};

// The scenario's vault, whose next registration read first runs a one-shot hook.
const holdingReads = (synthetic: SyntheticRegistrationScenario) => {
  let beforeRead: (() => Promise<void>) | undefined = undefined;
  const vault: NativeRegistrationVault = {
    ...synthetic.vault,
    registration: async () => {
      const hook = beforeRead;
      beforeRead = undefined;
      await hook?.();
      return synthetic.vault.registration();
    },
  };
  return {
    vault,
    beforeRead: (hook: () => Promise<void>) => {
      beforeRead = hook;
    },
  };
};

// The value of a snapshot field the scenario generated, such as a Recovery Key or Enrollment Code.
const shown = (
  store: Registration,
  field:
    | 'recoveryKey'
    | 'enrollmentCode'
    | 'enrollmentRequest'
    | 'revocationRecoveryKey',
) => {
  const { snapshot } = store.getSnapshot();
  const value = snapshot.kind === 'signed-out' ? undefined : snapshot[field];
  if (value === undefined) {
    throw new TypeError(`No ${field} shown`);
  }
  return value;
};

// The store state after an operation that finished without a failure.
const settled = (snapshot: RegistrationSnapshot) => ({
  snapshot,
  busy: false,
  failed: false,
});

const locked = () =>
  Promise.reject(Object.assign(new Error('locked'), { code: 'locked' }));

// A new Product Account presents its Recovery Key until setup is confirmed.
const recoveryKey = 'SYNTHETIC-RECOVERY-ring-1';
const unconfirmed = { privateSync: 'recovery-key', recoveryKey } as const;
const accounts = {
  google: {
    productAccountId: 'account-synthetic-product-subject',
    ...unconfirmed,
  },
  apple: {
    productAccountId: 'account-synthetic-apple-subject',
    contactEmail: 'relay@privaterelay.example.invalid',
    ...unconfirmed,
  },
} as const;

describe('product registration', () => {
  it('keeps a declined Gmail grant separate from Microsoft mail with the same subject', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-declined');
    synthetic.microsoft.subject = synthetic.google.subject;
    const store = createRegistration(synthetic.vault);
    await store.register('google');
    await store.addMailbox('gmail');
    expect(store.getSnapshot().snapshot).toMatchObject({
      kind: 'mailbox-needed',
      reason: 'declined',
    });
    await store.addMailbox('microsoft-graph');
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'connected' },
      failed: false,
    });
    expect(mailboxesOf(store.getSnapshot().snapshot)).toMatchObject([
      { provider: 'microsoft-graph', address: 'casey@example.invalid' },
    ]);
  });

  it('automatically reauthorizes a saved Gmail connection after an IMAP connection', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
    await store.register('google');
    await store.connectImap({
      address: 'imap@example.invalid',
      host: 'imap.example.invalid',
      port: 993,
      username: 'imap',
      password: synthetic.imap.password,
      smtp: {
        host: 'smtp.example.invalid',
        port: 587,
        security: 'starttls',
        username: 'imap',
      },
    });
    // A Gmail mailbox after the IMAP one comes from the account chooser.
    await store.addMailbox();
    // Both saved mailboxes then need authorization again: the IMAP password and the Gmail grant.
    synthetic.imap.password = 'changed-app-password';
    synthetic.expire('other@example.invalid');
    await store.register('google');
    expect(store.getSnapshot().snapshot.kind).toBe('connected');
    expect(store.getSnapshot().failed).toBe(false);
  });

  it('fakes only canonical Mock Mail Session scenarios besides test-only success', () => {
    expect.assertions(1);
    expect(scenarios.build).toStrictEqual(
      expect.arrayContaining(
        registrationScenarios.filter(
          (scenario) => scenario !== 'registration-success',
        ),
      ),
    );
  });

  it('keeps a mailbox removal explanation after refused sign-out and across foreground restore until the next sign-in', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue(undefined);
    const synthetic = await createRegistrationScenario('registration-success');
    const { vault, beforeRead } = holdingReads(synthetic);
    const store = createRegistration(vault);
    await store.register('google');
    await store.addMailbox();
    // Convex cannot be reached to unregister this device.
    synthetic.backend.unregisterFailure = 'offline';
    await store.signOut();
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'connected' },
      removalFailure: 'sign-out',
    });
    synthetic.backend.unregisterFailure = undefined;
    const held = Promise.withResolvers<undefined>();
    const entered = Promise.withResolvers<undefined>();
    beforeRead(async () => {
      entered.resolve(undefined);
      await held.promise;
    });
    const removed = store.deviceRemoved();
    await entered.promise;
    const resumed = store.resume();
    // Mailbox work found this device removed, and native code purged it.
    await synthetic.vault.purge('revoked');
    held.resolve(undefined);
    await Promise.all([removed, resumed]);
    expect(store.getSnapshot()).toStrictEqual({
      snapshot: { kind: 'signed-out', notice: 'revoked' },
      busy: false,
      failed: false,
    });
    // Signing in again replaces it; this new installation waits for approval.
    await store.register('google');
    await store.resume();
    expect(store.getSnapshot().snapshot).toMatchObject({
      kind: 'device-pending',
    });
    expect(store.getSnapshot().snapshot).not.toHaveProperty('notice');
  });

  it.each([
    ['signOut', { kind: 'signed-out' }],
    ['deleteProductAccount', { kind: 'signed-out', notice: 'deleted' }],
  ] as const)(
    'does not relabel %s when a mailbox removal restore queues behind it',
    async (operation, snapshot) => {
      expect.hasAssertions();
      const synthetic = await createRegistrationScenario(
        'registration-success',
      );
      const { vault, beforeRead } = holdingReads(synthetic);
      const held = Promise.withResolvers<undefined>();
      const entered = Promise.withResolvers<undefined>();
      const store = createRegistration(vault);
      await store.register('google');
      beforeRead(async () => {
        entered.resolve(undefined);
        await held.promise;
      });
      const changing = store[operation]();
      await entered.promise;
      const removed = store.deviceRemoved();
      held.resolve(undefined);
      await Promise.all([changing, removed]);
      expect(store.getSnapshot()).toStrictEqual({
        snapshot,
        busy: false,
        failed: false,
      });
    },
  );

  it('keeps the mailbox connected when native Product Sync state is unavailable', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue(undefined);
    const synthetic = await createRegistrationScenario('registration-success');
    // The Keychain's Product Sync items cannot be read.
    synthetic.device.productSync.unreadable = true;
    // Adding a mailbox again picks the same Gmail account, which repairs its connection.
    synthetic.choose('alex@example.invalid');
    const account = {
      productAccountId: 'account-synthetic-product-subject',
      signInProvider: 'google',
      privateSync: 'unavailable',
    } as const;
    const connected = {
      ...account,
      kind: 'connected',
      mailboxes: connectedTo('alex@example.invalid'),
    } as const;
    const store = createRegistration(synthetic.vault);
    await store.register('google');
    expect(store.getSnapshot().snapshot.kind).toBe('mailbox-needed');
    for (const operation of [
      () => store.addMailbox(),
      () => store.restore(),
      () => store.addMailbox(),
    ]) {
      await operation();
      expect(store.getSnapshot()).toStrictEqual({
        snapshot: connected,
        busy: false,
        failed: false,
      });
    }
    expect(
      registrationScreen(english, store.getSnapshot(), undefined).privateSync,
    ).toMatchObject({
      copy: {
        title: 'Private sync is unavailable',
        recoveryKey: undefined,
        enrollmentCode: undefined,
        pending: undefined,
      },
      offersRecovery: false,
    });
  });

  it('keeps enrollment and mailbox descriptors isolated between synthetic Product Accounts', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue(undefined);
    const synthetic = await createRegistrationScenario('registration-success');
    const trusted = createRegistration(synthetic.vault);
    await trusted.register('google');
    await trusted.addMailbox();
    // Another installation already holds the Apple Product Account's keys.
    const keyholder = synthetic.otherDevice();
    await createRegistration(keyholder.vault).register('apple');
    const pending = synthetic.otherDevice();
    const outsider = createRegistration(pending.vault);
    await outsider.register('apple');
    // A Pending Device never starts Gmail authorization, by sign-in or on its own.
    expect(outsider.getSnapshot()).toMatchObject({
      snapshot: { kind: 'device-pending' },
      failed: false,
    });
    await outsider.addMailbox('gmail', true);
    expect(outsider.getSnapshot()).toMatchObject({
      snapshot: { kind: 'device-pending' },
      failed: true,
    });
    await trusted.refreshPrivateSync();
    expect(trusted.getSnapshot().snapshot).not.toHaveProperty(
      'enrollmentRequest',
    );
    await outsider.refreshPrivateSync();
    expect(outsider.getSnapshot().snapshot).not.toHaveProperty(
      'privateSyncMailboxes',
    );
    expect(outsider.getSnapshot().snapshot).toMatchObject({
      privateSync: 'enrollment-pending',
    });
  });

  // Apple cannot renew its sign-in silently, so after a relaunch the mailbox waits for one to
  // reach Product Sync.
  const savedAfterRelaunch = {
    google: { privateSyncMailboxes: 'other@example.invalid' },
    apple: { privateSyncPending: 'mailbox' },
  } as const;

  it.each(
    (['google', 'apple'] as const).flatMap((provider) =>
      (
        [
          'registration-cancelled',
          'registration-declined',
          'registration-no-gmail',
        ] as const
      ).map((scenario) => [provider, scenario] as const),
    ),
  )(
    'retains %s Product Sign-In after %s and resumes with a different Gmail identity',
    async (provider, scenario) => {
      expect.hasAssertions();
      const synthetic = await createRegistrationScenario(scenario);
      const first = createRegistration(synthetic.vault);
      await first.restore();
      await first.register(provider);
      expect(first.getSnapshot()).toMatchObject({
        snapshot: {
          kind: 'mailbox-needed',
          signInProvider: provider,
          ...accounts[provider],
        },
        busy: false,
      });
      const relaunched = createRegistration(synthetic.relaunch());
      await relaunched.restore();
      expect(relaunched.getSnapshot().snapshot).toStrictEqual(
        first.getSnapshot().snapshot,
      );
      await relaunched.addMailbox('gmail', true);
      expect(relaunched.getSnapshot().snapshot).toStrictEqual({
        kind: 'connected',
        signInProvider: provider,
        ...accounts[provider],
        mailboxes: connectedTo('other@example.invalid'),
        ...savedAfterRelaunch[provider],
      });
    },
  );

  it('publishes the committed Product Account before an interrupted mailbox session and permits retry', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario(
      'registration-interrupted',
    );
    const store = createRegistration(synthetic.vault);
    await store.register('apple');
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'mailbox-needed', signInProvider: 'apple' },
      failed: false,
    });
    await store.addMailbox();
    expect(store.getSnapshot()).toMatchObject({
      snapshot: {
        kind: 'mailbox-needed',
        signInProvider: 'apple',
        reason: 'interrupted',
      },
      failed: false,
    });
    await store.restore();
    await store.addMailbox();
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'connected' },
      failed: false,
    });
  });

  it.each(['google', 'apple'] as const)(
    'returns quietly to the previous status when %s Product Sign-In is cancelled',
    async (provider) => {
      expect.hasAssertions();
      const synthetic = await createRegistrationScenario(
        'registration-success',
      );
      synthetic[provider].outcome = 'cancelled';
      const store = createRegistration(synthetic.vault);
      await store.restore();
      await store.register(provider);
      expect(store.getSnapshot()).toStrictEqual({
        snapshot: { kind: 'signed-out' },
        busy: false,
        failed: false,
      });
    },
  );

  it('verifies a connected account once per store and drops the connected status when verification fails', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue(undefined);
    const synthetic = await createRegistrationScenario('registration-success');
    let read = synthetic.vault.registration;
    const store = createRegistration({
      ...synthetic.vault,
      registration: () => read(),
    });
    await store.register('google');
    await store.addMailbox();
    expect(store.getSnapshot().snapshot.kind).toBe('connected');
    await store.restoreOnce();
    const verified = store.getSnapshot();
    // A later launch request in the same store does not verify again, so it cannot fail.
    read = () => Promise.reject(new Error('Synthetic host offline'));
    await store.restoreOnce();
    expect(store.getSnapshot()).toStrictEqual(verified);
    await store.restore();
    expect(store.getSnapshot()).toStrictEqual({
      snapshot: {
        kind: 'mailbox-needed',
        ...accounts.google,
        signInProvider: 'google',
        privateSyncMailboxes: 'alex@example.invalid',
      },
      busy: false,
      failed: true,
    });
  });

  it('keeps a locked state instead of onboarding when launched while locked, and restores the account after unlock', async () => {
    expect.hasAssertions();
    const errors = vi.spyOn(console, 'error').mockReturnValue(undefined);
    const synthetic = await createRegistrationScenario('registration-success');
    await connectedAccount(synthetic.vault);
    let read: () => Promise<unknown> = locked;
    let restores = 0;
    const store = createRegistration({
      ...synthetic.vault,
      registration: () => read(),
      forgetMailboxAccess: () => {
        restores += 1;
        return synthetic.vault.forgetMailboxAccess();
      },
    });
    await store.restoreOnce();
    const lockedState = {
      snapshot: { kind: 'signed-out' },
      busy: false,
      failed: false,
      locked: true,
    };
    expect(store.getSnapshot()).toStrictEqual(lockedState);
    // Becoming active while still locked keeps the locked state.
    await store.resume();
    expect(store.getSnapshot()).toStrictEqual(lockedState);
    read = synthetic.vault.registration;
    await store.resume();
    expect(store.getSnapshot()).toStrictEqual({
      snapshot: {
        kind: 'connected',
        ...accounts.google,
        signInProvider: 'google',
        mailboxes: connectedTo('alex@example.invalid'),
        privateSyncMailboxes: 'alex@example.invalid',
      },
      busy: false,
      failed: false,
    });
    // An unlocked account still verifies on every activation.
    await store.resume();
    expect(restores).toBe(4);
    expect(errors).not.toHaveBeenCalled();
  });

  it('shows launch progress until saved registration is read, also when an activation reads it first (#1070)', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
    const destination = () =>
      registrationScreen(english, store.getSnapshot(), undefined).destination;
    expect(destination()).toBe('restoring');
    // The activation finds no saved account, as the placeholder already says; launch restore skips.
    await Promise.all([store.resume(), store.restoreOnce()]);
    expect(store.getSnapshot()).toStrictEqual(settled({ kind: 'signed-out' }));
    expect(destination()).toBe('account');
  });

  it('verifies once per activation however many Mac windows report it', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-success');
    let restores = 0;
    const store = createRegistration({
      ...synthetic.vault,
      forgetMailboxAccess: () => {
        restores += 1;
        return synthetic.vault.forgetMailboxAccess();
      },
    });
    await store.register('google');
    await Promise.all([store.resume(), store.resume(), store.resume()]);
    expect(restores).toBe(1);
    await store.resume();
    expect(restores).toBe(2);
  });

  it('replaces a connected status when an unlocked foreground restore can no longer verify it', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
    await store.register('google');
    await store.addMailbox();
    await store.restoreOnce();
    expect(store.getSnapshot().snapshot.kind).toBe('connected');
    // The backend no longer confirms the Product Sign-In.
    synthetic.backend.connectFailure = 'unavailable';
    await store.resume();
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'mailbox-needed', reason: 'unavailable' },
      busy: false,
      failed: false,
    });
  });

  it('retains failed setup feedback when an activation queued during consent restores unchanged state', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue(undefined);
    const synthetic = await createRegistrationScenario('registration-success');
    const blocked = Promise.withResolvers<undefined>();
    const started = Promise.withResolvers<boolean>();
    let { signInMailbox } = synthetic.vault;
    const store = createRegistration({
      ...synthetic.vault,
      signInMailbox: (connection, suggest, provider) =>
        signInMailbox(connection, suggest, provider),
    });
    await store.register('google');
    await store.addMailbox();
    // Another Gmail mailbox's consent is interrupted.
    signInMailbox = async () => {
      started.resolve(true);
      await blocked.promise;
      throw Object.assign(new Error('Interrupted'), { code: 'unavailable' });
    };
    const registering = store.addMailbox('gmail', true);
    await started.promise;
    const activating = store.resume();
    blocked.resolve(undefined);
    await registering;
    await activating;
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'connected', signInProvider: 'google' },
      busy: false,
      failed: true,
    });
  });

  it.each([
    ['launch', 'restoreOnce', 0],
    ['retry', 'resume', 1],
  ] as const)(
    'retains an unlock activation while the %s restore is still pending',
    async (_phase, action, previousAttempts) => {
      expect.hasAssertions();
      const synthetic = await createRegistrationScenario(
        'registration-success',
      );
      await connectedAccount(synthetic.vault);
      const blocked = Promise.withResolvers<undefined>();
      const started = Promise.withResolvers<boolean>();
      let nativeRead: () => Promise<unknown> = locked;
      const store = createRegistration({
        ...synthetic.vault,
        registration: () => nativeRead(),
      });
      for (let attempt = 0; attempt < previousAttempts; attempt += 1) {
        await store.restoreOnce();
      }
      nativeRead = async () => {
        started.resolve(true);
        await blocked.promise;
        return locked();
      };
      const restoring = store[action]();
      await started.promise;
      // Unlock arrives before the pending native rejection crosses the bridge.
      nativeRead = synthetic.vault.registration;
      const activating = store.resume();
      blocked.resolve(undefined);
      await Promise.all([restoring, activating]);
      expect(store.getSnapshot()).toMatchObject({
        snapshot: { kind: 'connected', signInProvider: 'google' },
        busy: false,
        failed: false,
      });
      expect(store.getSnapshot()).not.toHaveProperty('locked');
    },
  );

  it('rejects malformed native connection data and prevents overlapping consent operations', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue(undefined);
    const synthetic = await createRegistrationScenario('registration-success');
    const gate = Promise.withResolvers<undefined>();
    let read = synthetic.vault.registration;
    const store = createRegistration({
      ...synthetic.vault,
      signInIdentity: async (provider, hint) => {
        await gate.promise;
        return synthetic.vault.signInIdentity(provider, hint);
      },
      registration: () => read(),
    });
    const registration = store.register('google');
    await store.addMailbox('gmail', true);
    // Nothing has read saved registration yet.
    expect(store.getSnapshot()).toStrictEqual({
      snapshot: { kind: 'signed-out' },
      busy: true,
      failed: false,
      restoring: true,
    });
    gate.resolve(undefined);
    await registration;
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'mailbox-needed' },
      busy: false,
      failed: false,
    });
    // Native code reports a connection without its provider, address or state.
    read = () =>
      Promise.resolve({
        signInProvider: 'google',
        mailboxes: [{ kind: 'connected' }],
        mailboxRemovalPending: false,
        session: true,
      });
    await store.addMailbox();
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'mailbox-needed' },
      busy: false,
      failed: true,
    });
  });

  it('links the other Sign-In Provider explicitly, keeps it across relaunch and opens the same Product Account with it', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-link');
    const store = createRegistration(synthetic.vault);
    await store.register('apple');
    // The Gmail mailbox is the Google account that is then linked.
    synthetic.choose('alex@example.invalid');
    await store.addMailbox();
    // A Gmail grant never links the mailbox's Google identity as a sign-in.
    expect(store.getSnapshot().snapshot).not.toHaveProperty('alternateSignIn');
    await store.link('google');
    const linked = {
      kind: 'connected',
      ...accounts.apple,
      signInProvider: 'apple',
      alternateSignIn: 'google',
      mailboxes: connectedTo('alex@example.invalid'),
      privateSyncMailboxes: 'alex@example.invalid',
    };
    expect(store.getSnapshot()).toStrictEqual({
      snapshot: linked,
      busy: false,
      failed: false,
    });
    const relaunched = createRegistration(synthetic.relaunch());
    await relaunched.restore();
    expect(relaunched.getSnapshot().snapshot).toStrictEqual(linked);
    await relaunched.register('google');
    expect(relaunched.getSnapshot().snapshot).toStrictEqual({
      ...linked,
      signInProvider: 'google',
      alternateSignIn: 'apple',
    });
  });

  it('keeps presenting the Recovery Key until the person confirms its final group', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
    await store.register('google');
    await store.addMailbox();
    const presented = store.getSnapshot().snapshot;
    await store.confirmRecoveryKey('0000');
    expect(store.getSnapshot()).toStrictEqual({
      snapshot: presented,
      busy: false,
      failed: false,
      recoveryKeyFailure: 'mismatch',
    });
    const feedback = store.getSnapshot();
    await store.resume();
    expect(store.getSnapshot()).toStrictEqual(feedback);
    const relaunched = createRegistration(synthetic.relaunch());
    await relaunched.restore();
    expect(relaunched.getSnapshot().snapshot).toStrictEqual(presented);
    await relaunched.confirmRecoveryKey(recoveryKey.slice(-4).toLowerCase());
    expect(relaunched.getSnapshot()).toStrictEqual({
      snapshot: {
        kind: 'connected',
        productAccountId: 'account-synthetic-product-subject',
        signInProvider: 'google',
        privateSync: 'ready',
        mailboxes: connectedTo('alex@example.invalid'),
        privateSyncMailboxes: 'alex@example.invalid',
      },
      busy: false,
      failed: false,
    });
  });

  // A refused link is an expected outcome and stays quiet; any other rejection logs only its code.
  it.each([
    {
      // Each sign-in identity already owns its own Product Account.
      code: 'identity-owned',
      linkFailure: 'identity-owned',
      logsFailure: false,
    },
    {
      code: 'stale-authentication',
      linkFailure: 'stale-authentication',
      logsFailure: false,
    },
    {
      code: 'unavailable',
      linkFailure: 'failed',
      logsFailure: true,
    },
  ] as const)(
    'reports a $code link rejection without changing the Product Account or logging its message',
    async ({ code, linkFailure, logsFailure }) => {
      expect.hasAssertions();
      const logged: unknown[] = [];
      vi.spyOn(console, 'error').mockImplementation((...values) => {
        logged.push(...values);
      });
      const synthetic = await createRegistrationScenario(
        'registration-success',
      );
      synthetic.backend.stale = code === 'stale-authentication';
      const store = createRegistration({
        ...synthetic.vault,
        // Only the unexpected link failure replaces a backend reply; the other refusals are real.
        call: (call) =>
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Only the named link request fails; every other real flow step still runs.
          code === 'unavailable' && call.path === '/sign-in-links/request'
            ? Promise.reject(
                Object.assign(
                  new Error('Link rejected for sealed@example.com'),
                  {
                    code: 'unavailable',
                  },
                ),
              )
            : synthetic.vault.call(call),
      });
      await store.register('google');
      const before = store.getSnapshot().snapshot;
      await store.link('apple');
      expect(store.getSnapshot()).toStrictEqual({
        snapshot: before,
        busy: false,
        failed: false,
        linkFailure,
      });
      expect([
        logged.includes('Registration failed:'),
        logged.includes(`code ${code}`),
      ]).toStrictEqual([logsFailure, logsFailure]);
      expect(String(logged)).not.toMatch(/sealed@/u);
      const feedback = store.getSnapshot();
      await store.resume();
      expect(store.getSnapshot()).toStrictEqual(feedback);
      // The failure clears once another operation finishes.
      await store.restore();
      expect(store.getSnapshot()).not.toHaveProperty('linkFailure');
    },
  );

  it('keeps both devices unchanged when a trusted device declines a request and reports a later approval as unavailable', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue(undefined);
    const synthetic = await createRegistrationScenario('registration-success');
    const trusted = createRegistration(synthetic.vault);
    const addedDevice = synthetic.otherDevice();
    const added = createRegistration(addedDevice.vault);
    await trusted.register('google');
    await added.register('google');
    const enrollmentCode = shown(added, 'enrollmentCode');
    await trusted.refreshPrivateSync();
    const request = shown(trusted, 'enrollmentRequest');
    expect({ enrollmentCode, request }).toStrictEqual({
      enrollmentCode: 'CODE-3',
      request: 'pending-1',
    });
    await trusted.declineEnrollment(request);
    await trusted.approveEnrollment(request, enrollmentCode);
    expect(trusted.getSnapshot()).toMatchObject({
      enrollmentFailure: 'unavailable',
      snapshot: { privateSync: 'recovery-key' },
    });
    const feedback = trusted.getSnapshot();
    await trusted.resume();
    expect(trusted.getSnapshot()).toStrictEqual(feedback);
    await added.refreshPrivateSync();
    // The declined request ended, so the added device asks again with a new code.
    expect(added.getSnapshot().snapshot).toMatchObject({
      privateSync: 'enrollment-pending',
      enrollmentCode: 'CODE-4',
      enrollmentNotice: 'renewed',
    });
    expect(added.getSnapshot().snapshot).not.toHaveProperty(
      'privateSyncMailboxes',
    );
  });

  it('unlocks a new device with the Recovery Key only after a wrong key and an interruption leave it unchanged', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue(undefined);
    const synthetic = await createRegistrationScenario('registration-success');
    const lost = createRegistration(synthetic.vault);
    await lost.register('google');
    await lost.addMailbox();
    const added = synthetic.otherDevice();
    const interrupted = createRegistration(added.vault);
    await interrupted.register('google');
    // The connection drops while the first attempt checks the key.
    added.sync.offline = true;
    await interrupted.recoverWithRecoveryKey(recoveryKey);
    added.sync.offline = false;
    const waiting = interrupted.getSnapshot().snapshot;
    expect(interrupted.getSnapshot()).toMatchObject({
      snapshot: { privateSync: 'enrollment-pending' },
      recoveryFailure: 'failed',
    });
    const relaunched = createRegistration(added.relaunch());
    await relaunched.restore();
    expect(relaunched.getSnapshot().snapshot).toStrictEqual(waiting);
    await relaunched.recoverWithRecoveryKey(
      shown(relaunched, 'enrollmentCode'),
    );
    await relaunched.resume();
    expect(relaunched.getSnapshot()).toStrictEqual({
      snapshot: waiting,
      busy: false,
      failed: false,
      recoveryFailure: 'rejected',
    });
    await relaunched.recoverWithRecoveryKey(
      recoveryKey.toLowerCase().replaceAll('-', ' '),
    );
    expect(relaunched.getSnapshot()).toStrictEqual({
      snapshot: {
        kind: 'mailbox-needed',
        productAccountId: 'account-synthetic-product-subject',
        signInProvider: 'google',
        privateSync: 'ready',
        privateSyncMailboxes: 'alex@example.invalid',
        // The lost device remains a Trusted Device of the account.
        trustedDevices: JSON.stringify([
          {
            id: 'device-synthetic-installation-1',
            name: 'Device device-synthetic-installation-1',
            registeredAt: 1001,
          },
        ]),
      },
      busy: false,
      failed: false,
    });
    // Its approval request is withdrawn, so the lost device's account lists none.
    await lost.refreshPrivateSync();
    expect(lost.getSnapshot().snapshot).not.toHaveProperty('enrollmentRequest');
  });

  it('shows the Enrollment Code that replaced an expired request when a Recovery Key is rejected', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario(
      'registration-enrollment',
    );
    const store = createRegistration(synthetic.vault);
    await store.register('google');
    const expired = shown(store, 'enrollmentCode');
    // The request ends while the form is open; the sign-in renewed for the attempt replaces it.
    synthetic.sync.clock += 900_001;
    await store.recoverWithRecoveryKey(expired);
    const { snapshot, recoveryFailure } = store.getSnapshot();
    expect({ snapshot, recoveryFailure }).toStrictEqual({
      snapshot: {
        kind: 'device-pending',
        productAccountId: 'account-synthetic-product-subject',
        signInProvider: 'google',
        privateSync: 'enrollment-pending',
        enrollmentCode: 'CODE-5',
      },
      recoveryFailure: 'rejected',
    });
    expect(shown(store, 'enrollmentCode')).not.toBe(expired);
  });

  it.each([
    { id: '', name: 'iPad', registeredAt: 1 },
    { id: 'synthetic-ipad', name: 'iPad', registeredAt: 8_640_000_000_000_001 },
    {
      id: 'synthetic-ipad',
      name: 'iPad',
      registeredAt: -8_640_000_000_000_001,
    },
  ])(
    'fails registration for a malformed trusted-device list and recovers on retry: %o',
    async ({ id, name, registeredAt }) => {
      expect.hasAssertions();
      vi.spyOn(console, 'error').mockReturnValue(undefined);
      const synthetic = await createRegistrationScenario(
        'registration-revocation',
      );
      // The backend lists another Trusted Device with a value no date or row can show.
      let malformed = true;
      const store = createRegistration({
        ...synthetic.vault,
        call: (call) =>
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Substitute only the malformed device-list reply until retry.
          malformed && call.path === 'productAccount:listTrustedDevices'
            ? Promise.resolve({
                status: 200,
                body: JSON.stringify({
                  status: 'success',
                  value: [
                    {
                      id,
                      displayName: name,
                      registeredAt,
                      lastSeenAt: 1,
                      platform: 'ios',
                    },
                  ],
                }),
              })
            : synthetic.vault.call(call),
      });
      await store.register('google');
      expect(store.getSnapshot()).toStrictEqual({
        snapshot: { kind: 'signed-out' },
        busy: false,
        failed: true,
      });
      malformed = false;
      await store.register('google');
      expect(store.getSnapshot()).toStrictEqual({
        snapshot: {
          kind: 'mailbox-needed',
          signInProvider: 'google',
          ...accounts.google,
          trustedDevices: JSON.stringify([syntheticTrustedDevice]),
        },
        busy: false,
        failed: false,
      });
    },
  );

  it.each([
    [
      'a truncated reply',
      '{"status":"success","value":[{"id":"synthetic-ipad"',
    ],
    [
      'a device instead of a list',
      JSON.stringify({
        status: 'success',
        value: {
          id: 'synthetic-ipad',
          displayName: 'iPad',
          registeredAt: 1,
          lastSeenAt: 1,
          platform: 'ios',
        },
      }),
    ],
  ])(
    'lists no trusted devices from %s and lists them on retry',
    async (_reply, body) => {
      expect.hasAssertions();
      vi.spyOn(console, 'error').mockReturnValue(undefined);
      const synthetic = await createRegistrationScenario(
        'registration-revocation',
      );
      let malformed = true;
      const store = createRegistration({
        ...synthetic.vault,
        call: (call) =>
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Substitute only the malformed device-list reply until retry.
          malformed && call.path === 'productAccount:listTrustedDevices'
            ? Promise.resolve({ status: 200, body })
            : synthetic.vault.call(call),
      });
      await store.register('google');
      expect(store.getSnapshot()).toStrictEqual(
        settled({
          kind: 'mailbox-needed',
          signInProvider: 'google',
          ...accounts.google,
        }),
      );
      malformed = false;
      await store.register('google');
      expect(store.getSnapshot()).toStrictEqual(
        settled({
          kind: 'mailbox-needed',
          signInProvider: 'google',
          ...accounts.google,
          trustedDevices: JSON.stringify([syntheticTrustedDevice]),
        }),
      );
    },
  );

  it('deletes the Product Account everywhere: other installations purge on their next verification', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-success');
    const current = createRegistration(synthetic.vault);
    const otherDevice = synthetic.otherDevice();
    const other = createRegistration(otherDevice.vault);
    await current.register('google');
    await other.register('google');
    // The other installation unlocks the account's keys with its Recovery Key.
    await other.recoverWithRecoveryKey(recoveryKey);
    await other.addMailbox();
    const deleted = {
      snapshot: { kind: 'signed-out', notice: 'deleted' },
      busy: false,
      failed: false,
    } as const;
    await current.deleteProductAccount();
    expect(current.getSnapshot()).toStrictEqual(deleted);
    expect(other.getSnapshot().snapshot.kind).toBe('connected');
    await other.restore();
    expect(other.getSnapshot()).toStrictEqual(deleted);
    // The deleted account cannot be reopened.
    await current.register('google');
    expect(current.getSnapshot()).toStrictEqual(deleted);
  });

  it('keeps the account when sign-out or deletion fails, and a cancelled sign-in stays quiet', async () => {
    expect.hasAssertions();
    const logged: unknown[] = [];
    vi.spyOn(console, 'error').mockImplementation((...values) => {
      logged.push(...values);
    });
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
    await store.register('google');
    // The Recovery Key is not backed up yet, so sign-out keeps it.
    synthetic.device.recoveryKeyConfirmed = false;
    const { snapshot } = store.getSnapshot();
    // Convex refuses the deletion before fencing anything; a refusal never logs its body.
    for (const [status, code] of [
      [403, 'removal-refused'],
      [401, 'stale-authentication'],
    ] as const) {
      synthetic.backend.deletionStatus = status;
      synthetic.backend.deletionCode = 'REFUSED sealed@example.invalid';
      await store.deleteProductAccount();
      expect(store.getSnapshot()).toStrictEqual({
        snapshot,
        busy: false,
        failed: false,
        removalFailure: 'deletion-refused',
      });
      expect(logged).toContain(`code ${code}`);
      expect(String(logged)).not.toMatch(/sealed@/u);
    }
    synthetic.backend.deletionStatus = 200;
    // The silent Google renewal sign-out needs is interrupted.
    synthetic.google.refreshFailure = 'offline';
    await store.signOut();
    expect(store.getSnapshot()).toStrictEqual({
      snapshot,
      busy: false,
      failed: false,
      removalFailure: 'sign-out',
    });
    synthetic.google.refreshFailure = undefined;
    synthetic.google.outcome = 'cancelled';
    await store.deleteProductAccount();
    expect(store.getSnapshot()).toStrictEqual({
      snapshot,
      busy: false,
      failed: false,
    });
    synthetic.google.outcome = undefined;
    await store.signOut();
    expect(store.getSnapshot().snapshot).toStrictEqual(snapshot);
    await store.confirmRecoveryKey(recoveryKey.slice(-4));
    await store.signOut();
    expect(store.getSnapshot()).toStrictEqual({
      snapshot: { kind: 'signed-out' },
      busy: false,
      failed: false,
    });
  });

  it('keeps an unanswered deletion uncertain when a retry is refused, until a later retry completes it', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue(undefined);
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
    await store.register('google');
    const { snapshot } = store.getSnapshot();
    // The backend applies the deletion, and its reply is lost.
    synthetic.backend.loseReply = true;
    await store.deleteProductAccount();
    const uncertain = store.getSnapshot();
    synthetic.backend.loseReply = false;
    // A refused retry of an unanswered deletion remains unavailable at the native boundary.
    synthetic.backend.deletionStatus = 403;
    await store.deleteProductAccount();
    expect([uncertain, store.getSnapshot().removalFailure]).toStrictEqual([
      { snapshot, busy: false, failed: false, removalFailure: 'deletion' },
      'deletion',
    ]);
    synthetic.backend.deletionStatus = 200;
    await store.deleteProductAccount();
    expect(store.getSnapshot()).toStrictEqual(
      settled({ kind: 'signed-out', notice: 'deleted' }),
    );
  });

  it('keeps the account when preparing a removal fails', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue(undefined);
    const synthetic = await createRegistrationScenario(
      'registration-revocation',
    );
    const store = createRegistration(synthetic.vault);
    await store.register('google');
    await store.confirmRecoveryKey(recoveryKey.slice(-4));
    const { snapshot } = store.getSnapshot();
    expect(trustedDevicesOf(snapshot)).toStrictEqual([syntheticTrustedDevice]);
    // Product Sync cannot reach Convex while the removal is prepared.
    synthetic.sync.offline = true;
    await store.revokeTrustedDevice(syntheticTrustedDevice.id);
    expect(store.getSnapshot()).toStrictEqual({
      snapshot,
      busy: false,
      failed: false,
      revocationFailure: 'failed',
    });
  });

  /* oxlint-disable vitest/max-expects -- Each journey proves one sequence of removal states. */
  // Synthetic journey: the synthetic vault stands in for native preparation and activation, so this
  // proves the flow's and store's states, not native code.
  it('removes a device only after its replacement Recovery Key is confirmed, renewing a stale proposal', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario(
      'registration-revocation',
    );
    const store = createRegistration(synthetic.vault);
    await store.register('google');
    await store.confirmRecoveryKey(recoveryKey.slice(-4));
    const remaining = {
      kind: 'mailbox-needed',
      signInProvider: 'google',
      productAccountId: 'account-synthetic-product-subject',
      privateSync: 'ready',
    } as const;
    const ready = {
      ...remaining,
      trustedDevices: JSON.stringify([syntheticTrustedDevice]),
    };
    expect(store.getSnapshot()).toStrictEqual(settled(ready));
    await store.revokeTrustedDevice(syntheticTrustedDevice.id);
    const replacement = shown(store, 'revocationRecoveryKey');
    const proposed = {
      ...ready,
      revocationDevice: syntheticTrustedDevice.id,
      revocationRecoveryKey: replacement,
    };
    expect(store.getSnapshot()).toStrictEqual(settled(proposed));
    expect(revocationProposal(english, proposed)).toStrictEqual({
      name: syntheticTrustedDevice.name,
      recoveryKey: replacement,
    });
    // Cancellation discards the proposal and leaves the device listed.
    await store.cancelRevocation();
    expect(store.getSnapshot()).toStrictEqual(settled(ready));
    await store.revokeTrustedDevice(syntheticTrustedDevice.id);
    const prepared = shown(store, 'revocationRecoveryKey');
    // A wrong entry sends nothing and keeps the proposal.
    await store.confirmRevocation(recoveryKey.slice(-4));
    expect(store.getSnapshot()).toStrictEqual({
      ...settled({ ...proposed, revocationRecoveryKey: prepared }),
      revocationFailure: 'mismatch',
    });
    // The account changed meanwhile: a fresh key replaces the confirmed one and nothing is removed.
    synthetic.changeAccount();
    await store.confirmRevocation(prepared.slice(-4));
    const renewedKey = shown(store, 'revocationRecoveryKey');
    const renewed = {
      ...proposed,
      revocationRecoveryKey: renewedKey,
      revocationNotice: 'renewed',
    } as const;
    expect(store.getSnapshot()).toStrictEqual(settled(renewed));
    expect(trustedDevicesOf(renewed)).toStrictEqual([syntheticTrustedDevice]);
    // Confirming the discarded key does not count.
    await store.confirmRevocation(prepared.slice(-4));
    expect(store.getSnapshot().revocationFailure).toBe('mismatch');
    await store.confirmRevocation(` ${renewedKey.slice(-4).toLowerCase()}`);
    expect(store.getSnapshot()).toStrictEqual(
      settled({ ...remaining, revocationNotice: 'removed' }),
    );
  });

  it('keeps an unconfirmed proposal, drops a superseded one, and shows a later failure instead of an earlier notice', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue(undefined);
    const synthetic = await createRegistrationScenario(
      'registration-revocation',
    );
    const store = createRegistration(synthetic.vault);
    await store.register('google');
    await store.confirmRecoveryKey(recoveryKey.slice(-4));
    await store.revokeTrustedDevice(syntheticTrustedDevice.id);
    const replacement = shown(store, 'revocationRecoveryKey');
    const entry = replacement.slice(-4);
    const proposed = {
      kind: 'mailbox-needed',
      signInProvider: 'google',
      productAccountId: 'account-synthetic-product-subject',
      privateSync: 'ready',
      trustedDevices: JSON.stringify([syntheticTrustedDevice]),
      revocationDevice: syntheticTrustedDevice.id,
      revocationRecoveryKey: replacement,
    } as const;
    // The reply was lost: the proposal stays, and confirming again retries it.
    const unconfirmedProposal = {
      ...proposed,
      revocationNotice: 'unconfirmed',
    } as const;
    const {
      revocationDevice: _device,
      revocationRecoveryKey: _key,
      trustedDevices: _devices,
      ...discarded
    } = proposed;
    // Another device removed the target first; its key never became current.
    const superseded = {
      ...discarded,
      revocationNotice: 'superseded',
    } as const;
    synthetic.sync.failActivationBeforeCommit = true;
    await store.confirmRevocation(entry);
    expect(store.getSnapshot()).toStrictEqual(settled(unconfirmedProposal));
    expect(revocationProposal(english, unconfirmedProposal)?.recoveryKey).toBe(
      replacement,
    );
    expect(revocationNotice(english, unconfirmedProposal, false)).toBe(
      english('revocation.unconfirmed'),
    );
    // A wrong retry entry cannot settle an earlier activation whose reply was lost.
    await store.confirmRevocation('WRNG');
    expect(store.getSnapshot()).toStrictEqual({
      ...settled(unconfirmedProposal),
      revocationFailure: 'mismatch',
    });
    // Convex refuses this attempt, which cannot settle the earlier one either.
    synthetic.sync.activationReply = {
      status: 400,
      body: JSON.stringify({ code: 'KEY_ROTATION_INVALID' }),
    };
    await store.confirmRevocation(entry);
    const failed = store.getSnapshot();
    expect(failed).toStrictEqual({
      ...settled(unconfirmedProposal),
      revocationFailure: 'failed',
    });
    expect(
      revocationNotice(
        english,
        unconfirmedProposal,
        failed.revocationFailure === 'failed',
      ),
    ).toBe('The device could not be removed. Try again.');
    // The sign-in is no longer recent, and its renewal is cancelled.
    synthetic.sync.staleOnce = true;
    synthetic.google.outcome = 'cancelled';
    await store.confirmRevocation(entry);
    expect(store.getSnapshot()).toStrictEqual(settled(unconfirmedProposal));
    synthetic.google.outcome = undefined;
    removeTrustedDevice(
      synthetic.sync,
      accounts.google.productAccountId,
      syntheticTrustedDevice.id,
    );
    await store.confirmRevocation(entry);
    expect(store.getSnapshot()).toStrictEqual(settled(superseded));
  });

  /* oxlint-enable vitest/max-expects */
});
