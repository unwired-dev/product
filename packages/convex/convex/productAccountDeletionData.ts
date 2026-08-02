import { v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx } from './_generated/server.js';

import { internalMutation } from './_generated/server.js';

const deletionBatchSize = 50;

const revocationMaterialValidator = v.union(
  v.object({ kind: v.literal('authorization-code'), value: v.string() }),
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
    const device = await ctx.db.get(args.trustedDeviceId);
    if (
      device === null ||
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      device.productAccountId !== account._id
    ) {
      throw new Error('Trusted device required');
    }
    const existing = await ctx.db
      .query('productAccountDeletionRequests')
      .withIndex('by_tokenIdentifier', (q) =>
        q.eq('tokenIdentifier', identity.tokenIdentifier),
      )
      .unique();
    if (existing !== null) {
      let { revocationMaterial } = existing;
      if (
        existing.phase === 'revocation-pending' &&
        revocationMaterial?.kind !== 'refresh-token'
      ) {
        revocationMaterial = {
          kind: 'authorization-code' as const,
          value: args.authorizationCode,
        };
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        await ctx.db.patch(existing._id, {
          revocationMaterial,
          updatedAt: Date.now(),
        });
      }
      return {
        phase: existing.phase,
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        requestId: existing._id,
        revocationMaterial,
        state: 'pending' as const,
      };
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
      revocationMaterial,
      state: 'pending' as const,
    };
  },
  returns: v.union(
    v.object({ state: v.literal('already-deleted') }),
    v.object({
      phase: v.union(
        v.literal('revocation-pending'),
        v.literal('deleting-data'),
      ),
      requestId: v.id('productAccountDeletionRequests'),
      revocationMaterial: v.optional(revocationMaterialValidator),
      state: v.literal('pending'),
    }),
  ),
});

export const storeRefreshToken = internalMutation({
  args: {
    refreshToken: v.string(),
    requestId: v.id('productAccountDeletionRequests'),
  },
  handler: async (ctx, args) => {
    const request = await ownedDeletionRequest(ctx, args.requestId);
    if (request.phase !== 'revocation-pending') {
      return null;
    }
    await ctx.db.patch(args.requestId, {
      revocationMaterial: {
        kind: 'refresh-token',
        value: args.refreshToken,
      },
      updatedAt: Date.now(),
    });
    return null;
  },
  returns: v.null(),
});

export const abortDeletion = internalMutation({
  args: { requestId: v.id('productAccountDeletionRequests') },
  handler: async (ctx, args) => {
    await ownedDeletionRequest(ctx, args.requestId);
    await ctx.db.delete(args.requestId);
    return null;
  },
  returns: v.null(),
});

export const markRevocationComplete = internalMutation({
  args: { requestId: v.id('productAccountDeletionRequests') },
  handler: async (ctx, args) => {
    const request = await ownedDeletionRequest(ctx, args.requestId);
    if (request.phase === 'revocation-pending') {
      await ctx.db.patch(args.requestId, {
        phase: 'deleting-data',
        revocationMaterial: undefined,
        updatedAt: Date.now(),
      });
    }
    return null;
  },
  returns: v.null(),
});

async function deleteGmailSignalBatch(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  routingDigest: string | undefined,
): Promise<boolean> {
  if (routingDigest === undefined) {
    return false;
  }
  const signals = await ctx.db
    .query('gmailPushVerificationSignals')
    .withIndex('by_routingDigest', (q) => q.eq('routingDigest', routingDigest))
    .take(deletionBatchSize);
  for (const signal of signals) {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete(signal._id);
  }
  return signals.length > 0;
}

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
  if (await deleteGmailSignalBatch(ctx, route.gmailRoutingDigest)) {
    return true;
  }
  if (await deleteGmailSignalBatch(ctx, route.gmailPreviousRoutingDigest)) {
    return true;
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

export const deleteNextBatch = internalMutation({
  args: { requestId: v.id('productAccountDeletionRequests') },
  handler: async (ctx, args) => {
    const request = await ownedDeletionRequest(ctx, args.requestId);
    if (request.phase !== 'deleting-data') {
      throw new Error('Apple authorization revocation required');
    }
    const payloads = await ctx.db
      .query('encryptedProductSyncPayloads')
      .withIndex('by_productAccountId', (q) =>
        q.eq('productAccountId', request.productAccountId),
      )
      .take(deletionBatchSize);
    if (payloads.length > 0) {
      for (const payload of payloads) {
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        await ctx.db.delete(payload._id);
      }
      return { complete: false };
    }
    if (await deleteGmailRouteWork(ctx, request.productAccountId)) {
      return { complete: false };
    }
    if (await deleteMicrosoftGraphRouteWork(ctx, request.productAccountId)) {
      return { complete: false };
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
      return { complete: false };
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
      return { complete: false };
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
    await ctx.db.delete(args.requestId);
    return { complete: true };
  },
  returns: v.object({ complete: v.boolean() }),
});
