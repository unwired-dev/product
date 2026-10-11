import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Predicate from 'effect/Predicate';
import * as Schema from 'effect/Schema';

import type { Code } from './registration-rejection.ts';
import type {
  NativeRegistrationVault,
  RegistrationRecord,
} from './registration-vault.ts';

import {
  backendCode,
  endsAccess,
  failWith,
  nativeSteps,
} from './registration-native.ts';
import {
  Approved,
  Declined,
  EncryptedPayload,
  EnrollmentRequested,
  EnrollmentStatus,
  KeyEnvelope,
  KeyRotationAcknowledgement,
  KeyRotationProposal,
  PendingEnrollment,
  StoredPayload,
  TrustedDeviceSummary,
} from './registration-replies.ts';
import { BackendReply } from './registration-vault.ts';

// The account's recovery envelope, under its reserved identifier.
const recoveryRecord = 'product-account-recovery-v1';

const Opened = Schema.Struct({ opened: Schema.Boolean });
const Admission = Schema.Struct({ admitted: Schema.Boolean });
const Recovered = Schema.Struct({ rejected: Schema.Boolean });
const EnrollmentKeys = Schema.Struct({
  enrollmentPublicKey: Schema.NonEmptyString,
  deviceKey: Schema.NonEmptyString,
});
const SealedEnrollment = Schema.Struct({
  keyVersion: Schema.Finite,
  encapsulatedKeyBase64: Schema.NonEmptyString,
  ciphertextBase64: Schema.NonEmptyString,
});
// What an activation carries besides this device's credentials, as native prepared it.
const RevocationRequest = Schema.Struct({
  trustedDeviceToRevokeId: Schema.NonEmptyString,
  proposalId: Schema.NonEmptyString,
  expectedKeyEpoch: Schema.Finite,
  expectedRecoveryUpdatedAt: Schema.Finite,
  keyEnvelopes: Schema.Array(
    Schema.Struct({
      trustedDeviceId: Schema.NonEmptyString,
      deviceEncryptionPublicKey: Schema.NonEmptyString,
      encapsulatedKeyBase64: Schema.NonEmptyString,
      ciphertextBase64: Schema.NonEmptyString,
    }),
  ),
  recoveryWrappedAccountKey: EncryptedPayload,
  recoveryVerifier: Schema.NonEmptyString,
});
const decodeActivated = Schema.decodeUnknownOption(
  Schema.fromJsonString(Schema.Struct({ keyEpoch: Schema.Finite })),
);
const decodeRefusal = Schema.decodeUnknownOption(
  Schema.fromJsonString(Schema.Struct({ code: Schema.String })),
);

type Proposal = typeof KeyRotationProposal.Type;
type Request = typeof PendingEnrollment.Type;
type Device = typeof TrustedDeviceSummary.Type;

// A settled removal: its notice depends on the key epoch this device holds after synchronizing.
export type Settlement = Readonly<{
  keyEpoch?: number;
  recoveryKeyCurrent: boolean;
  settledEpoch: number;
}>;
// What a removal step reports: its notice, whether Product Sync must synchronize before the status
// is read, and a settled removal's outcome.
export type RevocationReply = Readonly<{
  notice?: 'renewed' | 'unconfirmed' | 'superseded';
  synchronize?: true;
  settlement?: Settlement;
}>;

// How the account answered an activation.
type Activation =
  | Readonly<{ kind: 'activated' | 'conflict' | 'removed' | 'unknown' }>
  | Readonly<{ kind: 'refused'; code: Code }>;

const unknown: Activation = { kind: 'unknown' };
const refused = (code: Code): Activation => ({ kind: 'refused', code });
const refusalCode = (body: string) =>
  Option.match(decodeRefusal(body), {
    onNone: () => '',
    onSome: ({ code }) => code,
  });
// The activation refusals Convex answers with a conflict code.
const conflicts: ReadonlyMap<string, Activation> = new Map([
  ['KEY_ROTATION_CONFLICT', { kind: 'conflict' }],
  ['TRUSTED_DEVICE_ALREADY_REMOVED', { kind: 'removed' }],
]);
// How each status answers an activation. Refusals arrive before anything is applied; any other
// status, or a garbled success, can follow a committed activation, which its receipt settles.
const answers: ReadonlyMap<number, (body: string) => Activation> = new Map([
  [
    200,
    (body: string) =>
      Option.match(decodeActivated(body), {
        onNone: () => unknown,
        onSome: (): Activation => ({ kind: 'activated' }),
      }),
  ],
  [400, () => refused('unavailable')],
  [401, () => refused('stale-authentication')],
  [403, (body: string) => refused(backendCode(refusalCode(body)))],
  [404, () => refused('unavailable')],
  [
    409,
    (body: string) =>
      conflicts.get(refusalCode(body)) ?? refused('unavailable'),
  ],
]);
const activation = (reply: typeof BackendReply.Type | undefined) =>
  reply === undefined
    ? unknown
    : (answers.get(reply.status)?.(reply.body) ?? unknown);

