import type { Infer } from 'convex/values';

import {
  devicePushRegistrationResponseValidator,
  gmailPushVerificationResponseValidator,
} from '@private-email/contracts/pushRelay';
import { v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx, QueryCtx } from './_generated/server.js';

import { internal } from './_generated/api.js';
import {
  internalMutation,
  internalQuery,
  mutation,
  query,
} from './_generated/server.js';
import { requireAuthenticatedTrustedDevice } from './productAccountAuth.js';

const apnsEnvironmentValidator = v.union(
  v.literal('production'),
  v.literal('sandbox'),
);

const apnsRecipientValidator = v.object({
  apnsEnvironment: apnsEnvironmentValidator,
  apnsToken: v.string(),
  pushCleanupGeneration: v.number(),
  routeId: v.string(),
  trustedDeviceId: v.id('trustedDevices'),
});

type ApnsRecipient = Readonly<{
  apnsEnvironment: Infer<typeof apnsEnvironmentValidator>;
  apnsToken: string;
  pushCleanupGeneration: number;
  routeId: string;
  trustedDeviceId: Id<'trustedDevices'>;
}>;

const gmailPushVerificationSignalLifetimeMs = 10 * 60 * 1000;
const devicePushRouteInactivityLifetimeMs = 30 * 24 * 60 * 60 * 1000;
const devicePushRouteReconciliationBatchSize = 10;
const devicePushTokenCleanupBatchSize = 10;
const gmailPushProofCleanupBatchSize = 10;

function gmailHistoryIdAtOrAfter(
  candidateHistoryId: string,
  requestedHistoryId: string,
): boolean {
  if (candidateHistoryId === requestedHistoryId) {
    return true;
  }
  try {
    return BigInt(candidateHistoryId) >= BigInt(requestedHistoryId);
  } catch {
    return false;
  }
}

// fallow-ignore-next-line complexity
async function gmailRecipients(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  emailAddress: string,
): Promise<ApnsRecipient[]> {
  const connections = ctx.db
    .query('mailProviderConnections')
    .withIndex('by_provider_and_emailAddress_and_pushVerifiedAt', (q) =>
      q
        .eq('provider', 'gmail')
        .eq('emailAddress', emailAddress)
        .gt('pushVerifiedAt', undefined),
    );
  const recipients: ApnsRecipient[] = [];

  for await (const connection of connections) {
    // oxlint-disable-next-line eslint/no-use-before-define -- Function declarations are hoisted.
    const recipient = await apnsRecipientForDevice(ctx, {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      routeId: connection._id,
      pushVerifiedAt: connection.pushVerifiedAt ?? 0,
      trustedDeviceId: connection.trustedDeviceId,
    });
    if (recipient !== null) {
      recipients.push(recipient);
      if (recipients.length === 100) {
        break;
      }
    }
  }

  return recipients;
}

