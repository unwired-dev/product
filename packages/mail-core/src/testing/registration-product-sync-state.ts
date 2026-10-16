/* oxlint-disable typescript/prefer-readonly-parameter-types -- Tests change the synthetic device's state between steps. */
import type {
  MailboxDescriptor,
  ProfileRecord,
} from '../registration-vault.ts';
import type { Payload, Ring, Stored } from './registration-vault-state.ts';

import { unavailable } from './registration-vault-state.ts';

// A sealed record as native returns it; `ciphertext` names what `sealed` maps it to.
export const payload = (
  ciphertext: string,
  keyVersion: number,
  schemaVersion = 1,
): Payload => ({
  algorithm: 'AES-GCM-256',
  ciphertextBase64: ciphertext,
  keyVersion,
  nonceBase64: ciphertext,
  schemaVersion,
  tagBase64: 'synthetic',
});
// A typed Recovery Key or Enrollment Code as native code reads it: case, spaces and hyphens aside.
export const canonical = (entry: string) =>
  entry.replaceAll(/[\s-]/gu, '').toUpperCase();
// The value a Recovery Key derives to prove itself, and the digest Convex keeps of it.
export const proofOf = (recoveryKey: string) =>
  `proof:${canonical(recoveryKey)}`;
export const verifierOf = (proof: string) => `verifier:${proof}`;
// How long a Pending Device's request and code, and an approval, stay open.
export const enrollmentLifetime = 900_000;
// A Trusted Device that approves waiting devices whenever the backend `approves`.
export const syntheticApprover = 'synthetic-approver';
export const offline = () =>
  Object.assign(new Error('Synthetic'), { code: 'offline' });
// What a sealed key ring envelope opens to, and for whom: an approval sealed to a Pending Device's
// one-time key and code, or a removal's ring sealed to a Trusted Device's encryption key.
type Envelope =
  | {
      kind: 'enrollment';
      ring: Ring;
      account: string;
      device: string;
      publicKey: string;
      deviceKey: string;
      code: string;
    }
  | {
      kind: 'rotation';
      ring: Ring;
      account: string;
      device: string;
      deviceKey: string;
    };
// One Trusted Device of an account: its installation, bound encryption key, the newest key epoch it
// adopted, and the latest key ring envelope a removal sealed to it.
interface TrustedDevice {
  installation: string;
  registeredAt: number;
  // The name the account lists; a synthetic installation lists its identifier.
  name?: string;
  key?: string;
  epoch: number;
  envelope?: { keyEpoch: number; ciphertext: string };
}
// A Pending Device: its request's keys, a Trusted Device's approval, and the key epoch a matching
// Recovery Key proof authorized.
export interface PendingDevice {
  account: string;
  installation: string;
  expiresAt: number;
  publicKey?: string;
  deviceKey?: string;
  approval?: { keyVersion: number; ciphertext: string; approver: string };
  recovered?: number;
}

