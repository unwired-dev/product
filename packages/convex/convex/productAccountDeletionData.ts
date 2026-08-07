import { v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx } from './_generated/server.js';

import { internal } from './_generated/api.js';
import { internalMutation } from './_generated/server.js';
import {
  requireTrustedDeviceProof,
  trustedDeviceCredentialArgs,
} from './productAccountAuth.js';

const deletionBatchSize = 50;
const encryptedPayloadDeletionBatchSize = 4;
const deletionAttemptLeaseMilliseconds = 60_000;
const deletionContinuationRetryMilliseconds = 5000;
const deletionContinuationMaxRetryMilliseconds = 5 * 60 * 1000;
const revocationRequestLifetimeMilliseconds = 24 * 60 * 60 * 1000;

const revocationMaterialValidator = v.union(
  v.object({ kind: v.literal('authorization-code'), value: v.string() }),
  v.object({ kind: v.literal('access-token'), value: v.string() }),
  v.object({ kind: v.literal('refresh-token'), value: v.string() }),
);

async function authenticatedIdentity(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error('Authentication required');
  }
  return identity;
}

async function ownedDeletionRequest(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  requestId: Id<'productAccountDeletionRequests'>,
): Promise<Doc<'productAccountDeletionRequests'>> {
  const identity = await authenticatedIdentity(ctx);
  const request = await ctx.db.get(requestId);
  if (
    request === null ||
    request.tokenIdentifier !== identity.tokenIdentifier
  ) {
    throw new Error('Product Account deletion request required');
  }
  return request;
}

async function scheduleRevocationExpiry(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  request: Readonly<Doc<'productAccountDeletionRequests'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents contain mutable generated fields but are not mutated here.
): Promise<void> {
  await ctx.scheduler.runAfter(
    Math.max(
      0,
      revocationRequestLifetimeMilliseconds -
        (Date.now() - request.requestedAt),
    ),
    internal.productAccountDeletionData.scheduleRevocationRecovery,
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    { requestId: request._id },
  );
}

async function scheduleAuthorizationCodeExpiry(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  request: Readonly<Doc<'productAccountDeletionRequests'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents contain mutable generated fields but are not mutated here.
): Promise<void> {
  if (request.revocationMaterial?.kind === 'authorization-code') {
    await scheduleRevocationExpiry(ctx, request);
  }
}

