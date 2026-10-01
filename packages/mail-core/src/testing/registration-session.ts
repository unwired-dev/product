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
]);

export function createMockRegistrationSession(selection: unknown) {
  // oxlint-disable-next-line node/no-sync -- Fixed test-only scenario selection.
  const scenario = Schema.decodeUnknownSync(Scenario)(selection);
  let snapshot: RegistrationSnapshot = { kind: 'signed-out' };
  let attempted = false;
  // Each synthetic sign-in identity owns its own Product Account.
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
      if (
        snapshot.kind !== 'signed-out' &&
        snapshot.signInProvider !== provider
      ) {
        return Promise.reject(
          Object.assign(new Error('Synthetic identity is not linked'), {
            code: 'invalid-identity',
          }),
        );
      }
      snapshot = {
        kind: 'mailbox-needed',
        signInProvider: provider,
        ...accounts[provider],
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
      if (
        scenario !== 'registration-success' &&
        !reselect &&
        scenario !== 'registration-interrupted'
      ) {
        return Promise.resolve(snapshot);
      }
      snapshot = {
        kind: 'connected',
        signInProvider: snapshot.signInProvider,
        ...accounts[snapshot.signInProvider],
        providerSubject: reselect
          ? 'synthetic-alternate-google-subject'
          : 'synthetic-google-subject',
        address: reselect ? 'other@example.invalid' : 'alex@example.invalid',
      };
      return Promise.resolve(snapshot);
    },
  };
  return Object.freeze({ native });
}