// Convex's Product Sync rules: one recovery envelope per account, compare-and-set records, writes
// refused below the account's key epoch, Pending Devices that only a Trusted Device at the newest
// epoch or the current Recovery Key admits, and removals that commit all at once. `sealed` and
// `envelopes` stand in for the cryptography: each maps a ciphertext to what it seals, and only a
// ring of the same lineage at its epoch, or the named recipient, opens it.
export function createSyntheticProductSyncBackend() {
  return {
    accounts: new Map<
      string,
      {
        recovery?: string;
        recoveryUpdatedAt?: number;
        verifier?: string;
        ring?: Ring;
        records: Map<string, Stored>;
        // Installations admitted as Trusted Devices, and each Trusted Device by identifier.
        admitted: Set<string>;
        devices: Map<string, TrustedDevice>;
        // Activated removals with their epochs, and the one whose Recovery Key is current.
        proposals: Map<string, { keyEpoch: number; target: string }>;
        recoveryProposal?: string;
      }
    >(),
    // What each recovery envelope seals, for which account, under which Recovery Key.
    recoveries: new Map<string, { ring: Ring; key: string; account: string }>(),
    envelopes: new Map<string, Envelope>(),
    pending: new Map<string, PendingDevice>(),
    // Trusted Devices another device removed; their identifiers stay refused.
    revoked: new Set<string>(),
    // The opaque identifier each ring gives each provider account's descriptor.
    identifiers: new Map<string, string>(),
    rings: 0,
    sealed: new Map<
      string,
      {
        ring: string;
        account: string;
        record: string;
        descriptor: MailboxDescriptor;
      }
    >(),
    // What each sealed Mail Profile definition or ownership opens to, and under which identifier.
    sealedProfiles: new Map<
      string,
      {
        ring: string;
        account: string;
        identifier: string;
        record: ProfileRecord;
      }
    >(),
    clock: 1000,
    pageSize: 100,
    initializations: 0,
    activations: 0,
    listedPages: 0,
    // Synthetic secrets issued so far: one-time keys, codes, device keys and proposals.
    issued: 0,
    // Another device's write that lands just before this record's next write, or the next listing.
    beforePut: undefined as ((record: string) => void) | undefined,
    beforeList: undefined as (() => void) | undefined,
    // The next initialization applies, but its reply is lost.
    loseInitializationReply: false,
    // A Trusted Device of the account approves each waiting device with the code it shows.
    approves: false,
    // Product Sync calls cannot reach Convex.
    offline: false,
    // Connect replies omit Product Sync state, as receipts saved before it did.
    legacyReceipts: false,
    // Admission cannot reach Convex, or commits but its reply is lost.
    failCompletion: false,
    loseCompletionReply: false,
    // The next removal applies but its reply is lost, or it fails before committing.
    loseActivationReply: false,
    failActivationBeforeCommit: false,
    // The next activation answers with this HTTP status and body instead of applying.
    activationReply: undefined as { status: number; body: string } | undefined,
    // The removal reply arrives, but the following synchronization cannot reach the backend.
    offlineAfterActivation: false,
    // The next activation finds the Product Sign-In no longer recent.
    staleOnce: false,
    // Proposal outcome reads so far, and the one that loses its connection.
    outcomeReads: 0,
    failingOutcomeRead: undefined as number | undefined,
    failAcknowledgement: false,
    failRecoveryRead: false,
    // Runs once after the next proposal outcome read or rotation acknowledgement, as a concurrent
    // removal.
    afterOutcomeRead: undefined as (() => void) | undefined,
    afterAcknowledgement: undefined as (() => void) | undefined,
    // Native steps Product Sync took, in order.
    steps: [] as string[],
  };
}
export type SyntheticProductSync = ReturnType<
  typeof createSyntheticProductSyncBackend
>;

// Another device's sealed write: a descriptor under `record`, or a payload nobody here opens.
export function storeDescriptor(
  sync: SyntheticProductSync,
  {
    account,
    record,
    descriptor,
  }: Readonly<{
    account: string;
    record: string;
    descriptor: MailboxDescriptor | undefined;
  }>,
) {
  const entry = sync.accounts.get(account);
  if (entry?.ring === undefined) {
    throw new Error('Synthetic account without keys');
  }
  const ciphertext = `sealed-${sync.sealed.size + 1}`;
  if (descriptor !== undefined) {
    sync.sealed.set(ciphertext, {
      ring: entry.ring.id,
      account,
      record,
      descriptor,
    });
  }
  sync.clock += 1;
  entry.records.set(record, {
    payloadIdentifier: record,
    encryptedPayload: payload(ciphertext, entry.ring.current),
    updatedAt: sync.clock,
  });
}

// The opaque identifier a ring stores a mailbox account's descriptor under, by the provider's
// account as native code names it: `gmail:<subject>` or `microsoft-graph:<subject>`.
export function mailboxRecord(
  sync: SyntheticProductSync,
  ring: string,
  account: string,
) {
  const name = `${ring}\n${account}`;
  const known = sync.identifiers.get(name);
  if (known !== undefined) {
    return known;
  }
  const record = `mailbox.${ring}.${sync.identifiers.size + 1}`;
  sync.identifiers.set(name, record);
  return record;
}

// The opaque identifier a ring stores a Mail Profile's definition or a connection's ownership under.
function profileIdentifier(
  sync: SyntheticProductSync,
  ring: string,
  record: ProfileRecord,
) {
  const [kind, name] =
    record.kind === 'profile'
      ? ['profile', record.id]
      : ['mailbox-profile', record.record];
  const key = `${ring}\n${kind}\n${name}`;
  const known = sync.identifiers.get(key);
  if (known !== undefined) {
    return known;
  }
  const identifier = `${kind}.${ring}.${sync.identifiers.size + 1}`;
  sync.identifiers.set(key, identifier);
  return identifier;
}

