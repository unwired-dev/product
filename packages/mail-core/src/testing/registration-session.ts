import * as Schema from 'effect/Schema';

import type {
  NativeRegistration,
  RegistrationSnapshot,
  SignInProvider,
} from '../registration.ts';

const Scenario = Schema.Literals([
  'registration-cancelled',
  'registration-declined',
  'registration-no-gmail',
  'registration-interrupted',
  'registration-success',
  'registration-link',
  // The synthetic Product Account already has Product Sync keys on another device.
  'registration-enrollment',
]);

// A well-formed synthetic Recovery Key; it protects nothing.
export const syntheticRecoveryKey =
  'K7QM-2VXH-9D4T-RW8B-3NZC-6PJF-1GSA-5EYK-0MQT-4HBV-8XRD-2CWN-7G0P';

const rejection = (message: string, code: string) =>
  Promise.reject(Object.assign(new Error(message), { code }));

type SignedIn = Exclude<RegistrationSnapshot, { kind: 'signed-out' }>;
const account = (snapshot: SignedIn) => ({
  productAccountId: snapshot.productAccountId,
  signInProvider: snapshot.signInProvider,
  ...(snapshot.alternateSignIn === undefined
    ? {}
    : { alternateSignIn: snapshot.alternateSignIn }),
  ...(snapshot.contactEmail === undefined
    ? {}
    : { contactEmail: snapshot.contactEmail }),
  ...(snapshot.privateSync === undefined
    ? {}
    : { privateSync: snapshot.privateSync }),
  ...(snapshot.recoveryKey === undefined
    ? {}
    : { recoveryKey: snapshot.recoveryKey }),
  ...(snapshot.privateSyncMailboxes === undefined
    ? {}
    : { privateSyncMailboxes: snapshot.privateSyncMailboxes }),
});

// Scenarios whose first Gmail session grants access; the others need another mailbox.
const grantsFirstMailbox = new Set<typeof Scenario.Type>([
  'registration-success',
  'registration-link',
  'registration-enrollment',
  'registration-interrupted',
]);

const connectedTo = (
  snapshot: SignedIn,
  reselect: boolean,
): RegistrationSnapshot => {
  const address = reselect ? 'other@example.invalid' : 'alex@example.invalid';
  return {
    kind: 'connected',
    ...account(snapshot),
    providerSubject: reselect
      ? 'synthetic-alternate-google-subject'
      : 'synthetic-google-subject',
    address,
    // Only a device holding the account keys reads back the encrypted descriptor.
    ...(snapshot.privateSync === 'enrollment-needed'
      ? {}
      : { privateSyncMailboxes: address }),
  };
};

export function createMockRegistrationSession(selection: unknown) {
  // oxlint-disable-next-line node/no-sync -- Fixed test-only scenario selection.
  const scenario = Schema.decodeUnknownSync(Scenario)(selection);
  let snapshot: RegistrationSnapshot = { kind: 'signed-out' };
  let attempted = false;
  // Each synthetic sign-in identity owns its own Product Account, except the
  // unregistered identity that the link scenario adds to the first account.
  const accounts = {
    google: { productAccountId: 'synthetic-product-account' },
    apple: {
      productAccountId: 'synthetic-apple-product-account',
      contactEmail: 'relay@privaterelay.example.invalid',
    },
  } as const satisfies Record<SignInProvider, object>;
  const native: NativeRegistration = {
    restore: () => Promise.resolve(snapshot),
    signIn: (provider) => {
      if (snapshot.kind === 'signed-out') {
        // A new Product Account creates its keys; an existing one needs enrollment instead.
        snapshot = {
          kind: 'mailbox-needed',
          signInProvider: provider,
          ...accounts[provider],
          ...(scenario === 'registration-enrollment'
            ? { privateSync: 'enrollment-needed' }
            : {
                privateSync: 'recovery-key',
                recoveryKey: syntheticRecoveryKey,
              }),
        };
        return Promise.resolve(snapshot);
      }
      if (snapshot.signInProvider === provider) {
        snapshot = { kind: 'mailbox-needed', ...account(snapshot) };
        return Promise.resolve(snapshot);
      }
      if (snapshot.alternateSignIn !== provider) {
        return rejection(
          'Synthetic identity is not linked',
          'invalid-identity',
        );
      }
      // A Linked Sign-In opens the same Product Account on this device.
      snapshot = {
        kind: 'mailbox-needed',
        ...account(snapshot),
        signInProvider: provider,
        alternateSignIn: snapshot.signInProvider,
      };
      return Promise.resolve(snapshot);
    },
    authorizeGmail: (reselect) => {
      if (snapshot.kind === 'signed-out') {
        return Promise.reject(new Error('Synthetic Product Account required'));
      }
      if (scenario === 'registration-interrupted' && !attempted) {
        attempted = true;
        return Promise.reject(new Error('Synthetic authorization interrupted'));
      }
      if (!reselect && !grantsFirstMailbox.has(scenario)) {
        return Promise.resolve(snapshot);
      }
      snapshot = connectedTo(snapshot, reselect);
      return Promise.resolve(snapshot);
    },
    link: (provider) => {
      if (
        snapshot.kind === 'signed-out' ||
        snapshot.signInProvider === provider
      ) {
        return rejection('Synthetic Product Account required', 'unavailable');
      }
      if (scenario !== 'registration-link') {
        return rejection(
          'Synthetic identity owns another Product Account',
          'identity-owned',
        );
      }
      snapshot = { ...snapshot, alternateSignIn: provider };
      return Promise.resolve(snapshot);
    },
    confirmRecoveryKey: (entry) => {
      if (
        snapshot.kind === 'signed-out' ||
        snapshot.privateSync !== 'recovery-key'
      ) {
        return rejection('Synthetic Recovery Key unavailable', 'unavailable');
      }
      if (entry.trim().toUpperCase() !== syntheticRecoveryKey.slice(-4)) {
        return rejection(
          'Synthetic Recovery Key mismatch',
          'recovery-key-mismatch',
        );
      }
      const { recoveryKey: _recoveryKey, ...confirmed } = snapshot;
      snapshot = { ...confirmed, privateSync: 'ready' };
      return Promise.resolve(snapshot);
    },
  };
  return Object.freeze({ native });
}
