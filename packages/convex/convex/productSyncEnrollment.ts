import type {
  ProductSyncEnrollmentPendingRequest,
  ProductSyncEnrollmentStatus,
} from '@private-email/contracts/productSync';

import {
  encryptedProductSyncPayloadBodyValidator,
  productSyncEnrollmentCompletionValidator,
  productSyncEnrollmentPendingRequestValidator,
  productSyncEnrollmentRequestResponseValidator,
  productSyncEnrollmentStatusValidator,
} from '@private-email/contracts/productSync';
import { ConvexError, v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx } from './_generated/server.js';
import type { AuthenticatedProductAccount } from './productAccountAuth.js';

import { mutation } from './_generated/server.js';
import {
  preserveTrustedDeviceRevocationTarget,
  requireTrustedDeviceCapacity,
  trustedDeviceDisplayName,
} from './productAccount.js';
import {
  enrollmentLifetimeMilliseconds,
  newestProductSyncKeyEpoch,
  pendingDeviceProofArgs,
  requireAuthenticatedPendingDevice,
  requireAuthenticatedTrustedDevice,
  requireCurrentProductSyncKeyEpoch,
  trustedDeviceCredentialArgs,
  trustedDeviceCredentialDigest,
} from './productAccountAuth.js';

// An account has at most three Pending Devices; expired ones are skipped after the index scan.
const pendingDeviceScanLimit = 10;
const sealedKeyRingMaximumLength = 64 * 1024;
const recoveryPayloadIdentifier = 'product-account-recovery-v1';
// Standard base64 of a raw 32-byte X25519 public key or HPKE encapsulated key.
const x25519KeyPattern = /^[A-Za-z0-9+/]{43}=$/u;
const base64Pattern = /^[A-Za-z0-9+/]+={0,2}$/u;
const recoveryProofPattern = /^[0-9a-f]{64}$/u;

const productSyncEnrollmentErrorCodes = {
  notInitialized: 'PRODUCT_SYNC_NOT_INITIALIZED',
  unavailable: 'ENROLLMENT_REQUEST_UNAVAILABLE',
} as const;

function throwNotInitialized(): never {
  throw new ConvexError({
    code: productSyncEnrollmentErrorCodes.notInitialized,
  });
}

// Every unusable request fails the same way, so callers learn nothing about other requests.
function throwUnavailable(): never {
  throw new ConvexError({ code: productSyncEnrollmentErrorCodes.unavailable });
}

function requireInitialized(account: AuthenticatedProductAccount): void {
  if (account.productSyncMaterialInitializedAt === undefined) {
    throwNotInitialized();
  }
}

// A Trusted Device of the same account that has not been removed.
async function liveTrustedDevice(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<Doc<'trustedDevices'> | null> {
  const [device, revocation] = await Promise.all([
    ctx.db.get('trustedDevices', trustedDeviceId),
    ctx.db
      .query('revokedTrustedDevices')
      .withIndex('by_productAccountId_and_trustedDeviceId', (q) =>
        q
          .eq('productAccountId', productAccountId)
          .eq('trustedDeviceId', trustedDeviceId),
      )
      .first(),
  ]);
  return device?.productAccountId === productAccountId && revocation === null
    ? device
    : null;
}

// An open request another device of the same account can still approve or decline.
async function openRequest(
  ctx: MutationCtx,
  account: AuthenticatedProductAccount,
  pendingDeviceId: string,
): Promise<Doc<'pendingDevices'>> {
  const id = ctx.db.normalizeId('pendingDevices', pendingDeviceId);
  const pendingDevice =
    id === null ? null : await ctx.db.get('pendingDevices', id);
  if (
    pendingDevice?.productAccountId !== account.productAccountId ||
    pendingDevice.expiresAt <= Date.now() ||
    pendingDevice.enrollmentPublicKey === undefined
  ) {
    throwUnavailable();
  }
  return pendingDevice;
}

// An approval authorizes only while its approver is trusted and its epoch is still the newest.
async function approvalStillTrusted(
  ctx: MutationCtx,
  account: AuthenticatedProductAccount,
  pendingDevice: Readonly<Doc<'pendingDevices'>>,
): Promise<boolean> {
  const { approval } = pendingDevice;
  return (
    approval !== undefined &&
    approval.keyVersion === newestProductSyncKeyEpoch(account) &&
    (await liveTrustedDevice(
      ctx,
      account.productAccountId,
      approval.approvedByTrustedDeviceId,
    )) !== null
  );
}

const trustedProofArgs = {
  ...trustedDeviceCredentialArgs,
  trustedDeviceId: v.id('trustedDevices'),
};

// A Pending Device publishes a one-time key for approval; asking again replaces the earlier key,
// so an approval sealed to it can never be collected, and renews the Enrollment Code's lifetime.
export const request = mutation({
  args: { ...pendingDeviceProofArgs, enrollmentPublicKey: v.string() },
  handler: async (ctx, args) => {
    if (!x25519KeyPattern.test(args.enrollmentPublicKey)) {
      throw new Error('Enrollment public key is invalid');
    }
    const { account, pendingDevice } = await requireAuthenticatedPendingDevice(
      ctx,
      args,
    );
    requireInitialized(account);
    const now = Date.now();
    const expiresAt = now + enrollmentLifetimeMilliseconds;
    await ctx.db.patch('pendingDevices', pendingDevice._id, {
      approval: undefined,
      enrollmentPublicKey: args.enrollmentPublicKey,
      expiresAt,
      requestedAt: now,
    });
    return { expiresAt };
  },
  returns: productSyncEnrollmentRequestResponseValidator,
});

// Pending Devices of the caller's Product Account that wait for approval, newest first.
// Mutations evaluate server time on every explicit refresh, without a cached query result.
export const listPending = mutation({
  args: trustedProofArgs,
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    const candidates = await ctx.db
      .query('pendingDevices')
      .withIndex('by_productAccountId_and_expiresAt', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .gt('expiresAt', Date.now()),
      )
      .order('desc')
      .take(pendingDeviceScanLimit);
    return candidates.flatMap(
      (candidate): ProductSyncEnrollmentPendingRequest[] =>
        candidate.enrollmentPublicKey === undefined ||
        candidate.approval !== undefined
          ? []
          : [
              {
                createdAt: candidate.requestedAt ?? candidate.createdAt,
                displayName: trustedDeviceDisplayName(candidate),
                enrollmentPublicKey: candidate.enrollmentPublicKey,
                expiresAt: candidate.expiresAt,
                pendingDeviceId: candidate._id,
                platform: candidate.platform,
              },
            ],
    );
  },
  returns: v.array(productSyncEnrollmentPendingRequestValidator),
});

