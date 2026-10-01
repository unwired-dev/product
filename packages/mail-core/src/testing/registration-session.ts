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
]);

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
});

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
        snapshot = {
          kind: 'mailbox-needed',
          signInProvider: provider,
          ...accounts[provider],
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
      if (
        !['registration-success', 'registration-link'].includes(scenario) &&
        !reselect &&
        scenario !== 'registration-interrupted'
      ) {
        return Promise.resolve(snapshot);
      }
      snapshot = {
        kind: 'connected',
        ...account(snapshot),
        providerSubject: reselect
          ? 'synthetic-alternate-google-subject'
          : 'synthetic-google-subject',
        address: reselect ? 'other@example.invalid' : 'alex@example.invalid',
      };
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
  };
  return Object.freeze({ native });
}
