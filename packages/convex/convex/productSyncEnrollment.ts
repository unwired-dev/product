import type {
  ProductSyncEnrollmentPendingRequest,
  ProductSyncEnrollmentStatus,
} from '@private-email/contracts/productSync';

import {
  productSyncEnrollmentPendingRequestValidator,
  productSyncEnrollmentRequestResponseValidator,
  productSyncEnrollmentStatusValidator,
} from '@private-email/contracts/productSync';
import { ConvexError, v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx, QueryCtx } from './_generated/server.js';
import type { AuthenticatedProductAccount } from './productAccountAuth.js';

import { mutation } from './_generated/server.js';
import { trustedDeviceDisplayName } from './productAccount.js';
import {
  requireAuthenticatedTrustedDevice,
  requireCurrentProductSyncKeyEpoch,
  trustedDeviceCredentialArgs,
} from './productAccountAuth.js';

// Long enough to read a code from one screen and type it on another.
const enrollmentRequestLifetimeMilliseconds = 15 * 60 * 1000;
const enrollmentRequestCleanupLimit = 10;
const pendingEnrollmentRequestLimit = 20;
// The caller's own request and removed requesters are skipped after the index scan.
const pendingEnrollmentRequestScanLimit = 50;
const sealedKeyRingMaximumLength = 64 * 1024;
// Standard base64 of a raw 32-byte X25519 public key or HPKE encapsulated key.
const x25519KeyPattern = /^[A-Za-z0-9+/]{43}=$/u;
const base64Pattern = /^[A-Za-z0-9+/]+={0,2}$/u;

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

async function accountRequest(
  ctx: QueryCtx | MutationCtx,
  account: AuthenticatedProductAccount,
  requestId: string,
): Promise<Doc<'productSyncEnrollmentRequests'> | null> {
  const id = ctx.db.normalizeId('productSyncEnrollmentRequests', requestId);
  const request =
    id === null ? null : await ctx.db.get('productSyncEnrollmentRequests', id);
  return request?.productAccountId === account.productAccountId
    ? request
    : null;
}

