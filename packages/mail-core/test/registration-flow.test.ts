import * as Vitest from '@effect/vitest';
import * as Effect from 'effect/Effect';
import * as Fiber from 'effect/Fiber';
import * as Schema from 'effect/Schema';

import type { NativeRegistrationVault } from '../src/registration-flow.ts';
import type { NativeRegistration } from '../src/registration.ts';

import { createRegistrationFlow as registrationPrograms } from '../src/registration-flow.ts';
import {
  createRegistration,
  mailboxesOf,
  RegistrationSnapshotSchema,
} from '../src/registration.ts';
import { syntheticRecoveryKey } from '../src/testing/registration-session.ts';
import {
  createSyntheticDevice,
  createSyntheticVault,
} from '../src/testing/registration-vault.ts';

const { it } = Vitest;

// Promise adapter for the flow journeys; production composes these programs in the store.
const createRegistrationFlow = (
  vault: NativeRegistrationVault,
): NativeRegistration => {
  const flow = registrationPrograms(vault);
  return {
    restore: () => Effect.runPromise(flow.restore()),
    signIn: (provider) => Effect.runPromise(flow.signIn(provider)),
    addMailbox: (chooseAccount) =>
      Effect.runPromise(flow.addMailbox(chooseAccount)),
    authorizeGmail: (connection) =>
      Effect.runPromise(flow.authorizeGmail(connection)),
    removeMailbox: (connection) =>
      Effect.runPromise(flow.removeMailbox(connection)),
    link: (provider) => Effect.runPromise(flow.link(provider)),
    confirmRecoveryKey: (entry) =>
      Effect.runPromise(flow.confirmRecoveryKey(entry)),
    recoverWithRecoveryKey: (entry) =>
      Effect.runPromise(flow.recoverWithRecoveryKey(entry)),
    approveEnrollment: (requestId, code) =>
      Effect.runPromise(flow.approveEnrollment(requestId, code)),
    declineEnrollment: (requestId) =>
      Effect.runPromise(flow.declineEnrollment(requestId)),
    revokeTrustedDevice: (trustedDeviceId) =>
      Effect.runPromise(flow.revokeTrustedDevice(trustedDeviceId)),
    refreshPrivateSync: () => Effect.runPromise(flow.refreshPrivateSync()),
    signOut: () => Effect.runPromise(flow.signOut()),
    deleteProductAccount: () => Effect.runPromise(flow.deleteProductAccount()),
  };
};

// The registration flow over the synthetic native vault. Each relaunch is a new process over the
// same device Keychain, providers and backend.
const launch = () => {
  const synthetic = createSyntheticVault();
  return {
    ...synthetic,
    flow: createRegistrationFlow(synthetic.vault),
    relaunch: () =>
      createRegistrationFlow(createSyntheticVault(synthetic).vault),
    // Another installation signing in to the same backend with the same providers.
    otherDevice: () => {
      const other = createSyntheticVault({
        ...createSyntheticDevice(),
        google: synthetic.google,
        apple: synthetic.apple,
        backend: synthetic.backend,
      });
      return { ...other, flow: createRegistrationFlow(other.vault) };
    },
  };
};
const gmailScope = 'https://www.googleapis.com/auth/gmail.modify';
const snapshot = Schema.decodeUnknownSync(RegistrationSnapshotSchema);
type Registration = NativeRegistration;
const addresses = (snapshot: Parameters<typeof mailboxesOf>[0]) =>
  mailboxesOf(snapshot).map(({ address, state }) => ({ address, state }));

