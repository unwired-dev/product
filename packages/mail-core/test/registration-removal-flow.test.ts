import * as Vitest from '@effect/vitest';

import type { NativeRegistrationVault } from '../src/registration-flow.ts';
import type { NativeRegistration } from '../src/registration.ts';

import { createRegistrationFlow as registrationPrograms } from '../src/registration-flow.ts';
import { createRegistration, mailboxesOf } from '../src/registration.ts';
import { syntheticRecoveryKey } from '../src/testing/registration-session.ts';
import { createSyntheticVault } from '../src/testing/registration-vault.ts';
import { createRegistrationFlow, launch } from './registration-flow-fixture.ts';

type Registration = NativeRegistration;

describe('registration removal flow', () => {
  it('renews an aged sign-in once before confirming a prepared removal again', async () => {
    expect.hasAssertions();
    const { vault } = createSyntheticVault();
    await createRegistrationFlow(vault).signIn('google');
    const signInIdentity = vi.fn<NativeRegistrationVault['signInIdentity']>(
      (provider, hint) => vault.signInIdentity(provider, hint),
    );
    // The first activation finds the sign-in from preparing no longer recent.
    const confirmRevocation = vi
      .fn<NativeRegistrationVault['confirmRevocation']>()
      .mockRejectedValueOnce(
        Object.assign(new Error('stale'), { code: 'stale-authentication' }),
      )
      .mockResolvedValueOnce({ notice: 'removed' });
    const flow = createRegistrationFlow({
      ...vault,
      signInIdentity,
      revokeTrustedDevice: () => Promise.resolve({}),
      confirmRevocation,
      cancelRevocation: () => Promise.resolve({ notice: 'unconfirmed' }),
    });
    // Preparing asks for a fresh sign-in first and reports no removal yet.
    await expect(
      flow.revokeTrustedDevice('device-ipad'),
    ).resolves.not.toHaveProperty('revocationNotice');
    await expect(flow.confirmRevocation('ABCD')).resolves.toMatchObject({
      revocationNotice: 'removed',
    });
    await expect(flow.cancelRevocation()).resolves.toMatchObject({
      revocationNotice: 'unconfirmed',
    });
    expect({
      signIns: signInIdentity.mock.calls.length,
      confirmations: confirmRevocation.mock.calls,
    }).toStrictEqual({ signIns: 2, confirmations: [['ABCD'], ['ABCD']] });
  });

  // Replaces AccountRemovalTests.interruptedRemovalNeverReopensAccessAndResumesAcknowledgedCleanup.
  const removals = [
    {
      operation: 'signOut',
      remove: (registration: Registration) => registration.signOut(),
      pending: 'sign-out',
      cleaned: { kind: 'signed-out' },
    },
    {
      operation: 'deletion',
      remove: (registration: Registration) =>
        registration.deleteProductAccount(),
      pending: 'deletion',
      cleaned: { kind: 'signed-out', notice: 'deleted' },
    },
  ] as const;
  // An unanswered removal: the backend applied it, the reply was lost, and the device relaunched.
  const interrupted = async (
    provider: 'google' | 'apple',
    { operation, remove, pending }: (typeof removals)[number],
  ) => {
    const launched = launch();
    const { flow, device, google, apple, backend } = launched;
    await flow.signIn(provider);
    // The record as a crash after acknowledgement and vault deletion would leave it.
    const crashed = structuredClone(device.record);
    if (crashed !== undefined) {
      crashed.removal = { operation, acknowledged: true };
    }
    backend.loseReply = true;
    await remove(flow).catch(() => undefined);
    backend.loseReply = false;
    // Every prompt is cancelled; nothing may reopen access while the removal is unanswered.
    google.outcome = 'cancelled';
    apple.outcome = 'cancelled';
    const process = createSyntheticVault({ device, google, apple, backend });
    const relaunched = createRegistrationFlow(process.vault);
    const paused = {
      kind: 'mailbox-needed',
      productAccountId: `account-${provider === 'google' ? google.subject : apple.subject}`,
      signInProvider: provider,
      reason: 'unavailable',
      privateSync: 'unavailable',
      removalPending: pending,
    };
    return {
      ...launched,
      crashed,
      operation,
      process,
      relaunched,
      paused,
    };
  };

  it.each(
    removals.flatMap((removal) =>
      (['google', 'apple'] as const).map((provider) => ({ provider, removal })),
    ),
  )(
    'never reopens $provider access during an unanswered $removal.operation and resumes acknowledged cleanup',
    async ({ provider, removal }) => {
      /* oxlint-disable vitest/max-expects -- One journey proves the pause, the retry and the resumed cleanup. */
      expect.hasAssertions();
      const {
        relaunch,
        device,
        google,
        apple,
        crashed,
        operation,
        process,
        relaunched,
        paused,
      } = await interrupted(provider, removal);
      // The remote step happened, but a lost reply leaves local cleanup unacknowledged.
      expect(device.record?.removal).toStrictEqual({
        operation,
        acknowledged: false,
      });
      await expect(relaunched.restore()).resolves.toStrictEqual(paused);
      await expect(process.vault.registration()).resolves.toMatchObject({
        session: false,
      });
      await expect(relaunched.signIn('google')).resolves.toStrictEqual(paused);
      google.outcome = undefined;
      apple.outcome = undefined;
      await expect(removal.remove(relaunched)).resolves.toStrictEqual(
        removal.cleaned,
      );
      expect(device.record).toBeUndefined();
      // A crash after acknowledgement finishes on relaunch without renewing or prompting.
      device.record = crashed;
      google.outcome = 'cancelled';
      apple.outcome = 'cancelled';
      await expect(relaunch().restore()).resolves.toStrictEqual(
        removal.cleaned,
      );
      expect(device.record).toBeUndefined();
    },
  );

  it.each(['google', 'apple'] as const)(
    'keeps a $0 deletion pending when a retry is refused before fencing anything',
    async (provider) => {
      expect.hasAssertions();
      const { relaunch, device, google, apple, backend, relaunched, paused } =
        await interrupted(provider, removals[1]);
      // A failed revocation probe and a refusal of this retry prove nothing about the earlier
      // deletion whose reply was lost.
      google.outcome = undefined;
      apple.outcome = undefined;
      backend.revocationOffline = true;
      for (const [status, code] of [
        [401, undefined],
        [400, undefined],
        [409, undefined],
        [403, 'PENDING_DEVICE_UNAVAILABLE'],
      ] as const) {
        backend.deletionStatus = status;
        backend.deletionCode = code;
        await expect(relaunched.deleteProductAccount()).rejects.toMatchObject({
          code: 'unavailable',
        });
        expect(device.record?.removal?.operation).toBe('deletion');
        await expect(relaunch().restore()).resolves.toStrictEqual(paused);
      }
    },
  );

  // Replaces AccountRemovalTests.signingOutUnregistersFirstAndAnotherAccountSeesNothingOfTheLast.
  it('signs out only after unregistering and never before the Recovery Key is backed up', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves the backup gate, retry and both device kinds. */
    expect.hasAssertions();
    const { flow, relaunch, otherDevice, device, backend } = launch();
    await flow.signIn('google');
    await flow.addMailbox('gmail', false);
    const installation = device.record?.deviceIdentifier;
    // Signing out cannot discard the only Recovery Key before its backup is confirmed.
    device.recoveryKeyConfirmed = false;
    device.privateSync = {
      privateSync: 'recovery-key',
      recoveryKey: syntheticRecoveryKey,
    };
    await expect(relaunch().signOut()).resolves.toMatchObject({
      recoveryKey: syntheticRecoveryKey,
    });
    expect(backend.unregistered).toHaveLength(0);
    device.recoveryKeyConfirmed = true;
    device.privateSync = { privateSync: 'ready' };
    // Offline, sign-out changes nothing on the backend and can be retried.
    backend.unregisterFailure = 'offline';
    await expect(relaunch().signOut()).rejects.toMatchObject({
      code: 'unavailable',
    });
    expect(device.record).toBeDefined();
    backend.unregisterFailure = undefined;
    await expect(relaunch().signOut()).resolves.toStrictEqual({
      kind: 'signed-out',
    });
    expect(backend.unregistered).toStrictEqual([
      {
        identity: { provider: 'google', subject: 'synthetic-product-subject' },
        installation,
      },
    ]);
    expect(backend.deletions).toHaveLength(0);
    expect(device.record).toBeUndefined();
    await expect(relaunch().restore()).resolves.toStrictEqual({
      kind: 'signed-out',
    });

    // A Pending Device has no keys or Recovery Key to protect; it signs out with its own proof.
    backend.pendingDevices = true;
    const { flow: pending } = otherDevice();
    await expect(pending.signIn('google')).resolves.toMatchObject({
      kind: 'device-pending',
    });
    await expect(pending.signOut()).resolves.toStrictEqual({
      kind: 'signed-out',
    });
    expect(backend.calls.at(-1)).toMatchObject({
      path: 'productAccount:unregisterPendingDevice',
      device: true,
      installation: true,
    });
  });

  // Replaces AccountRemovalTests.appleSignOutAsksAppleAgainForTheSameIdentity.
  it('asks Apple again for the same identity before signing out', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves cancellation, another Apple ID and the sign-out. */
    expect.hasAssertions();
    const { flow, device, apple, backend } = launch();
    await flow.signIn('apple');
    apple.outcome = 'cancelled';
    await expect(flow.signOut()).rejects.toMatchObject({ code: 'cancelled' });
    apple.outcome = undefined;
    apple.subject = 'another-apple-subject';
    await expect(flow.signOut()).rejects.toMatchObject({
      code: 'invalid-identity',
    });
    expect(backend.unregistered).toHaveLength(0);
    expect(device.record).toBeDefined();
    apple.subject = 'synthetic-apple-subject';
    const { signIns } = apple;
    await expect(flow.signOut()).resolves.toStrictEqual({ kind: 'signed-out' });
    expect(apple.signIns).toBe(signIns + 1);
    expect(backend.unregistered[0]?.identity.provider).toBe('apple');
    expect(device.record).toBeUndefined();
  });

  // Replaces AccountRemovalTests.expiredPendingDeviceDeletesWithExistingProofOrRenewsMissingProof.
  const pendingDevice = async () => {
    const { flow, otherDevice, backend } = launch();
    await flow.signIn('google');
    backend.pendingDevices = true;
    const joining = otherDevice();
    await joining.flow.signIn('google');
    return { ...joining, backend };
  };

  it('deletes from an expired Pending Device with its existing proof', async () => {
    expect.hasAssertions();
    const { flow, device, backend } = await pendingDevice();
    // An existing expired proof still permits deletion even when admission is unavailable.
    backend.connectFailure = 'unavailable';
    await expect(flow.deleteProductAccount()).resolves.toStrictEqual({
      kind: 'signed-out',
      notice: 'deleted',
    });
    expect(backend.deleted.has('account-synthetic-product-subject')).toBe(true);
    expect(device.record).toBeUndefined();
  });

  it('renews a missing Pending Device proof before recording deletion intent', async () => {
    expect.hasAssertions();
    const { flow, device, backend } = await pendingDevice();
    const expired = device.record?.product?.trustedDeviceId;
    // Another connection's bounded cleanup removed this expired record.
    backend.pendingExpired = true;
    backend.deletionStatus = 403;
    backend.deletionCode = 'PENDING_DEVICE_UNAVAILABLE';
    await expect(flow.deleteProductAccount()).rejects.toMatchObject({
      code: 'unavailable',
    });
    expect(device.record?.removal).toBeUndefined();
    expect(device.record?.product?.trustedDeviceId).not.toBe(expired);
    backend.deletionStatus = 200;
    await expect(flow.deleteProductAccount()).resolves.toStrictEqual({
      kind: 'signed-out',
      notice: 'deleted',
    });
  });

  // Replaces AccountRemovalTests.deletionNeedsAFreshSignInAndEveryReachableDevicePurges.
  it('deletes only after a fresh sign-in and purges every device that reaches the account', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves each refusal, every device's purge and Apple deletion. */
    expect.hasAssertions();
    const {
      flow: current,
      otherDevice,
      device,
      google,
      apple,
      backend,
    } = launch();
    const { flow: other } = otherDevice();
    await current.signIn('google');
    await other.signIn('google');

    // A cancelled sign-in deletes nothing.
    google.outcome = 'cancelled';
    await expect(current.deleteProductAccount()).rejects.toMatchObject({
      code: 'cancelled',
    });
    google.outcome = undefined;
    expect(backend.deletions).toHaveLength(0);
    // Another identity of the same provider cannot open this account.
    google.subject = 'synthetic-other-subject';
    await expect(current.deleteProductAccount()).rejects.toMatchObject({
      code: 'invalid-identity',
    });
    expect(device.record?.removal).toBeUndefined();
    google.subject = 'synthetic-product-subject';
    // A refusal Convex returns before fencing anything leaves the account open, not pending.
    for (const [status, code, host] of [
      [401, undefined, 'stale-authentication'],
      [400, undefined, 'removal-refused'],
      [403, 'PENDING_DEVICE_UNAVAILABLE', 'unavailable'],
    ] as const) {
      backend.deletionStatus = status;
      backend.deletionCode = code;
      await expect(current.deleteProductAccount()).rejects.toMatchObject({
        code: host,
      });
      expect(device.record?.removal).toBeUndefined();
      await expect(current.restore()).resolves.not.toHaveProperty(
        'removalPending',
      );
    }
    backend.deletionStatus = 200;
    backend.loseReply = true;
    await expect(current.deleteProductAccount()).rejects.toMatchObject({
      code: 'unavailable',
    });
    backend.loseReply = false;

    // Google deletion is confirmed by an interactive sign-in, not a silent renewal.
    const sessions = google.hints.length;
    await expect(current.deleteProductAccount()).resolves.toStrictEqual({
      kind: 'signed-out',
      notice: 'deleted',
    });
    expect(google.hints).toHaveLength(sessions + 1);
    expect(backend.deletions.at(-1)?.provider).toBe('google');
    expect(backend.deletions.at(-1)?.authorizationCode).toBeUndefined();
    expect(device.record).toBeUndefined();
    // Another device of the account purges when it next reaches Convex.
    await expect(other.restore()).resolves.toStrictEqual({
      kind: 'signed-out',
      notice: 'deleted',
    });
    // Signing in again finds the account deleted and keeps nothing.
    await expect(current.signIn('google')).resolves.toStrictEqual({
      kind: 'signed-out',
      notice: 'deleted',
    });
    expect(device.record).toBeUndefined();

    // An account Sign in with Apple also opens is deleted through Apple, with its code. An Apple
    // link this device had not seen is learned from Convex's refusal and used on the next attempt.
    google.subject = 'synthetic-linked-subject';
    await current.signIn('google');
    backend.deletionStatus = 409;
    await expect(current.deleteProductAccount()).rejects.toMatchObject({
      code: 'removal-refused',
    });
    expect(device.record?.removal).toBeUndefined();
    expect(device.record?.product?.signInProviders).toStrictEqual([
      'google',
      'apple',
    ]);
    backend.deletionStatus = 200;
    const { signIns } = apple;
    await expect(current.deleteProductAccount()).resolves.toStrictEqual({
      kind: 'signed-out',
      notice: 'deleted',
    });
    expect(apple.signIns).toBe(signIns + 1);
    expect(backend.deletions.at(-1)).toMatchObject({
      provider: 'apple',
      authorizationCode: `synthetic-apple-code-${apple.signIns}`,
    });
    expect(backend.calls.at(-1)).toMatchObject({
      path: '/product-account/delete',
      identity: true,
      device: true,
      appleAuthorization: true,
    });
  });

  it.each(['google', 'apple'] as const)(
    'purges a revoked %s device before any prompt, and skips the check offline',
    async (provider) => {
      expect.hasAssertions();
      const { flow, relaunch, device, google, apple, backend } = launch();
      await flow.signIn(provider);
      backend.revocationOffline = true;
      await expect(relaunch().restore()).resolves.toMatchObject({
        kind: 'mailbox-needed',
      });
      backend.revocationOffline = false;
      backend.revoked = true;
      // Neither a cancelled prompt nor a revoked provider grant may keep a removed device's data.
      google.outcome = 'cancelled';
      apple.outcome = 'cancelled';
      apple.state = 'revoked';
      await expect(relaunch().signIn(provider)).resolves.toStrictEqual({
        kind: 'signed-out',
        notice: 'revoked',
      });
      expect(device.record).toBeUndefined();
    },
  );

  it.each(['revoked', 'deleted'] as const)(
    'reports a native-initiated %s purge on the next shared operation',
    async (code) => {
      expect.hasAssertions();
      const { vault, device } = createSyntheticVault();
      const registration = vi.fn<NativeRegistrationVault['registration']>(
        vault.registration,
      );
      const store = createRegistration(
        registrationPrograms({
          ...vault,
          registration,
          purge: async (notice) => {
            await vault.purge(notice);
            registration.mockImplementation(vault.registration);
            return null;
          },
        }),
      );
      await store.register('google');
      await store.addMailbox();
      expect(store.getSnapshot().snapshot.kind).toBe('connected');
      const [mailbox] = mailboxesOf(store.getSnapshot().snapshot);
      Vitest.assert.isDefined(mailbox);
      // The APNs callback already cleared native custody, outside the shared action.
      await vault.purge(code);
      registration.mockRejectedValue(
        Object.assign(new Error('Synthetic native rejection'), { code }),
      );
      expect(device.record).toBeUndefined();
      await store.removeMailbox(mailbox.id);
      expect(store.getSnapshot()).toStrictEqual({
        snapshot: { kind: 'signed-out', notice: code },
        busy: false,
        failed: false,
      });
      // Acknowledging the notice leaves a new explicit sign-in usable.
      await store.register('google');
      await store.addMailbox();
      expect(store.getSnapshot().snapshot.kind).toBe('connected');
    },
  );
});