function requireSealedKeyRing(
  args: Readonly<{ ciphertextBase64: string; encapsulatedKeyBase64: string }>,
): void {
  if (
    !x25519KeyPattern.test(args.encapsulatedKeyBase64) ||
    args.ciphertextBase64.length > sealedKeyRingMaximumLength ||
    !base64Pattern.test(args.ciphertextBase64)
  ) {
    throw new Error('Sealed Product Sync key ring is invalid');
  }
}

// A Trusted Device holding the account's newest key epoch seals that ring to the Pending Device's
// current one-time key. An approver behind a pending epoch adopts it first.
export const approve = mutation({
  args: {
    ...trustedProofArgs,
    ciphertextBase64: v.string(),
    encapsulatedKeyBase64: v.string(),
    enrollmentPublicKey: v.string(),
    keyVersion: v.number(),
    pendingDeviceId: v.string(),
  },
  handler: async (ctx, args) => {
    requireSealedKeyRing(args);
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    requireInitialized(account);
    requireCurrentProductSyncKeyEpoch(account, args.keyVersion);
    const approver = await ctx.db.get('trustedDevices', args.trustedDeviceId);
    if (approver?.productSyncKeyEpoch !== args.keyVersion) {
      throw new Error('Product Sync key rotation required');
    }
    const pendingDevice = await openRequest(ctx, account, args.pendingDeviceId);
    if (
      pendingDevice.approval !== undefined ||
      pendingDevice.enrollmentPublicKey !== args.enrollmentPublicKey
    ) {
      throwUnavailable();
    }
    const now = Date.now();
    await ctx.db.patch('pendingDevices', pendingDevice._id, {
      approval: {
        approvedAt: now,
        approvedByTrustedDeviceId: args.trustedDeviceId,
        ciphertextBase64: args.ciphertextBase64,
        encapsulatedKeyBase64: args.encapsulatedKeyBase64,
        keyVersion: args.keyVersion,
      },
      // The Pending Device gets a fresh window to collect the approval.
      expiresAt: now + enrollmentLifetimeMilliseconds,
    });
    return { approved: true };
  },
  returns: v.object({ approved: v.boolean() }),
});

// Any Trusted Device in the Product Account may decline an open request; the device asks again.
export const decline = mutation({
  args: { ...trustedProofArgs, pendingDeviceId: v.string() },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    const pendingDevice = await openRequest(ctx, account, args.pendingDeviceId);
    await ctx.db.patch('pendingDevices', pendingDevice._id, {
      approval: undefined,
      enrollmentPublicKey: undefined,
    });
    return { declined: true };
  },
  returns: v.object({ declined: v.boolean() }),
});

