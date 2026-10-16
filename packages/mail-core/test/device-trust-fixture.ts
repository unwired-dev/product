/* oxlint-disable typescript/prefer-readonly-parameter-types -- Journey helpers read the mutable synthetic Keychain record shared with each device. */
import * as Predicate from 'effect/Predicate';

import type { createSyntheticDevice } from '../src/testing/registration-vault.ts';
import type { RegistrationFlow } from './registration-flow-fixture.ts';

import {
  createSyntheticDevice as syntheticDevice,
  createSyntheticProductSyncBackend,
  createSyntheticVault,
} from '../src/testing/registration-vault.ts';
import { createRegistrationFlow, launch } from './registration-flow-fixture.ts';

export type Device = ReturnType<typeof createSyntheticDevice>['device'];

export const account = 'account-synthetic-product-subject';
export const productSubject = 'synthetic-product-subject';
export const mailboxSubject = 'synthetic-mailbox-subject';

export const required = <T>(value: T | undefined, what: string): T => {
  if (value === undefined) {
    throw new Error(`No ${what}`);
  }
  return value;
};
// A snapshot's text field, or nothing.
export const textOf = (snapshot: unknown, name: string) =>
  Predicate.hasProperty(snapshot, name) && Predicate.isString(snapshot[name])
    ? snapshot[name]
    : undefined;
// A snapshot's text field, which the journey needs to continue.
export const field = (snapshot: unknown, name: string) =>
  required(textOf(snapshot, name), name);
// The final group of a Recovery Key, as the person enters it to confirm.
export const lastGroup = (key: string) => key.slice(-4);
// A step's snapshot, or the code it was refused with.
export const outcome = async (step: Promise<unknown>) => {
  try {
    return await step;
  } catch (error) {
    return {
      refused:
        Predicate.hasProperty(error, 'code') && Predicate.isString(error.code)
          ? error.code
          : undefined,
    };
  }
};
// What a device's Keychain holds of the account, as native keeps it.
export const productOf = (device: Readonly<Device>) =>
  required(device.record?.product, 'Product Account');
export const idOf = (device: Readonly<Device>) =>
  productOf(device).trustedDeviceId;
export const heldEpoch = (device: Readonly<Device>) =>
  device.productSync.vault?.ring.current;
export const revocationOf = (device: Readonly<Device>) =>
  device.productSync.vault?.revocation;

// Prepares and confirms a removal on `flow`, returning the confirmation's snapshot.
const remove = async (flow: RegistrationFlow, target: string) => {
  const prepared = await flow.revokeTrustedDevice(target);
  return flow.confirmRevocation(
    lastGroup(field(prepared, 'revocationRecoveryKey')),
  );
};

// The account's first installation and Convex with Product Sync; further installations sign in to
// the same backend with the same Google account, each with its own Keychain.
export const setup = () => {
  const launched = launch();
  const sync = createSyntheticProductSyncBackend();
  launched.backend.productSync = sync;
  const keys = () =>
    required(sync.accounts.get(account), 'Product Sync account');
  const ring = () => required(keys().ring, 'account keys');
  const trustedDevice = (id: string) =>
    required(keys().devices.get(id), 'Trusted Device');
  // The Recovery Key Convex holds the current recovery envelope for.
  const currentRecoveryKey = () =>
    sync.recoveries.get(required(keys().recovery, 'recovery envelope'))?.key;
  const install = () => {
    const shared = {
      ...syntheticDevice(),
      google: launched.google,
      apple: launched.apple,
      backend: launched.backend,
    };
    return {
      device: shared.device,
      flow: createRegistrationFlow(createSyntheticVault(shared).vault),
      relaunch: () =>
        createRegistrationFlow(createSyntheticVault(shared).vault),
    };
  };
  // The first installation creates the keys and confirms its Recovery Key, which it returns.
  const createKeys = async (mailbox = false) => {
    const key = field(await launched.flow.signIn('google'), 'recoveryKey');
    await launched.flow.confirmRecoveryKey(lastGroup(key));
    if (mailbox) {
      launched.google.subject = mailboxSubject;
      await launched.flow.addMailbox('gmail', false);
      launched.google.subject = productSubject;
    }
    return key;
  };
  // Another installation, unlocked with the Recovery Key.
  const recovered = async (key: string) => {
    const next = install();
    await next.flow.signIn('google');
    await next.flow.recoverWithRecoveryKey(key);
    return { ...next, id: idOf(next.device) };
  };
  return {
    ...launched,
    sync,
    keys,
    ring,
    trustedDevice,
    currentRecoveryKey,
    install,
    createKeys,
    recovered,
    remove,
  };
};
export type Setup = ReturnType<typeof setup>;