describe('registration flow', () => {
  it.effect(
    'does not save an identity after its owning flow is interrupted',
    () =>
      Effect.gen(function* () {
        /* oxlint-disable vitest/no-standalone-expect -- Oxlint does not recognize @effect/vitest's effect test callback. */
        expect.hasAssertions();
        const { vault, device } = createSyntheticVault();
        const signedIn = Promise.withResolvers<unknown>();
        const started = Promise.withResolvers<undefined>();
        const flow = registrationPrograms({
          ...vault,
          signInIdentity: () => {
            started.resolve(undefined);
            return signedIn.promise;
          },
        });
        const fiber = yield* Effect.forkChild(flow.signIn('google'));
        yield* Effect.promise(() => started.promise);
        yield* Fiber.interrupt(fiber);
        signedIn.resolve({ matches: false });
        yield* Effect.yieldNow;
        expect(device.record).toBeUndefined();
      }),
  );

  it('composes the vault flow with the shared store through registration, offline restore and sign-out', async () => {
    expect.hasAssertions();
    const { vault, backend } = createSyntheticVault();
    const store = createRegistration(registrationPrograms(vault));
    await store.restore();
    await store.register('google');
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'connected', signInProvider: 'google' },
      failed: false,
    });
    backend.offline = true;
    await store.resume();
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'cached' },
      failed: false,
    });
    backend.offline = false;
    await store.signOut();
    expect(store.getSnapshot()).toStrictEqual({
      snapshot: { kind: 'signed-out' },
      busy: false,
      failed: false,
    });
  });

  it('logs a recovered malformed native reply without logging its input', async () => {
    expect.hasAssertions();
    const { vault } = createSyntheticVault();
    const malformed = vi.fn<NativeRegistrationVault['renewIdentity']>(
      vault.renewIdentity,
    );
    const store = createRegistration(
      registrationPrograms({ ...vault, renewIdentity: malformed }),
    );
    await store.register('google');
    malformed.mockResolvedValue({ matches: 'private-input' });
    const error = vi.spyOn(console, 'error').mockReturnValue(undefined);
    try {
      await store.resume();
      expect(store.getSnapshot().snapshot).toMatchObject({
        kind: 'mailbox-needed',
        reason: 'unavailable',
      });
      const logged = JSON.stringify(error.mock.calls);
      expect(logged).toContain('Registration reply unreadable:');
      expect(logged).toContain('invalid at matches');
      expect(logged).not.toContain('private-input');
    } finally {
      error.mockRestore();
    }
  });

  // Replaces RegistrationTests.googleRegistrationRetainsAccountAcrossConsentFailuresAndReselection.
  it('keeps the Google Product Account across Gmail consent failures and mailbox reselection', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves each consent failure and the reselected mailbox. */
    expect.hasAssertions();
    const { flow: first, relaunch, google } = launch();
    google.scopes = [];
    const registered = await first.signIn('google');
    expect(registered).toStrictEqual({
      kind: 'mailbox-needed',
      productAccountId: 'account-synthetic-product-subject',
      signInProvider: 'google',
    });
    for (const failure of ['cancelled', 'declined', 'gmail-unavailable']) {
      google.outcome = failure;
      await expect(first.addMailbox(false)).resolves.toMatchObject({
        kind: 'mailbox-needed',
        productAccountId: 'account-synthetic-product-subject',
        reason: failure,
      });
      await expect(relaunch().restore()).resolves.toMatchObject({
        kind: 'mailbox-needed',
      });
    }
    google.outcome = undefined;
    // A signed-in Google identity with missing mail scopes cannot connect Gmail.
    await expect(first.addMailbox(false)).resolves.toMatchObject({
      kind: 'mailbox-needed',
      reason: 'declined',
    });
    google.scopes = [gmailScope];
    google.gmailAvailable = false;
    await expect(first.addMailbox(false)).resolves.toMatchObject({
      kind: 'mailbox-needed',
      reason: 'gmail-unavailable',
    });
    google.gmailAvailable = true;
    google.subject = 'synthetic-mailbox-subject';
    google.address = 'same@example.invalid';
    const connected = snapshot(await relaunch().addMailbox(true));
    expect(connected).toMatchObject({
      kind: 'connected',
      productAccountId: 'account-synthetic-product-subject',
      signInProvider: 'google',
    });
    expect(addresses(connected)).toStrictEqual([
      { address: 'same@example.invalid', state: 'connected' },
    ]);
    await expect(relaunch().restore()).resolves.toStrictEqual(connected);
    // A failed addition of another mailbox is reported without dropping the connected one.
    for (const failure of ['cancelled', 'declined', 'gmail-unavailable']) {
      google.outcome = failure;
      await expect(first.addMailbox(true)).rejects.toMatchObject({
        code: failure,
      });
      await expect(relaunch().restore()).resolves.toStrictEqual(connected);
    }
    google.outcome = undefined;
    google.gmailAvailable = false;
    await expect(relaunch().restore()).resolves.toMatchObject({
      kind: 'mailbox-needed',
      reason: 'gmail-unavailable',
    });
  });

  // Replaces RegistrationTests.interruptedGoogleRegistrationResumesWithoutReplacingIdentityOrExistingInbox.
  it('resumes an interrupted Google registration without replacing its Product identity', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves the interruption, offline restore and replacement refusals. */
    expect.hasAssertions();
    const { flow, relaunch, device, google, backend } = launch();
    backend.offline = true;
    await expect(flow.signIn('google')).rejects.toMatchObject({
      code: 'unavailable',
    });
    // The sign-in is saved before the backend request, so it survives the interruption.
    const installation = device.record?.deviceIdentifier;
    expect(device.record?.subject).toBe('synthetic-product-subject');
    backend.offline = false;
    await expect(relaunch().restore()).resolves.toStrictEqual({
      kind: 'mailbox-needed',
      productAccountId: 'account-synthetic-product-subject',
      signInProvider: 'google',
    });
    // Offline, the renewed sign-in is still saved and the retained Product Account stays usable.
    const renewed = device.record?.credential;
    backend.offline = true;
    await expect(relaunch().restore()).resolves.toStrictEqual({
      kind: 'mailbox-needed',
      productAccountId: 'account-synthetic-product-subject',
      signInProvider: 'google',
      reason: 'unavailable',
    });
    expect(device.record?.credential).not.toBe(renewed);
    // A Product identity failure before mailbox selection reports the retained account.
    await expect(relaunch().addMailbox(true)).resolves.toMatchObject({
      kind: 'mailbox-needed',
      reason: 'interrupted',
    });
    backend.offline = false;
    // Another identity cannot replace the committed Product Account or its installation.
    google.subject = 'different-product-subject';
    await expect(relaunch().signIn('google')).rejects.toMatchObject({
      code: 'invalid-identity',
    });
    expect(device.record?.subject).toBe('synthetic-product-subject');
    expect(device.record?.deviceIdentifier).toBe(installation);
    // A record for another Google client is ignored rather than blocking a new sign-in.
    device.clientID = 'rotated-client';
    await expect(relaunch().restore()).resolves.toStrictEqual({
      kind: 'signed-out',
    });
    await expect(relaunch().signIn('google')).resolves.toMatchObject({
      kind: 'mailbox-needed',
      productAccountId: 'account-different-product-subject',
    });
  });

  // Replaces RegistrationTests.appleRegistrationContinuesIntoGmailWithoutLinkingIdentities.
  it('continues Apple registration into Gmail without linking identities', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves the Apple account, its Gmail consent and revocation. */
    expect.hasAssertions();
    const { flow, relaunch, device, google, apple, backend } = launch();
    apple.outcome = 'cancelled';
    await expect(flow.signIn('apple')).rejects.toMatchObject({
      code: 'cancelled',
    });
    expect(device.record).toBeUndefined();
    apple.outcome = undefined;
    const account = {
      productAccountId: 'account-synthetic-apple-subject',
      signInProvider: 'apple',
      contactEmail: 'relay@privaterelay.example.invalid',
    } as const;
    await expect(relaunch().signIn('apple')).resolves.toStrictEqual({
      kind: 'mailbox-needed',
      ...account,
    });
    // Apple sign-in grants no mail scope; the first Gmail session is declined here.
    google.scopes = [];
    const declined = snapshot(await relaunch().addMailbox(false));
    expect(declined).toStrictEqual({
      kind: 'mailbox-needed',
      ...account,
      reason: 'declined',
    });
    // Restoring checks Apple's credential state without renewing the backend session.
    await expect(relaunch().restore()).resolves.toStrictEqual(declined);
    // The Gmail account's address matches the relay address but is not a Linked Sign-In.
    google.scopes = [gmailScope];
    google.subject = 'synthetic-mailbox-subject';
    google.address = 'relay@privaterelay.example.invalid';
    const connected = snapshot(await relaunch().addMailbox(false));
    expect(connected).toMatchObject({ kind: 'connected', ...account });
    expect(addresses(connected)).toStrictEqual([
      { address: 'relay@privaterelay.example.invalid', state: 'connected' },
    ]);
    await expect(relaunch().restore()).resolves.toStrictEqual(connected);
    // Neither the Apple identity nor its address is used to choose a Google mailbox.
    expect(google.hints).toStrictEqual([undefined, undefined]);
    expect(backend.connected.map(({ provider }) => provider)).toStrictEqual([
      'apple',
    ]);
    // A committed Apple Product Account is not reachable through Google without explicit linking.
    await expect(relaunch().signIn('google')).rejects.toMatchObject({
      code: 'invalid-identity',
    });
    // Reauthentication keeps the address Apple returned on first authorization.
    await expect(relaunch().signIn('apple')).resolves.toMatchObject({
      contactEmail: account.contactEmail,
    });
    await expect(relaunch().addMailbox(false)).resolves.toStrictEqual(
      connected,
    );
    apple.state = 'revoked';
    await expect(relaunch().restore()).resolves.toStrictEqual({
      kind: 'mailbox-needed',
      ...account,
      reason: 'unavailable',
    });
    await expect(relaunch().addMailbox(false)).resolves.toMatchObject({
      reason: 'unavailable',
    });
    expect(device.record?.product?.productAccountId).toBe(
      account.productAccountId,
    );
  });

  // Replaces RegistrationTests.interruptedAppleRegistrationRestartsWithoutAnUncommittedAccount.
  it('restarts an interrupted Apple registration without an uncommitted account', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves the interruption and the fresh start. */
    expect.hasAssertions();
    const { flow, relaunch, device, backend } = launch();
    backend.offline = true;
    await expect(flow.signIn('apple')).rejects.toMatchObject({
      code: 'unavailable',
    });
    expect(device.record?.provider).toBe('apple');
    // Only an interactive Apple session can finish it, so restore reports the sign-in step.
    await expect(relaunch().restore()).resolves.toStrictEqual({
      kind: 'signed-out',
    });
    await expect(relaunch().addMailbox(false)).rejects.toMatchObject({
      code: 'unavailable',
    });
    backend.offline = false;
    // No Product Account was committed, so another Sign-In Provider may start fresh.
    await expect(relaunch().signIn('google')).resolves.toMatchObject({
      productAccountId: 'account-synthetic-product-subject',
      signInProvider: 'google',
    });
    expect(device.record?.contactEmail).toBeUndefined();
  });

  // Replaces RegistrationTests.linkingVerifiesBothIdentitiesAndOpensTheSameAccountFromEitherProvider.
  it('links after verifying both identities and opens the account from either provider', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves both verifications and each provider's access. */
    expect.hasAssertions();
    const { flow, relaunch, otherDevice, google, apple, backend } = launch();
    await flow.signIn('apple');
    google.subject = 'synthetic-mailbox-subject';
    const connected = snapshot(await relaunch().addMailbox(false));
    expect(connected.kind).toBe('connected');
    // The Gmail grant is a Mailbox Connection, never a Linked Sign-In.
    expect(connected).not.toHaveProperty('alternateSignIn');
    expect(backend.owners.has('synthetic-mailbox-subject')).toBe(false);

    // Cancelling the second identity leaves the account unchanged.
    google.subject = 'synthetic-linked-subject';
    google.outcome = 'cancelled';
    await expect(relaunch().link('google')).rejects.toMatchObject({
      code: 'cancelled',
    });
    await expect(relaunch().restore()).resolves.toStrictEqual(connected);
    google.outcome = undefined;
    google.hints.length = 0;
    const linked = snapshot(await relaunch().link('google'));
    expect(linked).toStrictEqual({ ...connected, alternateSignIn: 'google' });
    // Both identities were verified interactively; the mailbox never hinted the linked one.
    expect(backend.verified).toStrictEqual([
      'synthetic-apple-subject',
      'synthetic-apple-subject',
      'synthetic-linked-subject',
    ]);
    expect(google.hints).toStrictEqual([undefined]);
    await expect(relaunch().restore()).resolves.toStrictEqual(linked);
    // Linking again reports the existing link without another Google session.
    await expect(relaunch().link('google')).resolves.toStrictEqual(linked);
    expect(google.hints).toStrictEqual([undefined]);

    // On another installation the linked Google identity opens the same Product Account.
    await expect(otherDevice().flow.signIn('google')).resolves.toMatchObject({
      productAccountId: 'account-synthetic-apple-subject',
      signInProvider: 'google',
      alternateSignIn: 'apple',
    });

    // When Apple is revoked here, the Linked Sign-In recovers this device's account.
    apple.state = 'revoked';
    await expect(relaunch().restore()).resolves.toMatchObject({
      reason: 'unavailable',
    });
    // The connected mailbox is rechecked, not reauthorized, after switching sign-ins.
    google.hints.length = 0;
    await expect(relaunch().signIn('google')).resolves.toStrictEqual({
      ...connected,
      signInProvider: 'google',
      alternateSignIn: 'apple',
    });
    expect(google.hints).toStrictEqual([undefined]);
  });

  // Replaces RegistrationTests.linkingRejectsOwnedIdentitiesStaleSessionsAndUnlinkedSwitches.
  it('refuses owned identities, stale sessions and unlinked switches', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves each refusal leaves the account unchanged. */
    expect.hasAssertions();
    const { flow, apple, backend } = launch();
    // This Google identity already registered its own Product Account elsewhere.
    backend.owners.set(
      'synthetic-product-subject',
      'account-synthetic-product-subject',
    );
    backend.linked.set('account-synthetic-product-subject', ['google']);
    const registered = snapshot(await flow.signIn('apple'));
    // An unlinked provider cannot reach the committed account or create another one.
    await expect(flow.signIn('google')).rejects.toMatchObject({
      code: 'invalid-identity',
    });
    await expect(flow.link('google')).rejects.toMatchObject({
      code: 'identity-owned',
    });
    backend.stale = true;
    await expect(flow.link('google')).rejects.toMatchObject({
      code: 'stale-authentication',
    });
    // A different Apple ID cannot vouch for this Product Account.
    backend.stale = false;
    apple.subject = 'another-apple-subject';
    await expect(flow.link('google')).rejects.toMatchObject({
      code: 'invalid-identity',
    });
    await expect(flow.restore()).resolves.toStrictEqual(registered);
    expect(backend.linked.get('account-synthetic-apple-subject')).toStrictEqual(
      ['apple'],
    );
    expect(backend.owners.size).toBe(2);
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
    await flow.addMailbox(false);
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

  // Covers the Convex transport that moved from the Swift bridge, as #715 asked.
  it('decodes Convex replies and keeps the fixed rejection codes and texts', async () => {
    /* oxlint-disable vitest/max-expects -- One table proves every reply shape and host code. */
    expect.hasAssertions();
    const { vault, flow } = launch();
    await flow.signIn('google');
    const replying = (status: number, body: string) =>
      createRegistrationFlow({
        ...vault,
        call: () => Promise.resolve({ status, body }),
      } satisfies NativeRegistrationVault);
    const error = (code: string) =>
      JSON.stringify({ status: 'error', errorData: { code } });
    // Application errors carry their code whatever the HTTP status.
    for (const [status, body, code] of [
      [400, error('SIGN_IN_IDENTITY_OWNED'), 'identity-owned'],
      [200, error('SIGN_IN_PROVIDER_ALREADY_LINKED'), 'identity-owned'],
      [
        500,
        error('SIGN_IN_RECENT_AUTHENTICATION_REQUIRED'),
        'stale-authentication',
      ],
      [200, error('SIGN_IN_LINK_EXPIRED'), 'stale-authentication'],
      [200, error('SIGN_IN_NOT_LINKED'), 'invalid-identity'],
      // The flow's own distinctions reach hosts as their established codes.
      [200, error('PENDING_DEVICE_UNAVAILABLE'), 'unavailable'],
      // Unknown codes and malformed replies close the boundary.
      [200, error('SOMETHING_NEW'), 'unavailable'],
      [200, error('toString'), 'unavailable'],
      [200, 'not json', 'unavailable'],
      [
        200,
        JSON.stringify({
          status: 'success',
          value: { linkTicket: null, signInProviders: ['google', 'apple'] },
        }),
        'unavailable',
      ],
      [500, JSON.stringify({ status: 'success', value: {} }), 'unavailable'],
      [200, JSON.stringify({ status: 'success', value: {} }), 'unavailable'],
    ] as const) {
      await expect(replying(status, body).link('apple')).rejects.toMatchObject({
        code,
        message:
          'Registration could not finish. Retry with your saved account.',
      });
    }
    // The request names only non-secret arguments and the credentials native code attaches.
    const requests: unknown[] = [];
    await createRegistrationFlow({
      ...vault,
      call: (request) => {
        requests.push(request);
        return Promise.resolve({
          status: 200,
          body: error('SIGN_IN_NOT_LINKED'),
        });
      },
    })
      .link('apple')
      .catch(() => undefined);
    expect(requests).toStrictEqual([
      {
        endpoint: 'query',
        path: 'productAccount:isTrustedDeviceRevoked',
        args: { productAccountId: 'account-synthetic-product-subject' },
        device: true,
      },
      {
        endpoint: 'action',
        path: '/sign-in-links/request',
        args: { provider: 'apple' },
        identity: true,
        device: true,
      },
    ]);
    // Native rejections keep their codes and fixed texts.
    await expect(
      createRegistrationFlow({
        ...vault,
        signInIdentity: () =>
          Promise.reject(
            Object.assign(new Error('SDK detail'), { code: 'cancelled' }),
          ),
      }).link('apple'),
    ).rejects.toMatchObject({
      code: 'cancelled',
      message: 'Sign-in was cancelled.',
    });
    await expect(
      createRegistrationFlow({
        ...vault,
        registration: () =>
          Promise.reject(
            Object.assign(new Error('Keychain detail'), { code: 'locked' }),
          ),
      }).restore(),
    ).rejects.toMatchObject({
      code: 'locked',
      message: 'Unlock your device to open your saved account.',
    });
    // A malformed native projection fails closed.
    await expect(
      createRegistrationFlow({
        ...vault,
        registration: () =>
          Promise.resolve({
            signInProvider: 'google',
            mailboxes: 'unexpected',
          }),
      }).restore(),
    ).rejects.toMatchObject({ code: 'unavailable' });
    await expect(
      createRegistrationFlow({
        ...vault,
        forgetMailboxAccess: () => Promise.resolve('unexpected'),
      }).restore(),
    ).rejects.toMatchObject({ code: 'unavailable' });
  });
});
