import * as Vitest from '@effect/vitest';
import * as Effect from 'effect/Effect';
import * as Fiber from 'effect/Fiber';
import * as Schema from 'effect/Schema';

import type { NativeRegistrationVault } from '../src/registration-flow.ts';

import { createRegistrationFlow as registrationPrograms } from '../src/registration-flow.ts';
import {
  createRegistration,
  mailboxesOf,
  RegistrationSnapshotSchema,
} from '../src/registration.ts';
import { createSyntheticVault } from '../src/testing/registration-vault.ts';
import { createRegistrationFlow, launch } from './registration-flow-fixture.ts';

const { it } = Vitest;

const gmailScope = 'https://www.googleapis.com/auth/gmail.modify';
const snapshot = Schema.decodeUnknownSync(RegistrationSnapshotSchema);
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
    // Product Sign-In connects no mailbox until the person chooses one.
    expect(store.getSnapshot().snapshot).toMatchObject({
      kind: 'mailbox-needed',
    });
    expect(store.getSnapshot().snapshot).not.toHaveProperty('reason');
    await store.addMailbox();
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
      await expect(first.addMailbox('gmail', false)).resolves.toMatchObject({
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
    await expect(first.addMailbox('gmail', false)).resolves.toMatchObject({
      kind: 'mailbox-needed',
      reason: 'declined',
    });
    google.scopes = [gmailScope];
    google.gmailAvailable = false;
    await expect(first.addMailbox('gmail', false)).resolves.toMatchObject({
      kind: 'mailbox-needed',
      reason: 'gmail-unavailable',
    });
    google.gmailAvailable = true;
    google.subject = 'synthetic-mailbox-subject';
    google.address = 'same@example.invalid';
    const connected = snapshot(await relaunch().addMailbox('gmail', true));
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
      await expect(first.addMailbox('gmail', true)).rejects.toMatchObject({
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
    await expect(relaunch().addMailbox('gmail', true)).resolves.toMatchObject({
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
    const declined = snapshot(await relaunch().addMailbox('gmail', false));
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
    const connected = snapshot(await relaunch().addMailbox('gmail', false));
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
    await expect(relaunch().addMailbox('gmail', false)).resolves.toStrictEqual(
      connected,
    );
    apple.state = 'revoked';
    await expect(relaunch().restore()).resolves.toStrictEqual({
      kind: 'mailbox-needed',
      ...account,
      reason: 'unavailable',
    });
    await expect(relaunch().addMailbox('gmail', false)).resolves.toMatchObject({
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
    await expect(relaunch().addMailbox('gmail', false)).rejects.toMatchObject({
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
    const connected = snapshot(await relaunch().addMailbox('gmail', false));
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
