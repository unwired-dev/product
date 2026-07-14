import { devicePushRegistrationResponseValidator } from '@private-email/contracts/pushRelay';
import { v } from 'convex/values';

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
});

type ApnsRecipient = Readonly<{
  apnsEnvironment: 'production' | 'sandbox';
  apnsToken: string;
}>;

async function gmailRecipients(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  emailAddress: string,
): Promise<ApnsRecipient[]> {
  const connections = await ctx.db
    .query('mailProviderConnections')
    .withIndex('by_provider_and_emailAddress', (q) =>
      q.eq('provider', 'gmail').eq('emailAddress', emailAddress),
    )
    .take(100);
  const recipients: ApnsRecipient[] = [];

  for (const connection of connections) {
    const device = await ctx.db.get(connection.trustedDeviceId);
    if (
      device?.apnsEnvironment !== undefined &&
      device.apnsToken !== undefined
    ) {
      recipients.push({
        apnsEnvironment: device.apnsEnvironment,
        apnsToken: device.apnsToken,
      });
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
