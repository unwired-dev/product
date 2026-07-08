import { productAccountConnectResponseValidator } from '@private-email/contracts/productAccount';
import { v } from 'convex/values';

import { mutation } from './_generated/server.js';

export const connect = mutation({
  args: {
    deviceIdentifier: v.string(),
    platform: v.string(),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error('Authentication required');
    }

    const { tokenIdentifier } = identity;
    const now = Date.now();

    const existingAccount = await ctx.db
      .query('productAccounts')
      .withIndex('by_tokenIdentifier', (q) =>
        q.eq('tokenIdentifier', tokenIdentifier),
      )
      .unique();

    const accountCreated = !existingAccount;
    const productAccountId =
      existingAccount === null
        ? await ctx.db.insert('productAccounts', {
            createdAt: now,
            lastSeenAt: now,
            tokenIdentifier,
          })
        : // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
          existingAccount._id;

    if (existingAccount !== null) {
      await ctx.db.patch(productAccountId, { lastSeenAt: now });
    }

    const existingDevice = await ctx.db
      .query('trustedDevices')
      .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
        q
          .eq('productAccountId', productAccountId)
          .eq('deviceIdentifier', args.deviceIdentifier),
      )
      .unique();

    const deviceRegistered = !existingDevice;
    const trustedDeviceId =
      existingDevice === null
        ? await ctx.db.insert('trustedDevices', {
            deviceIdentifier: args.deviceIdentifier,
            lastSeenAt: now,
            platform: args.platform,
            productAccountId,
            registeredAt: now,
          })
        : // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
          existingDevice._id;

    if (existingDevice !== null) {
      await ctx.db.patch(trustedDeviceId, { lastSeenAt: now });
    }

    return {
      accountCreated,
      deviceRegistered,
      productAccountId,
      trustedDeviceId,
    };
  },
  returns: productAccountConnectResponseValidator,
});
