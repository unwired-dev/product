import type { Infer } from 'convex/values';

import {
  devicePushRegistrationResponseValidator,
  gmailPushVerificationResponseValidator,
} from '@private-email/contracts/pushRelay';
import { v } from 'convex/values';

import type { Id } from './_generated/dataModel.js';
import type { MutationCtx, QueryCtx } from './_generated/server.js';

import { internal } from './_generated/api.js';
import {
  internalMutation,
  internalQuery,
  mutation,
} from './_generated/server.js';
import {
  requireProductAccount,
  requireTrustedDevice,
} from './productAccountAuth.js';

const apnsEnvironmentValidator = v.union(
  v.literal('production'),
  v.literal('sandbox'),
);

const apnsRecipientValidator = v.object({
  apnsEnvironment: apnsEnvironmentValidator,
  apnsToken: v.string(),
  trustedDeviceId: v.id('trustedDevices'),
});

type ApnsRecipient = Readonly<{
  apnsEnvironment: Infer<typeof apnsEnvironmentValidator>;
  apnsToken: string;
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
    if (connection.pushVerifiedAt !== undefined) {
      const device = await ctx.db.get(connection.trustedDeviceId);
      if (
        device?.apnsEnvironment !== undefined &&
        device.apnsToken !== undefined
      ) {
        recipients.push({
          apnsEnvironment: device.apnsEnvironment,
          apnsToken: device.apnsToken,
          // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
          trustedDeviceId: device._id,
        });
      }
    }
  }

  return recipients;
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

    const account = await requireProductAccount(ctx);
    await requireTrustedDevice(
      ctx,
      account.productAccountId,
      args.trustedDeviceId,
    );
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
    const account = await requireProductAccount(ctx);
    await requireTrustedDevice(
      ctx,
      account.productAccountId,
      args.trustedDeviceId,
    );
    await ctx.db.patch(args.trustedDeviceId, {
      apnsEnvironment: undefined,
      apnsToken: undefined,
      lastSeenAt: Date.now(),
    });
    const connection = await ctx.db
      .query('mailProviderConnections')
      .withIndex('by_productAccountId_and_provider_and_trustedDeviceId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('provider', 'gmail')
          .eq('trustedDeviceId', args.trustedDeviceId),
      )
      .unique();
    if (connection !== null) {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(connection._id, {
        pushVerificationHistoryId: undefined,
        pushVerificationRequestedAt: undefined,
        pushVerifiedHistoryId: undefined,
        pushVerifiedAt: undefined,
      });
    }

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

    const account = await requireProductAccount(ctx);
    await requireTrustedDevice(
      ctx,
      account.productAccountId,
      args.trustedDeviceId,
    );
    const connection = await ctx.db
      .query('mailProviderConnections')
      .withIndex('by_productAccountId_and_provider_and_trustedDeviceId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('provider', 'gmail')
          .eq('trustedDeviceId', args.trustedDeviceId),
      )
      .unique();
    if (connection === null) {
      throw new Error('Gmail connection required');
    }
    if (connection.pushVerifiedHistoryId === args.historyId) {
      return { verified: true };
    }

    const signals = await ctx.db
      .query('gmailPushVerificationSignals')
      .withIndex('by_emailAddress', (q) =>
        q.eq('emailAddress', connection.emailAddress),
      )
      .order('desc')
      .take(100);
    const now = Date.now();
    const signal = signals.find(
      (candidate) =>
        now - candidate.receivedAt <= gmailPushVerificationSignalLifetimeMs &&
        gmailHistoryIdAtOrAfter(candidate.historyId, args.historyId),
    );
    const verified = signal !== undefined;
    const verifiedHistoryId =
      verified &&
      (connection.pushVerifiedHistoryId === undefined ||
        gmailHistoryIdAtOrAfter(
          args.historyId,
          connection.pushVerifiedHistoryId,
        ))
        ? args.historyId
        : connection.pushVerifiedHistoryId;
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.patch(connection._id, {
      pushVerificationHistoryId: verified ? undefined : args.historyId,
      pushVerificationRequestedAt: verified ? undefined : now,
      pushVerifiedHistoryId: verifiedHistoryId,
      pushVerifiedAt: verified ? now : connection.pushVerifiedAt,
    });
    return { verified };
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
    const existingSignal = await ctx.db
      .query('gmailPushVerificationSignals')
      .withIndex('by_emailAddress_and_historyId', (q) =>
        q.eq('emailAddress', args.emailAddress).eq('historyId', args.historyId),
      )
      .unique();
    await (existingSignal === null
      ? ctx.db.insert('gmailPushVerificationSignals', {
          emailAddress: args.emailAddress,
          historyId: args.historyId,
          receivedAt: now,
        })
      : // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        ctx.db.patch(existingSignal._id, {
          receivedAt: now,
        }));

    const staleSignals = await ctx.db
      .query('gmailPushVerificationSignals')
      .withIndex('by_emailAddress', (q) =>
        q.eq('emailAddress', args.emailAddress),
      )
      .take(100);
    await Promise.all(
      staleSignals.map(async (signal) => {
        if (now - signal.receivedAt > gmailPushVerificationSignalLifetimeMs) {
          // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
          await ctx.db.delete(signal._id);
        }
      }),
    );

    const pendingConnections = await ctx.db
      .query('mailProviderConnections')
      .withIndex(
        'by_provider_and_emailAddress_and_pushVerificationRequestedAt',
        (q) =>
          q
            .eq('provider', 'gmail')
            .eq('emailAddress', args.emailAddress)
            .gt('pushVerificationRequestedAt', undefined),
      )
      .take(100);
    for (const connection of pendingConnections) {
      if (
        connection.pushVerificationHistoryId !== undefined &&
        gmailHistoryIdAtOrAfter(
          args.historyId,
          connection.pushVerificationHistoryId,
        ) &&
        connection.pushVerificationRequestedAt !== undefined &&
        now - connection.pushVerificationRequestedAt <=
          gmailPushVerificationSignalLifetimeMs
      ) {
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        await ctx.db.patch(connection._id, {
          pushVerificationHistoryId: undefined,
          pushVerificationRequestedAt: undefined,
          pushVerifiedHistoryId: connection.pushVerificationHistoryId,
          pushVerifiedAt: now,
        });
      }
    }

    const recipients = await gmailRecipients(ctx, args.emailAddress);
    if (recipients.length > 0) {
      await ctx.scheduler.runAfter(0, internal.apns.deliverGmailWakeups, {
        historyId: args.historyId,
        recipients,
      });
    }

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
    }
    return null;
  },
  returns: v.null(),
});
