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

// The code a synthetic new device shows for approval; it protects nothing.
export const syntheticEnrollmentCode =
  'H4KP-9QWE-3TRM-7XB2-H4KP-9QWE-3TRM-7XB2-H4KP-9QWE-3TRM-7XB2-H4KP-9QW8';

export const syntheticEnrollmentRequest = 'synthetic-enrollment-request';
const normalizedCode = (code: string) =>
  code.replaceAll(/[\s-]/gu, '').toUpperCase();

interface SyntheticAccountState {
  enrollment: undefined | { state: 'pending' | 'approved' | 'cancelled' };
  mailboxes: Set<string>;
}

// Installations share transport state, while each verified Product Account keeps its own data.
export function createSyntheticAccount() {
  return new Map<string, SyntheticAccountState>();
}
type SyntheticAccount = ReturnType<typeof createSyntheticAccount>;

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
  ...(snapshot.enrollmentCode === undefined
    ? {}
    : { enrollmentCode: snapshot.enrollmentCode }),
});

// Scenarios whose first Gmail session grants access; the others need another mailbox.
const grantsFirstMailbox = new Set<typeof Scenario.Type>([
  'registration-success',
  'registration-link',
  'registration-interrupted',
]);

const withoutRequest = (snapshot: SignedIn): SignedIn => {
  const {
    enrollmentRequest: _request,
    enrollmentDevice: _device,
    ...rest
  } = snapshot;
  return rest;
};

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
    ...(snapshot.privateSync === 'enrollment-pending'
      ? {}
      : { privateSyncMailboxes: address }),
  };
};

export function createMockRegistrationSession(
  selection: unknown,
  installations: SyntheticAccount = createSyntheticAccount(),
) {
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
  const syncAccount = (id: string): SyntheticAccountState => {
    const existing = installations.get(id);
    if (existing !== undefined) {
      return existing;
    }
    const created: SyntheticAccountState = {
      enrollment: undefined,
      mailboxes: new Set<string>(),
    };
    installations.set(id, created);
    return created;
  };
  const native: NativeRegistration = {
    restore: () => Promise.resolve(snapshot),
    signIn: (provider) => {
      if (snapshot.kind === 'signed-out') {
        // A new Product Account creates its keys; an existing one asks a trusted device.
        if (scenario === 'registration-enrollment') {
          syncAccount(accounts[provider].productAccountId).enrollment = {
            state: 'pending',
          };
        }
        snapshot = {
          kind: 'mailbox-needed',
          signInProvider: provider,
          ...accounts[provider],
          ...(scenario === 'registration-enrollment'
            ? {
                privateSync: 'enrollment-pending',
                enrollmentCode: syntheticEnrollmentCode,
              }
            : {
                privateSync: 'recovery-key',
                recoveryKey: syntheticRecoveryKey,
              }),
        };
        return Promise.resolve(snapshot);
      }
      if (snapshot.signInProvider === provider) {
        // A saved mailbox that still verifies stays connected.
        if (snapshot.kind !== 'connected') {
          snapshot = { kind: 'mailbox-needed', ...account(snapshot) };
        }
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
      const connected = connectedTo(snapshot, reselect);
      if (
        connected.kind === 'connected' &&
        connected.privateSyncMailboxes !== undefined
      ) {
        syncAccount(connected.productAccountId).mailboxes.add(
          connected.address,
        );
      }
      snapshot = connected;
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
    approveEnrollment: (requestId, code) => {
      if (
        snapshot.kind === 'signed-out' ||
        snapshot.enrollmentRequest !== requestId
      ) {
        return rejection(
          'Synthetic request unavailable',
          'enrollment-unavailable',
        );
      }
      if (normalizedCode(code) !== normalizedCode(syntheticEnrollmentCode)) {
        return rejection('Synthetic code mismatch', 'enrollment-code-invalid');
      }
      syncAccount(snapshot.productAccountId).enrollment = { state: 'approved' };
      snapshot = withoutRequest(snapshot);
      return Promise.resolve(snapshot);
    },
    declineEnrollment: (requestId) => {
      if (
        snapshot.kind === 'signed-out' ||
        snapshot.enrollmentRequest !== requestId
      ) {
        return rejection(
          'Synthetic request unavailable',
          'enrollment-unavailable',
        );
      }
      syncAccount(snapshot.productAccountId).enrollment = {
        state: 'cancelled',
      };
      snapshot = withoutRequest(snapshot);
      return Promise.resolve(snapshot);
    },
    refreshPrivateSync: () => {
      if (snapshot.kind === 'signed-out') {
        return rejection('Synthetic Product Account required', 'unavailable');
      }
      const shared = syncAccount(snapshot.productAccountId);
      const { enrollment } = shared;
      if (snapshot.privateSync === 'enrollment-pending') {
        // The approved device adopts the account keys and reads the synchronized mailboxes.
        if (enrollment?.state === 'approved') {
          shared.enrollment = undefined;
          const { enrollmentCode: _code, ...unlocked } = snapshot;
          snapshot = {
            ...unlocked,
            privateSync: 'ready',
            ...(shared.mailboxes.size === 0
              ? {}
              : {
                  privateSyncMailboxes: [...shared.mailboxes].join('\n'),
                }),
          };
        }
        return Promise.resolve(snapshot);
      }
      // A trusted device sees another device waiting for approval.
      snapshot =
        enrollment?.state === 'pending'
          ? {
              ...snapshot,
              enrollmentRequest: syntheticEnrollmentRequest,
              enrollmentDevice: 'iPad',
            }
          : withoutRequest(snapshot);
      return Promise.resolve(snapshot);
    },
  };
  return Object.freeze({ native });
}
