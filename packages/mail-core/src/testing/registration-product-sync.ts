/* oxlint-disable typescript/prefer-readonly-parameter-types -- Tests change the synthetic device's state between steps. */
import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';
import * as Predicate from 'effect/Predicate';
import * as Schema from 'effect/Schema';

import type {
  NativeRegistrationVault,
  MailboxChange,
  MailboxDescriptor,
} from '../registration-vault.ts';
import type {
  Connection,
  Identity,
  Payload,
  Presented,
  Receipt,
  Ring,
  SavedRecord,
  Stored,
  SyncVault,
} from './registration-vault-state.ts';
import type { createSyntheticDevice } from './registration-vault.ts';

import { EncryptedPayload } from '../registration-replies.ts';
import {
  attempt,
  refusal,
  success,
  unavailable,
} from './registration-vault-state.ts';

// A sealed record as native returns it; `ciphertext` names what `sealed` maps it to.
const payload = (ciphertext: string, keyVersion: number): Payload => ({
  algorithm: 'AES-GCM-256',
  ciphertextBase64: ciphertext,
  keyVersion,
  nonceBase64: ciphertext,
  schemaVersion: 1,
  tagBase64: 'synthetic',
});
// The only copy of a Recovery Key not yet backed up, or a removal whose outcome is unknown.
const holdsUnsettledKeys = (vault: SyncVault | undefined) =>
  (vault?.recoveryKey !== undefined && !vault.recoveryKeyConfirmed) ||
  vault?.revocation?.submitted === true;
const isPayload = Schema.is(EncryptedPayload);

// Saves what synchronization learned about one connection; a null epoch clears it.
const applyChange = (connection: Connection, change: MailboxChange) => {
  if ('epoch' in change) {
    if (change.epoch === null || change.epoch === undefined) {
      delete connection.epoch;
    } else {
      connection.epoch = change.epoch;
    }
  }
  if (change.published === true) {
    connection.published = true;
  }
};

// Convex's Product Sync rules: one recovery envelope per account, compare-and-set records, and
// writes refused below the account's key epoch. `sealed` stands in for the cryptography: it maps
// each ciphertext to what it seals, and only a ring of the same lineage at its epoch opens it.
export function createSyntheticProductSyncBackend() {
  return {
    accounts: new Map<
      string,
      {
        recovery?: string;
        ring?: Ring;
        records: Map<string, Stored>;
        // Installations admitted as Trusted Devices.
        admitted: Set<string>;
      }
    >(),
    // What each recovery envelope seals: the ring its creator published.
    recoveries: new Map<string, Ring>(),
    // The opaque identifier each ring gives each Google account's descriptor.
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
    clock: 1000,
    pageSize: 100,
    initializations: 0,
    listedPages: 0,
    // Another device's write that lands just before this record's next write, or the next listing.
    beforePut: undefined as ((record: string) => void) | undefined,
    beforeList: undefined as (() => void) | undefined,
    // The next initialization applies, but its reply is lost.
    loseInitializationReply: false,
    // Whether another Trusted Device approves a waiting device.
    approves: false,
    // Product Sync calls cannot reach Convex.
    offline: false,
    // Connect replies omit Product Sync state, as receipts saved before it did.
    legacyReceipts: false,
    requests: [] as Array<{ id: string; device: string; expiresAt: number }>,
    trustedDevices: [] as Array<{
      id: string;
      name: string;
      registeredAt: number;
    }>,
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
    encryptedPayload: {
      algorithm: 'AES-GCM-256',
      ciphertextBase64: ciphertext,
      keyVersion: entry.ring.current,
      nonceBase64: ciphertext,
      schemaVersion: 1,
      tagBase64: 'synthetic',
    },
    updatedAt: sync.clock,
  });
}

