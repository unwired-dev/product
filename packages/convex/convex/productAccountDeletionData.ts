import { v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx } from './_generated/server.js';

import { internal } from './_generated/api.js';
import { internalMutation } from './_generated/server.js';
import {
  accountTokenIdentifier,
  productAccountForSignIn,
  requirePendingDeviceProof,
  requireTrustedDeviceProof,
  signInProvidersForAccount,
  trustedDeviceCredentialArgs,
} from './productAccountAuth.js';

const deletionBatchSize = 50;
const encryptedPayloadDeletionBatchSize = 4;
const deletionAttemptLeaseMilliseconds = 60_000;
const deletionContinuationRetryMilliseconds = 5000;
const deletionContinuationMaxRetryMilliseconds = 5 * 60 * 1000;
const revocationRequestLifetimeMilliseconds = 24 * 60 * 60 * 1000;

// A revocation token keeps the Apple client it was issued to.
const revocationTokenValidator = v.object({
  clientId: v.optional(v.string()),
  kind: v.union(v.literal('access-token'), v.literal('refresh-token')),
  value: v.string(),
});

const revocationMaterialValidator = v.union(
  v.object({ kind: v.literal('authorization-code'), value: v.string() }),
  revocationTokenValidator,
);

async function authenticatedIdentity(ctx: MutationCtx) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error('Authentication required');
  }
  return identity;
}

async function ownedDeletionRequest(
  ctx: MutationCtx,
  requestId: Id<'productAccountDeletionRequests'>,
): Promise<Doc<'productAccountDeletionRequests'>> {
  const identity = await authenticatedIdentity(ctx);
  const request = await ctx.db.get('productAccountDeletionRequests', requestId);
  if (
    request === null ||
    request.tokenIdentifier !==
      (await accountTokenIdentifier(ctx, identity.tokenIdentifier))
  ) {
    throw new Error('Product Account deletion request required');
  }
  return request;
}

async function scheduleRevocationExpiry(
  ctx: MutationCtx,
  request: Readonly<Doc<'productAccountDeletionRequests'>>,
): Promise<void> {
  await ctx.scheduler.runAfter(
    Math.max(
      0,
      revocationRequestLifetimeMilliseconds -
        (Date.now() - request.requestedAt),
    ),
    internal.productAccountDeletionData.scheduleRevocationRecovery,
    { requestId: request._id },
  );
}

async function scheduleAuthorizationCodeExpiry(
  ctx: MutationCtx,
  request: Readonly<Doc<'productAccountDeletionRequests'>>,
): Promise<void> {
  if (request.revocationMaterial?.kind === 'authorization-code') {
    await scheduleRevocationExpiry(ctx, request);
  }
}

type DeletingDevice = Readonly<{
  pendingDeviceCredential?: string;
  pendingDeviceId?: string;
  trustedDeviceCredential?: string;
  trustedDeviceId?: string;
}>;

// fallow-ignore-next-line complexity -- Each malformed or mixed device proof fails closed.
async function requireDeletingDevice(
  ctx: MutationCtx,
  account: Readonly<Doc<'productAccounts'>>,
  device: DeletingDevice,
): Promise<
  | { requestedByPendingDeviceId: Id<'pendingDevices'> }
  | { requestedByTrustedDeviceId: Id<'trustedDevices'> }
> {
  if (device.pendingDeviceId !== undefined) {
    const pendingDeviceId = ctx.db.normalizeId(
      'pendingDevices',
      device.pendingDeviceId,
    );
    if (
      pendingDeviceId === null ||
      device.trustedDeviceId !== undefined ||
      device.pendingDeviceCredential === undefined
    ) {
      throw new Error('Trusted device required');
    }
    await requirePendingDeviceProof(ctx, account._id, {
      allowExpired: true,
      pendingDeviceCredential: device.pendingDeviceCredential,
      pendingDeviceId,
    });
    return { requestedByPendingDeviceId: pendingDeviceId };
  }
  const trustedDeviceId =
    device.trustedDeviceId === undefined
      ? null
      : ctx.db.normalizeId('trustedDevices', device.trustedDeviceId);
  if (trustedDeviceId === null) {
    throw new Error('Trusted device required');
  }
  await requireTrustedDeviceProof(
    ctx,
    {
      deviceCredentialEnforcementActivatedAt:
        account.deviceCredentialEnforcementActivatedAt,
      productAccountId: account._id,
    },
    {
      trustedDeviceCredential: device.trustedDeviceCredential,
      trustedDeviceId,
    },
  );
  return { requestedByTrustedDeviceId: trustedDeviceId };
}