export const prepareDeletion = internalMutation({
  args: {
    ...trustedDeviceCredentialArgs,
    attemptId: v.string(),
    authorizationCode: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  // fallow-ignore-next-line complexity -- One transaction arbitrates tombstones, leases, retries, and device ownership.
  handler: async (ctx, args) => {
    const identity = await authenticatedIdentity(ctx);
    const tombstone = await ctx.db
      .query('productAccountDeletionTombstones')
      .withIndex('by_tokenIdentifier', (q) =>
        q.eq('tokenIdentifier', identity.tokenIdentifier),
      )
      .unique();
    if (tombstone !== null) {
      return { state: 'already-deleted' as const };
    }
    // fallow-ignore-next-line code-duplication -- Deletion keeps its authenticated account lookup local to this transaction.
    const account = await ctx.db
      .query('productAccounts')
      .withIndex('by_tokenIdentifier', (q) =>
        q.eq('tokenIdentifier', identity.tokenIdentifier),
      )
      .unique();
    if (account === null) {
      throw new Error('Product Account required');
    }
    await requireTrustedDeviceProof(
      ctx,
      {
        deviceCredentialEnforcementActivatedAt:
          account.deviceCredentialEnforcementActivatedAt,
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        productAccountId: account._id,
      },
      {
        trustedDeviceCredential: args.trustedDeviceCredential,
        trustedDeviceId: args.trustedDeviceId,
      },
    );
    if (args.authorizationCode.length === 0) {
      throw new Error('Recent Sign in with Apple authorization is required');
    }
    const existing = await ctx.db
      .query('productAccountDeletionRequests')
      .withIndex('by_tokenIdentifier', (q) =>
        q.eq('tokenIdentifier', identity.tokenIdentifier),
      )
      .unique();
    if (existing !== null) {
      if (
        existing.phase === 'revocation-pending' &&
        existing.activeAttemptId !== undefined &&
        existing.activeAttemptId !== args.attemptId &&
        Date.now() - existing.updatedAt < deletionAttemptLeaseMilliseconds
      ) {
        return { state: 'in-progress' as const };
      }
      let { revocationMaterial } = existing;
      if (
        existing.phase === 'revocation-pending' &&
        existing.revocationSucceededAt === undefined &&
        (revocationMaterial === undefined ||
          revocationMaterial.kind === 'authorization-code')
      ) {
        revocationMaterial = {
          kind: 'authorization-code' as const,
          value: args.authorizationCode,
        };
      }
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(existing._id, {
        activeAttemptId:
          existing.phase === 'revocation-pending'
            ? args.attemptId
            : existing.activeAttemptId,
        revocationMaterial,
        updatedAt: Date.now(),
      });
      return {
        phase: existing.phase,
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        requestId: existing._id,
        revocationPreviouslyAttempted:
          existing.revocationAttemptedAt !== undefined,
        revocationPreviouslySucceeded:
          existing.revocationSucceededAt !== undefined,
        revocationMaterial,
        state: 'pending' as const,
      };
    }
    const now = Date.now();
    const revocationMaterial = {
      kind: 'authorization-code' as const,
      value: args.authorizationCode,
    };
    const requestId = await ctx.db.insert('productAccountDeletionRequests', {
      activeAttemptId: args.attemptId,
      phase: 'revocation-pending',
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      productAccountId: account._id,
      requestedAt: now,
      requestedByTrustedDeviceId: args.trustedDeviceId,
      revocationMaterial,
      tokenIdentifier: identity.tokenIdentifier,
      updatedAt: now,
    });
    const request = await ctx.db.get(requestId);
    if (request !== null) {
      await scheduleAuthorizationCodeExpiry(ctx, request);
    }
    return {
      phase: 'revocation-pending' as const,
      requestId,
      revocationPreviouslyAttempted: false,
      revocationPreviouslySucceeded: false,
      revocationMaterial,
      state: 'pending' as const,
    };
  },
  returns: v.union(
    v.object({ state: v.literal('already-deleted') }),
    v.object({ state: v.literal('in-progress') }),
    v.object({
      phase: v.union(
        v.literal('revocation-pending'),
        v.literal('deleting-data'),
      ),
      requestId: v.id('productAccountDeletionRequests'),
      revocationPreviouslyAttempted: v.boolean(),
      revocationPreviouslySucceeded: v.boolean(),
      revocationMaterial: v.optional(revocationMaterialValidator),
      state: v.literal('pending'),
    }),
  ),
});

export const storeRevocationToken = internalMutation({
  args: {
    attemptId: v.string(),
    requestId: v.id('productAccountDeletionRequests'),
    token: v.object({
      kind: v.union(v.literal('access-token'), v.literal('refresh-token')),
      value: v.string(),
    }),
  },
  handler: async (ctx, args) => {
    const request = await ownedDeletionRequest(ctx, args.requestId);
    if (
      request.phase !== 'revocation-pending' ||
      request.activeAttemptId !== args.attemptId
    ) {
      throw new Error('Product Account deletion attempt superseded');
    }
    await ctx.db.patch(args.requestId, {
      revocationMaterial: args.token,
      updatedAt: Date.now(),
    });
    await scheduleRevocationExpiry(ctx, request);
    return null;
  },
  returns: v.null(),
});

export const markRevocationAttemptStarted = internalMutation({
  args: {
    attemptId: v.string(),
    requestId: v.id('productAccountDeletionRequests'),
  },
  // fallow-ignore-next-line complexity -- A single durable recovery chain is scheduled only for the active lease.
  handler: async (ctx, args) => {
    const request = await ownedDeletionRequest(ctx, args.requestId);
    if (
      request.phase !== 'revocation-pending' ||
      request.activeAttemptId !== args.attemptId
    ) {
      throw new Error('Product Account deletion attempt superseded');
    }
    const now = Date.now();
    await ctx.db.patch(args.requestId, {
      revocationAttemptedAt: Date.now(),
      revocationRecoveryScheduledAt:
        request.revocationRecoveryScheduledAt ?? now,
      updatedAt: now,
    });
    if (request.revocationRecoveryScheduledAt === undefined) {
      await ctx.scheduler.runAfter(
        deletionAttemptLeaseMilliseconds,
        internal.productAccountDeletionData.scheduleRevocationRecovery,
        { requestId: args.requestId },
      );
    }
    return null;
  },
  returns: v.null(),
});

// fallow-ignore-next-line code-duplication -- Success and attempt markers remain separate capabilities with distinct call sites.
export const markRevocationSucceeded = internalMutation({
  args: {
    attemptId: v.string(),
    requestId: v.id('productAccountDeletionRequests'),
  },
  handler: async (ctx, args) => {
    const request = await ownedDeletionRequest(ctx, args.requestId);
    if (
      request.phase !== 'revocation-pending' ||
      request.activeAttemptId !== args.attemptId
    ) {
      throw new Error('Product Account deletion attempt superseded');
    }
    await ctx.db.patch(args.requestId, {
      revocationMaterial: undefined,
      revocationSucceededAt: Date.now(),
      updatedAt: Date.now(),
    });
    return null;
  },
  returns: v.null(),
});

export const scheduleRevocationRecovery = internalMutation({
  args: { requestId: v.id('productAccountDeletionRequests') },
  // fallow-ignore-next-line complexity -- Recovery scheduling validates every durable revocation precondition.
  handler: async (ctx, args) => {
    const request = await ctx.db.get(args.requestId);
    if (request === null || request.phase !== 'revocation-pending') {
      return null;
    }
    if (
      request.activeAttemptId !== undefined &&
      Date.now() - request.updatedAt < deletionAttemptLeaseMilliseconds
    ) {
      await ctx.scheduler.runAfter(
        deletionAttemptLeaseMilliseconds,
        internal.productAccountDeletionData.scheduleRevocationRecovery,
        args,
      );
      return null;
    }
    if (request.revocationSucceededAt !== undefined) {
      await ctx.db.patch(args.requestId, {
        activeAttemptId: undefined,
        phase: 'deleting-data',
        revocationAttemptedAt: undefined,
        revocationMaterial: undefined,
        revocationRecoveryScheduledAt: undefined,
        revocationSucceededAt: undefined,
        updatedAt: Date.now(),
      });
      await ctx.scheduler.runAfter(
        0,
        internal.productAccountDeletionData.continueProductAccountDeletion,
        { requestId: args.requestId },
      );
      return null;
    }
    if (
      Date.now() - request.requestedAt >=
        revocationRequestLifetimeMilliseconds &&
      request.revocationAttemptedAt === undefined
    ) {
      await ctx.db.delete(args.requestId);
      return null;
    }
    if (
      request.revocationAttemptedAt === undefined ||
      request.revocationMaterial?.kind === 'authorization-code' ||
      request.revocationMaterial === undefined
    ) {
      return null;
    }
    await ctx.scheduler.runAfter(
      deletionAttemptLeaseMilliseconds,
      internal.productAccountDeletionData.scheduleRevocationRecovery,
      args,
    );
    await ctx.scheduler.runAfter(
      0,
      internal.productAccountDeletion.resumeProductAccountRevocation,
      args,
    );
    return null;
  },
  returns: v.null(),
});

export const prepareRevocationRecovery = internalMutation({
  args: {
    attemptId: v.string(),
    requestId: v.id('productAccountDeletionRequests'),
  },
  // fallow-ignore-next-line complexity -- Recovery leases must reject every stale or incomplete request state.
  handler: async (ctx, args) => {
    const request = await ctx.db.get(args.requestId);
    if (
      request === null ||
      request.phase !== 'revocation-pending' ||
      request.revocationAttemptedAt === undefined ||
      request.revocationMaterial?.kind === 'authorization-code' ||
      request.revocationMaterial === undefined ||
      (request.activeAttemptId !== undefined &&
        Date.now() - request.updatedAt < deletionAttemptLeaseMilliseconds)
    ) {
      return null;
    }
    await ctx.db.patch(args.requestId, {
      activeAttemptId: args.attemptId,
      updatedAt: Date.now(),
    });
    return {
      revocationPreviouslySucceeded:
        request.revocationSucceededAt !== undefined,
      token: request.revocationMaterial,
    };
  },
  returns: v.union(
    v.null(),
    v.object({
      revocationPreviouslySucceeded: v.boolean(),
      token: v.object({
        kind: v.union(v.literal('access-token'), v.literal('refresh-token')),
        value: v.string(),
      }),
    }),
  ),
});

// fallow-ignore-next-line code-duplication -- Recovery abort retains its destructive semantics and exact lease guard.
export const abortRecoveredRevocation = internalMutation({
  args: {
    attemptId: v.string(),
    requestId: v.id('productAccountDeletionRequests'),
  },
  // fallow-ignore-next-line complexity -- Abort is permitted only for the exact active recovery lease.
  handler: async (ctx, args) => {
    const request = await ctx.db.get(args.requestId);
    if (
      request?.phase === 'revocation-pending' &&
      request.revocationAttemptedAt !== undefined &&
      request.activeAttemptId === args.attemptId
    ) {
      await ctx.db.delete(args.requestId);
    }
    return null;
  },
  returns: v.null(),
});

// fallow-ignore-next-line code-duplication -- Recovery success is an idempotent internal capability, unlike user-owned mutations.
export const markRecoveredRevocationSucceeded = internalMutation({
  args: {
    attemptId: v.string(),
    requestId: v.id('productAccountDeletionRequests'),
  },
  handler: async (ctx, args) => {
    const request = await ctx.db.get(args.requestId);
    if (
      request?.phase !== 'revocation-pending' ||
      request.activeAttemptId !== args.attemptId
    ) {
      return null;
    }
    await ctx.db.patch(args.requestId, {
      revocationMaterial: undefined,
      revocationSucceededAt: Date.now(),
      updatedAt: Date.now(),
    });
    return null;
  },
  returns: v.null(),
});

// fallow-ignore-next-line code-duplication -- User abort deletes state while release only yields the lease.
export const abortDeletion = internalMutation({
  args: {
    attemptId: v.string(),
    requestId: v.id('productAccountDeletionRequests'),
  },
  handler: async (ctx, args) => {
    const request = await ownedDeletionRequest(ctx, args.requestId);
    if (
      request.phase === 'revocation-pending' &&
      request.activeAttemptId === args.attemptId
    ) {
      await ctx.db.delete(args.requestId);
    }
    return null;
  },
  returns: v.null(),
});

// fallow-ignore-next-line code-duplication -- Lease release must remain callable without deletion authority.
export const releaseDeletionAttempt = internalMutation({
  args: {
    attemptId: v.string(),
    requestId: v.id('productAccountDeletionRequests'),
  },
  handler: async (ctx, args) => {
    const request = await ownedDeletionRequest(ctx, args.requestId);
    if (
      request.phase === 'revocation-pending' &&
      request.activeAttemptId === args.attemptId
    ) {
      await scheduleAuthorizationCodeExpiry(ctx, request);
      await ctx.db.patch(args.requestId, {
        activeAttemptId: undefined,
        updatedAt: Date.now(),
      });
    }
    return null;
  },
  returns: v.null(),
});

export const markRevocationComplete = internalMutation({
  args: {
    attemptId: v.string(),
    requestId: v.id('productAccountDeletionRequests'),
  },
  handler: async (ctx, args) => {
    const request = await ownedDeletionRequest(ctx, args.requestId);
    if (
      request.phase === 'revocation-pending' &&
      request.activeAttemptId === args.attemptId
    ) {
      await ctx.scheduler.runAfter(
        0,
        internal.productAccountDeletionData.continueProductAccountDeletion,
        { requestId: args.requestId },
      );
      await ctx.db.patch(args.requestId, {
        activeAttemptId: undefined,
        phase: 'deleting-data',
        revocationAttemptedAt: undefined,
        revocationMaterial: undefined,
        revocationRecoveryScheduledAt: undefined,
        revocationSucceededAt: undefined,
        updatedAt: Date.now(),
      });
    } else if (request.phase === 'revocation-pending') {
      throw new Error('Product Account deletion attempt superseded');
    }
    return null;
  },
  returns: v.null(),
});

// fallow-ignore-next-line code-duplication -- Recovery completion intentionally mirrors foreground completion without user auth.
export const completeRecoveredRevocation = internalMutation({
  args: {
    attemptId: v.string(),
    requestId: v.id('productAccountDeletionRequests'),
  },
  // fallow-ignore-next-line complexity -- Completion atomically fences revocation before scheduling data deletion.
  handler: async (ctx, args) => {
    const request = await ctx.db.get(args.requestId);
    if (
      request?.phase === 'revocation-pending' &&
      request.revocationAttemptedAt !== undefined &&
      request.activeAttemptId === args.attemptId
    ) {
      await ctx.scheduler.runAfter(
        0,
        internal.productAccountDeletionData.continueProductAccountDeletion,
        { requestId: args.requestId },
      );
      await ctx.db.patch(args.requestId, {
        activeAttemptId: undefined,
        phase: 'deleting-data',
        revocationAttemptedAt: undefined,
        revocationMaterial: undefined,
        revocationRecoveryScheduledAt: undefined,
        revocationSucceededAt: undefined,
        updatedAt: Date.now(),
      });
    }
    return null;
  },
  returns: v.null(),
});

async function deleteGmailRouteWork(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  productAccountId: Id<'productAccounts'>,
): Promise<boolean> {
  const route = await ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productAccountId_and_provider', (q) =>
      q.eq('productAccountId', productAccountId).eq('provider', 'gmail'),
    )
    .first();
  if (route === null) {
    return false;
  }
  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  await ctx.db.delete(route._id);
  return true;
}