async function ownRequest(
  ctx: QueryCtx | MutationCtx,
  args: Readonly<{
    requestId: string;
    trustedDeviceCredential?: string;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<Readonly<{
  account: AuthenticatedProductAccount;
  request: Doc<'productSyncEnrollmentRequests'>;
}> | null> {
  const account = await requireAuthenticatedTrustedDevice(
    ctx,
    args.trustedDeviceId,
    args.trustedDeviceCredential,
  );
  const request = await accountRequest(ctx, account, args.requestId);
  return request?.trustedDeviceId === args.trustedDeviceId
    ? { account, request }
    : null;
}

function isOpen(
  request: Readonly<Doc<'productSyncEnrollmentRequests'>>,
  now: number,
): boolean {
  return request.state === 'pending' && request.expiresAt > now;
}

// A request outliving its device, or from a revoked one, is never shown or approved.
async function liveDevice(
  ctx: QueryCtx | MutationCtx,
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

async function pendingRequestSummary(
  ctx: QueryCtx,
  candidate: Readonly<Doc<'productSyncEnrollmentRequests'>>,
): Promise<ProductSyncEnrollmentPendingRequest | null> {
  const requester = await liveDevice(
    ctx,
    candidate.productAccountId,
    candidate.trustedDeviceId,
  );
  return requester === null
    ? null
    : {
        createdAt: candidate.createdAt,
        displayName: trustedDeviceDisplayName(requester),
        enrollmentPublicKey: candidate.enrollmentPublicKey,
        expiresAt: candidate.expiresAt,
        platform: requester.platform,
        requestId: candidate._id,
        requesterTrustedDeviceId: candidate.trustedDeviceId,
      };
}

function enrollmentStatus(
  request: Readonly<Doc<'productSyncEnrollmentRequests'>>,
  now: number,
): ProductSyncEnrollmentStatus {
  const { approval, expiresAt } = request;
  if (request.state === 'cancelled') {
    return { state: 'cancelled' };
  }
  if (expiresAt <= now) {
    return { expiresAt, state: 'expired' };
  }
  if (approval === undefined) {
    return { expiresAt, state: 'pending' };
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
}

const proofArgs = {
  ...trustedDeviceCredentialArgs,
  trustedDeviceId: v.id('trustedDevices'),
};

// A Trusted Device without Product Sync keys publishes a one-time key for approval.
export const request = mutation({
  args: { ...proofArgs, enrollmentPublicKey: v.string() },
  handler: async (ctx, args) => {
    if (!x25519KeyPattern.test(args.enrollmentPublicKey)) {
      throw new Error('Enrollment public key is invalid');
    }
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    requireInitialized(account);
    // A new request supersedes earlier ones, so their approvals can never be collected.
    const earlier = await ctx.db
      .query('productSyncEnrollmentRequests')
      .withIndex('by_trustedDeviceId', (q) =>
        q.eq('trustedDeviceId', args.trustedDeviceId),
      )
      .take(enrollmentRequestCleanupLimit);
    for (const previous of earlier) {
      await ctx.db.delete('productSyncEnrollmentRequests', previous._id);
    }
    const now = Date.now();
    const expiresAt = now + enrollmentRequestLifetimeMilliseconds;
    const requestId = await ctx.db.insert('productSyncEnrollmentRequests', {
      createdAt: now,
      enrollmentPublicKey: args.enrollmentPublicKey,
      expiresAt,
      productAccountId: account.productAccountId,
      state: 'pending',
      trustedDeviceId: args.trustedDeviceId,
    });
    return { expiresAt, requestId };
  },
  returns: productSyncEnrollmentRequestResponseValidator,
});

// Open requests from other devices in the caller's Product Account, newest first.
// Mutations evaluate server time on every explicit refresh, without a cached query result.
export const listPending = mutation({
  args: proofArgs,
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    const candidates = await ctx.db
      .query('productSyncEnrollmentRequests')
      .withIndex('by_productAccountId_and_state_and_expiresAt', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('state', 'pending')
          .gt('expiresAt', Date.now()),
      )
      .order('desc')
      .take(pendingEnrollmentRequestScanLimit);
    const summaries = await Promise.all(
      candidates
        .filter(
          ({ trustedDeviceId }) => trustedDeviceId !== args.trustedDeviceId,
        )
        .map(async (candidate) => pendingRequestSummary(ctx, candidate)),
    );
    return summaries
      .filter((summary) => summary !== null)
      .slice(0, pendingEnrollmentRequestLimit);
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

// A pending, unexpired request from the named live device, which is not the approver.
// fallow-ignore-next-line complexity -- Every unusable request fails closed with the same unavailable response.
async function approvableRequest(
  ctx: MutationCtx,
  account: AuthenticatedProductAccount,
  args: Readonly<{
    requestId: string;
    requesterTrustedDeviceId: string;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<Doc<'productSyncEnrollmentRequests'>> {
  const enrollmentRequest = await accountRequest(ctx, account, args.requestId);
  if (
    enrollmentRequest === null ||
    !isOpen(enrollmentRequest, Date.now()) ||
    enrollmentRequest.trustedDeviceId !==
      ctx.db.normalizeId('trustedDevices', args.requesterTrustedDeviceId) ||
    enrollmentRequest.trustedDeviceId === args.trustedDeviceId ||
    (await liveDevice(
      ctx,
      enrollmentRequest.productAccountId,
      enrollmentRequest.trustedDeviceId,
    )) === null
  ) {
    throwUnavailable();
  }
  return enrollmentRequest;
}

// An approving Trusted Device hands over the key ring sealed to the request's one-time key.
export const approve = mutation({
  args: {
    ...proofArgs,
    ciphertextBase64: v.string(),
    encapsulatedKeyBase64: v.string(),
    keyVersion: v.number(),
    requestId: v.string(),
    requesterTrustedDeviceId: v.string(),
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
    const enrollmentRequest = await approvableRequest(ctx, account, args);
    const now = Date.now();
    await ctx.db.patch('productSyncEnrollmentRequests', enrollmentRequest._id, {
      approval: {
        approvedAt: now,
        approvedByTrustedDeviceId: args.trustedDeviceId,
        ciphertextBase64: args.ciphertextBase64,
        encapsulatedKeyBase64: args.encapsulatedKeyBase64,
        keyVersion: args.keyVersion,
      },
      // The requesting device gets a fresh window to collect the approval.
      expiresAt: now + enrollmentRequestLifetimeMilliseconds,
      state: 'approved',
    });
    return { approved: true };
  },
  returns: v.object({ approved: v.boolean() }),
});

// Any Trusted Device in the Product Account, including the requester, may cancel an open request.
export const decline = mutation({
  args: { ...proofArgs, requestId: v.string() },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    const enrollmentRequest = await accountRequest(
      ctx,
      account,
      args.requestId,
    );
    if (enrollmentRequest === null || !isOpen(enrollmentRequest, Date.now())) {
      throwUnavailable();
    }
    await ctx.db.patch('productSyncEnrollmentRequests', enrollmentRequest._id, {
      state: 'cancelled',
    });
    return { declined: true };
  },
  returns: v.object({ declined: v.boolean() }),
});

// An uncollected envelope loses authority when its approver leaves or the epoch changes.
async function approvalStillTrusted(
  ctx: MutationCtx,
  account: AuthenticatedProductAccount,
  enrollmentRequest: Readonly<Doc<'productSyncEnrollmentRequests'>>,
): Promise<boolean> {
  const { approval } = enrollmentRequest;
  if (approval === undefined) {
    return false;
  }
  try {
    requireCurrentProductSyncKeyEpoch(account, approval.keyVersion);
  } catch {
    return false;
  }
  return (
    (await liveDevice(
      ctx,
      account.productAccountId,
      approval.approvedByTrustedDeviceId,
    )) !== null
  );
}

// Only the requesting device observes its request; anything else reads as cancelled.
// Evaluate expiry against fresh server time on every collection attempt.
export const status = mutation({
  args: { ...proofArgs, requestId: v.string() },
  handler: async (ctx, args): Promise<ProductSyncEnrollmentStatus> => {
    const own = await ownRequest(ctx, args);
    if (
      own === null ||
      (own.request.state === 'approved' &&
        !(await approvalStillTrusted(ctx, own.account, own.request)))
    ) {
      return { state: 'cancelled' };
    }
    return enrollmentStatus(own.request, Date.now());
  },
  returns: productSyncEnrollmentStatusValidator,
});

// The enrolled device removes the sealed key ring from the server; retries after a lost response are no-ops.
export const complete = mutation({
  args: { ...proofArgs, requestId: v.string() },
  handler: async (ctx, args) => {
    const own = await ownRequest(ctx, args);
    if (own === null) {
      return { completed: false };
    }
    if (enrollmentStatus(own.request, Date.now()).state !== 'approved') {
      return { completed: false };
    }
    if (!(await approvalStillTrusted(ctx, own.account, own.request))) {
      return { completed: false };
    }
    await ctx.db.delete('productSyncEnrollmentRequests', own.request._id);
    return { completed: true };
  },
  returns: v.object({ completed: v.boolean() }),
});
