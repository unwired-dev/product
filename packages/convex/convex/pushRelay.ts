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
  const connections = await ctx.db
    .query('mailProviderConnections')
    .withIndex('by_provider_and_emailAddress_and_pushVerifiedAt', (q) =>
      q
        .eq('provider', 'gmail')
        .eq('emailAddress', emailAddress)
        .gt('pushVerifiedAt', undefined),
    )
    .take(100);
  const recipients: ApnsRecipient[] = [];

  for (const connection of connections) {
    // oxlint-disable-next-line eslint/no-use-before-define -- Function declarations are hoisted.
    const recipient = await apnsRecipientForDevice(
      ctx,
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      connection._id,
      connection.trustedDeviceId,
    );
    if (recipient !== null) {
      recipients.push(recipient);
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

async function requireGmailConnection(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  productAccountId: Id<'productAccounts'>,
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<Doc<'mailProviderConnections'>> {
  const connection = await ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productAccountId_and_provider_and_trustedDeviceId', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('provider', 'gmail')
        .eq('trustedDeviceId', trustedDeviceId),
    )
    .unique();
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
  if (existingSignal === null) {
    await ctx.db.insert('gmailPushVerificationSignals', {
      emailAddress: signal.emailAddress,
      historyId: signal.historyId,
      receivedAt: signal.now,
    });
    return;
  }
  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  await ctx.db.patch(existingSignal._id, { receivedAt: signal.now });
}

async function deleteStaleVerificationSignals(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  emailAddress: string,
  now: number,
): Promise<void> {
  const signals = await ctx.db
    .query('gmailPushVerificationSignals')
    .withIndex('by_emailAddress', (q) => q.eq('emailAddress', emailAddress))
    .take(100);
  for (const signal of signals) {
    if (now - signal.receivedAt > gmailPushVerificationSignalLifetimeMs) {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.delete(signal._id);
    }
  }
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
    .take(100);
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
  productAccountId: Id<'productAccounts'>,
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<void> {
  const connections = await ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productAccountId_and_provider_and_trustedDeviceId', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('provider', 'gmail')
        .eq('trustedDeviceId', trustedDeviceId),
    )
    .collect();
  await Promise.all(
    connections.map((connection) =>
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      ctx.db.patch(connection._id, {
        pushVerificationHistoryId: undefined,
        pushVerificationRequestedAt: undefined,
        pushVerifiedHistoryId: undefined,
        pushVerifiedAt: undefined,
      }),
    ),
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
    await ctx.db.patch(args.trustedDeviceId, {
      apnsEnvironment: args.apnsEnvironment,
      apnsToken: args.apnsToken,
      lastSeenAt: Date.now(),
    });

    return { registered: true };
  },
  returns: devicePushRegistrationResponseValidator,
});

export const unregisterDevice = mutation({
  args: {
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
    );
    await ctx.db.patch(args.trustedDeviceId, {
      apnsEnvironment: undefined,
      apnsToken: undefined,
      lastSeenAt: Date.now(),
    });
    await clearGmailPushProofs(
      ctx,
      account.productAccountId,
      args.trustedDeviceId,
    );

    return { registered: false };
  },
  returns: devicePushRegistrationResponseValidator,
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
    await deleteStaleVerificationSignals(ctx, args.emailAddress, now);
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

export const clearStaleDevice = internalMutation({
  args: {
    apnsToken: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const device = await ctx.db.get(args.trustedDeviceId);
    if (device?.apnsToken === args.apnsToken) {
      await ctx.db.patch(args.trustedDeviceId, {
        apnsEnvironment: undefined,
        apnsToken: undefined,
      });
      await clearGmailPushProofs(
        ctx,
        device.productAccountId,
        args.trustedDeviceId,
      );
    }
    return null;
  },
  returns: v.null(),
});
