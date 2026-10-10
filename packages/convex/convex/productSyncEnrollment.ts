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
  isSealedKeyRing,
  newestProductSyncKeyEpoch,
  pendingDeviceProofArgs,
  provesCurrentRecoveryKey,
  requireAuthenticatedPendingDevice,
  requireAuthenticatedTrustedDevice,
  requireCurrentProductSyncKeyEpoch,
  requireDeviceEncryptionPublicKey,
  throwProductSyncKeyRotationRequired,
  trustedDeviceCredentialArgs,
  x25519KeyPattern,
} from './productAccountAuth.js';

// An account has at most three Pending Devices; expired ones are skipped after the index scan.
const pendingDeviceScanLimit = 10;
const recoveryPayloadIdentifier = 'product-account-recovery-v1';

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
// fallow-ignore-next-line complexity -- Every unusable request fails closed with the same unavailable response.
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

// A Pending Device publishes a one-time key for approval with its long-lived device key; asking
// again replaces both, so an approval sealed to the earlier one can never be collected, and renews
// the Enrollment Code's lifetime.
export const request = mutation({
  args: {
    ...pendingDeviceProofArgs,
    deviceEncryptionPublicKey: v.string(),
    enrollmentPublicKey: v.string(),
  },
  handler: async (ctx, args) => {
    if (!x25519KeyPattern.test(args.enrollmentPublicKey)) {
      throw new Error('Enrollment public key is invalid');
    }
    requireDeviceEncryptionPublicKey(args.deviceEncryptionPublicKey);
    const { account, pendingDevice } = await requireAuthenticatedPendingDevice(
      ctx,
      args,
    );
    requireInitialized(account);
    const now = Date.now();
    const expiresAt = now + enrollmentLifetimeMilliseconds;
    await ctx.db.patch('pendingDevices', pendingDevice._id, {
      approval: undefined,
      deviceEncryptionPublicKey: args.deviceEncryptionPublicKey,
      enrollmentPublicKey: args.enrollmentPublicKey,
      expiresAt,
      recoveryKeyVersion: undefined,
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
      // fallow-ignore-next-line complexity -- Only an open request with both of its keys is listed.
      (candidate): ProductSyncEnrollmentPendingRequest[] =>
        candidate.enrollmentPublicKey === undefined ||
        candidate.deviceEncryptionPublicKey === undefined ||
        candidate.approval !== undefined
          ? []
          : [
              {
                createdAt: candidate.requestedAt ?? candidate.createdAt,
                deviceEncryptionPublicKey: candidate.deviceEncryptionPublicKey,
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
  if (!isSealedKeyRing(args)) {
    throw new Error('Sealed Product Sync key ring is invalid');
  }
}

// A Trusted Device holding the account's newest key epoch seals that ring to the Pending Device's
// current one-time key. An approver behind the newest epoch adopts it first.
export const approve = mutation({
  args: {
    ...trustedProofArgs,
    ciphertextBase64: v.string(),
    deviceEncryptionPublicKey: v.string(),
    encapsulatedKeyBase64: v.string(),
    enrollmentPublicKey: v.string(),
    keyVersion: v.number(),
    pendingDeviceId: v.string(),
  },
  // fallow-ignore-next-line complexity -- Each refused approval fails closed before the ring is stored.
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
      throwProductSyncKeyRotationRequired();
    }
    const pendingDevice = await openRequest(ctx, account, args.pendingDeviceId);
    if (
      pendingDevice.approval !== undefined ||
      pendingDevice.enrollmentPublicKey !== args.enrollmentPublicKey ||
      pendingDevice.deviceEncryptionPublicKey !== args.deviceEncryptionPublicKey
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
  // fallow-ignore-next-line complexity -- Expiry, authorization and request state determine the response.
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

// A Pending Device proves the current Recovery Key with a value derived from it for this purpose
// only. A match returns the current recovery envelope, which the device opens itself, and
// authorizes its admission at that epoch with the device key it presented; a mismatch returns
// nothing and changes nothing.
export const recover = mutation({
  args: {
    ...pendingDeviceProofArgs,
    deviceEncryptionPublicKey: v.string(),
    recoveryProof: v.string(),
  },
  handler: async (ctx, args) => {
    requireDeviceEncryptionPublicKey(args.deviceEncryptionPublicKey);
    const { account, pendingDevice } = await requireAuthenticatedPendingDevice(
      ctx,
      args,
    );
    requireInitialized(account);
    const [productAccount, recovery] = await Promise.all([
      ctx.db.get('productAccounts', account.productAccountId),
      ctx.db
        .query('encryptedProductSyncPayloads')
        .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
          q
            .eq('productAccountId', account.productAccountId)
            .eq('payloadIdentifier', recoveryPayloadIdentifier),
        )
        .unique(),
    ]);
    if (
      productAccount === null ||
      recovery === null ||
      !(await provesCurrentRecoveryKey(productAccount, args.recoveryProof))
    ) {
      return null;
    }
    await ctx.db.patch('pendingDevices', pendingDevice._id, {
      deviceEncryptionPublicKey: args.deviceEncryptionPublicKey,
      recoveryKeyVersion: recovery.encryptedPayload.keyVersion,
    });
    return recovery.encryptedPayload;
  },
  returns: v.union(v.null(), encryptedProductSyncPayloadBodyValidator),
});

// Sent after the Pending Device stored the keys durably. It becomes a Trusted Device acknowledged
// at the authorized epoch, keeps its credential and binds the encryption key later rotations seal to.
export const complete = mutation({
  args: {
    ...pendingDeviceProofArgs,
    deviceEncryptionPublicKey: v.string(),
    keyVersion: v.number(),
  },
  // fallow-ignore-next-line complexity -- Refused identifiers, stale epochs and void authorizations cannot admit a device.
  handler: async (ctx, args) => {
    requireDeviceEncryptionPublicKey(args.deviceEncryptionPublicKey);
    const { account, pendingDevice } = await requireAuthenticatedPendingDevice(
      ctx,
      args,
    );
    const keyEpoch = newestProductSyncKeyEpoch(account);
    // A removed installation's identifier stays refused, even if it waited again after a sign-out.
    const revocation = await ctx.db
      .query('revokedTrustedDevices')
      .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('deviceIdentifier', pendingDevice.deviceIdentifier),
      )
      .first();
    if (revocation !== null) {
      await ctx.db.delete('pendingDevices', pendingDevice._id);
      return { admitted: false as const };
    }
    // Only the device key presented in the authorizing request or Recovery Key proof is bound.
    if (
      args.keyVersion !== keyEpoch ||
      args.deviceEncryptionPublicKey !==
        pendingDevice.deviceEncryptionPublicKey ||
      (pendingDevice.recoveryKeyVersion !== keyEpoch &&
        !(await approvalStillTrusted(ctx, account, pendingDevice)))
    ) {
      return { admitted: false as const };
    }
    await requireTrustedDeviceCapacity(ctx, account.productAccountId);
    const now = Date.now();
    const trustedDeviceId = await ctx.db.insert('trustedDevices', {
      credentialDigest: pendingDevice.credentialDigest,
      deviceEncryptionPublicKey: args.deviceEncryptionPublicKey,
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