export const prepareDeletion = internalMutation({
  args: {
    ...trustedDeviceCredentialArgs,
    attemptId: v.string(),
    // Omitted only after the HTTP route verified a recent Product Sign-In.
    authorizationCode: v.optional(v.string()),
    // Strings, because the HTTP route forwards them unvalidated. Exactly one device asks: a
    // Trusted Device, or a Pending Device, which may delete the account but read none of it.
    pendingDeviceCredential: v.optional(v.string()),
    pendingDeviceId: v.optional(v.string()),
    trustedDeviceId: v.optional(v.string()),
  },
  // fallow-ignore-next-line complexity -- One transaction arbitrates tombstones, leases, retries, and device ownership.
  handler: async (ctx, args) => {
    const identity = await authenticatedIdentity(ctx);
    // A Linked Sign-In requests deletion of the account it opens, keyed by its original identity.
    const tokenIdentifier = await accountTokenIdentifier(
      ctx,
      identity.tokenIdentifier,
    );
    const tombstone = await ctx.db
      .query('productAccountDeletionTombstones')
      .withIndex('by_tokenIdentifier', (q) =>
        q.eq('tokenIdentifier', tokenIdentifier),
      )
      .unique();
    if (tombstone !== null) {
      return { state: 'already-deleted' as const };
    }
    const account = await productAccountForSignIn(ctx, tokenIdentifier);
    if (account === null) {
      throw new Error('Product Account required');
    }
    const existing = await ctx.db
      .query('productAccountDeletionRequests')
      .withIndex('by_tokenIdentifier', (q) =>
        q.eq('tokenIdentifier', tokenIdentifier),
      )
      .unique();
    // Authentication owns this already-authorized deletion. Cleanup may have removed the
    // requesting device, so resuming it cannot depend on that device still existing.
    if (existing?.phase === 'deleting-data') {
      return {
        phase: existing.phase,
        requestId: existing._id,
        revocationPreviouslyAttempted:
          existing.revocationAttemptedAt !== undefined,
        revocationPreviouslySucceeded:
          existing.revocationSucceededAt !== undefined,
        state: 'pending' as const,
      };
    }
    const requestedBy = await requireDeletingDevice(ctx, account, args);
    // An account Sign in with Apple opens revokes that authorization, so it needs a fresh code.
    const { authorizationCode } = args;
    const signInProviders =
      authorizationCode === undefined
        ? await signInProvidersForAccount(ctx, account)
        : [];
    if (
      authorizationCode === undefined
        ? signInProviders.includes('apple')
        : authorizationCode.length === 0
    ) {
      throw new Error('Recent Sign in with Apple authorization is required');
    }
    if (existing !== null) {
      if (
        existing.activeAttemptId !== undefined &&
        existing.activeAttemptId !== args.attemptId &&
        Date.now() - existing.updatedAt < deletionAttemptLeaseMilliseconds
      ) {
        return { state: 'in-progress' as const };
      }
      let { revocationMaterial } = existing;
      if (
        authorizationCode !== undefined &&
        existing.revocationSucceededAt === undefined &&
        (revocationMaterial === undefined ||
          revocationMaterial.kind === 'authorization-code')
      ) {
        revocationMaterial = {
          kind: 'authorization-code' as const,
          value: authorizationCode,
        };
      }
      await ctx.db.patch('productAccountDeletionRequests', existing._id, {
        activeAttemptId: args.attemptId,
        revocationMaterial,
        updatedAt: Date.now(),
      });
      return {
        phase: existing.phase,
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
    if (authorizationCode === undefined) {
      // Nothing to revoke: fence the account now and delete its data durably.
      const requestId = await ctx.db.insert('productAccountDeletionRequests', {
        phase: 'deleting-data',
        productAccountId: account._id,
        requestedAt: now,
        ...requestedBy,
        tokenIdentifier,
        updatedAt: now,
      });
      await ctx.scheduler.runAfter(
        0,
        internal.productAccountDeletionData.continueProductAccountDeletion,
        { requestId },
      );
      return {
        phase: 'deleting-data' as const,
        requestId,
        revocationPreviouslyAttempted: false,
        revocationPreviouslySucceeded: false,
        state: 'pending' as const,
      };
    }
    const revocationMaterial = {
      kind: 'authorization-code' as const,
      value: authorizationCode,
    };
    const requestId = await ctx.db.insert('productAccountDeletionRequests', {
      activeAttemptId: args.attemptId,
      phase: 'revocation-pending',
      productAccountId: account._id,
      requestedAt: now,
      ...requestedBy,
      revocationMaterial,
      tokenIdentifier,
      updatedAt: now,
    });
    const request = await ctx.db.get(
      'productAccountDeletionRequests',
      requestId,
    );
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
    token: revocationTokenValidator,
  },
  handler: async (ctx, args) => {
    const request = await ownedDeletionRequest(ctx, args.requestId);
    if (
      request.phase !== 'revocation-pending' ||
      request.activeAttemptId !== args.attemptId
    ) {
      throw new Error('Product Account deletion attempt superseded');
    }
    await ctx.db.patch('productAccountDeletionRequests', args.requestId, {
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
    await ctx.db.patch('productAccountDeletionRequests', args.requestId, {
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
    await ctx.db.patch('productAccountDeletionRequests', args.requestId, {
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
    const request = await ctx.db.get(
      'productAccountDeletionRequests',
      args.requestId,
    );
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
      await ctx.db.patch('productAccountDeletionRequests', args.requestId, {
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
      await ctx.db.delete('productAccountDeletionRequests', args.requestId);
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
    const request = await ctx.db.get(
      'productAccountDeletionRequests',
      args.requestId,
    );
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
    await ctx.db.patch('productAccountDeletionRequests', args.requestId, {
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
      token: revocationTokenValidator,
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
    const request = await ctx.db.get(
      'productAccountDeletionRequests',
      args.requestId,
    );
    if (
      request?.phase === 'revocation-pending' &&
      request.revocationAttemptedAt !== undefined &&
      request.activeAttemptId === args.attemptId
    ) {
      await ctx.db.delete('productAccountDeletionRequests', args.requestId);
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
    const request = await ctx.db.get(
      'productAccountDeletionRequests',
      args.requestId,
    );
    if (
      request?.phase !== 'revocation-pending' ||
      request.activeAttemptId !== args.attemptId
    ) {
      return null;
    }
    await ctx.db.patch('productAccountDeletionRequests', args.requestId, {
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
      await ctx.db.delete('productAccountDeletionRequests', args.requestId);
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
      await ctx.db.patch('productAccountDeletionRequests', args.requestId, {
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
      await ctx.db.patch('productAccountDeletionRequests', args.requestId, {
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
    const request = await ctx.db.get(
      'productAccountDeletionRequests',
      args.requestId,
    );
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
      await ctx.db.patch('productAccountDeletionRequests', args.requestId, {
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
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
): Promise<boolean> {
  const route = await ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productAccountId_and_provider_and_emailAddress', (q) =>
      q.eq('productAccountId', productAccountId).eq('provider', 'gmail'),
    )
    .first();
  if (route === null) {
    return false;
  }
  await ctx.db.delete('mailProviderConnections', route._id);
  return true;
}

async function deleteMicrosoftGraphRouteWork(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
): Promise<boolean> {
  const route = await ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productAccountId_and_provider_and_emailAddress', (q) =>
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
    .withIndex('by_routeId', (q) => q.eq('routeId', route._id))
    .take(deletionBatchSize);
  if (wakeups.length > 0) {
    for (const wakeup of wakeups) {
      await ctx.db.delete('microsoftGraphWakeupStates', wakeup._id);
    }
    return true;
  }
  await ctx.db.delete('mailProviderConnections', route._id);
  return true;
}

async function tombstoneSignIn(
  ctx: MutationCtx,
  link: Readonly<Doc<'linkedSignIns'>>,
): Promise<void> {
  const tombstone = await ctx.db
    .query('productAccountDeletionTombstones')
    .withIndex('by_tokenIdentifier', (q) =>
      q.eq('tokenIdentifier', link.tokenIdentifier),
    )
    .unique();
  if (tombstone === null) {
    await ctx.db.insert('productAccountDeletionTombstones', {
      deletedAt: Date.now(),
      productAccountId: link.productAccountId,
      tokenIdentifier: link.tokenIdentifier,
    });
  }
  await ctx.db.delete('linkedSignIns', link._id);
}

// Every Linked Sign-In is tombstoned with the account so it cannot reopen or recreate it.
async function deleteSignInLinks(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
): Promise<boolean> {
  const requests = await ctx.db
    .query('signInLinkRequests')
    .withIndex('by_productAccountId', (q) =>
      q.eq('productAccountId', productAccountId),
    )
    .take(deletionBatchSize);
  const links = await ctx.db
    .query('linkedSignIns')
    .withIndex('by_productAccountId_and_provider', (q) =>
      q.eq('productAccountId', productAccountId),
    )
    .take(deletionBatchSize);
  await Promise.all([
    ...requests.map(async (request) =>
      ctx.db.delete('signInLinkRequests', request._id),
    ),
    ...links.map(async (link) => tombstoneSignIn(ctx, link)),
  ]);
  return requests.length + links.length > 0;
}

// oxlint-disable complexity -- Ordered bounded deletion drains each account-owned table before the tombstone.
// fallow-ignore-next-line complexity -- Ordered bounded deletion drains each account-owned table before the tombstone.
async function deleteNextBatchData(
  ctx: MutationCtx,
  requestId: Id<'productAccountDeletionRequests'>,
): Promise<boolean> {
  const request = await ctx.db.get('productAccountDeletionRequests', requestId);
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
  if (await deleteSignInLinks(ctx, request.productAccountId)) {
    return false;
  }
  const pendingDevices = await ctx.db
    .query('pendingDevices')
    .withIndex('by_productAccountId_and_expiresAt', (q) =>
      q.eq('productAccountId', request.productAccountId),
    )
    .take(deletionBatchSize);
  if (pendingDevices.length > 0) {
    for (const pendingDevice of pendingDevices) {
      await ctx.db.delete('pendingDevices', pendingDevice._id);
    }
    return false;
  }
  const scheduledSends = await ctx.db
    .query('scheduledSends')
    .withIndex('by_productAccountId_and_scheduleId', (q) =>
      q.eq('productAccountId', request.productAccountId),
    )
    .take(deletionBatchSize);
  if (scheduledSends.length > 0) {
    for (const scheduledSend of scheduledSends) {
      if (scheduledSend.scheduledFunctionId !== undefined) {
        await ctx.scheduler.cancel(scheduledSend.scheduledFunctionId);
      }
      await ctx.db.delete('scheduledSends', scheduledSend._id);
    }
    return false;
  }
  const devices = await ctx.db
    .query('trustedDevices')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
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
          await ctx.db.delete('devicePushRouteHeartbeats', heartbeat._id);
        }
        return false;
      }
      await ctx.db.delete('trustedDevices', deviceId);
    }
    return false;
  }
  const revokedDevices = await ctx.db
    .query('revokedTrustedDevices')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q.eq('productAccountId', request.productAccountId),
    )
    .take(deletionBatchSize);
  if (revokedDevices.length > 0) {
    for (const revokedDevice of revokedDevices) {
      await ctx.db.delete('revokedTrustedDevices', revokedDevice._id);
    }
    return false;
  }
  const revocationTargets = await ctx.db
    .query('trustedDeviceRevocationTargets')
    .withIndex('by_productAccountId_and_trustedDeviceId', (q) =>
      q.eq('productAccountId', request.productAccountId),
    )
    .take(deletionBatchSize);
  if (revocationTargets.length > 0) {
    for (const target of revocationTargets) {
      await ctx.db.delete('trustedDeviceRevocationTargets', target._id);
    }
    return false;
  }
  const payloads = await ctx.db
    .query('encryptedProductSyncPayloads')
    .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
      q.eq('productAccountId', request.productAccountId),
    )
    .take(encryptedPayloadDeletionBatchSize);
  if (payloads.length > 0) {
    for (const payload of payloads) {
      await ctx.db.delete('encryptedProductSyncPayloads', payload._id);
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
      await ctx.db.delete('gmailOpaqueIdentityBindings', binding._id);
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
  const account = await ctx.db.get('productAccounts', request.productAccountId);
  if (account !== null) {
    await ctx.db.delete('productAccounts', request.productAccountId);
  }
  await ctx.db.delete('productAccountDeletionRequests', requestId);
  return true;
}
// oxlint-enable complexity

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
