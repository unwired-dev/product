/* oxlint-disable typescript/prefer-readonly-parameter-types -- Presets change the synthetic device's state between steps. */
import * as Effect from 'effect/Effect';

import type { NativeMailAssistance } from '../assistance-enablement.ts';
import type { NativeRegistrationVault } from '../registration-vault.ts';
import type { SyntheticAddress } from './registration-device.ts';

import { createRegistrationFlow } from '../registration-flow.ts';
import {
  createRegistration,
  mailboxesOf,
  profilesOf,
} from '../registration.ts';
import { configuredBackend } from './registration-product-sync-state.ts';
import {
  createSyntheticDevice,
  createSyntheticProductSyncBackend,
  createSyntheticVault,
  removeTrustedDevice,
} from './registration-vault.ts';

// The registration Mock Mail Session scenarios as presets of the synthetic vault, each one also in
// scripts/mock-mail-scenarios.json, plus the test-only 'registration-success'.
export const registrationScenarios = [
  'registration-cancelled',
  'registration-declined',
  'registration-no-gmail',
  'registration-interrupted',
  'registration-success',
  'registration-link',
  // The synthetic Product Accounts already have Product Sync keys on another device.
  'registration-enrollment',
  // This device creates the keys, and an iPad of the account can be removed.
  'registration-revocation',
  // Another device removes this one after sign-in; the next activation learns of it, and a new
  // sign-in waits for approval like any other device after the first.
  'registration-revoked',
] as const;
export type RegistrationScenario = (typeof registrationScenarios)[number];

// Other Trusted Devices of the account, which this device can remove.
export const syntheticTrustedDevice = {
  id: 'synthetic-ipad',
  name: 'iPad',
  registeredAt: Date.UTC(2026, 8, 1),
} as const;
export const syntheticSecondTrustedDevice = {
  id: 'synthetic-mac',
  name: 'Mac',
  registeredAt: Date.UTC(2026, 8, 2),
} as const;

// The Google account the account chooser picks, beside the Product Sign-In's own Gmail.
const otherSubject = 'synthetic-other-subject';

type SyntheticDevice = ReturnType<typeof createSyntheticDevice>;

// Native device storage's Mail Assistance Enablement by Product Account; every purge removes it.
const assistanceOf = (shared: SyntheticDevice) => {
  const enabled = new Map<string, readonly string[]>();
  // Pending and removing accounts have no owner.
  const owner = () => {
    const product = shared.device.record?.product;
    return product === undefined ||
      product.pending === true ||
      shared.device.record?.removal !== undefined
      ? null
      : product.productAccountId;
  };
  const mailAssistance: NativeMailAssistance = {
    mailAssistance: () => {
      const current = owner();
      return Promise.resolve({
        owner: current,
        profiles: current === null ? [] : (enabled.get(current) ?? []),
      });
    },
    setMailAssistance: (account, profiles) => {
      if (account !== owner()) {
        return Promise.reject(
          Object.assign(new Error('Synthetic account changed'), {
            code: 'mailbox-invalidated',
          }),
        );
      }
      enabled.set(account, profiles);
      return Promise.resolve({ owner: account, profiles });
    },
  };
  return {
    mailAssistance,
    purge: () => {
      enabled.clear();
    },
  };
};

// Lists another Trusted Device, with its encryption key, for every account holding keys unless it
// was removed.
const listDevice = (
  shared: SyntheticDevice,
  trusted: Readonly<{ id: string; name: string; registeredAt: number }>,
) => {
  const sync = shared.backend.productSync;
  for (const entry of sync?.accounts.values() ?? []) {
    if (
      entry.ring !== undefined &&
      !entry.devices.has(trusted.id) &&
      sync?.revoked.has(trusted.id) === false
    ) {
      entry.devices.set(trusted.id, {
        installation: `${trusted.id}-installation`,
        registeredAt: trusted.registeredAt,
        name: trusted.name,
        // Its encryption key, so a removal seals the new keys to it too.
        key: `${trusted.id}-key`,
        epoch: entry.ring.current,
      });
    }
  }
};