async function apnsRecipientForDevice(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Request data is immutable input.
  request: Readonly<{
    routeId: Id<'mailProviderConnections'>;
    pushVerifiedAt: number;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<ApnsRecipient | null> {
  const device = await ctx.db.get(request.trustedDeviceId);
  // oxlint-disable-next-line eslint/no-use-before-define -- Helper narrows the route fields.
  if (!hasActiveApnsRoute(device)) {
    return null;
  }
  if (request.pushVerifiedAt <= (device.gmailPushProofsInvalidatedAt ?? 0)) {
    return null;
  }
  // oxlint-disable-next-line eslint/no-use-before-define -- Helper builds the recipient after route validation.
  return apnsRecipient(device, request.routeId);
}

function apnsRecipient(
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  device: Readonly<
    Doc<'trustedDevices'> & {
      apnsEnvironment: Infer<typeof apnsEnvironmentValidator>;
      apnsToken: string;
    }
  >,
  routeId: Id<'mailProviderConnections'>,
): ApnsRecipient {
  return {
    apnsEnvironment: device.apnsEnvironment,
    apnsToken: device.apnsToken,
    pushCleanupGeneration: device.pushCleanupGeneration ?? 0,
    routeId,
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    trustedDeviceId: device._id,
  };
}

function hasActiveApnsRoute(
  device: Doc<'trustedDevices'> | null, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
): device is Doc<'trustedDevices'> & {
  apnsEnvironment: Infer<typeof apnsEnvironmentValidator>;
  apnsToken: string;
} {
  return (
    device?.apnsEnvironment !== undefined && device.apnsToken !== undefined
  );
}

function isOtherVerifiedGmailRoute(
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  trustedDeviceId: Id<'trustedDevices'>,
): boolean {
  return (
    connection.pushVerifiedAt !== undefined &&
    connection.trustedDeviceId !== trustedDeviceId
  );
}

async function hasOtherActiveGmailRoute(
  ctx: QueryCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex ids are immutable branded strings.
  request: Readonly<{
    emailAddress: string;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<boolean> {
  const connections = ctx.db
    .query('mailProviderConnections')
    .withIndex('by_provider_and_emailAddress_and_pushVerifiedAt', (q) =>
      q.eq('provider', 'gmail').eq('emailAddress', request.emailAddress),
    );

  for await (const connection of connections) {
    if (isOtherVerifiedGmailRoute(connection, request.trustedDeviceId)) {
      const device = await ctx.db.get(connection.trustedDeviceId);
      if (
        hasActiveApnsRoute(device) &&
        (connection.pushVerifiedAt ?? 0) >
          (device.gmailPushProofsInvalidatedAt ?? 0)
      ) {
        return true;
      }
    }
  }
  return false;
}

function gmailConnectionsForDevice(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  productAccountId: Id<'productAccounts'>,
  trustedDeviceId: Id<'trustedDevices'>,
) {
  return ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productAccountId_and_provider_and_trustedDeviceId', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('provider', 'gmail')
        .eq('trustedDeviceId', trustedDeviceId),
    );
}

async function requireGmailConnection(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  productAccountId: Id<'productAccounts'>,
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<Doc<'mailProviderConnections'>> {
  const connection = await gmailConnectionsForDevice(
    ctx,
    productAccountId,
    trustedDeviceId,
  ).unique();
  if (connection === null) {
    throw new Error('Gmail connection required');
  }
  return connection;
}

function hasMatchingVerificationSignal(
  signals: ReadonlyArray<Doc<'gmailPushVerificationSignals'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  request: Readonly<{ historyId: string; invalidatedAt: number; now: number }>,
): boolean {
  return signals.some(
    (candidate) =>
      candidate.receivedAt > request.invalidatedAt &&
      request.now - candidate.receivedAt <=
        gmailPushVerificationSignalLifetimeMs &&
      gmailHistoryIdAtOrAfter(candidate.historyId, request.historyId),
  );
}

function nextVerifiedHistoryId(
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  historyId: string,
): string {
  if (connection.pushVerifiedHistoryId === undefined) {
    return historyId;
  }
  return gmailHistoryIdAtOrAfter(historyId, connection.pushVerifiedHistoryId)
    ? historyId
    : connection.pushVerifiedHistoryId;
}

function gmailVerificationPatch(
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  request: Readonly<{ historyId: string; now: number; verified: boolean }>,
) {
  if (request.verified) {
    return {
      pushVerificationHistoryId: undefined,
      pushVerificationRequestedAt: undefined,
      pushVerifiedHistoryId: nextVerifiedHistoryId(
        connection,
        request.historyId,
      ),
      pushVerifiedAt: request.now,
    };
  }
  return {
    pushVerificationHistoryId: request.historyId,
    pushVerificationRequestedAt: request.now,
    pushVerifiedHistoryId: connection.pushVerifiedHistoryId,
    pushVerifiedAt: connection.pushVerifiedAt,
  };
}

function gmailPushProofUpdatedAt(
  device: Doc<'trustedDevices'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  now: number,
): number {
  return Math.max(
    now,
    (device.gmailPushProofsInvalidatedAt ?? 0) + 1,
    connection.pushVerifiedAt ?? 0,
  );
}

async function recordGmailVerificationSignal(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  signal: Readonly<{ emailAddress: string; historyId: string; now: number }>,
): Promise<void> {
  const existingSignal = await ctx.db
    .query('gmailPushVerificationSignals')
    .withIndex('by_emailAddress_and_historyId', (q) =>
      q
        .eq('emailAddress', signal.emailAddress)
        .eq('historyId', signal.historyId),
    )
    .unique();
  const signalId =
    existingSignal === null
      ? await ctx.db.insert('gmailPushVerificationSignals', {
          emailAddress: signal.emailAddress,
          historyId: signal.historyId,
          receivedAt: signal.now,
        })
      : existingSignal._id; // oxlint-disable-line eslint/no-underscore-dangle -- Convex document id field
  if (existingSignal !== null) {
    await ctx.db.patch(signalId, { receivedAt: signal.now });
  }
  await ctx.scheduler.runAfter(
    gmailPushVerificationSignalLifetimeMs,
    internal.pushRelay.expireGmailVerificationSignal,
    {
      receivedAt: signal.now,
      signalId,
    },
  );
}

// Each guard validates an independent Gmail proof requirement.
// fallow-ignore-next-line complexity
function pendingVerificationMatches(
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  request: Readonly<{ historyId: string; invalidatedAt: number; now: number }>,
): boolean {
  if (connection.pushVerificationHistoryId === undefined) {
    return false;
  }
  if (connection.pushVerificationRequestedAt === undefined) {
    return false;
  }
  return (
    connection.pushVerificationRequestedAt > request.invalidatedAt &&
    gmailHistoryIdAtOrAfter(
      request.historyId,
      connection.pushVerificationHistoryId,
    ) &&
    request.now - connection.pushVerificationRequestedAt <=
      gmailPushVerificationSignalLifetimeMs
  );
}

// Pending proofs must be checked independently for every matching Gmail connection.
// fallow-ignore-next-line complexity
async function verifyPendingGmailConnections(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  request: Readonly<{ emailAddress: string; historyId: string; now: number }>,
): Promise<void> {
  const connections = await ctx.db
    .query('mailProviderConnections')
    .withIndex(
      'by_provider_and_emailAddress_and_pushVerificationRequestedAt',
      (q) =>
        q
          .eq('provider', 'gmail')
          .eq('emailAddress', request.emailAddress)
          .gt('pushVerificationRequestedAt', undefined),
    )
    .order('desc')
    .collect();
  for (const connection of connections) {
    const device = await ctx.db.get(connection.trustedDeviceId);
    if (
      device !== null &&
      pendingVerificationMatches(connection, {
        historyId: request.historyId,
        invalidatedAt: device.gmailPushProofsInvalidatedAt ?? 0,
        now: request.now,
      })
    ) {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(connection._id, {
        pushVerificationHistoryId: undefined,
        pushVerificationRequestedAt: undefined,
        pushVerifiedHistoryId: connection.pushVerificationHistoryId,
        pushVerifiedAt: gmailPushProofUpdatedAt(
          device,
          connection,
          request.now,
        ),
      });
    }
  }
}

async function scheduleGmailWakeups(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  historyId: string,
  recipients: readonly ApnsRecipient[], // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Recipient data is treated as immutable input.
): Promise<void> {
  if (recipients.length === 0) {
    return;
  }
  await ctx.scheduler.runAfter(0, internal.apns.deliverGmailWakeups, {
    historyId,
    recipients: [...recipients],
  });
}

async function clearGmailPushProofs(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex ids are immutable branded strings.
  request: Readonly<{
    cleanupStartedAt: number;
    cursor?: string | null;
    productAccountId: Id<'productAccounts'>;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<void> {
  const page = await gmailConnectionsForDevice(
    ctx,
    request.productAccountId,
    request.trustedDeviceId,
  ).paginate({
    cursor: request.cursor ?? null,
    numItems: gmailPushProofCleanupBatchSize,
  });
  await Promise.all(
    page.page.map((connection) =>
      // oxlint-disable-next-line eslint/no-use-before-define -- Helper keeps pagination orchestration small.
      clearGmailPushProof(ctx, connection, request.cleanupStartedAt),
    ),
  );
  if (!page.isDone) {
    await ctx.scheduler.runAfter(
      0,
      internal.pushRelay.continueGmailPushProofCleanup,
      {
        cleanupStartedAt: request.cleanupStartedAt,
        cursor: page.continueCursor,
        productAccountId: request.productAccountId,
        trustedDeviceId: request.trustedDeviceId,
      },
    );
  }
}

async function clearGmailPushProof(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context patches proof records.
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  cleanupStartedAt: number,
): Promise<void> {
  // oxlint-disable-next-line eslint/no-use-before-define -- Helper isolates timestamp comparison.
  const clearPendingProof = shouldClearGmailPushProof(
    connection.pushVerificationRequestedAt,
    cleanupStartedAt,
  );
  // oxlint-disable-next-line eslint/no-use-before-define -- Helper isolates timestamp comparison.
  const clearVerifiedProof = shouldClearGmailPushProof(
    connection.pushVerifiedAt,
    cleanupStartedAt,
  );
  if (!clearPendingProof && !clearVerifiedProof) {
    return;
  }
  await ctx.db.patch(
    connection._id, // oxlint-disable-line eslint/no-underscore-dangle -- Convex document id field
    // oxlint-disable-next-line eslint/no-use-before-define -- Helper centralizes the conditional patch.
    gmailPushProofPatch(clearPendingProof, clearVerifiedProof),
  );
}

function shouldClearGmailPushProof(
  proofUpdatedAt: number | undefined,
  cleanupStartedAt: number,
): boolean {
  return proofUpdatedAt === undefined || proofUpdatedAt <= cleanupStartedAt;
}

function gmailPushProofPatch(
  clearPendingProof: boolean,
  clearVerifiedProof: boolean,
) {
  return {
    ...(clearPendingProof
      ? {
          pushVerificationHistoryId: undefined,
          pushVerificationRequestedAt: undefined,
        }
      : {}),
    ...(clearVerifiedProof
      ? {
          pushVerifiedHistoryId: undefined,
          pushVerifiedAt: undefined,
        }
      : {}),
  };
}

async function devicePushRouteHeartbeat(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<Doc<'devicePushRouteHeartbeats'> | null> {
  return ctx.db
    .query('devicePushRouteHeartbeats')
    .withIndex('by_trustedDeviceId', (q) =>
      q.eq('trustedDeviceId', trustedDeviceId),
    )
    .unique();
}

async function refreshDevicePushRouteHeartbeat(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  trustedDeviceId: Id<'trustedDevices'>,
  refreshedAt: number,
): Promise<void> {
  const heartbeat = await devicePushRouteHeartbeat(ctx, trustedDeviceId);
  if (heartbeat === null) {
    await ctx.db.insert('devicePushRouteHeartbeats', {
      refreshedAt,
      trustedDeviceId,
    });
    return;
  }
  await ctx.db.patch(
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    heartbeat._id,
    { refreshedAt },
  );
}

async function clearDevicePushRoute(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  device: Doc<'trustedDevices'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  request?: Readonly<{
    lastSeenAt?: number;
    preservePushCleanupGeneration?: boolean;
  }>,
): Promise<void> {
  const cleanupStartedAt = Date.now();
  // oxlint-disable-next-line eslint/no-use-before-define -- Helper removes the route heartbeat first.
  await deleteDevicePushRouteHeartbeat(ctx, device._id); // oxlint-disable-line eslint/no-underscore-dangle -- Convex document id field
  await ctx.db.patch(
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    device._id,
    // oxlint-disable-next-line eslint/no-use-before-define -- Helper builds the route-clear patch.
    clearedDevicePushRoutePatch(device, request, cleanupStartedAt),
  );
  await clearGmailPushProofs(ctx, {
    cleanupStartedAt,
    productAccountId: device.productAccountId,
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    trustedDeviceId: device._id,
  });
}

function clearedDevicePushRoutePatch(
  device: Doc<'trustedDevices'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  request:
    | Readonly<{
        lastSeenAt?: number;
        preservePushCleanupGeneration?: boolean;
      }>
    | undefined,
  cleanupStartedAt: number,
) {
  return {
    apnsEnvironment: undefined,
    apnsToken: undefined,
    apnsTokenRegisteredAt: undefined,
    gmailPushProofsInvalidatedAt: cleanupStartedAt,
    lastSeenAt: request?.lastSeenAt ?? device.lastSeenAt,
    // oxlint-disable-next-line eslint/no-use-before-define -- Helper preserves monotonic cleanup generations.
    pushCleanupGeneration: nextPushCleanupGeneration(device, request),
  };
}

function nextPushCleanupGeneration(
  device: Doc<'trustedDevices'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  request: Readonly<{ preservePushCleanupGeneration?: boolean }> | undefined,
): number | undefined {
  if (request?.preservePushCleanupGeneration) {
    return device.pushCleanupGeneration;
  }
  return (device.pushCleanupGeneration ?? 0) + 1;
}

async function deleteDevicePushRouteHeartbeat(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context deletes heartbeat records.
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<void> {
  const heartbeat = await devicePushRouteHeartbeat(ctx, trustedDeviceId);
  if (heartbeat !== null) {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete(heartbeat._id);
  }
}

function pushCleanupGenerationForRegistration(
  device: Doc<'trustedDevices'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  args: Readonly<{
    apnsEnvironment: Infer<typeof apnsEnvironmentValidator>;
    apnsToken: string;
  }>,
): number {
  const currentGeneration = device.pushCleanupGeneration ?? 0;
  return device.apnsEnvironment === args.apnsEnvironment &&
    device.apnsToken === args.apnsToken
    ? currentGeneration
    : currentGeneration + 1;
}

async function registeredTrustedDevice(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context reads authentication state.
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<Doc<'trustedDevices'>> {
  await requireAuthenticatedTrustedDevice(ctx, trustedDeviceId);
  const device = await ctx.db.get(trustedDeviceId);
  if (device === null) {
    throw new Error('Trusted device required');
  }
  return device;
}

async function clearReusedApnsToken(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex ids are immutable branded strings.
  request: Readonly<{
    apnsToken: string;
    cleanupStartedAt: number;
    pushCleanupGeneration: number;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<void> {
  const devices = await ctx.db
    .query('trustedDevices')
    .withIndex('by_apnsToken', (q) => q.eq('apnsToken', request.apnsToken))
    .take(devicePushTokenCleanupBatchSize);
  await Promise.all(
    devices
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      .filter((device) => device._id !== request.trustedDeviceId)
      .filter(
        (device) =>
          (device.apnsTokenRegisteredAt ?? 0) <= request.cleanupStartedAt,
      )
      .map((device) => clearDevicePushRoute(ctx, device)),
  );
  if (devices.length === devicePushTokenCleanupBatchSize) {
    await ctx.scheduler.runAfter(
      0,
      internal.pushRelay.continueReusedApnsTokenCleanup,
      {
        apnsToken: request.apnsToken,
        cleanupStartedAt: request.cleanupStartedAt,
        pushCleanupGeneration: request.pushCleanupGeneration,
        trustedDeviceId: request.trustedDeviceId,
      },
    );
  }
}

export const registerDevice = mutation({
  args: {
    apnsEnvironment: apnsEnvironmentValidator,
    apnsToken: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    if (args.apnsToken.length === 0) {
      throw new Error('APNs token required');
    }

    const device = await registeredTrustedDevice(ctx, args.trustedDeviceId);
    const now = Date.now();
    const pushCleanupGeneration = pushCleanupGenerationForRegistration(
      device,
      args,
    );
    await clearReusedApnsToken(ctx, {
      ...args,
      cleanupStartedAt: now,
      pushCleanupGeneration,
    });
    await ctx.db.patch(args.trustedDeviceId, {
      apnsEnvironment: args.apnsEnvironment,
      apnsToken: args.apnsToken,
      apnsTokenRegisteredAt: now,
      lastSeenAt: now,
      pushCleanupGeneration,
    });
    await refreshDevicePushRouteHeartbeat(ctx, args.trustedDeviceId, now);

    return { registered: true };
  },
  returns: devicePushRegistrationResponseValidator,
});

export const unregisterDevice = mutation({
  args: {
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    await requireAuthenticatedTrustedDevice(ctx, args.trustedDeviceId);
    const device = await ctx.db.get(args.trustedDeviceId);
    if (device === null) {
      throw new Error('Trusted device required');
    }
    await clearDevicePushRoute(ctx, device, {
      lastSeenAt: Date.now(),
      preservePushCleanupGeneration: true,
    });

    return { registered: false };
  },
  returns: devicePushRegistrationResponseValidator,
});

export const shouldStopGmailWatch = query({
  args: {
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
    );
    const connection = await requireGmailConnection(
      ctx,
      account.productAccountId,
      args.trustedDeviceId,
    );
    return !(await hasOtherActiveGmailRoute(ctx, {
      emailAddress: connection.emailAddress,
      trustedDeviceId: args.trustedDeviceId,
    }));
  },
  returns: v.boolean(),
});

export const verifyGmailWatch = mutation({
  args: {
    historyId: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  // The mutation has distinct authentication, freshness, and signal-verification guards.
  // fallow-ignore-next-line complexity
  handler: async (ctx, args) => {
    if (args.historyId.length === 0) {
      throw new Error('Gmail history id required');
    }

    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
    );
    const connection = await requireGmailConnection(
      ctx,
      account.productAccountId,
      args.trustedDeviceId,
    );
    const device = await ctx.db.get(args.trustedDeviceId);
    if (device === null) {
      throw new Error('Trusted device required');
    }
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    const routeId = connection._id;
    if (
      connection.pushVerifiedHistoryId === args.historyId &&
      (connection.pushVerifiedAt ?? 0) >
        (device.gmailPushProofsInvalidatedAt ?? 0)
    ) {
      return { routeId, verified: true };
    }

    const signals = await ctx.db
      .query('gmailPushVerificationSignals')
      .withIndex('by_emailAddress', (q) =>
        q.eq('emailAddress', connection.emailAddress),
      )
      .order('desc')
      .take(100);
    const now = gmailPushProofUpdatedAt(device, connection, Date.now());
    const verified = hasMatchingVerificationSignal(signals, {
      historyId: args.historyId,
      invalidatedAt: device.gmailPushProofsInvalidatedAt ?? 0,
      now,
    });
    await ctx.db.patch(
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      connection._id,
      gmailVerificationPatch(connection, {
        historyId: args.historyId,
        now,
        verified,
      }),
    );
    return { routeId, verified };
  },
  returns: gmailPushVerificationResponseValidator,
});

export const resolveGmailRecipients = internalQuery({
  args: { emailAddress: v.string() },
  handler: async (ctx, args) => gmailRecipients(ctx, args.emailAddress),
  returns: v.array(apnsRecipientValidator),
});

export const enqueueGmailWakeups = internalMutation({
  args: {
    emailAddress: v.string(),
    historyId: v.string(),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    await recordGmailVerificationSignal(ctx, {
      emailAddress: args.emailAddress,
      historyId: args.historyId,
      now,
    });
    await verifyPendingGmailConnections(ctx, {
      emailAddress: args.emailAddress,
      historyId: args.historyId,
      now,
    });

    const recipients = await gmailRecipients(ctx, args.emailAddress);
    await scheduleGmailWakeups(ctx, args.historyId, recipients);

    return { recipientCount: recipients.length };
  },
  returns: v.object({ recipientCount: v.number() }),
});

export const expireGmailVerificationSignal = internalMutation({
  args: {
    receivedAt: v.number(),
    signalId: v.id('gmailPushVerificationSignals'),
  },
  handler: async (ctx, args) => {
    const signal = await ctx.db.get(args.signalId);
    if (signal?.receivedAt === args.receivedAt) {
      await ctx.db.delete(args.signalId);
    }
    return null;
  },
  returns: v.null(),
});

export const continueGmailPushProofCleanup = internalMutation({
  args: {
    cleanupStartedAt: v.number(),
    cursor: v.string(),
    productAccountId: v.id('productAccounts'),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    await clearGmailPushProofs(ctx, args);
    return null;
  },
  returns: v.null(),
});

export const continueReusedApnsTokenCleanup = internalMutation({
  args: {
    apnsToken: v.string(),
    cleanupStartedAt: v.number(),
    pushCleanupGeneration: v.number(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const tokenOwners = await ctx.db
      .query('trustedDevices')
      .withIndex('by_apnsToken_and_apnsTokenRegisteredAt', (q) =>
        q
          .eq('apnsToken', args.apnsToken)
          .gte('apnsTokenRegisteredAt', args.cleanupStartedAt),
      )
      .order('desc')
      .take(2);
    if (
      tokenOwners.some(
        (owner) =>
          // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
          owner._id !== args.trustedDeviceId &&
          owner.pushCleanupGeneration !== undefined &&
          (owner.apnsTokenRegisteredAt ?? 0) >= args.cleanupStartedAt,
      )
    ) {
      return null;
    }
    await clearReusedApnsToken(ctx, args);
    return null;
  },
  returns: v.null(),
});

export const reconcileStaleDevicePushRoutes = internalMutation({
  args: {
    cursor: v.optional(v.string()),
    staleBefore: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const staleBefore =
      args.staleBefore ?? Date.now() - devicePushRouteInactivityLifetimeMs;
    const page = await ctx.db
      .query('trustedDevices')
      .withIndex('by_apnsToken', (q) => q.gt('apnsToken', ''))
      .paginate({
        cursor: args.cursor ?? null,
        numItems: devicePushRouteReconciliationBatchSize,
      });
    const heartbeats = await Promise.all(
      page.page.map((device) =>
        devicePushRouteHeartbeat(
          ctx,
          // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
          device._id,
        ),
      ),
    );
    const staleDeviceIds = new Set(
      page.page
        .filter(
          (device, index) =>
            (heartbeats[index]?.refreshedAt ?? device.lastSeenAt) < staleBefore,
        )
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        .map((device) => device._id),
    );
    await Promise.all(
      page.page.map(async (device, index) => {
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        if (staleDeviceIds.has(device._id)) {
          await clearDevicePushRoute(ctx, device);
          return;
        }
        if (heartbeats[index] === null) {
          await refreshDevicePushRouteHeartbeat(
            ctx,
            // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
            device._id,
            device.lastSeenAt,
          );
        }
      }),
    );
    if (!page.isDone) {
      await ctx.scheduler.runAfter(
        0,
        internal.pushRelay.reconcileStaleDevicePushRoutes,
        { cursor: page.continueCursor, staleBefore },
      );
    }

    return { clearedRouteCount: staleDeviceIds.size };
  },
  returns: v.object({ clearedRouteCount: v.number() }),
});

export const clearStaleDevice = internalMutation({
  args: {
    apnsToken: v.string(),
    pushCleanupGeneration: v.number(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const device = await ctx.db.get(args.trustedDeviceId);
    // oxlint-disable-next-line eslint/no-use-before-define -- Helper validates the current route identity.
    if (isCurrentPushRoute(device, args)) {
      await clearDevicePushRoute(ctx, device);
    }
    return null;
  },
  returns: v.null(),
});

function isCurrentPushRoute(
  device: Doc<'trustedDevices'> | null, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  request: Readonly<{
    apnsToken: string;
    pushCleanupGeneration: number;
  }>,
): device is Doc<'trustedDevices'> {
  return (
    device?.apnsToken === request.apnsToken &&
    (device.pushCleanupGeneration ?? 0) === request.pushCleanupGeneration
  );
}