// The opaque identifier a ring stores a Google account's mailbox descriptor under.
export function mailboxRecord(
  sync: SyntheticProductSync,
  ring: string,
  subject: string,
) {
  const name = `${ring}\n${subject}`;
  const known = sync.identifiers.get(name);
  if (known !== undefined) {
    return known;
  }
  const record = `mailbox.${ring}.${sync.identifiers.size + 1}`;
  sync.identifiers.set(name, record);
  return record;
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

// Product Sync's synthetic native and Convex boundaries, composed into a registration process.
export function createSyntheticSyncVault(
  shared: Readonly<ReturnType<typeof createSyntheticDevice>>,
  {
    saved,
    connectionId,
    newlyAuthorized,
    live,
    connect,
    verified,
    cached,
  }: Readonly<{
    saved: () => SavedRecord;
    connectionId: (subject: string, address?: string) => string;
    newlyAuthorized: Set<string>;
    live: Readonly<{ session: Identity | undefined }>;
    connect: (
      signedIn: Readonly<Identity>,
      installation: string,
      previous?: Readonly<Receipt>,
    ) => Receipt;
    verified: Set<string>;
    cached: Set<string>;
  }>,
) {
  const { device, backend } = shared;
  // The Product Sync account a Trusted Device's proof reaches.
  const accountKeys = (product: Readonly<Receipt> | undefined) => {
    const sync = backend.productSync;
    const entry =
      product === undefined || product.pending === true
        ? undefined
        : sync?.accounts.get(product.productAccountId);
    if (sync?.offline === true) {
      throw Object.assign(new Error('Synthetic'), { code: 'offline' });
    }
    if (sync === undefined || entry === undefined) {
      throw unavailable();
    }
    return { sync, entry };
  };

  // The Keychain's Product Sync items, which fail to read when `unreadable`.
  const syncKeys = () => {
    if (device.productSync.unreadable) {
      throw unavailable();
    }
    return device.productSync;
  };
  const syncBackend = () => {
    if (backend.productSync === undefined) {
      throw unavailable();
    }
    return backend.productSync;
  };
  const trusted = () => {
    const record = saved();
    if (record.product === undefined || record.product.pending === true) {
      throw unavailable();
    }
    return { record, product: record.product };
  };
  const publishedVault = () => {
    const { product } = trusted();
    const { vault } = syncKeys();
    if (vault?.published !== true) {
      throw unavailable();
    }
    return { vault, account: product.productAccountId };
  };
  // What native projects of this device's Product Sync state.
  // fallow-ignore-next-line complexity -- Each optional field mirrors the native projection.
  const productSyncState = (record: Readonly<SavedRecord>) => {
    const { product } = record;
    const sync = backend.productSync;
    if (product === undefined || sync === undefined) {
      return undefined;
    }
    if (device.productSync.unreadable) {
      return 'unreadable';
    }
    const keys = device.productSync;
    const { vault } = keys;
    return {
      pending: product.pending === true,
      ...(product.materialInitialized === undefined
        ? {}
        : { materialInitialized: product.materialInitialized }),
      deviceKey: keys.deviceKey,
      ...(product.pending === true && keys.enrollment !== undefined
        ? { enrollment: keys.enrollment }
        : {}),
      requests: keys.requests,
      trustedDevices: keys.trustedDevices,
      ...(vault === undefined
        ? {}
        : {
            vault: {
              keyEpoch: vault.ring.current,
              published: vault.published,
              recoveryKeyConfirmed: vault.recoveryKeyConfirmed,
              ...(vault.recoveryKey === undefined
                ? {}
                : { recoveryKey: vault.recoveryKey }),
              ...(vault.revocation === undefined
                ? {}
                : { revocation: vault.revocation }),
              ...(vault.readMailboxes === undefined
                ? {}
                : { readMailboxes: vault.readMailboxes }),
              ...(vault.savedMailboxes === undefined
                ? {}
                : { savedMailboxes: vault.savedMailboxes }),
              mailboxes: record.connections.map((connection) => {
                const id = connectionId(connection.subject, connection.address);
                return {
                  id,
                  record: mailboxRecord(
                    sync,
                    vault.ring.id,
                    connection.subject,
                  ),
                  published: connection.published === true,
                  newlyAuthorized: newlyAuthorized.has(id),
                  ...(connection.observed === undefined
                    ? {}
                    : { observed: connection.observed }),
                  ...(connection.observedEpoch === undefined
                    ? {}
                    : { observedEpoch: connection.observedEpoch }),
                };
              }),
              removals: (record.removals ?? []).map((removal) => ({
                id: connectionId(removal.subject, removal.address),
                record: mailboxRecord(sync, vault.ring.id, removal.subject),
                address: removal.address,
                ...(removal.epoch === undefined
                  ? {}
                  : { epoch: removal.epoch }),
              })),
            },
          }),
    };
  };

  const handlers: Readonly<
    Record<string, (request: Presented) => { status: number; body: string }>
  > = {
    'productSync:initialize': ({ call, product }) => {
      const { sync, entry } = accountKeys(product);
      const envelope = call.args.encryptedPayload;
      const ring = isPayload(envelope)
        ? sync.recoveries.get(envelope.ciphertextBase64)
        : undefined;
      if (ring === undefined || !isPayload(envelope)) {
        return refusal('UNAVAILABLE');
      }
      if (entry.recovery !== undefined) {
        return success({
          initialized: entry.recovery === envelope.ciphertextBase64,
        });
      }
      entry.recovery = envelope.ciphertextBase64;
      entry.ring = structuredClone(ring);
      sync.initializations += 1;
      if (sync.loseInitializationReply) {
        sync.loseInitializationReply = false;
        throw Object.assign(new Error('Synthetic'), { code: 'offline' });
      }
      return success({ initialized: true });
    },
    'productSync:listEncryptedPayloadsForTrustedDevice': ({
      call,
      product,
    }) => {
      const { sync, entry } = accountKeys(product);
      const options = call.args.paginationOpts;
      const cursor =
        Predicate.hasProperty(options, 'cursor') &&
        Predicate.isString(options.cursor)
          ? options.cursor
          : null;
      if (cursor === null) {
        sync.beforeList?.();
      }
      sync.listedPages += 1;
      const prefix = String(call.args.payloadIdentifierPrefix);
      const records = Arr.sortWith(
        [...entry.records.values()].filter(({ payloadIdentifier }) =>
          payloadIdentifier.startsWith(prefix),
        ),
        ({ payloadIdentifier }) => payloadIdentifier,
        Order.String,
      );
      const start = cursor === null ? 0 : Number(cursor);
      const page = records.slice(start, start + sync.pageSize);
      const end = start + page.length;
      return success({
        page,
        isDone: end >= records.length,
        continueCursor: String(end),
      });
    },
    // fallow-ignore-next-line complexity -- Mirrors Convex's compare-and-set and epoch refusals.
    'productSync:putEncryptedPayloadIfUnchanged': ({ call, product }) => {
      const { sync, entry } = accountKeys(product);
      const record = String(call.args.payloadIdentifier);
      const sealed = call.args.encryptedPayload;
      const expected = Predicate.isNumber(call.args.expectedUpdatedAt)
        ? call.args.expectedUpdatedAt
        : undefined;
      if (!isPayload(sealed)) {
        return refusal('UNAVAILABLE');
      }
      sync.beforePut?.(record);
      if (sealed.keyVersion !== entry.ring?.current) {
        return refusal('PRODUCT_SYNC_KEY_ROTATION_REQUIRED');
      }
      const existing = entry.records.get(record);
      if (existing !== undefined && existing.updatedAt !== expected) {
        return success(existing);
      }
      // As Convex does, a compare-and-set against a record that no longer exists is refused.
      if (existing === undefined && expected !== undefined) {
        return refusal('PRODUCT_SYNC_PAYLOAD_CHANGED');
      }
      sync.clock += 1;
      const stored = {
        payloadIdentifier: record,
        encryptedPayload: sealed,
        updatedAt: sync.clock,
      };
      entry.records.set(record, stored);
      return success(stored);
    },
  };

  const operations: Pick<
    NativeRegistrationVault,
    | 'createKeyRing'
    | 'recordInitialization'
    | 'reenroll'
    | 'admitPendingDevice'
    | 'adoptRotation'
    | 'refreshDevices'
    | 'finishSynchronization'
    | 'sealMailboxDescriptor'
    | 'openMailboxDescriptors'
    | 'recordMailboxChanges'
    | 'purgeMailbox'
    | 'removeQueuedPushRoutes'
    | 'recordMailboxReadback'
  > = {
    createKeyRing: () =>
      attempt(() => {
        const sync = syncBackend();
        const { product } = trusted();
        const keys = syncKeys();
        if (keys.vault === undefined) {
          if (product.materialInitialized !== false) {
            throw unavailable();
          }
          sync.rings += 1;
          const id = `ring-${sync.rings}`;
          keys.vault = {
            ring: { id, epochs: [1], current: 1 },
            published: false,
            recoveryKey: `SYNTHETIC-RECOVERY-${id}`,
            recoveryKeyConfirmed: false,
          };
        }
        const { vault } = keys;
        if (vault.published || vault.recoveryKey === undefined) {
          throw unavailable();
        }
        keys.deviceKey = true;
        const envelope = `recovery-${vault.ring.id}`;
        sync.recoveries.set(envelope, structuredClone(vault.ring));
        sync.steps.push('createKeyRing');
        return {
          recoveryEnvelope: payload(envelope, vault.ring.current),
          recoveryVerifier: `verifier-${vault.ring.id}`,
          deviceKey: 'synthetic-device-key',
        };
      }),
    recordInitialization: (initialized) =>
      attempt(() => {
        syncBackend().steps.push(`recordInitialization:${initialized}`);
        const { product } = trusted();
        const keys = syncKeys();
        if (keys.vault === undefined || keys.vault.published) {
          throw unavailable();
        }
        if (initialized) {
          keys.vault.published = true;
        } else {
          keys.vault = undefined;
          product.materialInitialized = true;
        }
        return null;
      }),
    reenroll: () =>
      attempt(() => {
        syncBackend().steps.push('reenroll');
        const { record, product } = trusted();
        const keys = syncKeys();
        if (
          live.session === undefined ||
          keys.deviceKey ||
          holdsUnsettledKeys(keys.vault)
        ) {
          throw unavailable();
        }
        record.deviceIdentifier = `synthetic-installation-${(backend.installations += 1)}`;
        keys.vault = undefined;
        keys.enrollment = undefined;
        record.product = connect(
          live.session,
          record.deviceIdentifier,
          product,
        );
        verified.clear();
        cached.clear();
        keys.requests = [];
        keys.trustedDevices = [];
        return null;
      }),
    admitPendingDevice: () =>
      attempt(() => {
        const sync = syncBackend();
        sync.steps.push('admitPendingDevice');
        const record = saved();
        const { product } = record;
        const keys = syncKeys();
        const entry =
          product === undefined
            ? undefined
            : sync.accounts.get(product.productAccountId);
        if (product?.pending !== true || entry === undefined) {
          throw unavailable();
        }
        if (!sync.approves || entry.ring === undefined) {
          keys.enrollment ??= { code: 'SYNTHETIC-ENROLLMENT-CODE' };
          return { admitted: false };
        }
        keys.vault = {
          ring: structuredClone(entry.ring),
          published: true,
          recoveryKeyConfirmed: true,
        };
        keys.deviceKey = true;
        keys.enrollment = undefined;
        entry.admitted.add(record.deviceIdentifier);
        record.product = {
          productAccountId: product.productAccountId,
          trustedDeviceId: `synthetic-device-${(backend.devices += 1)}`,
          ...(product.signInProviders === undefined
            ? {}
            : { signInProviders: product.signInProviders }),
          materialInitialized: true,
        };
        return { admitted: true };
      }),
    adoptRotation: () =>
      attempt(() => {
        const sync = syncBackend();
        sync.steps.push('adoptRotation');
        const { product } = trusted();
        const { vault } = syncKeys();
        const ring = sync.accounts.get(product.productAccountId)?.ring;
        if (vault === undefined) {
          throw unavailable();
        }
        if (ring?.id === vault.ring.id && ring.current > vault.ring.current) {
          vault.ring = structuredClone(ring);
        }
        return null;
      }),
    refreshDevices: () =>
      attempt(() => {
        const sync = syncBackend();
        sync.steps.push('refreshDevices');
        const { product } = trusted();
        const keys = syncKeys();
        keys.requests = [...sync.requests];
        keys.trustedDevices = sync.trustedDevices.filter(
          ({ id }) => id !== product.trustedDeviceId,
        );
        return null;
      }),
    finishSynchronization: () =>
      attempt(() => {
        newlyAuthorized.clear();
        return null;
      }),
    sealMailboxDescriptor: (record, descriptor) =>
      attempt(() => {
        const sync = syncBackend();
        const { vault, account } = publishedVault();
        const ciphertext = `sealed-${sync.sealed.size + 1}`;
        sync.sealed.set(ciphertext, {
          ring: vault.ring.id,
          account,
          record,
          descriptor: { ...descriptor },
        });
        return payload(ciphertext, vault.ring.current);
      }),
    openMailboxDescriptors: (records) =>
      attempt(() => {
        const sync = syncBackend();
        const { vault, account } = publishedVault();
        return records.map(({ payloadIdentifier, encryptedPayload }) => {
          const sealed = sync.sealed.get(encryptedPayload.ciphertextBase64);
          return sealed !== undefined &&
            sealed.ring === vault.ring.id &&
            sealed.account === account &&
            sealed.record === payloadIdentifier &&
            vault.ring.epochs.includes(encryptedPayload.keyVersion)
            ? sealed.descriptor
            : null;
        });
      }),
    recordMailboxChanges: (changes, settledRemovals) =>
      attempt(() => {
        const record = saved();
        for (const change of changes) {
          const connection = record.connections.find(
            ({ subject, address }) =>
              connectionId(subject, address) === change.id,
          );
          if (connection !== undefined) {
            applyChange(connection, change);
          }
        }
        const { vault } = syncKeys();
        const sync = syncBackend();
        if (vault !== undefined && settledRemovals.length > 0) {
          const remaining = (record.removals ?? []).filter(
            ({ subject }) =>
              !settledRemovals.includes(
                mailboxRecord(sync, vault.ring.id, subject),
              ),
          );
          record.removals = remaining;
        }
        if (record.removals?.length === 0) {
          delete record.removals;
        }
        return null;
      }),
    purgeMailbox: (id) =>
      attempt(() => {
        syncBackend().steps.push(`purgeMailbox:${id}`);
        const record = saved();
        record.connections = record.connections.filter(
          ({ subject, address }) => connectionId(subject, address) !== id,
        );
        verified.delete(id);
        cached.delete(id);
        return null;
      }),
    removeQueuedPushRoutes: () =>
      attempt(() => {
        syncBackend().steps.push('removeQueuedPushRoutes');
        return null;
      }),
    recordMailboxReadback: (addresses, confirmed, epochs) =>
      attempt(() => {
        const { vault } = syncKeys();
        if (vault === undefined) {
          throw unavailable();
        }
        vault.readMailboxes = [...addresses];
        vault.savedMailboxes = { ...confirmed };
        vault.descriptorEpochs = { ...epochs };
        return null;
      }),
  };
  return { operations, handlers, project: productSyncState };
}