// One process of a host over the preset's device: its vault, and its Mail Assistance Enablement.
// fallow-ignore-next-line complexity -- One fixed scenario table decides each process's behavior.
function launchScenario(
  scenario: RegistrationScenario,
  shared: SyntheticDevice,
  assistance: ReturnType<typeof assistanceOf>,
) {
  const synthetic = createSyntheticVault(shared);
  const { vault } = synthetic;
  let interrupted = scenario !== 'registration-interrupted';
  let removed = scenario !== 'registration-revoked';
  const presets: NativeRegistrationVault = {
    ...vault,
    purge: async (operation) => {
      const purged = await vault.purge(operation);
      assistance.purge();
      return purged;
    },
    // The first mailbox authorization of this process is interrupted.
    signInMailbox: (connection, suggest, provider) => {
      if (!interrupted) {
        interrupted = true;
        return Promise.reject(new Error('Synthetic authorization interrupted'));
      }
      return vault.signInMailbox(connection, suggest, provider);
    },
    call: (call) => {
      const product = shared.device.record?.product;
      const sync = shared.backend.productSync;
      // Another device removes this one before its first activation after sign-in.
      if (
        !removed &&
        call.path === 'productAccount:isTrustedDeviceRevoked' &&
        product !== undefined &&
        product.pending !== true &&
        sync !== undefined
      ) {
        removed = true;
        removeTrustedDevice(
          sync,
          product.productAccountId,
          product.trustedDeviceId,
        );
      }
      if (scenario === 'registration-revocation') {
        listDevice(shared, syntheticTrustedDevice);
      }
      return vault.call(call);
    },
  };
  return { ...synthetic, vault: presets };
}

// The providers and backend another installation shares with this one.
const pick = ({
  google,
  apple,
  microsoft,
  imap,
  backend,
}: SyntheticDevice) => ({ google, apple, microsoft, imap, backend });

// Creates the Google and Apple Product Accounts' keys on another installation, which confirms
// their Recovery Keys; this device's sign-in then waits for approval.
async function createKeysElsewhere(shared: SyntheticDevice) {
  const keys: Record<string, string> = {};
  for (const provider of ['google', 'apple'] as const) {
    const flow = createRegistrationFlow(
      createSyntheticVault({ ...createSyntheticDevice(), ...pick(shared) })
        .vault,
    );
    const signedIn = await Effect.runPromise(flow.signIn(provider));
    const key = 'recoveryKey' in signedIn ? signedIn.recoveryKey : undefined;
    if (key === undefined) {
      throw new Error('Synthetic Recovery Key missing');
    }
    await Effect.runPromise(flow.confirmRecoveryKey(key.slice(-4)));
    keys[provider] = key;
  }
  return keys;
}

// A registration Mock Mail Session over the synthetic vault, with Product Sync. The suggested Gmail
// is the Product Sign-In's own Google account, alex@example.invalid; the account chooser picks
// other@example.invalid unless `choose` names another.
// fallow-ignore-next-line complexity -- One fixed scenario table configures each synthetic provider.
export async function createRegistrationScenario(
  scenario: RegistrationScenario,
  shared: SyntheticDevice = createSyntheticDevice(),
) {
  const { google, apple, backend } = shared;
  backend.productSync ??= createSyntheticProductSyncBackend();
  google.chosen = otherSubject;
  google.addresses[otherSubject] = 'other@example.invalid';
  // Each sign-in identity owns its own Product Account, so only the link scenario links them.
  if (scenario !== 'registration-link') {
    for (const subject of [google.subject, apple.subject]) {
      if (!backend.owners.has(subject)) {
        backend.owners.set(subject, `account-${subject}`);
      }
    }
  }
  if (scenario === 'registration-cancelled') {
    google.mailRefusals.set(google.subject, 'cancelled');
  } else if (scenario === 'registration-declined') {
    google.mailRefusals.set(google.subject, 'declined');
  } else if (scenario === 'registration-no-gmail') {
    google.refused.add(google.subject);
  }
  const recoveryKeys =
    scenario === 'registration-enrollment'
      ? await createKeysElsewhere(shared)
      : {};
  return installScenario(scenario, shared, recoveryKeys);
}