async function deleteMicrosoftGraphRouteWork(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  productAccountId: Id<'productAccounts'>,
): Promise<boolean> {
  const route = await ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productAccountId_and_provider', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('provider', 'microsoft-graph'),
    )
    .first();
  if (route === null) {
    return false;
  }
  const wakeups = await ctx.db
    .query('microsoftGraphWakeupStates')
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    .withIndex('by_routeId', (q) => q.eq('routeId', route._id))
    .take(deletionBatchSize);
  if (wakeups.length > 0) {
    for (const wakeup of wakeups) {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.delete(wakeup._id);
    }
    return true;
  }
  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  await ctx.db.delete(route._id);
  return true;
}

// fallow-ignore-next-line complexity -- Ordered bounded deletion drains each account-owned table before the tombstone.
async function deleteNextBatchData(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  requestId: Id<'productAccountDeletionRequests'>,
): Promise<boolean> {
  const request = await ctx.db.get(requestId);
  if (request === null) {
    return true;
  }
  if (request.phase !== 'deleting-data') {
    throw new Error('Apple authorization revocation required');
  }
  if (await deleteGmailRouteWork(ctx, request.productAccountId)) {
    return false;
  }
  if (await deleteMicrosoftGraphRouteWork(ctx, request.productAccountId)) {
    return false;
  }
  const devices = await ctx.db
    .query('trustedDevices')
    .withIndex('by_productAccountId', (q) =>
      q.eq('productAccountId', request.productAccountId),
    )
    .take(deletionBatchSize);
  if (devices.length > 0) {
    for (const device of devices) {
      const { _id: deviceId } = device;
      const heartbeats = await ctx.db
        .query('devicePushRouteHeartbeats')
        .withIndex('by_trustedDeviceId', (q) =>
          q.eq('trustedDeviceId', deviceId),
        )
        .take(deletionBatchSize);
      if (heartbeats.length > 0) {
        for (const heartbeat of heartbeats) {
          // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
          await ctx.db.delete(heartbeat._id);
        }
        return false;
      }
      await ctx.db.delete(deviceId);
    }
    return false;
  }
  const revokedDevices = await ctx.db
    .query('revokedTrustedDevices')
    .withIndex('by_productAccountId', (q) =>
      q.eq('productAccountId', request.productAccountId),
    )
    .take(deletionBatchSize);
  if (revokedDevices.length > 0) {
    for (const revokedDevice of revokedDevices) {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.delete(revokedDevice._id);
    }
    return false;
  }
  const deviceIdentifierHistory = await ctx.db
    .query('trustedDeviceIdentifierHistory')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q.eq('productAccountId', request.productAccountId),
    )
    .take(deletionBatchSize);
  if (deviceIdentifierHistory.length > 0) {
    for (const history of deviceIdentifierHistory) {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.delete(history._id);
    }
    return false;
  }
  const payloads = await ctx.db
    .query('encryptedProductSyncPayloads')
    .withIndex('by_productAccountId', (q) =>
      q.eq('productAccountId', request.productAccountId),
    )
    .take(encryptedPayloadDeletionBatchSize);
  if (payloads.length > 0) {
    for (const payload of payloads) {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.delete(payload._id);
    }
    return false;
  }
  const bindings = await ctx.db
    .query('gmailOpaqueIdentityBindings')
    .withIndex('by_productAccountId_and_opaqueConnectionId', (q) =>
      q.eq('productAccountId', request.productAccountId),
    )
    .take(deletionBatchSize);
  if (bindings.length > 0) {
    for (const binding of bindings) {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.delete(binding._id);
    }
    return false;
  }
  const tombstone = await ctx.db
    .query('productAccountDeletionTombstones')
    .withIndex('by_tokenIdentifier', (q) =>
      q.eq('tokenIdentifier', request.tokenIdentifier),
    )
    .unique();
  if (tombstone === null) {
    await ctx.db.insert('productAccountDeletionTombstones', {
      deletedAt: Date.now(),
      productAccountId: request.productAccountId,
      tokenIdentifier: request.tokenIdentifier,
    });
  }
  const account = await ctx.db.get(request.productAccountId);
  if (account !== null) {
    await ctx.db.delete(request.productAccountId);
  }
  await ctx.db.delete(requestId);
  return true;
}

