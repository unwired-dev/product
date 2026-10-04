import type { RegistrationSnapshot } from '../src/registration.ts';

import { createRegistration } from '../src/registration.ts';
import {
  createMockRegistrationSession,
  createSyntheticAccount,
  syntheticEnrollmentCode,
  syntheticEnrollmentRequest,
  syntheticRecoveryKey,
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
});