// Enrollment, Recovery Key recovery, key rotation adoption and Device Revocation. Native code holds
// every key and the Recovery Key and Enrollment Code's key material; this decides each step.
export function createDeviceTrustProgram(vault: NativeRegistrationVault) {
  const { native, step, saved, sync, convex } = nativeSteps(vault);
  // Other devices' requests and the account's other Trusted Devices, as this process last listed
  // them; a request or device acted on leaves the list.
  let listed:
    | {
        account: string;
        requests: readonly Request[];
        trustedDevices: readonly Device[];
      }
    | undefined = undefined;

  const listedFor = (value: RegistrationRecord) =>
    listed !== undefined && listed.account === value.product?.productAccountId
      ? listed
      : undefined;
  const forget = (filter: Readonly<{ request?: string; device?: string }>) => {
    if (listed !== undefined) {
      listed = {
        ...listed,
        requests: listed.requests.filter(
          ({ pendingDeviceId }) => pendingDeviceId !== filter.request,
        ),
        trustedDevices: listed.trustedDevices.filter(
          ({ id }) => id !== filter.device,
        ),
      };
    }
  };
  const forgetDevices = Effect.sync(() => {
    listed = undefined;
  });

  const proposal = (id: string) =>
    convex(
      {
        endpoint: 'query',
        path: 'productAccount:getKeyRotationProposal',
        args: { proposalId: id },
        session: true,
        device: true,
      },
      Schema.NullOr(KeyRotationProposal),
    );

  // Adopts this device's newest key ring, however many removals it missed, and only then
  // acknowledges it. An activation this device sent without a reply settles here: once the account
  // recorded it, this device's own envelope carries its ring. Returns that receipt.
  const adoptRotation = Effect.gen(function* () {
    const state = yield* sync;
    const revocation = state.vault?.revocation;
    const outcome: Proposal | null =
      revocation?.submitted === true
        ? yield* proposal(revocation.proposal)
        : null;
    // Without its encryption key the device adopts no rotation, only its own committed proposal.
    if (!state.deviceKey) {
      if (outcome !== null) {
        yield* step(() => vault.settleRevocation(outcome.keyEpoch));
      }
      return outcome;
    }
    const rotation = yield* convex(
      {
        endpoint: 'query',
        path: 'productAccount:getProductSyncKeyRotation',
        args: {},
        session: true,
        device: true,
      },
      Schema.NullOr(KeyEnvelope),
    );
    if (rotation !== null) {
      yield* step(() => vault.adoptRotation(rotation));
    }
    if (outcome !== null) {
      yield* step(() => vault.settleRevocation(outcome.keyEpoch));
    }
    if (rotation !== null) {
      yield* convex(
        {
          endpoint: 'mutation',
          path: 'productAccount:acknowledgeProductSyncKeyRotation',
          args: { keyEpoch: rotation.keyEpoch },
          session: true,
          device: true,
        },
        KeyRotationAcknowledgement,
      ).pipe(
        // Adoption is durable; a later synchronization retries this tracking-only acknowledgement.
        Effect.catchIf(
          ({ code }) => !endsAccess.has(code),
          ({ code }) =>
            Effect.logError(
              'Product Sync rotation acknowledgement failed:',
              `code ${code}`,
            ),
        ),
      );
    }
    return outcome;
  });

  const confirmAdmission = native(vault.confirmAdmission, Admission).pipe(
    Effect.map(({ admitted }) => admitted),
  );

  // Asks a Trusted Device to approve this Pending Device, and adopts the keys sealed to it once they
  // open with this device's key and code. Admission follows only after the keys are stored. An
  // approval that does not open, or that became void, changes nothing; a new request replaces it.
  // True once this device is a Trusted Device.
  // fallow-ignore-next-line complexity -- Each enrollment state decides one admission step.
  const admit = Effect.gen(function* () {
    let state = yield* sync;
    // Keys stored by an attempt that did not hear back whether it was admitted.
    if (state.vault !== undefined) {
      if (yield* confirmAdmission) {
        return true;
      }
      state = yield* sync;
    }
    let notice: 'renewed' | 'rejected' | null = null;
    if (state.enrollment !== undefined) {
      const status = yield* convex(
        {
          endpoint: 'mutation',
          path: 'productSyncEnrollment:status',
          args: {},
          session: true,
          device: true,
        },
        EnrollmentStatus,
      );
      if (status.state === 'pending') {
        return false;
      }
      if (status.state === 'approved') {
        const { approval } = status;
        if (
          approval !== undefined &&
          (yield* native(() => vault.openEnrollment(approval), Opened))
            .opened &&
          (yield* confirmAdmission)
        ) {
          return true;
        }
        notice = 'rejected';
      } else {
        notice = 'renewed';
      }
    }
    const keys = yield* native(
      () => vault.beginEnrollment(notice),
      EnrollmentKeys,
    );
    yield* convex(
      {
        endpoint: 'mutation',
        path: 'productSyncEnrollment:request',
        args: {
          enrollmentPublicKey: keys.enrollmentPublicKey,
          deviceEncryptionPublicKey: keys.deviceKey,
        },
        session: true,
        device: true,
      },
      EnrollmentRequested,
    );
    return false;
  });

  // Other devices' requests and the account's other Trusted Devices, kept for approval and removal.
  const refreshDevices = Effect.gen(function* () {
    const value = yield* saved;
    const state = yield* sync;
    const account = value.product?.productAccountId;
    if (account === undefined) {
      return yield* failWith('unavailable');
    }
    const requests = yield* convex(
      {
        endpoint: 'mutation',
        path: 'productSyncEnrollment:listPending',
        args: {},
        session: true,
        device: true,
      },
      Schema.Array(PendingEnrollment),
    );
    listed = {
      account,
      requests,
      trustedDevices: listedFor(value)?.trustedDevices ?? [],
    };
    const roster = yield* convex(
      {
        endpoint: 'query',
        path: 'productAccount:listTrustedDevices',
        args: {},
        session: true,
        device: true,
      },
      Schema.Array(TrustedDeviceSummary),
    );
    listed = {
      account,
      requests,
      trustedDevices: roster.filter(({ id }) => id !== state.deviceId),
    };
  });

  // The account's recovery envelope as Convex stores it.
  const recoveryEnvelope = convex(
    {
      endpoint: 'query',
      path: 'productSync:getEncryptedPayloadForTrustedDevice',
      args: { payloadIdentifier: recoveryRecord },
      session: true,
      device: true,
    },
    Schema.NullOr(StoredPayload),
  ).pipe(
    Effect.filterOrElse(Predicate.isNotNull, () => failWith('unavailable')),
  );

  // Unlocks this device without a trusted device, after the flow renewed its Product Sign-In: the
  // Recovery Key opens the account's published recovery envelope on this device and never leaves
  // it. A Pending Device is admitted once its keys are stored. A key that does not open it, or an
  // interruption before the keys are saved, leaves the account keys and encrypted data intact.
  const recover = Effect.fnUntraced(function* (entry: string) {
    const state = yield* sync;
    // Already unlocked, for example by an approval collected while reconnecting.
    if (!state.pending && state.vault !== undefined) {
      return false;
    }
    if (state.materialInitialized !== true) {
      return yield* failWith('unavailable');
    }
    if (!state.pending) {
      const stored = yield* recoveryEnvelope;
      return (yield* native(
        () => vault.recoverTrustedDevice(entry, stored.encryptedPayload),
        Recovered,
      )).rejected;
    }
    const { rejected } = yield* native(
      () => vault.recoverPendingDevice(entry),
      Recovered,
    );
    // A rotation that started meanwhile voids the proof; the device stays pending and proves again.
    if (!rejected && !(yield* confirmAdmission)) {
      return yield* failWith('unavailable');
    }
    return rejected;
  });

  // Seals this device's keys to another device of the account, unlocked by the code it shows. Only
  // the account's newest key epoch is sealed; one this device has not adopted yet is adopted first.
  const approveEnrollment = Effect.fnUntraced(function* (
    requestId: string,
    code: string,
  ) {
    if (
      !(yield* native(() => vault.readsAsEnrollmentCode(code), Schema.Boolean))
    ) {
      return yield* failWith('enrollment-code-invalid');
    }
    const value = yield* saved;
    const state = yield* sync;
    const request = listedFor(value)?.requests.find(
      ({ pendingDeviceId }) => pendingDeviceId === requestId,
    );
    if (
      !value.session ||
      state.pending ||
      state.vault?.published !== true ||
      request === undefined
    ) {
      return yield* failWith('enrollment-unavailable');
    }
    if (!state.deviceKey) {
      return yield* failWith('unavailable');
    }
    yield* adoptRotation;
    const { pendingDeviceId, enrollmentPublicKey, deviceEncryptionPublicKey } =
      request;
    const sealed = yield* native(
      () =>
        vault.sealEnrollment(code, {
          pendingDeviceId,
          enrollmentPublicKey,
          deviceEncryptionPublicKey,
        }),
      SealedEnrollment,
    );
    yield* convex(
      {
        endpoint: 'mutation',
        path: 'productSyncEnrollment:approve',
        args: {
          pendingDeviceId,
          enrollmentPublicKey,
          deviceEncryptionPublicKey,
          ...sealed,
        },
        session: true,
        device: true,
      },
      Approved,
    );
    forget({ request: requestId });
  });

  const declineEnrollment = Effect.fnUntraced(function* (requestId: string) {
    const value = yield* saved;
    if (!value.session || value.product === undefined) {
      return yield* failWith('enrollment-unavailable');
    }
    if (!(yield* sync).deviceKey) {
      return yield* failWith('unavailable');
    }
    yield* convex(
      {
        endpoint: 'mutation',
        path: 'productSyncEnrollment:decline',
        args: { pendingDeviceId: requestId },
        session: true,
        device: true,
      },
      Declined,
    );
    forget({ request: requestId });
  });

  // The fresh roster no longer lists the selected device: it may have signed out, or enrolled again
  // under a new identifier that is still trusted, so nothing proves it was removed. The stale
  // selection is forgotten and synchronization refreshes the list.
  const unlisted = (target: string): RevocationReply => {
    forget({ device: target });
    return { synchronize: true };
  };

  // Seals a new epoch to every remaining device's bound encryption key, this one's included, and to
  // a new Recovery Key, against the epoch and recovery record read now. False when the roster no
  // longer lists the target.
  const prepare = Effect.fnUntraced(function* (target: string) {
    const recovery = yield* recoveryEnvelope;
    const roster = yield* convex(
      {
        endpoint: 'query',
        path: 'productAccount:listTrustedDevices',
        args: {},
        session: true,
        device: true,
      },
      Schema.Array(TrustedDeviceSummary),
    );
    if (!roster.some(({ id }) => id === target)) {
      return false;
    }
    yield* step(() =>
      vault.prepareRevocation({
        trustedDeviceId: target,
        expectedRecoveryUpdatedAt: recovery.updatedAt,
        devices: roster
          .filter(({ id }) => id !== target)
          .map(({ id, deviceEncryptionPublicKey }) => ({
            id,
            ...(deviceEncryptionPublicKey === undefined
              ? {}
              : { deviceEncryptionPublicKey }),
          })),
      }),
    );
    return true;
  });

  // A settled removal; synchronization may adopt a later rotation before its notice is derived.
  const settlement = Effect.fnUntraced(function* (outcome: Proposal | null) {
    const { vault: held } = yield* sync;
    if (held === undefined) {
      return yield* failWith('unavailable');
    }
    return {
      synchronize: true,
      settlement: {
        ...(outcome === null ? {} : { keyEpoch: outcome.keyEpoch }),
        recoveryKeyCurrent: outcome?.recoveryKeyCurrent === true,
        settledEpoch: held.keyEpoch,
      },
    } satisfies RevocationReply;
  });

  // Prepares removing another Trusted Device with the fresh interactive Product Sign-In the flow
  // just collected. Nothing reaches the backend until the person confirms the replacement Recovery
  // Key, which the status shows.
  // fallow-ignore-next-line complexity -- Each guard keeps a removal from replacing unsettled keys.
  const revoke = Effect.fnUntraced(function* (target: string) {
    const state = yield* sync;
    if (
      state.pending ||
      target === state.deviceId ||
      state.vault?.published !== true ||
      // Never replace a Recovery Key the person has not backed up yet.
      !state.vault.recoveryKeyConfirmed
    ) {
      return yield* failWith('unavailable');
    }
    yield* step(vault.adoptIdentity);
    if (!state.deviceKey) {
      return yield* failWith('unavailable');
    }
    // An earlier activation without a reply may have applied; adopting settles it first.
    yield* adoptRotation;
    if ((yield* sync).vault?.revocation !== undefined) {
      return {} satisfies RevocationReply;
    }
    return (yield* prepare(target)) ? {} : unlisted(target);
  });

  // Activates the prepared removal once the entry matches the end of its replacement Recovery Key.
  // A sign-in that is no longer recent rejects as stale authentication, so the flow renews it and
  // confirms again.
  // fallow-ignore-next-line complexity -- Each activation answer settles the proposal differently.
  const confirmRevocation = Effect.fnUntraced(function* (entry: string) {
    const state = yield* sync;
    const pending = state.vault?.revocation;
    // A failed status refresh can leave the host showing a proposal already settled here.
    if (pending === undefined) {
      return {} satisfies RevocationReply;
    }
    const target = pending.device;
    // Kept before sending: a lost reply is settled by sending this same request again.
    const request = yield* native(
      () => vault.submitRevocation(entry),
      RevocationRequest,
    );
    const reply = yield* native(
      () =>
        vault.call({
          endpoint: 'action',
          path: '/trusted-devices/revoke',
          args: request,
          session: true,
          device: true,
        }),
      BackendReply,
    ).pipe(Effect.orElseSucceed(() => undefined));
    const answer = activation(reply);
    if (answer.kind === 'unknown') {
      // Confirming again repeats the same request safely.
      return { notice: 'unconfirmed' } satisfies RevocationReply;
    }
    if (answer.kind === 'refused') {
      // Settles this attempt, but not an earlier unanswered submission.
      if (!pending.submitted) {
        yield* step(vault.withdrawRevocation);
      }
      return yield* failWith(answer.code);
    }
    if (answer.kind === 'removed') {
      // Another device removed it first; this proposal and its key never applied.
      yield* step(vault.discardRevocation);
      return {
        ...unlisted(target),
        notice: 'superseded',
      } satisfies RevocationReply;
    }
    if (answer.kind === 'conflict') {
      // The account changed since preparing, so this proposal never applied. Without its key the
      // device only enrolls again; otherwise a fresh proposal and key are confirmed again, and the
      // rejected one stays cancellable if preparing it fails.
      if (!state.deviceKey) {
        yield* step(vault.discardRevocation);
        return { synchronize: true } satisfies RevocationReply;
      }
      yield* step(vault.withdrawRevocation);
      yield* adoptRotation;
      if (!(yield* prepare(target))) {
        yield* step(vault.discardRevocation);
        return unlisted(target);
      }
      return { notice: 'renewed' } satisfies RevocationReply;
    }
    // Read before adopting: a failed read leaves the proposal to settle on the next attempt.
    if ((yield* proposal(request.proposalId)) === null) {
      return { notice: 'unconfirmed' } satisfies RevocationReply;
    }
    // The receipt stays until this device durably adopts the committed ring.
    const outcome = yield* adoptRotation;
    forget({ device: target });
    return yield* settlement(outcome);
  });

  // Discards the prepared removal; an activation sent without a reply is settled first, and stays
  // while its outcome is unknown.
  const cancelRevocation = Effect.gen(function* () {
    const pending = (yield* sync).vault?.revocation;
    if (pending === undefined) {
      return {} satisfies RevocationReply;
    }
    if (!pending.submitted) {
      yield* step(vault.discardRevocation);
      return {} satisfies RevocationReply;
    }
    const signedIn = yield* step(vault.adoptIdentity).pipe(
      Effect.as(true),
      Effect.catchIf(
        ({ code }) => code === 'stale-authentication',
        () => Effect.succeed(false),
      ),
    );
    // Read before adopting, so a failed read leaves the proposal in place.
    if (signedIn && (yield* proposal(pending.proposal)) !== null) {
      const outcome = yield* adoptRotation;
      if ((yield* sync).vault?.revocation === undefined) {
        return yield* settlement(outcome);
      }
    }
    // An absent receipt cannot rule out a request that is still reaching the backend.
    return { notice: 'unconfirmed' } satisfies RevocationReply;
  });

  return {
    listedFor,
    forgetDevices,
    adoptRotation,
    admit,
    refreshDevices,
    recover,
    approveEnrollment,
    declineEnrollment,
    revoke,
    confirmRevocation,
    cancelRevocation,
  };
}
