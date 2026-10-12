/* oxlint-disable typescript/prefer-readonly-parameter-types -- Tests change the synthetic device's state between steps. */
import * as Arr from 'effect/Array';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Predicate from 'effect/Predicate';
import * as Schema from 'effect/Schema';

import type {
  PendingDevice,
  SyntheticProductSync,
} from './registration-product-sync-state.ts';
import type { Presented, Receipt } from './registration-vault-state.ts';

import { EncryptedPayload } from '../registration-replies.ts';
import {
  enrollmentLifetime,
  offline,
  payload,
  configuredBackend,
  syntheticApprover,
  verifierOf,
} from './registration-product-sync-state.ts';
import { refusal, success, unavailable } from './registration-vault-state.ts';

const isPayload = Schema.is(EncryptedPayload);
// A Convex refusal with its error code, returned as the function's reply.
const refused = (code: string): never => {
  throw Object.assign(new Error('Synthetic refusal'), { refusal: code });
};
const refusalOf = (error: unknown) =>
  Predicate.hasProperty(error, 'refusal') && Predicate.isString(error.refusal)
    ? error.refusal
    : undefined;
const ActivationEnvelopes = Schema.Array(
  Schema.Struct({
    trustedDeviceId: Schema.String,
    deviceEncryptionPublicKey: Schema.String,
    ciphertextBase64: Schema.String,
  }),
);
const decodeEnvelopes = Schema.decodeUnknownOption(ActivationEnvelopes);
// An HTTP action's reply.
const answer = (status: number, body: unknown) => ({
  status,
  body: JSON.stringify(body),
});
// A failure or refusal a test arranged for the next activation.
const arrangedActivation = (sync: SyntheticProductSync) => {
  if (sync.failActivationBeforeCommit) {
    sync.failActivationBeforeCommit = false;
    throw offline();
  }
  if (sync.staleOnce) {
    sync.staleOnce = false;
    return answer(401, { code: 'SIGN_IN_RECENT_AUTHENTICATION_REQUIRED' });
  }
  const reply = sync.activationReply;
  sync.activationReply = undefined;
  return reply;
};

// With Product Sync, an installation of an account that holds keys waits for admission as a
// Pending Device; an admitted one returns as the same Trusted Device, unless it was removed.
// fallow-ignore-next-line complexity -- Mirrors Convex's admission of Trusted and Pending Devices.
export function admitSyntheticInstallation(
  backend: {
    productSync: SyntheticProductSync | undefined;
    pendingDevices: boolean;
    devices: number;
  },
  account: string,
  installation: string,
) {
  const sync = backend.productSync;
  if (sync === undefined) {
    return undefined;
  }
  const keys = sync.accounts.get(account);
  const id = `device-${installation}`;
  if (sync.revoked.has(id)) {
    throw Object.assign(new Error('Synthetic refusal'), { code: 'revoked' });
  }
  const admitted =
    keys === undefined ||
    keys.admitted.has(installation) ||
    (keys.admitted.size === 0 && keys.recovery === undefined);
  if (admitted && !backend.pendingDevices) {
    const entry = keys ?? {
      records: new Map(),
      admitted: new Set<string>(),
      devices: new Map(),
      proposals: new Map(),
    };
    entry.admitted.add(installation);
    if (!entry.devices.has(id)) {
      sync.clock += 1;
      entry.devices.set(id, {
        installation,
        registeredAt: sync.clock,
        epoch: keys?.ring?.current ?? 1,
      });
    }
    sync.accounts.set(account, entry);
    return { sync, id, pending: false };
  }
  // A record that ended is replaced by a new Pending Device.
  const open = [...sync.pending].find(
    ([, pending]) =>
      pending.installation === installation &&
      pending.account === account &&
      pending.expiresAt > sync.clock,
  );
  if (open !== undefined) {
    return { sync, id: open[0], pending: true };
  }
  for (const [pendingId, pending] of sync.pending) {
    if (pending.installation === installation) {
      sync.pending.delete(pendingId);
    }
  }
  const pendingId = `pending-${(backend.devices += 1)}`;
  sync.pending.set(pendingId, {
    account,
    installation,
    expiresAt: sync.clock + 900_000,
  });
  return { sync, id: pendingId, pending: true };
}