// Seals a Profile definition or ownership as the account's keys would, under its identifier.
export function sealProfile(
  sync: SyntheticProductSync,
  account: string,
  record: ProfileRecord,
) {
  const ring = sync.accounts.get(account)?.ring;
  if (ring === undefined) {
    throw new Error('Synthetic account without keys');
  }
  const identifier = profileIdentifier(sync, ring.id, record);
  const ciphertext = `profile-sealed-${sync.sealedProfiles.size + 1}`;
  sync.sealedProfiles.set(ciphertext, {
    ring: ring.id,
    account,
    identifier,
    record: structuredClone(record),
  });
  return {
    payloadIdentifier: identifier,
    encryptedPayload: payload(ciphertext, ring.current),
  };
}

// Another device's write of a Profile definition or ownership, over whatever is stored.
export function storeProfile(
  sync: SyntheticProductSync,
  account: string,
  record: ProfileRecord,
) {
  const sealed = sealProfile(sync, account, record);
  sync.clock += 1;
  sync.accounts.get(account)?.records.set(sealed.payloadIdentifier, {
    ...sealed,
    updatedAt: sync.clock,
  });
}

// Every Profile definition and ownership stored for the account, opened with its keys.
export function storedProfiles(sync: SyntheticProductSync, account: string) {
  return [...(sync.accounts.get(account)?.records.values() ?? [])].flatMap(
    ({ encryptedPayload }) => {
      const sealed = sync.sealedProfiles.get(encryptedPayload.ciphertextBase64);
      return sealed === undefined ? [] : [sealed.record];
    },
  );
}

// The descriptor stored under a record, opened with the account's keys.
export function storedDescriptor(
  sync: SyntheticProductSync,
  account: string,
  record: string,
) {
  const stored = sync.accounts.get(account)?.records.get(record);
  return stored === undefined
    ? undefined
    : sync.sealed.get(stored.encryptedPayload.ciphertextBase64)?.descriptor;
}

// Another device's removal, committed outside this device: a new epoch sealed to every remaining
// Trusted Device and a replacement Recovery Key, as the device holding the account's keys would seal
// them. Returns that Recovery Key.
export function removeTrustedDevice(
  sync: SyntheticProductSync,
  account: string,
  target?: string,
) {
  const entry = sync.accounts.get(account);
  if (entry?.ring === undefined) {
    throw new Error('Synthetic account without keys');
  }
  const epoch = Math.max(...entry.ring.epochs) + 1;
  const ring = {
    id: entry.ring.id,
    epochs: [...entry.ring.epochs, epoch],
    current: epoch,
  };
  if (target !== undefined) {
    entry.admitted.delete(entry.devices.get(target)?.installation ?? '');
    sync.revoked.add(target);
    entry.devices.delete(target);
  }
  for (const [id, device] of entry.devices) {
    if (device.key !== undefined) {
      const ciphertext = `rotation-${(sync.issued += 1)}`;
      sync.envelopes.set(ciphertext, {
        kind: 'rotation',
        ring: structuredClone(ring),
        account,
        device: id,
        deviceKey: device.key,
      });
      device.envelope = { keyEpoch: epoch, ciphertext };
    }
  }
  entry.ring = ring;
  const key = `SYNTHETIC-RECOVERY-${ring.id}-${epoch}`;
  const recovery = `recovery-${ring.id}-${epoch}`;
  sync.recoveries.set(recovery, { ring: structuredClone(ring), key, account });
  sync.clock += 1;
  entry.recovery = recovery;
  entry.verifier = verifierOf(proofOf(key));
  entry.recoveryUpdatedAt = sync.clock;
  delete entry.recoveryProposal;
  return key;
}

// The configured Product Sync boundary, absent when a registration test omits it.
export function configuredBackend(
  backend: Readonly<{ productSync: SyntheticProductSync | undefined }>,
) {
  if (backend.productSync === undefined) {
    throw unavailable();
  }
  return backend.productSync;
}
