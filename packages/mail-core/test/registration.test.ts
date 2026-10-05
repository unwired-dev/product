import type { RegistrationSnapshot } from '../src/registration.ts';

import {
  createRegistration,
  offersRecovery,
  privateSyncCopy,
  revocationCopy,
  revocationNotice,
  trustedDevicesOf,
} from '../src/registration.ts';
import {
  createMockRegistrationSession,
  createSyntheticAccount,
  syntheticEnrollmentCode,
  syntheticEnrollmentRequest,
  syntheticRecoveryKey,
  syntheticTrustedDevice,
} from '../src/testing/registration-session.ts';

// A new Product Account presents its Recovery Key until setup is confirmed.
const unconfirmed = {
  privateSync: 'recovery-key',
  recoveryKey: syntheticRecoveryKey,
} as const;
const accounts = {
  google: { productAccountId: 'synthetic-product-account', ...unconfirmed },
  apple: {
    productAccountId: 'synthetic-apple-product-account',
    contactEmail: 'relay@privaterelay.example.invalid',
    ...unconfirmed,
  },
} as const;

describe('product registration', () => {
  it('keeps the mailbox connected when native Product Sync state is unavailable', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    const account = {
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      privateSync: 'unavailable',
    } as const;
    const connected = {
      ...account,
      kind: 'connected',
      providerSubject: 'synthetic-google-subject',
      address: 'alex@example.invalid',
    } as const;
    const store = createRegistration({
      ...session.native,
      signIn: () => Promise.resolve({ ...account, kind: 'mailbox-needed' }),
      authorizeGmail: () => Promise.resolve(connected),
      restore: () => Promise.resolve(connected),
    });
    for (const operation of [
      () => store.register('google'),
      () => store.restore(),
      () => store.authorizeGmail(false),
    ]) {
      await operation();
      expect(store.getSnapshot()).toStrictEqual({
        snapshot: connected,
        busy: false,
        failed: false,
      });
    }
    expect(privateSyncCopy(account)).toMatchObject({
      title: 'Private sync is unavailable',
      recoveryKey: undefined,
      enrollmentCode: undefined,
      pending: undefined,
    });
    expect(offersRecovery(account.privateSync)).toBe(false);
  });

  it('keeps enrollment and mailbox descriptors isolated between synthetic Product Accounts', async () => {
    expect.hasAssertions();
    const accounts = createSyntheticAccount();
    const trusted = createRegistration(
      createMockRegistrationSession('registration-success', accounts).native,
    );
    const outsider = createRegistration(
      createMockRegistrationSession('registration-enrollment', accounts).native,
    );
    await trusted.register('google');
    await outsider.register('apple');
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

  it.each(
    (['google', 'apple'] as const).flatMap((provider) =>
      [
        'registration-cancelled',
        'registration-declined',
        'registration-no-gmail',
      ].map((scenario) => [provider, scenario] as const),
    ),
  )(
    'retains %s Product Sign-In after %s and resumes with a different Gmail identity',
    async (provider, scenario) => {
      expect.hasAssertions();
      const session = createMockRegistrationSession(scenario);
      const first = createRegistration(session.native);
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
      const relaunched = createRegistration(session.native);
      await relaunched.restore();
      expect(relaunched.getSnapshot().snapshot).toStrictEqual(
        first.getSnapshot().snapshot,
      );
      await relaunched.authorizeGmail(true);
      expect(relaunched.getSnapshot().snapshot).toStrictEqual({
        kind: 'connected',
        signInProvider: provider,
        ...accounts[provider],
        providerSubject: 'synthetic-alternate-google-subject',
        address: 'other@example.invalid',
        privateSyncMailboxes: 'other@example.invalid',
      });
    },
  );

  it('publishes the committed Product Account before an interrupted mailbox session and permits retry', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-interrupted');
    const store = createRegistration(session.native);
    await store.register('apple');
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'mailbox-needed', signInProvider: 'apple' },
      failed: true,
    });
    await store.restore();
    await store.authorizeGmail(false);
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'connected' },
      failed: false,
    });
  });

  it.each(['google', 'apple'] as const)(
    'returns quietly to the previous status when %s Product Sign-In is cancelled',
    async (provider) => {
      expect.hasAssertions();
      const session = createMockRegistrationSession('registration-success');
      const store = createRegistration({
        ...session.native,
        signIn: () =>
          Promise.reject(
            Object.assign(new Error('Cancelled'), { code: 'cancelled' }),
          ),
      });
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
    const session = createMockRegistrationSession('registration-success');
    let restores = 0;
    let nativeRestore = session.native.restore;
    const store = createRegistration({
      ...session.native,
      restore: () => {
        restores += 1;
        return nativeRestore();
      },
    });
    await store.register('google');
    expect(store.getSnapshot().snapshot.kind).toBe('connected');
    await store.restoreOnce();
    await store.restoreOnce();
    expect(restores).toBe(1);
    expect(store.getSnapshot().snapshot.kind).toBe('connected');
    nativeRestore = () => Promise.reject(new Error('Synthetic host offline'));
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
    const session = createMockRegistrationSession('registration-success');
    await createRegistration(session.native).register('google');
    let nativeRestore = (): Promise<unknown> =>
      Promise.reject(Object.assign(new Error('locked'), { code: 'locked' }));
    let restores = 0;
    const store = createRegistration({
      ...session.native,
      restore: () => {
        restores += 1;
        return nativeRestore();
      },
    });
    await store.restoreOnce();
    const locked = {
      snapshot: { kind: 'signed-out' },
      busy: false,
      failed: false,
      locked: true,
    };
    expect(store.getSnapshot()).toStrictEqual(locked);
    // Becoming active while still locked keeps the locked state.
    await store.resume();
    expect(store.getSnapshot()).toStrictEqual(locked);
    nativeRestore = session.native.restore;
    await store.resume();
    expect(store.getSnapshot()).toStrictEqual({
      snapshot: {
        kind: 'connected',
        ...accounts.google,
        signInProvider: 'google',
        providerSubject: 'synthetic-google-subject',
        address: 'alex@example.invalid',
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

  it('verifies once per activation however many Mac windows report it', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    let restores = 0;
    const store = createRegistration({
      ...session.native,
      restore: () => {
        restores += 1;
        return session.native.restore();
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
    const session = createMockRegistrationSession('registration-success');
    let { restore } = session.native;
    const store = createRegistration({
      ...session.native,
      restore: () => restore(),
    });
    await store.register('google');
    await store.restoreOnce();
    expect(store.getSnapshot().snapshot.kind).toBe('connected');
    restore = () =>
      Promise.resolve({
        ...accounts.google,
        signInProvider: 'google',
        kind: 'mailbox-needed',
        reason: 'unavailable',
      });
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
    const session = createMockRegistrationSession('registration-success');
    const blocked = Promise.withResolvers<unknown>();
    const started = Promise.withResolvers<boolean>();
    const store = createRegistration({
      ...session.native,
      authorizeGmail: () => {
        started.resolve(true);
        return blocked.promise;
      },
    });
    const registering = store.register('google');
    await started.promise;
    const activating = store.resume();
    blocked.reject(
      Object.assign(new Error('Interrupted'), { code: 'unavailable' }),
    );
    await registering;
    await activating;
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'mailbox-needed', signInProvider: 'google' },
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
      const session = createMockRegistrationSession('registration-success');
      await createRegistration(session.native).register('google');
      const blocked = Promise.withResolvers<unknown>();
      const started = Promise.withResolvers<boolean>();
      const locked = Object.assign(new Error('locked'), { code: 'locked' });
      let nativeRestore = (): Promise<unknown> => Promise.reject(locked);
      const store = createRegistration({
        ...session.native,
        restore: () => nativeRestore(),
      });
      for (let attempt = 0; attempt < previousAttempts; attempt += 1) {
        await store.restoreOnce();
      }
      nativeRestore = () => {
        started.resolve(true);
        return blocked.promise;
      };
      const restoring = store[action]();
      await started.promise;
      // Unlock arrives before the pending native rejection crosses the bridge.
      nativeRestore = session.native.restore;
      const activating = store.resume();
      blocked.reject(locked);
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
    const session = createMockRegistrationSession('registration-success');
    const gate = Promise.withResolvers<undefined>();
    const store = createRegistration({
      ...session.native,
      signIn: async (provider) => {
        await gate.promise;
        return session.native.signIn(provider);
      },
      authorizeGmail: () => Promise.resolve({ kind: 'connected' }),
    });
    const registration = store.register('google');
    await store.authorizeGmail(true);
    expect(store.getSnapshot()).toStrictEqual({
      snapshot: { kind: 'signed-out' },
      busy: true,
      failed: false,
    });
    gate.resolve(undefined);
    await registration;
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'mailbox-needed' },
      busy: false,
      failed: true,
    });
  });

  it('links the other Sign-In Provider explicitly, keeps it across relaunch and opens the same Product Account with it', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-link');
    const store = createRegistration(session.native);
    await store.register('apple');
    // A Gmail grant never links the mailbox's Google identity as a sign-in.
    expect(store.getSnapshot().snapshot).not.toHaveProperty('alternateSignIn');
    await store.link('google');
    const linked = {
      kind: 'connected',
      ...accounts.apple,
      signInProvider: 'apple',
      alternateSignIn: 'google',
      providerSubject: 'synthetic-google-subject',
      address: 'alex@example.invalid',
      privateSyncMailboxes: 'alex@example.invalid',
    };
    expect(store.getSnapshot()).toStrictEqual({
      snapshot: linked,
      busy: false,
      failed: false,
    });
    const relaunched = createRegistration(session.native);
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
    const session = createMockRegistrationSession('registration-success');
    const store = createRegistration(session.native);
    await store.register('google');
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
    const relaunched = createRegistration(session.native);
    await relaunched.restore();
    expect(relaunched.getSnapshot().snapshot).toStrictEqual(presented);
    await relaunched.confirmRecoveryKey(
      syntheticRecoveryKey.slice(-4).toLowerCase(),
    );
    expect(relaunched.getSnapshot()).toStrictEqual({
      snapshot: {
        kind: 'connected',
        productAccountId: 'synthetic-product-account',
        signInProvider: 'google',
        privateSync: 'ready',
        providerSubject: 'synthetic-google-subject',
        address: 'alex@example.invalid',
        privateSyncMailboxes: 'alex@example.invalid',
      },
      busy: false,
      failed: false,
    });
  });

  it.each([
    ['identity-owned', 'identity-owned'],
    ['stale-authentication', 'stale-authentication'],
    ['unavailable', 'failed'],
  ] as const)(
    'reports a %s link rejection without changing the Product Account or logging its message',
    async (code, linkFailure) => {
      expect.hasAssertions();
      const logged: unknown[] = [];
      vi.spyOn(console, 'error').mockImplementation((...values) => {
        logged.push(...values);
      });
      const session = createMockRegistrationSession('registration-success');
      const store = createRegistration({
        ...session.native,
        link: () =>
          Promise.reject(
            Object.assign(new Error('Link rejected for sealed@example.com'), {
              code,
            }),
          ),
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
      expect(logged).toContain(`code ${code}`);
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
    const account = createSyntheticAccount();
    const trusted = createRegistration(
      createMockRegistrationSession('registration-success', account).native,
    );
    const added = createRegistration(
      createMockRegistrationSession('registration-enrollment', account).native,
    );
    await trusted.register('google');
    await added.register('google');
    await trusted.refreshPrivateSync();
    expect(trusted.getSnapshot().snapshot).toMatchObject({
      enrollmentRequest: syntheticEnrollmentRequest,
    });
    await trusted.declineEnrollment(syntheticEnrollmentRequest);
    await trusted.approveEnrollment(
      syntheticEnrollmentRequest,
      syntheticEnrollmentCode,
    );
    expect(trusted.getSnapshot()).toMatchObject({
      enrollmentFailure: 'unavailable',
      snapshot: { privateSync: 'recovery-key' },
    });
    const feedback = trusted.getSnapshot();
    await trusted.resume();
    expect(trusted.getSnapshot()).toStrictEqual(feedback);
    await added.refreshPrivateSync();
    expect(added.getSnapshot().snapshot).toMatchObject({
      privateSync: 'enrollment-pending',
      enrollmentCode: syntheticEnrollmentCode,
    });
    expect(added.getSnapshot().snapshot).not.toHaveProperty(
      'privateSyncMailboxes',
    );
  });

  it('unlocks a new device with the Recovery Key only after a wrong key and an interruption leave it unchanged', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue(undefined);
    const account = createSyntheticAccount();
    const lost = createRegistration(
      createMockRegistrationSession('registration-success', account).native,
    );
    await lost.register('google');
    const session = createMockRegistrationSession(
      'registration-enrollment',
      account,
    );
    // The connection drops while the first attempt checks the key.
    const interrupted = createRegistration({
      ...session.native,
      recoverWithRecoveryKey: () =>
        Promise.reject(
          Object.assign(new Error('Synthetic connection lost'), {
            code: 'unavailable',
          }),
        ),
    });
    await interrupted.register('google');
    await interrupted.recoverWithRecoveryKey(syntheticRecoveryKey);
    const waiting = interrupted.getSnapshot().snapshot;
    expect(interrupted.getSnapshot()).toMatchObject({
      snapshot: { privateSync: 'enrollment-pending' },
      recoveryFailure: 'failed',
    });
    const relaunched = createRegistration(session.native);
    await relaunched.restore();
    expect(relaunched.getSnapshot().snapshot).toStrictEqual(waiting);
    await relaunched.recoverWithRecoveryKey(syntheticEnrollmentCode);
    await relaunched.resume();
    expect(relaunched.getSnapshot()).toStrictEqual({
      snapshot: waiting,
      busy: false,
      failed: false,
      recoveryFailure: 'rejected',
    });
    await relaunched.recoverWithRecoveryKey(
      syntheticRecoveryKey.toLowerCase().replaceAll('-', ' '),
    );
    expect(relaunched.getSnapshot()).toStrictEqual({
      snapshot: {
        kind: 'mailbox-needed',
        productAccountId: 'synthetic-product-account',
        signInProvider: 'google',
        privateSync: 'ready',
        privateSyncMailboxes: 'alex@example.invalid',
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
    const session = createMockRegistrationSession('registration-enrollment');
    const renewedCode =
      'Q7XM-2KTD-9RWP-4HVB-Q7XM-2KTD-9RWP-4HVB-Q7XM-2KTD-9RWP-4HVB-Q7XM-2KT8';
    let shown: RegistrationSnapshot = { kind: 'signed-out' };
    const store = createRegistration({
      ...session.native,
      // The sign-in renewed for the attempt replaced the expired request before the key failed.
      recoverWithRecoveryKey: () =>
        Promise.resolve({
          ...shown,
          enrollmentCode: renewedCode,
          recoveryNotice: 'rejected',
        }),
    });
    await store.register('google');
    shown = store.getSnapshot().snapshot;
    await store.recoverWithRecoveryKey(syntheticEnrollmentCode);
    const { snapshot, recoveryFailure } = store.getSnapshot();
    expect({ snapshot, recoveryFailure }).toStrictEqual({
      snapshot: {
        kind: 'mailbox-needed',
        productAccountId: 'synthetic-product-account',
        signInProvider: 'google',
        privateSync: 'enrollment-pending',
        enrollmentCode: renewedCode,
      },
      recoveryFailure: 'rejected',
    });
  });

  it.each([
    '[{"id":"synthetic-ipad"',
    '[{"id":"","name":"iPad","registeredAt":1}]',
    '{"id":"synthetic-ipad","name":"iPad","registeredAt":1}',
    '[{"id":"synthetic-ipad","name":"iPad","registeredAt":8640000000000001}]',
    '[{"id":"synthetic-ipad","name":"iPad","registeredAt":-8640000000000001}]',
  ])(
    'fails registration for a malformed trusted-device list and recovers on retry: %s',
    async (malformed) => {
      expect.hasAssertions();
      const session = createMockRegistrationSession('registration-revocation');
      let trustedDevices = malformed;
      const store = createRegistration({
        ...session.native,
        signIn: async (provider) => {
          await session.native.signIn(provider);
          return {
            kind: 'mailbox-needed',
            signInProvider: 'google',
            ...accounts.google,
            trustedDevices,
          };
        },
      });
      await store.register('google');
      expect(store.getSnapshot()).toStrictEqual({
        snapshot: { kind: 'signed-out' },
        busy: false,
        failed: true,
      });
      trustedDevices = JSON.stringify([syntheticTrustedDevice]);
      await store.register('google');
      expect(store.getSnapshot()).toStrictEqual({
        snapshot: {
          kind: 'mailbox-needed',
          signInProvider: 'google',
          ...accounts.google,
          trustedDevices,
        },
        busy: false,
        failed: false,
      });
    },
  );

  it('keeps the account when a removal fails', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-revocation');
    const store = createRegistration({
      ...session.native,
      revokeTrustedDevice: () =>
        Promise.reject(new Error('Synthetic removal interrupted')),
    });
    await store.register('google');
    const { snapshot } = store.getSnapshot();
    expect(trustedDevicesOf(snapshot)).toStrictEqual([syntheticTrustedDevice]);
    await store.revokeTrustedDevice(syntheticTrustedDevice.id);
    expect(store.getSnapshot()).toStrictEqual({
      snapshot,
      busy: false,
      failed: false,
      revocationFailed: true,
    });
  });

  it('shows a later removal failure instead of the earlier success, while cancellation stays quiet', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-revocation');
    const otherDevice = {
      ...syntheticTrustedDevice,
      id: 'synthetic-mac',
      name: 'Mac',
    };
    const initial = {
      kind: 'mailbox-needed',
      signInProvider: 'google',
      ...accounts.google,
      trustedDevices: JSON.stringify([syntheticTrustedDevice, otherDevice]),
    } as const;
    const removed = {
      ...initial,
      trustedDevices: JSON.stringify([otherDevice]),
      revocationNotice: 'removed',
    } as const;
    let removal: () => Promise<unknown> = () => Promise.resolve(removed);
    const store = createRegistration({
      ...session.native,
      signIn: () => Promise.resolve(initial),
      revokeTrustedDevice: () => removal(),
    });
    await store.register('google');
    await store.revokeTrustedDevice(syntheticTrustedDevice.id);
    removal = () => Promise.reject(new Error('Synthetic removal interrupted'));
    await store.revokeTrustedDevice(otherDevice.id);
    const failed = store.getSnapshot();
    expect(failed).toStrictEqual({
      snapshot: removed,
      busy: false,
      failed: false,
      revocationFailed: true,
    });
    expect(revocationNotice(removed, failed.revocationFailed === true)).toBe(
      revocationCopy.failed,
    );
    removal = () =>
      Promise.reject(
        Object.assign(new Error('Synthetic cancelled'), { code: 'cancelled' }),
      );
    await store.revokeTrustedDevice(otherDevice.id);
    expect(store.getSnapshot()).toStrictEqual({
      snapshot: removed,
      busy: false,
      failed: false,
    });
    // A removal this device did not complete itself reports no new Recovery Key.
    const unconfirmed = {
      ...removed,
      revocationNotice: 'unconfirmed',
    } as const;
    removal = () => Promise.resolve(unconfirmed);
    await store.revokeTrustedDevice(otherDevice.id);
    expect(store.getSnapshot().snapshot).toStrictEqual(unconfirmed);
  });
});