export const deleteNextBatch = internalMutation({
  args: { requestId: v.id('productAccountDeletionRequests') },
  handler: async (ctx, args) => ({
    complete: await deleteNextBatchData(ctx, args.requestId),
  }),
  returns: v.object({ complete: v.boolean() }),
});

export const continueProductAccountDeletion = internalMutation({
  args: {
    attempt: v.optional(v.number()),
    requestId: v.id('productAccountDeletionRequests'),
  },
  handler: async (ctx, args): Promise<null> => {
    try {
      const result: Readonly<{ complete: boolean }> = await ctx.runMutation(
        internal.productAccountDeletionData.deleteNextBatch,
        { requestId: args.requestId },
      );
      if (result.complete) {
        return null;
      }
      await ctx.scheduler.runAfter(
        0,
        internal.productAccountDeletionData.continueProductAccountDeletion,
        { requestId: args.requestId },
      );
    } catch {
      const attempt = (args.attempt ?? 0) + 1;
      console.error('Product Account deletion batch failed', { attempt });
      await ctx.scheduler.runAfter(
        Math.min(
          deletionContinuationRetryMilliseconds * 2 ** (attempt - 1),
          deletionContinuationMaxRetryMilliseconds,
        ),
        internal.productAccountDeletionData.continueProductAccountDeletion,
        { attempt, requestId: args.requestId },
      );
    }
    return null;
  },
  returns: v.null(),
});
