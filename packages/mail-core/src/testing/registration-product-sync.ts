/* oxlint-disable typescript/prefer-readonly-parameter-types -- Tests change the synthetic device's state between steps. */
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type {
  NativeRegistrationVault,
  MailboxChange,
} from '../registration-vault.ts';
import type { MailProvider } from '../registration.ts';
import type {
  Connection,
  Identity,
  Receipt,
  Ring,
  SavedRecord,
  Stored,
  SyncVault,
} from './registration-vault-state.ts';
import type { createSyntheticDevice } from './registration-vault.ts';

import { Envelope as ConvexReply } from '../registration-native.ts';
import { EncryptedPayload } from '../registration-replies.ts';
import { createSyntheticSyncHandlers } from './registration-product-sync-backend.ts';
import {
  mailboxRecord,
  payload,
  proofOf,
  configuredBackend,
  sealProfile,
  verifierOf,
} from './registration-product-sync-state.ts';
import { attempt, unavailable } from './registration-vault-state.ts';

export {
  mailboxRecord,
  createSyntheticProductSyncBackend,
  removeTrustedDevice,
  storeDescriptor,
  storedDescriptor,
  storeProfile,
  storedProfiles,
} from './registration-product-sync-state.ts';
export type { SyntheticProductSync } from './registration-product-sync-state.ts';

// The only copy of a Recovery Key not yet backed up, or a removal whose outcome is unknown.
const holdsUnsettledKeys = (vault: SyncVault | undefined) =>
  (vault?.recoveryKey !== undefined && !vault.recoveryKeyConfirmed) ||
  vault?.revocation?.submitted === true;
const isPayload = Schema.is(EncryptedPayload);
// A synthetic Enrollment Code, which reads as one only in this shape.
const enrollmentCode = /^CODE-\d+$/u;
// Replies this harness wrote itself, which always decode.
const Completion = Schema.Struct({
  admitted: Schema.Boolean,
  trustedDeviceId: Schema.optionalKey(Schema.String),
});
const Binding = Schema.Struct({ bound: Schema.Boolean });
const decodeReply = (value: unknown) =>
  Option.getOrThrow(Schema.decodeUnknownOption(ConvexReply)(value));
const decodeCompletion = (value: unknown) =>
  Option.getOrThrow(Schema.decodeUnknownOption(Completion)(value));
const decodeBinding = (value: unknown) =>
  Option.getOrThrow(Schema.decodeUnknownOption(Binding)(value));
const holds = (ring: Ring, epochs: readonly number[]) =>
  epochs.every((epoch) => ring.epochs.includes(epoch));

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