// Convex's synthetic credential checks and protocol handlers; vault operations remain separate.
export function createSyntheticSyncHandlers(
  // The parts of a synthetic device this boundary reads: its Keychain's open enrollment request,
  // and Convex with Product Sync and an expired Pending Device record.
  shared: Readonly<{
    device: Readonly<{
      productSync: Readonly<{
        enrollment?:
          | Readonly<{ key: string; code: string; pendingDeviceId: string }>
          | undefined;
      }>;
    }>;
    backend: Readonly<{
      productSync: SyntheticProductSync | undefined;
      pendingExpired: boolean;
    }>;
  }>,
) {
  const { backend, device } = shared;
  const syncBackend = () => configuredBackend(backend);
  // The Product Sync account a live Trusted Device's proof reaches.
  // fallow-ignore-next-line complexity -- Mirrors Convex's Trusted Device proof checks.
  const accountKeys = (product: Readonly<Receipt> | undefined) => {
    const sync = syncBackend();
    if (sync.offline) {
      throw offline();
    }
    if (product !== undefined && sync.revoked.has(product.trustedDeviceId)) {
      return refused('TRUSTED_DEVICE_REVOKED');
    }
    const entry =
      product === undefined || product.pending === true
        ? undefined
        : sync.accounts.get(product.productAccountId);
    const trusted = entry?.devices.get(product?.trustedDeviceId ?? '');
    if (entry === undefined || trusted === undefined) {
      throw unavailable();
    }
    return { sync, entry, trusted };
  };
  // The caller's own Pending Device, unexpired unless it reads its status.
  // fallow-ignore-next-line complexity -- Mirrors Convex's Pending Device proof checks.
  const pendingDevice = (
    product: Readonly<Receipt> | undefined,
    expired = false,
  ) => {
    const sync = syncBackend();
    if (sync.offline) {
      throw offline();
    }
    const pending =
      product?.pending === true
        ? sync.pending.get(product.trustedDeviceId)
        : undefined;
    const entry = sync.accounts.get(product?.productAccountId ?? '');
    if (
      product === undefined ||
      pending === undefined ||
      entry === undefined ||
      pending.account !== product.productAccountId ||
      (!expired && pending.expiresAt <= sync.clock)
    ) {
      return refused('PENDING_DEVICE_UNAVAILABLE');
    }
    return { sync, entry, pending, id: product.trustedDeviceId };
  };
  // An approval authorizes only while its approver is trusted and its epoch is still the newest.
  const approvalStillTrusted = (pending: PendingDevice) => {
    const entry = syncBackend().accounts.get(pending.account);
    const { approval } = pending;
    return (
      approval !== undefined &&
      approval.keyVersion === entry?.ring?.current &&
      (approval.approver === syntheticApprover ||
        entry.devices.has(approval.approver))
    );
  };
  // This Pending Device's open request, only while it belongs to the same Pending Device.
  const openEnrollment = (product: Readonly<Receipt>) => {
    const { enrollment } = device.productSync;
    return product.pending === true &&
      enrollment?.pendingDeviceId === product.trustedDeviceId
      ? enrollment
      : undefined;
  };
  // Why Convex refuses an activation before applying anything: the snapshot it was prepared
  // against must be current, and its envelopes must cover exactly the remaining devices with bound
  // keys. A repeat of an applied proposal answers with its epoch.
  // fallow-ignore-next-line complexity -- Each condition is one of Convex's activation refusals.
  const activationRefusal = ({
    entry,
    args,
    caller,
    envelopes,
  }: Readonly<{
    entry: ReturnType<typeof accountKeys>['entry'];
    args: Readonly<Record<string, unknown>>;
    caller: string;
    envelopes: typeof ActivationEnvelopes.Type;
  }>) => {
    const target = String(args.trustedDeviceToRevokeId);
    const activated = entry.proposals.get(String(args.proposalId));
    if (activated !== undefined) {
      return activated.target === target
        ? answer(200, { keyEpoch: activated.keyEpoch })
        : answer(409, { code: 'KEY_ROTATION_CONFLICT' });
    }
    if (target === caller) {
      return answer(400, { code: 'KEY_ROTATION_INVALID' });
    }
    if (syncBackend().revoked.has(target)) {
      return answer(409, { code: 'TRUSTED_DEVICE_ALREADY_REMOVED' });
    }
    if (!entry.devices.has(target) || entry.ring === undefined) {
      return answer(404, { code: 'KEY_ROTATION_INVALID' });
    }
    const remaining = [...entry.devices.keys()].filter((id) => id !== target);
    const covered = Arr.sort(
      envelopes.map(({ trustedDeviceId }) => trustedDeviceId),
      Order.String,
    );
    const current =
      args.expectedKeyEpoch === entry.ring.current &&
      args.expectedRecoveryUpdatedAt === entry.recoveryUpdatedAt &&
      covered.join(',') === Arr.sort(remaining, Order.String).join(',') &&
      envelopes.every(
        ({ trustedDeviceId, deviceEncryptionPublicKey }) =>
          entry.devices.get(trustedDeviceId)?.key === deviceEncryptionPublicKey,
      );
    return current ? undefined : answer(409, { code: 'KEY_ROTATION_CONFLICT' });
  };
  // The removal Convex activates all at once: the target goes, each remaining device receives its
  // envelope, and the new epoch and replacement Recovery Key become current together.
  // fallow-ignore-next-line complexity -- Mirrors Convex's all-or-nothing activation.
  const activate = ({ call, product }: Presented) => {
    const sync = syncBackend();
    if (product !== undefined && sync.revoked.has(product.trustedDeviceId)) {
      return answer(403, { code: 'TRUSTED_DEVICE_REVOKED' });
    }
    const { entry, trusted: activator } = accountKeys(product);
    const { args } = call;
    const envelopes = decodeEnvelopes(args.keyEnvelopes).pipe(
      Option.getOrElse(() => []),
    );
    const refusedReply =
      arrangedActivation(sync) ??
      activationRefusal({
        entry,
        args,
        caller: product?.trustedDeviceId ?? '',
        envelopes,
      });
    if (refusedReply !== undefined) {
      return refusedReply;
    }
    const epoch = (entry.ring?.current ?? 0) + 1;
    const recovery = args.recoveryWrappedAccountKey;
    const sealed = isPayload(recovery)
      ? sync.recoveries.get(recovery.ciphertextBase64)
      : undefined;
    if (
      !isPayload(recovery) ||
      sealed?.ring.current !== epoch ||
      recovery.keyVersion !== epoch ||
      recovery.schemaVersion !== 3
    ) {
      return answer(400, { code: 'KEY_ROTATION_INVALID' });
    }
    const target = String(args.trustedDeviceToRevokeId);
    entry.admitted.delete(entry.devices.get(target)?.installation ?? '');
    sync.revoked.add(target);
    entry.devices.delete(target);
    for (const { trustedDeviceId, ciphertextBase64 } of envelopes) {
      const survivor = entry.devices.get(trustedDeviceId);
      if (survivor !== undefined) {
        survivor.envelope = { keyEpoch: epoch, ciphertext: ciphertextBase64 };
      }
    }
    entry.ring = structuredClone(sealed.ring);
    sync.clock += 1;
    entry.recovery = recovery.ciphertextBase64;
    entry.verifier = String(args.recoveryVerifier);
    entry.recoveryUpdatedAt = sync.clock;
    entry.recoveryProposal = String(args.proposalId);
    entry.proposals.set(String(args.proposalId), { keyEpoch: epoch, target });
    activator.epoch = epoch;
    sync.activations += 1;
    sync.offline = sync.offlineAfterActivation;
    if (sync.loseActivationReply) {
      sync.loseActivationReply = false;
      throw offline();
    }
    return answer(200, { keyEpoch: epoch });
  };

  const handlers: Readonly<
    Record<string, (request: Presented) => { status: number; body: string }>
  > = {
    'productSync:initialize': ({ call, product }) => {
      const { sync, entry, trusted: caller } = accountKeys(product);
      const envelope = call.args.encryptedPayload;
      const sealed = isPayload(envelope)
        ? sync.recoveries.get(envelope.ciphertextBase64)
        : undefined;
      if (sealed === undefined || !isPayload(envelope)) {
        return refusal('UNAVAILABLE');
      }
      if (entry.recovery !== undefined) {
        return success({
          initialized: entry.recovery === envelope.ciphertextBase64,
        });
      }
      entry.recovery = envelope.ciphertextBase64;
      entry.verifier = String(call.args.recoveryVerifier);
      entry.recoveryUpdatedAt = sync.clock;
      entry.ring = structuredClone(sealed.ring);
      caller.key = String(call.args.deviceEncryptionPublicKey);
      sync.initializations += 1;
      if (sync.loseInitializationReply) {
        sync.loseInitializationReply = false;
        throw offline();
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
    // Every write commits only while each record is still at its expected revision, absent where
    // none is expected; otherwise nothing changes and the stored records are returned.
    'productSync:putEncryptedPayloadsAtomically': ({ call, product }) => {
      const { sync, entry } = accountKeys(product);
      const writes = Array.isArray(call.args.writes) ? call.args.writes : [];
      const parsed = writes.flatMap((write: unknown) =>
        Predicate.hasProperty(write, 'payloadIdentifier') &&
        Predicate.hasProperty(write, 'encryptedPayload') &&
        isPayload(write.encryptedPayload)
          ? [
              {
                record: String(write.payloadIdentifier),
                sealed: write.encryptedPayload,
                expected:
                  Predicate.hasProperty(write, 'expectedUpdatedAt') &&
                  Predicate.isNumber(write.expectedUpdatedAt)
                    ? write.expectedUpdatedAt
                    : undefined,
              },
            ]
          : [],
      );
      if (parsed.length === 0 || parsed.length !== writes.length) {
        return refusal('UNAVAILABLE');
      }
      for (const { record } of parsed) {
        sync.beforePut?.(record);
      }
      if (
        parsed.some(({ sealed }) => sealed.keyVersion !== entry.ring?.current)
      ) {
        return refusal('PRODUCT_SYNC_KEY_ROTATION_REQUIRED');
      }
      const existing = parsed.map(({ record }) => entry.records.get(record));
      if (
        parsed.some(
          ({ expected }, index) => existing[index]?.updatedAt !== expected,
        )
      ) {
        return success({
          committed: false,
          payloads: existing.filter((stored) => stored !== undefined),
        });
      }
      sync.clock += 1;
      const payloads = parsed.map(({ record, sealed }) => {
        const stored = {
          payloadIdentifier: record,
          encryptedPayload: sealed,
          updatedAt: sync.clock,
        };
        entry.records.set(record, stored);
        return stored;
      });
      return success({ committed: true, payloads });
    },
    // The account's recovery envelope; a missing record is null.
    'productSync:getEncryptedPayloadForTrustedDevice': ({ call, product }) => {
      const { sync, entry } = accountKeys(product);
      const identifier = String(call.args.payloadIdentifier);
      if (identifier !== 'product-account-recovery-v1') {
        return success(entry.records.get(identifier) ?? null);
      }
      if (sync.failRecoveryRead) {
        throw offline();
      }
      const sealed =
        entry.recovery === undefined
          ? undefined
          : sync.recoveries.get(entry.recovery);
      return success(
        entry.recovery === undefined || sealed === undefined
          ? null
          : {
              payloadIdentifier: identifier,
              encryptedPayload: payload(entry.recovery, sealed.ring.current, 3),
              updatedAt: entry.recoveryUpdatedAt ?? 0,
            },
      );
    },
    // Only the current Recovery Key binds a key, once; a different bound key is never replaced.
    'productSync:bindDeviceEncryptionKey': ({ call, product }) => {
      const { entry, trusted: caller } = accountKeys(product);
      if (verifierOf(String(call.args.recoveryProof)) !== entry.verifier) {
        return success({ bound: false });
      }
      const key = String(call.args.deviceEncryptionPublicKey);
      if (caller.key !== undefined && caller.key !== key) {
        return refusal('UNAVAILABLE');
      }
      caller.key = key;
      caller.epoch = entry.ring?.current ?? 1;
      return success({ bound: true });
    },
    // A new request replaces the earlier key, so an approval sealed to it is never collected.
    'productSyncEnrollment:request': ({ call, product }) => {
      const { sync, entry, pending } = pendingDevice(product);
      if (entry.recovery === undefined) {
        return refusal('UNAVAILABLE');
      }
      pending.publicKey = String(call.args.enrollmentPublicKey);
      pending.deviceKey = String(call.args.deviceEncryptionPublicKey);
      delete pending.approval;
      delete pending.recovered;
      pending.expiresAt = sync.clock + enrollmentLifetime;
      return success({ expiresAt: pending.expiresAt });
    },
    // A declined request, or an approval whose approver left or whose epoch was superseded, reads
    // as cancelled. With `approves`, a Trusted Device approves with the code this device shows.
    // fallow-ignore-next-line complexity -- Mirrors Convex's request states and the auto-approver.
    'productSyncEnrollment:status': ({ product }) => {
      const sync = backend.productSync;
      if (sync === undefined) {
        return backend.pendingExpired
          ? refusal('PENDING_DEVICE_UNAVAILABLE')
          : success({ state: 'pending' });
      }
      const { entry, pending } = pendingDevice(product, true);
      if (pending.expiresAt <= sync.clock) {
        return success({ state: 'expired', expiresAt: pending.expiresAt });
      }
      const shown = product === undefined ? undefined : openEnrollment(product);
      if (
        sync.approves &&
        pending.approval === undefined &&
        pending.publicKey !== undefined &&
        pending.deviceKey !== undefined &&
        shown?.key === pending.publicKey &&
        entry.ring !== undefined
      ) {
        const ciphertext = `enrollment-${(sync.issued += 1)}`;
        sync.envelopes.set(ciphertext, {
          kind: 'enrollment',
          ring: structuredClone(entry.ring),
          account: pending.account,
          device: product?.trustedDeviceId ?? '',
          publicKey: pending.publicKey,
          deviceKey: pending.deviceKey,
          code: shown.code,
        });
        pending.approval = {
          keyVersion: entry.ring.current,
          ciphertext,
          approver: syntheticApprover,
        };
      }
      if (pending.publicKey === undefined) {
        return success({ state: 'cancelled' });
      }
      if (pending.approval === undefined) {
        return success({ state: 'pending', expiresAt: pending.expiresAt });
      }
      if (!approvalStillTrusted(pending)) {
        return success({ state: 'cancelled' });
      }
      return success({
        state: 'approved',
        expiresAt: pending.expiresAt,
        approval: {
          keyVersion: pending.approval.keyVersion,
          encapsulatedKeyBase64: 'synthetic',
          ciphertextBase64: pending.approval.ciphertext,
        },
      });
    },
    // Admits at the newest epoch, which the approval or the Recovery Key proof authorized, with the
    // encryption key the request or proof named.
    // fallow-ignore-next-line complexity -- Mirrors Convex's admission refusals.
    'productSyncEnrollment:complete': ({ call, product }) => {
      const { sync, entry, pending, id } = pendingDevice(product);
      if (sync.failCompletion) {
        throw offline();
      }
      const epoch = entry.ring?.current;
      if (
        call.args.keyVersion !== epoch ||
        call.args.deviceEncryptionPublicKey !== pending.deviceKey ||
        (pending.recovered !== epoch && !approvalStillTrusted(pending))
      ) {
        return success({ admitted: false });
      }
      sync.pending.delete(id);
      const trustedDeviceId = `device-${pending.installation}`;
      entry.admitted.add(pending.installation);
      sync.clock += 1;
      entry.devices.set(trustedDeviceId, {
        installation: pending.installation,
        registeredAt: sync.clock,
        ...(pending.deviceKey === undefined ? {} : { key: pending.deviceKey }),
        epoch: epoch ?? 1,
      });
      if (sync.loseCompletionReply) {
        sync.loseCompletionReply = false;
        throw offline();
      }
      return success({ admitted: true, trustedDeviceId });
    },
    // Only the current Recovery Key admits a device; a mismatch returns nothing.
    'productSyncEnrollment:recover': ({ call, product }) => {
      const { sync, entry, pending } = pendingDevice(product);
      if (
        entry.recovery === undefined ||
        verifierOf(String(call.args.recoveryProof)) !== entry.verifier
      ) {
        return success(null);
      }
      const sealed = sync.recoveries.get(entry.recovery);
      if (sealed !== undefined) {
        pending.recovered = sealed.ring.current;
      }
      pending.deviceKey = String(call.args.deviceEncryptionPublicKey);
      return success(
        sealed === undefined
          ? null
          : payload(entry.recovery, sealed.ring.current, 3),
      );
    },
    // Requests from other devices of the account that still wait for approval.
    'productSyncEnrollment:listPending': ({ product }) => {
      const { sync } = accountKeys(product);
      return success(
        [...sync.pending].flatMap(([pendingDeviceId, pending]) =>
          pending.account !== product?.productAccountId ||
          pending.expiresAt <= sync.clock ||
          pending.publicKey === undefined ||
          pending.deviceKey === undefined ||
          pending.approval !== undefined
            ? []
            : [
                {
                  createdAt: pending.expiresAt - enrollmentLifetime,
                  deviceEncryptionPublicKey: pending.deviceKey,
                  displayName: 'iPad',
                  enrollmentPublicKey: pending.publicKey,
                  expiresAt: pending.expiresAt,
                  pendingDeviceId,
                  platform: 'ios',
                },
              ],
        ),
      );
    },
    // Only a Trusted Device holding the newest epoch approves, once, the key the device showed.
    // fallow-ignore-next-line complexity -- Mirrors Convex's approval refusals.
    'productSyncEnrollment:approve': ({ call, product }) => {
      const { sync, entry, trusted: approver } = accountKeys(product);
      const { keyVersion } = call.args;
      if (keyVersion !== entry.ring?.current || approver.epoch !== keyVersion) {
        return refusal('UNAVAILABLE');
      }
      const id = String(call.args.pendingDeviceId);
      const pending = sync.pending.get(id);
      if (
        pending === undefined ||
        pending.account !== product?.productAccountId ||
        pending.expiresAt <= sync.clock ||
        pending.publicKey === undefined ||
        pending.approval !== undefined ||
        pending.publicKey !== call.args.enrollmentPublicKey
      ) {
        return refusal('ENROLLMENT_REQUEST_UNAVAILABLE');
      }
      pending.approval = {
        keyVersion,
        ciphertext: String(call.args.ciphertextBase64),
        approver: product.trustedDeviceId,
      };
      pending.expiresAt = sync.clock + enrollmentLifetime;
      return success({ approved: true });
    },
    // Any Trusted Device of the account cancels an open request; the device asks again.
    'productSyncEnrollment:decline': ({ call, product }) => {
      const { sync } = accountKeys(product);
      const pending = sync.pending.get(String(call.args.pendingDeviceId));
      if (
        pending === undefined ||
        pending.account !== product?.productAccountId ||
        pending.expiresAt <= sync.clock ||
        pending.publicKey === undefined
      ) {
        return refusal('ENROLLMENT_REQUEST_UNAVAILABLE');
      }
      delete pending.publicKey;
      delete pending.approval;
      return success({ declined: true });
    },
    'productAccount:getProductSyncKeyRotation': ({ product }) => {
      const { trusted: caller } = accountKeys(product);
      return success(
        caller.envelope === undefined
          ? null
          : {
              keyEpoch: caller.envelope.keyEpoch,
              encapsulatedKeyBase64: 'synthetic',
              ciphertextBase64: caller.envelope.ciphertext,
            },
      );
    },
    // Adoption only: stale and repeated acknowledgements never lower it or hold anything back.
    'productAccount:acknowledgeProductSyncKeyRotation': ({ call, product }) => {
      const { sync, entry, trusted: caller } = accountKeys(product);
      if (sync.failAcknowledgement) {
        throw offline();
      }
      const keyEpoch = Number(call.args.keyEpoch);
      if (keyEpoch > (entry.ring?.current ?? 1)) {
        return refusal('UNAVAILABLE');
      }
      caller.epoch = Math.max(caller.epoch, keyEpoch);
      const after = sync.afterAcknowledgement;
      sync.afterAcknowledgement = undefined;
      after?.();
      return success({ keyEpoch });
    },
    'productAccount:listTrustedDevices': ({ product }) => {
      const { entry } = accountKeys(product);
      return success(
        [...entry.devices].map(([id, trustedDevice]) => ({
          id,
          displayName: `Device ${id}`,
          registeredAt: trustedDevice.registeredAt,
          lastSeenAt: trustedDevice.registeredAt,
          platform: 'ios',
          ...(trustedDevice.key === undefined
            ? {}
            : { deviceEncryptionPublicKey: trustedDevice.key }),
        })),
      );
    },
    'productAccount:getKeyRotationProposal': ({ call, product }) => {
      const { sync, entry } = accountKeys(product);
      sync.outcomeReads += 1;
      if (sync.outcomeReads === sync.failingOutcomeRead) {
        throw offline();
      }
      const id = String(call.args.proposalId);
      const activated = entry.proposals.get(id);
      const reply = success(
        activated === undefined
          ? null
          : {
              keyEpoch: activated.keyEpoch,
              recoveryKeyCurrent: entry.recoveryProposal === id,
            },
      );
      const after = sync.afterOutcomeRead;
      sync.afterOutcomeRead = undefined;
      after?.();
      return reply;
    },
    '/trusted-devices/revoke': activate,
  };
  // Convex replies with a refusal's code; anything else fails the call itself.
  const guardedHandlers = Object.fromEntries(
    Object.entries(handlers).map(([path, handler]) => [
      path,
      (request: Presented) => {
        try {
          return handler(request);
        } catch (error) {
          const code = refusalOf(error);
          if (code === undefined) {
            throw error;
          }
          return path.startsWith('/')
            ? { status: 403, body: JSON.stringify({ code }) }
            : refusal(code);
        }
      },
    ]),
  );
  return guardedHandlers;
}
