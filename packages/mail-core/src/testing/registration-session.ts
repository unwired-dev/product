import * as Schema from 'effect/Schema';

import type {
  NativeRegistration,
  RegistrationSnapshot,
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
  const native: NativeRegistration = {
    restore: () => Promise.resolve(snapshot),
    signIn: () => {
      snapshot = {
        kind: 'mailbox-needed',
        productAccountId: 'synthetic-product-account',
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
        productAccountId: 'synthetic-product-account',
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