// Product Sync's synthetic native and Convex boundaries, composed into a registration process.
export function createSyntheticSyncVault(
  shared: Readonly<ReturnType<typeof createSyntheticDevice>>,
  {
    saved,
    connectionId,
    newlyAuthorized,
    live,
    connect,
    adoptIdentity,
    verified,
    cached,
  }: Readonly<{
    saved: () => SavedRecord;
    connectionId: (
      provider: MailProvider,
      subject: string,
      address: string,
    ) => string;
    newlyAuthorized: Set<string>;
    live: Readonly<{ session: Identity | undefined }>;
    connect: (
      signedIn: Readonly<Identity>,
      installation: string,
      previous?: Readonly<Receipt>,
    ) => Receipt;
    adoptIdentity: () => void;
    verified: Set<string>;
    cached: Set<string>;
  }>,
) {
  const { device, backend } = shared;
  const syncBackend = () => configuredBackend(backend);
  const guardedHandlers = createSyntheticSyncHandlers(shared);
  // The Keychain's Product Sync items, which fail to read when `unreadable`.
  const syncKeys = () => {
    if (device.productSync.unreadable) {
      throw unavailable();
    }
    return device.productSync;
  };
  // This installation's public encryption key; creating one replaces a lost key.
  const deviceKey = (creating = false) => {
    const keys = syncKeys();
    if (!keys.deviceKey || keys.deviceKeyName === undefined) {
      if (!creating) {
        throw unavailable();
      }
      keys.deviceKey = true;
      keys.deviceKeyName = `device-key-${(syncBackend().issued += 1)}`;
    }
    return keys.deviceKeyName;
  };
  const registered = () => {
    const record = saved();
    if (record.product === undefined) {
      throw unavailable();
    }
    return { record, product: record.product };
  };
  const trusted = () => {
    const { record, product } = registered();
    if (product.pending === true) {
      throw unavailable();
    }
    return { record, product };
  };
  const publishedVault = () => {
    const { product } = trusted();
    const { vault } = syncKeys();
    if (vault?.published !== true) {
      throw unavailable();
    }
    return { vault, account: product.productAccountId };
  };
  // Each record's sealed value when it opens for this account under its own identifier, at an
  // epoch this device's ring holds; otherwise null.
  const openRecords = <A>(
    records: ReadonlyArray<Readonly<Stored>>,
    sealedAs: (ciphertext: string) =>
      | Readonly<{
          ring: string;
          account: string;
          identifier: string;
          value: A;
        }>
      | undefined,
  ) => {
    const { vault, account } = publishedVault();
    return records.map(({ payloadIdentifier, encryptedPayload }) => {
      const sealed = sealedAs(encryptedPayload.ciphertextBase64);
      return sealed !== undefined &&
        sealed.ring === vault.ring.id &&
        sealed.account === account &&
        sealed.identifier === payloadIdentifier &&
        vault.ring.epochs.includes(encryptedPayload.keyVersion)
        ? sealed.value
        : null;
    });
  };
  // This Pending Device's open request, only while it belongs to the same Pending Device.
  const openEnrollment = (product: Readonly<Receipt>) => {
    const { enrollment } = device.productSync;
    return product.pending === true &&
      enrollment?.pendingDeviceId === product.trustedDeviceId
      ? enrollment
      : undefined;
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
    const enrollment = openEnrollment(product);
    return {
      pending: product.pending === true,
      ...(product.materialInitialized === undefined
        ? {}
        : { materialInitialized: product.materialInitialized }),
      deviceKey: keys.deviceKey,
      deviceId: product.trustedDeviceId,
      ...(enrollment === undefined
        ? {}
        : {
            enrollment: {
              code: enrollment.code,
              ...(enrollment.notice === undefined
                ? {}
                : { notice: enrollment.notice }),
            },
          }),
      ...(vault === undefined
        ? {}
        : {
            vault: {
              keyEpoch: vault.ring.current,
              published: vault.published,
              recoveryKeyConfirmed: vault.recoveryKeyConfirmed,
              ...(vault.recoveryKey === undefined || vault.recoveryKeyConfirmed
                ? {}
                : { recoveryKey: vault.recoveryKey }),
              ...(vault.revocation === undefined
                ? {}
                : {
                    revocation: {
                      proposal: vault.revocation.proposal,
                      device: vault.revocation.device,
                      recoveryKey: vault.revocation.recoveryKey,
                      submitted: vault.revocation.submitted,
                    },
                  }),
              ...(vault.readMailboxes === undefined
                ? {}
                : { readMailboxes: vault.readMailboxes }),
              ...(vault.savedMailboxes === undefined
                ? {}
                : { savedMailboxes: vault.savedMailboxes }),
              mailboxes: record.connections.map((connection) => {
                const id = connectionId(
                  connection.provider,
                  connection.subject,
                  connection.address,
                );
                return {
                  id,
                  record: mailboxRecord(
                    sync,
                    vault.ring.id,
                    `${connection.provider}:${connection.subject}`,
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
                id: connectionId(
                  removal.provider,
                  removal.subject,
                  removal.address,
                ),
                record: mailboxRecord(
                  sync,
                  vault.ring.id,
                  `${removal.provider}:${removal.subject}`,
                ),
                provider: removal.provider,
                address: removal.address,
                ...(removal.epoch === undefined
                  ? {}
                  : { epoch: removal.epoch }),
              })),
            },
          }),
    };
  };

  // A Convex call native makes itself, with this process's session and this device's proof.
  const send = (path: string, args: Record<string, unknown>) => {
    if (live.session === undefined) {
      throw unavailable();
    }
    const handler = guardedHandlers[path];
    if (handler === undefined) {
      throw unavailable();
    }
    const reply = decodeReply(
      handler({
        call: { endpoint: 'mutation', path, args, session: true, device: true },
        product: saved().product,
        signedIn: live.session,
      }).body,
    );
    if (reply.status !== 'success') {
      throw Object.assign(new Error('Synthetic refusal'), {
        code:
          reply.errorData?.code === 'TRUSTED_DEVICE_REVOKED'
            ? 'revoked'
            : 'unavailable',
      });
    }
    return reply.value;
  };
  // Opens a recovery envelope with an entered Recovery Key, only for this account.
  const openRecovery = (ciphertext: string, entry: string, account: string) => {
    const sealed = syncBackend().recoveries.get(ciphertext);
    return sealed?.key === entry && sealed.account === account
      ? structuredClone(sealed.ring)
      : undefined;
  };
  const storeRing = (ring: Ring) => {
    syncKeys().vault = { ring, published: true, recoveryKeyConfirmed: true };
  };

  const operations: Pick<
    NativeRegistrationVault,
    | 'createKeyRing'
    | 'recordInitialization'
    | 'reenroll'
    | 'beginEnrollment'
    | 'openEnrollment'
    | 'confirmAdmission'
    | 'recoverPendingDevice'
    | 'recoverTrustedDevice'
    | 'readsAsEnrollmentCode'
    | 'sealEnrollment'
    | 'adoptRotation'
    | 'settleRevocation'
    | 'prepareRevocation'
    | 'submitRevocation'
    | 'withdrawRevocation'
    | 'discardRevocation'
    | 'finishSynchronization'
    | 'sealMailboxDescriptor'
    | 'openMailboxDescriptors'
    | 'recordMailboxChanges'
    | 'purgeMailbox'
    | 'removeQueuedPushRoutes'
    | 'recordMailboxReadback'
    | 'sealProfileRecord'
    | 'openProfileRecords'
    | 'recordProfiles'
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
        const key = deviceKey(true);
        const envelope = `recovery-${vault.ring.id}`;
        sync.recoveries.set(envelope, {
          ring: structuredClone(vault.ring),
          key: vault.recoveryKey,
          account: product.productAccountId,
        });
        sync.steps.push('createKeyRing');
        return {
          recoveryEnvelope: payload(envelope, vault.ring.current, 3),
          recoveryVerifier: verifierOf(proofOf(vault.recoveryKey)),
          deviceKey: key,
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
        return null;
      }),
    beginEnrollment: (notice) =>
      attempt(() => {
        const sync = syncBackend();
        sync.steps.push('beginEnrollment');
        const { product } = registered();
        if (product.pending !== true) {
          throw unavailable();
        }
        const key = deviceKey(true);
        sync.issued += 1;
        syncKeys().enrollment = {
          pendingDeviceId: product.trustedDeviceId,
          key: `one-time-key-${sync.issued}`,
          code: `CODE-${sync.issued}`,
          ...(notice === null ? {} : { notice }),
        };
        return {
          enrollmentPublicKey: `one-time-key-${sync.issued}`,
          deviceKey: key,
        };
      }),
    openEnrollment: (approval) =>
      // fallow-ignore-next-line complexity -- Each condition is one binding the approval is sealed to.
      attempt(() => {
        const { product } = registered();
        const enrollment = openEnrollment(product);
        if (enrollment === undefined) {
          throw unavailable();
        }
        const sealed = syncBackend().envelopes.get(approval.ciphertextBase64);
        const opened =
          sealed?.kind === 'enrollment' &&
          sealed.publicKey === enrollment.key &&
          sealed.code === enrollment.code &&
          sealed.account === product.productAccountId &&
          sealed.device === product.trustedDeviceId &&
          sealed.deviceKey === device.productSync.deviceKeyName &&
          device.productSync.deviceKey &&
          sealed.ring.current === approval.keyVersion;
        if (opened) {
          storeRing(structuredClone(sealed.ring));
        }
        return { opened };
      }),
    confirmAdmission: () =>
      attempt(() => {
        const sync = syncBackend();
        sync.steps.push('confirmAdmission');
        const { record, product } = registered();
        const { vault } = syncKeys();
        if (product.pending !== true || vault === undefined) {
          throw unavailable();
        }
        const reply = send('productSyncEnrollment:complete', {
          keyVersion: vault.ring.current,
          deviceEncryptionPublicKey: deviceKey(),
        });
        const completion = decodeCompletion(reply);
        if (!completion.admitted || completion.trustedDeviceId === undefined) {
          syncKeys().vault = undefined;
          return { admitted: false };
        }
        record.product = {
          productAccountId: product.productAccountId,
          trustedDeviceId: completion.trustedDeviceId,
          ...(product.signInProviders === undefined
            ? {}
            : { signInProviders: product.signInProviders }),
          materialInitialized: true,
        };
        syncKeys().enrollment = undefined;
        return { admitted: true };
      }),
    recoverPendingDevice: (entry) =>
      attempt(() => {
        const { product } = registered();
        if (product.pending !== true) {
          throw unavailable();
        }
        if (entry.trim().length === 0) {
          return { rejected: true };
        }
        const envelope = send('productSyncEnrollment:recover', {
          recoveryProof: proofOf(entry),
          deviceEncryptionPublicKey: deviceKey(),
        });
        const ring = isPayload(envelope)
          ? openRecovery(
              envelope.ciphertextBase64,
              entry,
              product.productAccountId,
            )
          : undefined;
        if (ring === undefined) {
          return { rejected: true };
        }
        storeRing(ring);
        return { rejected: false };
      }),
    recoverTrustedDevice: (entry, envelope) =>
      attempt(() => {
        const { product } = trusted();
        if (entry.trim().length === 0) {
          return { rejected: true };
        }
        const ring = openRecovery(
          envelope.ciphertextBase64,
          entry,
          product.productAccountId,
        );
        if (ring === undefined) {
          return { rejected: true };
        }
        const binding = decodeBinding(
          send('productSync:bindDeviceEncryptionKey', {
            deviceEncryptionPublicKey: deviceKey(),
            recoveryProof: proofOf(entry),
          }),
        );
        if (!binding.bound) {
          return { rejected: true };
        }
        storeRing(ring);
        return { rejected: false };
      }),
    readsAsEnrollmentCode: (entry) =>
      Promise.resolve(enrollmentCode.test(entry.trim().toUpperCase())),
    sealEnrollment: (code, request) =>
      attempt(() => {
        if (!enrollmentCode.test(code.trim().toUpperCase())) {
          throw Object.assign(new Error('Synthetic'), {
            code: 'enrollment-code-invalid',
          });
        }
        const sync = syncBackend();
        const { vault, account } = publishedVault();
        deviceKey();
        const ciphertext = `enrollment-${(sync.issued += 1)}`;
        sync.envelopes.set(ciphertext, {
          kind: 'enrollment',
          ring: structuredClone(vault.ring),
          account,
          device: request.pendingDeviceId,
          publicKey: request.enrollmentPublicKey,
          deviceKey: request.deviceEncryptionPublicKey,
          code: code.trim().toUpperCase(),
        });
        return {
          keyVersion: vault.ring.current,
          encapsulatedKeyBase64: 'synthetic',
          ciphertextBase64: ciphertext,
        };
      }),
    adoptRotation: (envelope) =>
      // fallow-ignore-next-line complexity -- Each condition is one binding the rotation is sealed to.
      attempt(() => {
        const sync = syncBackend();
        sync.steps.push('adoptRotation');
        const { product } = trusted();
        const { vault } = syncKeys();
        if (vault === undefined) {
          throw unavailable();
        }
        if (vault.ring.epochs.includes(envelope.keyEpoch)) {
          return null;
        }
        const sealed = sync.envelopes.get(envelope.ciphertextBase64);
        // The new ring must keep every key this device holds, so no record becomes unreadable.
        if (
          sealed?.kind !== 'rotation' ||
          sealed.account !== product.productAccountId ||
          sealed.device !== product.trustedDeviceId ||
          sealed.deviceKey !== deviceKey() ||
          sealed.ring.current !== envelope.keyEpoch ||
          sealed.ring.id !== vault.ring.id ||
          !holds(sealed.ring, vault.ring.epochs)
        ) {
          throw unavailable();
        }
        vault.ring = structuredClone(sealed.ring);
        return null;
      }),
    settleRevocation: (keyEpoch) =>
      attempt(() => {
        const { vault } = syncKeys();
        const pending = vault?.revocation;
        if (vault === undefined || pending?.submitted !== true) {
          return null;
        }
        if (!device.productSync.deviceKey) {
          // The receipt commits this exact proposal; its confirmed backup opens only that ring.
          if (
            pending.ring.current !== keyEpoch ||
            !holds(pending.ring, vault.ring.epochs)
          ) {
            throw unavailable();
          }
          vault.ring = structuredClone(pending.ring);
        } else if (vault.ring.current < keyEpoch) {
          return null;
        }
        delete vault.revocation;
        return null;
      }),
    prepareRevocation: (proposal) =>
      // fallow-ignore-next-line complexity -- Mirrors the native guards before sealing a removal.
      attempt(() => {
        const sync = syncBackend();
        const { product } = trusted();
        const { vault, account } = publishedVault();
        const target = proposal.trustedDeviceId;
        if (
          !vault.recoveryKeyConfirmed ||
          vault.revocation?.submitted === true ||
          target === product.trustedDeviceId
        ) {
          throw unavailable();
        }
        const own = deviceKey();
        if (
          proposal.devices.find(({ id }) => id === product.trustedDeviceId)
            ?.deviceEncryptionPublicKey !== own
        ) {
          throw unavailable();
        }
        const epoch = Math.max(...vault.ring.epochs) + 1;
        const ring = {
          id: vault.ring.id,
          epochs: [...vault.ring.epochs, epoch],
          current: epoch,
        };
        const keyEnvelopes = proposal.devices.map(
          ({ id, deviceEncryptionPublicKey }) => {
            if (id === target || deviceEncryptionPublicKey === undefined) {
              throw unavailable();
            }
            const ciphertext = `rotation-${(sync.issued += 1)}`;
            sync.envelopes.set(ciphertext, {
              kind: 'rotation',
              ring: structuredClone(ring),
              account,
              device: id,
              deviceKey: deviceEncryptionPublicKey,
            });
            return {
              trustedDeviceId: id,
              deviceEncryptionPublicKey,
              encapsulatedKeyBase64: 'synthetic',
              ciphertextBase64: ciphertext,
            };
          },
        );
        sync.issued += 1;
        const recoveryKey = `SYNTHETIC-RECOVERY-${ring.id}-${epoch}-${sync.issued}`;
        const recovery = `recovery-${ring.id}-${epoch}-${sync.issued}`;
        sync.recoveries.set(recovery, {
          ring: structuredClone(ring),
          key: recoveryKey,
          account,
        });
        const proposalId = `proposal-${sync.issued}`;
        vault.revocation = {
          proposal: proposalId,
          device: target,
          recoveryKey,
          submitted: false,
          ring,
          request: {
            trustedDeviceToRevokeId: target,
            proposalId,
            expectedKeyEpoch: vault.ring.current,
            expectedRecoveryUpdatedAt: proposal.expectedRecoveryUpdatedAt,
            keyEnvelopes,
            recoveryWrappedAccountKey: payload(recovery, epoch, 3),
            recoveryVerifier: verifierOf(proofOf(recoveryKey)),
          },
        };
        return null;
      }),
    submitRevocation: (entry) =>
      attempt(() => {
        registered();
        const { vault } = syncKeys();
        const pending = vault?.revocation;
        if (pending === undefined) {
          throw unavailable();
        }
        if (
          entry.length === 0 ||
          !pending.recoveryKey.toLowerCase().endsWith(entry.toLowerCase())
        ) {
          throw Object.assign(new Error('Synthetic'), {
            code: 'recovery-key-mismatch',
          });
        }
        // A lost key permits only replay of intent that was already confirmed and submitted.
        if (!device.productSync.deviceKey && !pending.submitted) {
          throw unavailable();
        }
        adoptIdentity();
        pending.submitted = true;
        return structuredClone(pending.request);
      }),
    withdrawRevocation: () =>
      attempt(() => {
        const pending = syncKeys().vault?.revocation;
        if (pending !== undefined) {
          pending.submitted = false;
        }
        return null;
      }),
    discardRevocation: () =>
      attempt(() => {
        const { vault } = syncKeys();
        if (vault !== undefined) {
          delete vault.revocation;
        }
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
      attempt(() =>
        openRecords(records, (ciphertext) => {
          const sealed = syncBackend().sealed.get(ciphertext);
          return (
            sealed && {
              ...sealed,
              identifier: sealed.record,
              value: sealed.descriptor,
            }
          );
        }),
      ),
    recordMailboxChanges: (changes, settledRemovals) =>
      attempt(() => {
        const record = saved();
        for (const change of changes) {
          const connection = record.connections.find(
            ({ provider, subject, address }) =>
              connectionId(provider, subject, address) === change.id,
          );
          if (connection !== undefined) {
            applyChange(connection, change);
          }
        }
        const { vault } = syncKeys();
        const sync = syncBackend();
        if (vault !== undefined && settledRemovals.length > 0) {
          const remaining = (record.removals ?? []).filter(
            ({ subject, provider }) =>
              !settledRemovals.includes(
                mailboxRecord(sync, vault.ring.id, `${provider}:${subject}`),
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
          ({ provider, subject, address }) =>
            connectionId(provider, subject, address) !== id,
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
    sealProfileRecord: (record) =>
      attempt(() => {
        const { account } = publishedVault();
        return sealProfile(syncBackend(), account, record);
      }),
    openProfileRecords: (records) =>
      attempt(() =>
        openRecords(records, (ciphertext) => {
          const sealed = syncBackend().sealedProfiles.get(ciphertext);
          return sealed && { ...sealed, value: structuredClone(sealed.record) };
        }),
      ),
    recordProfiles: (state) =>
      attempt(() => {
        const { vault } = syncKeys();
        if (vault === undefined || trusted().product.pending === true) {
          throw unavailable();
        }
        syncBackend().steps.push('recordProfiles');
        saved().profiles = structuredClone(state);
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
  return {
    operations,
    handlers: guardedHandlers,
    project: productSyncState,
  };
}