// One installation of a configured scenario: its device, Keychain and controls.
function installScenario(
  scenario: RegistrationScenario,
  shared: SyntheticDevice,
  recoveryKeys: Readonly<Record<string, string>>,
) {
  const { google, backend } = shared;
  const sync = configuredBackend(backend);
  const assistance = assistanceOf(shared);
  const launched = launchScenario(scenario, shared, assistance);
  const account = () => shared.device.record?.product?.productAccountId;
  return {
    ...launched,
    sync,
    // The Recovery Keys the other installation confirmed, by Sign-In Provider.
    recoveryKeys,
    mailAssistance: assistance.mailAssistance,
    // The host launched again over the same device.
    relaunch: () => launchScenario(scenario, shared, assistance).vault,
    // Another installation of the same providers and backend, with its own Keychain.
    otherDevice: () =>
      installScenario(
        scenario,
        { ...createSyntheticDevice(), ...pick(shared) },
        recoveryKeys,
      ),
    // The next account chooser picks this Google account.
    choose: (address: Exclude<SyntheticAddress, 'casey@example.invalid'>) => {
      google.chosen =
        address === 'alex@example.invalid' ? google.subject : otherSubject;
    },
    // The provider refuses this connection's grant at its next verification; the others stay.
    expire: (address: SyntheticAddress) => {
      if (address === 'casey@example.invalid') {
        shared.microsoft.revokedGrants.add(shared.microsoft.subject);
      } else {
        google.revokedGrants.add(
          address === 'alex@example.invalid' ? google.subject : otherSubject,
        );
      }
    },
    // The account lists a second Trusted Device that this device can remove.
    addSecondTrustedDevice: () => {
      listDevice(shared, syntheticSecondTrustedDevice);
    },
    // This installation's Keychain loses its Product Sync items; it must be approved again.
    loseDeviceKey: () => {
      const items = shared.device.productSync;
      items.vault = undefined;
      items.deviceKey = false;
      items.deviceKeyName = undefined;
    },
    // Another device removes a device of the account, so a prepared removal must be renewed.
    changeAccount: () => {
      const signedIn = account();
      if (signedIn !== undefined) {
        removeTrustedDevice(sync, signedIn);
      }
    },
  };
}
export type SyntheticRegistrationScenario = ReturnType<typeof installScenario>;

// The two-Profile Mock Mail Session: a connected registration store whose Default Profile owns
// alex@example.invalid and whose published Work Profile owns other@example.invalid.
export async function createTwoProfileRegistration(
  shared: SyntheticDevice = createSyntheticDevice(),
) {
  const synthetic = await createRegistrationScenario(
    'registration-success',
    shared,
  );
  const registration = createRegistration(synthetic.vault);
  await registration.register('google');
  await registration.addMailbox();
  await registration.confirmRecoveryKey(
    // oxlint-disable-next-line node/no-sync -- The synthetic device's Product Sync items, not a sync API.
    synthetic.device.productSync.vault?.recoveryKey?.slice(-4) ?? '',
  );
  await registration.addMailbox('gmail', true);
  await registration.createProfile('Work');
  const { snapshot } = registration.getSnapshot();
  const work = profilesOf(snapshot).find(({ name }) => name === 'Work')?.id;
  const other = mailboxesOf(snapshot).find(
    ({ address }) => address === 'other@example.invalid',
  )?.id;
  if (work === undefined || other === undefined) {
    throw new Error('Two-Profile scenario setup failed');
  }
  await registration.moveMailbox(other, work);
  return { ...synthetic, registration, work };
}
