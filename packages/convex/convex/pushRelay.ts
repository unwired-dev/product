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
  routeId: v.string(),
  trustedDeviceId: v.id('trustedDevices'),
});

type ApnsRecipient = Readonly<{
  apnsEnvironment: Infer<typeof apnsEnvironmentValidator>;
  apnsToken: string;
  routeId: string;
  trustedDeviceId: Id<'trustedDevices'>;
}>;

const gmailPushVerificationSignalLifetimeMs = 10 * 60 * 1000;
const devicePushRouteInactivityLifetimeMs = 30 * 24 * 60 * 60 * 1000;
const devicePushRouteReconciliationBatchSize = 10;
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
    const recipient = await apnsRecipientForDevice(
      ctx,
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      connection._id,
      connection.trustedDeviceId,
    );
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
  routeId: Id<'mailProviderConnections'>,
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<ApnsRecipient | null> {
  const device = await ctx.db.get(trustedDeviceId);
  if (device?.apnsEnvironment === undefined || device.apnsToken === undefined) {
    return null;
  }
  return {
    apnsEnvironment: device.apnsEnvironment,
    apnsToken: device.apnsToken,
    routeId,
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    trustedDeviceId: device._id,
  };
}

function hasActiveApnsRoute(
  device: Doc<'trustedDevices'> | null, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
): boolean {
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
      if (hasActiveApnsRoute(device)) {
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
  historyId: string,
  now: number,
): boolean {
  return signals.some(
    (candidate) =>
      now - candidate.receivedAt <= gmailPushVerificationSignalLifetimeMs &&
      gmailHistoryIdAtOrAfter(candidate.historyId, historyId),
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

function pendingVerificationMatches(
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  historyId: string,
  now: number,
): boolean {
  if (connection.pushVerificationHistoryId === undefined) {
    return false;
  }
  if (connection.pushVerificationRequestedAt === undefined) {
    return false;
  }
  return (
    gmailHistoryIdAtOrAfter(historyId, connection.pushVerificationHistoryId) &&
    now - connection.pushVerificationRequestedAt <=
      gmailPushVerificationSignalLifetimeMs
  );
}

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
    if (
      pendingVerificationMatches(connection, request.historyId, request.now)
    ) {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(connection._id, {
        pushVerificationHistoryId: undefined,
        pushVerificationRequestedAt: undefined,
        pushVerifiedHistoryId: connection.pushVerificationHistoryId,
        pushVerifiedAt: request.now,
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
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      ctx.db.patch(connection._id, {
        pushVerificationHistoryId: undefined,
        pushVerificationRequestedAt: undefined,
        pushVerifiedHistoryId: undefined,
        pushVerifiedAt: undefined,
      }),
    ),
  );
  if (!page.isDone) {
    await ctx.scheduler.runAfter(
      0,
      internal.pushRelay.continueGmailPushProofCleanup,
      {
        cursor: page.continueCursor,
        productAccountId: request.productAccountId,
        trustedDeviceId: request.trustedDeviceId,
      },
    );
  }
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
  lastSeenAt?: number,
): Promise<void> {
  const heartbeat = await devicePushRouteHeartbeat(
    ctx,
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    device._id,
  );
  if (heartbeat !== null) {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete(heartbeat._id);
  }
  await ctx.db.patch(
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    device._id,
    {
      apnsEnvironment: undefined,
      apnsToken: undefined,
      lastSeenAt: lastSeenAt ?? device.lastSeenAt,
    },
  );
  await clearGmailPushProofs(ctx, {
    productAccountId: device.productAccountId,
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    trustedDeviceId: device._id,
  });
}

async function clearReusedApnsToken(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  trustedDeviceId: Id<'trustedDevices'>,
  apnsToken: string,
): Promise<void> {
  const devices = await ctx.db
    .query('trustedDevices')
    .withIndex('by_apnsToken', (q) => q.eq('apnsToken', apnsToken))
    .take(100);
  await Promise.all(
    devices
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      .filter((device) => device._id !== trustedDeviceId)
      .map((device) => clearDevicePushRoute(ctx, device)),
  );
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

    await requireAuthenticatedTrustedDevice(ctx, args.trustedDeviceId);
    await clearReusedApnsToken(ctx, args.trustedDeviceId, args.apnsToken);
    const now = Date.now();
    await ctx.db.patch(args.trustedDeviceId, {
      apnsEnvironment: args.apnsEnvironment,
      apnsToken: args.apnsToken,
      lastSeenAt: now,
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
    await clearDevicePushRoute(ctx, device, Date.now());

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
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    const routeId = connection._id;
    if (connection.pushVerifiedHistoryId === args.historyId) {
      return { routeId, verified: true };
    }

    const signals = await ctx.db
      .query('gmailPushVerificationSignals')
      .withIndex('by_emailAddress', (q) =>
        q.eq('emailAddress', connection.emailAddress),
      )
      .order('desc')
      .take(100);
    const now = Date.now();
    const verified = hasMatchingVerificationSignal(
      signals,
      args.historyId,
      now,
    );
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
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const device = await ctx.db.get(args.trustedDeviceId);
    if (device?.apnsToken === args.apnsToken) {
      await clearDevicePushRoute(ctx, device);
    }
    return null;
  },
  returns: v.null(),
});
