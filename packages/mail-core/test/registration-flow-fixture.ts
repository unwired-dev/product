import * as Effect from 'effect/Effect';

import type { NativeRegistrationVault } from '../src/registration-flow.ts';
import type { NativeRegistration } from '../src/registration.ts';

import { createRegistrationFlow as registrationPrograms } from '../src/registration-flow.ts';

// Promise adapter for the flow journeys; production composes these programs in the store.
export const createRegistrationFlow = (
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
    confirmRevocation: (entry) =>
      Effect.runPromise(flow.confirmRevocation(entry)),
    cancelRevocation: () => Effect.runPromise(flow.cancelRevocation()),
    // oxlint-disable-next-line node/no-sync -- This runs an Effect program, not synchronous filesystem I/O.
    refreshPrivateSync: () => Effect.runPromise(flow.refreshPrivateSync()),
    signOut: () => Effect.runPromise(flow.signOut()),
    deleteProductAccount: () => Effect.runPromise(flow.deleteProductAccount()),
  };
};