// Only the Pending Device observes its request. A declined request, or an approval whose approver
// left or whose epoch was superseded, reads as cancelled.
export const status = mutation({
  args: pendingDeviceProofArgs,
  handler: async (ctx, args): Promise<ProductSyncEnrollmentStatus> => {
    const { account, pendingDevice } = await requireAuthenticatedPendingDevice(
      ctx,
      args,
      { allowExpired: true },
    );
    const { approval, expiresAt } = pendingDevice;
    if (expiresAt <= Date.now()) {
      return { expiresAt, state: 'expired' };
    }
    if (pendingDevice.enrollmentPublicKey === undefined) {
      return { state: 'cancelled' };
    }
    if (approval === undefined) {
      return { expiresAt, state: 'pending' };
    }
    if (!(await approvalStillTrusted(ctx, account, pendingDevice))) {
      return { state: 'cancelled' };
    }
    return {
      approval: {
        ciphertextBase64: approval.ciphertextBase64,
        encapsulatedKeyBase64: approval.encapsulatedKeyBase64,
        keyVersion: approval.keyVersion,
      },
      expiresAt,
      state: 'approved',
    };
  },
  returns: productSyncEnrollmentStatusValidator,
});

// The newest recovery envelope and the verifier of the Recovery Key that opens it. While a
// rotation is pending, only the replacement Recovery Key that the removal issued admits a device.
async function admittingRecoveryEnvelope(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
): Promise<Readonly<{
  envelope: Doc<'encryptedProductSyncPayloads'>['encryptedPayload'];
  verifier: string;
}> | null> {
  const account = await ctx.db.get('productAccounts', productAccountId);
  if (account === null) {
    return null;
  }
  if (account.productSyncPendingKeyEpoch !== undefined) {
    const envelope = account.productSyncPendingRecoveryWrappedAccountKey;
    const verifier = account.productSyncPendingRecoveryVerifier;
    return envelope === undefined || verifier === undefined
      ? null
      : { envelope, verifier };
  }
  const recovery = await ctx.db
    .query('encryptedProductSyncPayloads')
    .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('payloadIdentifier', recoveryPayloadIdentifier),
    )
    .unique();
  const verifier = account.productSyncRecoveryVerifier;
  return recovery === null || verifier === undefined
    ? null
    : { envelope: recovery.encryptedPayload, verifier };
}

// A Pending Device proves the Recovery Key with a value derived from it for this purpose only.
// A match returns the newest recovery envelope, which the device opens itself, and authorizes its
// admission at that epoch; a mismatch returns nothing and changes nothing.
export const recover = mutation({
  args: { ...pendingDeviceProofArgs, recoveryProof: v.string() },
  handler: async (ctx, args) => {
    const { account, pendingDevice } = await requireAuthenticatedPendingDevice(
      ctx,
      args,
    );
    requireInitialized(account);
    const admitting = await admittingRecoveryEnvelope(
      ctx,
      account.productAccountId,
    );
    if (
      admitting === null ||
      !recoveryProofPattern.test(args.recoveryProof) ||
      (await trustedDeviceCredentialDigest(args.recoveryProof)) !==
        admitting.verifier
    ) {
      return null;
    }
    await ctx.db.patch('pendingDevices', pendingDevice._id, {
      recoveryKeyVersion: admitting.envelope.keyVersion,
    });
    return admitting.envelope;
  },
  returns: v.union(v.null(), encryptedProductSyncPayloadBodyValidator),
});

// Sent after the Pending Device stored the keys durably. It becomes a Trusted Device acknowledged
// at the authorized epoch, so it never fetches a transition, and keeps its credential.
export const complete = mutation({
  args: { ...pendingDeviceProofArgs, keyVersion: v.number() },
  handler: async (ctx, args) => {
    const { account, pendingDevice } = await requireAuthenticatedPendingDevice(
      ctx,
      args,
    );
    const keyEpoch = newestProductSyncKeyEpoch(account);
    if (
      args.keyVersion !== keyEpoch ||
      (pendingDevice.recoveryKeyVersion !== keyEpoch &&
        !(await approvalStillTrusted(ctx, account, pendingDevice)))
    ) {
      return { admitted: false as const };
    }
    await requireTrustedDeviceCapacity(ctx, account.productAccountId);
    const now = Date.now();
    const trustedDeviceId = await ctx.db.insert('trustedDevices', {
      credentialDigest: pendingDevice.credentialDigest,
      deviceIdentifier: pendingDevice.deviceIdentifier,
      ...(pendingDevice.displayName === undefined
        ? {}
        : { displayName: pendingDevice.displayName }),
      lastSeenAt: now,
      platform: pendingDevice.platform,
      productAccountId: account.productAccountId,
      productSyncKeyEpoch: keyEpoch,
      registeredAt: now,
    });
    await preserveTrustedDeviceRevocationTarget(ctx, {
      credentialDigest: pendingDevice.credentialDigest,
      deviceIdentifier: pendingDevice.deviceIdentifier,
      productAccountId: account.productAccountId,
      trustedDeviceId,
    });
    if (account.deviceCredentialEnforcementActivatedAt === undefined) {
      await ctx.db.patch('productAccounts', account.productAccountId, {
        deviceCredentialEnforcementActivatedAt: now,
      });
    }
    await ctx.db.delete('pendingDevices', pendingDevice._id);
    return { admitted: true as const, trustedDeviceId };
  },
  returns: productSyncEnrollmentCompletionValidator,
});
