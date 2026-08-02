import { v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx } from './_generated/server.js';

import { internal } from './_generated/api.js';
import { internalMutation } from './_generated/server.js';

const deletionBatchSize = 50;
const encryptedPayloadDeletionBatchSize = 4;
const deletionAttemptLeaseMilliseconds = 60_000;

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

export const prepareDeletion = internalMutation({
  args: {
    attemptId: v.string(),
    authorizationCode: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
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
    const account = await ctx.db
      .query('productAccounts')
      .withIndex('by_tokenIdentifier', (q) =>
        q.eq('tokenIdentifier', identity.tokenIdentifier),
      )
      .unique();
    if (account === null) {
      throw new Error('Product Account required');
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
        revocationMaterial,
        state: 'pending' as const,
      };
    }
    const device = await ctx.db.get(args.trustedDeviceId);
    if (
      device === null ||
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      device.productAccountId !== account._id
    ) {
      throw new Error('Trusted device required');
    }
    if (args.authorizationCode.length === 0) {
      throw new Error('Recent Sign in with Apple authorization is required');
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
    return {
      phase: 'revocation-pending' as const,
      requestId,
      revocationPreviouslyAttempted: false,
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
    return null;
  },
  returns: v.null(),
});

export const markRevocationAttemptStarted = internalMutation({
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
      revocationAttemptedAt: Date.now(),
      updatedAt: Date.now(),
    });
    await ctx.scheduler.runAfter(
      deletionAttemptLeaseMilliseconds,
      internal.productAccountDeletionData.scheduleRevocationRecovery,
      { requestId: args.requestId },
    );
    return null;
  },
  returns: v.null(),
});

export const scheduleRevocationRecovery = internalMutation({
  args: { requestId: v.id('productAccountDeletionRequests') },
  handler: async (ctx, args) => {
    const request = await ctx.db.get(args.requestId);
    if (
      request === null ||
      request.phase !== 'revocation-pending' ||
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
    return { token: request.revocationMaterial };
  },
  returns: v.union(
    v.null(),
    v.object({
      token: v.object({
        kind: v.union(v.literal('access-token'), v.literal('refresh-token')),
        value: v.string(),
      }),
    }),
  ),
});

export const abortRecoveredRevocation = internalMutation({
  args: {
    attemptId: v.string(),
    requestId: v.id('productAccountDeletionRequests'),
  },
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
        updatedAt: Date.now(),
      });
    } else if (request.phase === 'revocation-pending') {
      throw new Error('Product Account deletion attempt superseded');
    }
    return null;
  },
  returns: v.null(),
});

export const completeRecoveredRevocation = internalMutation({
  args: {
    attemptId: v.string(),
    requestId: v.id('productAccountDeletionRequests'),
  },
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
  const wakeup = await ctx.db
    .query('microsoftGraphWakeupStates')
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    .withIndex('by_routeId', (q) => q.eq('routeId', route._id))
    .unique();
  if (wakeup !== null) {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete(wakeup._id);
  }
  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  await ctx.db.delete(route._id);
  return true;
}

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
      const heartbeat = await ctx.db
        .query('devicePushRouteHeartbeats')
        .withIndex('by_trustedDeviceId', (q) =>
          q.eq('trustedDeviceId', deviceId),
        )
        .unique();
      if (heartbeat !== null) {
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        await ctx.db.delete(heartbeat._id);
      }
      await ctx.db.delete(deviceId);
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
  args: { requestId: v.id('productAccountDeletionRequests') },
  handler: async (ctx, args): Promise<null> => {
    if (!(await deleteNextBatchData(ctx, args.requestId))) {
      await ctx.scheduler.runAfter(
        0,
        internal.productAccountDeletionData.continueProductAccountDeletion,
        args,
      );
    }
    return null;
  },
  returns: v.null(),
});
