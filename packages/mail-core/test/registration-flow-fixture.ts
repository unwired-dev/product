import * as Effect from 'effect/Effect';

import type { NativeRegistrationVault } from '../src/registration-flow.ts';
import type { NativeRegistration } from '../src/registration.ts';

import { createRegistrationFlow as registrationPrograms } from '../src/registration-flow.ts';
import {
  createSyntheticDevice,
  createSyntheticVault,
} from '../src/testing/registration-vault.ts';

// Promise adapter for the flow journeys; production composes these programs in the store.
export const createRegistrationFlow = (
  vault: NativeRegistrationVault,
): Required<NativeRegistration> => {
  const flow = registrationPrograms(vault);
  return {
    restore: () => Effect.runPromise(flow.restore()),
    signIn: (provider) => Effect.runPromise(flow.signIn(provider)),
    addMailbox: (provider, chooseAccount) =>
      Effect.runPromise(flow.addMailbox(provider, chooseAccount)),
    authorizeMailbox: (connection) =>
      Effect.runPromise(flow.authorizeMailbox(connection)),
    connectImap: (setup) => Effect.runPromise(flow.connectImap(setup)),
    removeMailbox: (connection) =>
      Effect.runPromise(flow.removeMailbox(connection)),
    createProfile: (name) => Effect.runPromise(flow.createProfile(name)),
    renameProfile: (profile, name) =>
      Effect.runPromise(flow.renameProfile(profile, name)),
    removeProfile: (profile) => Effect.runPromise(flow.removeProfile(profile)),
    moveMailbox: (connection, profile) =>
      Effect.runPromise(flow.moveMailbox(connection, profile)),
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
    // oxlint-disable-next-line node/no-sync -- The async private-sync program performs no synchronous Node I/O.
    refreshPrivateSync: () => Effect.runPromise(flow.refreshPrivateSync()),
    adoptKeyRotation: () => Effect.runPromise(flow.adoptKeyRotation()),
    signOut: () => Effect.runPromise(flow.signOut()),
    deleteProductAccount: () => Effect.runPromise(flow.deleteProductAccount()),
  };
};

// The registration flow over the synthetic native vault. Each relaunch is a new process over the
// same device Keychain, providers and backend.
export const launch = () => {
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
