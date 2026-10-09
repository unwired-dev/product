import { v } from 'convex/values';

import { mutation } from './_generated/server.js';
import {
  requireAuthenticatedTrustedDevice,
  trustedDeviceCredentialArgs,
} from './productAccountAuth.js';

// Native code derives the identifier from the Draft's identifier with the account's Product Sync
// keys, so the claim names no message, recipient or content.
const claimIdentifierPattern = /^draft-delivery\.[\da-f]{32}$/u;

// Permission for one Trusted Device to hand a Draft to its mail provider. The first device to claim
// a Draft holds the claim for good, and asking again from it keeps it, so a device that lost the
// reply can learn its claim; every other device is refused.
export const claim = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    claimIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const { productAccountId } = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    if (!claimIdentifierPattern.test(args.claimIdentifier)) {
      throw new Error('Invalid delivery claim');
    }
    const existing = await ctx.db
      .query('draftDeliveryClaims')
      .withIndex('by_productAccountId_and_claimIdentifier', (q) =>
        q
          .eq('productAccountId', productAccountId)
          .eq('claimIdentifier', args.claimIdentifier),
      )
      .unique();
    if (existing !== null) {
      return { claimed: existing.trustedDeviceId === args.trustedDeviceId };
    }
    await ctx.db.insert('draftDeliveryClaims', {
      claimIdentifier: args.claimIdentifier,
      claimedAt: Date.now(),
      productAccountId,
      trustedDeviceId: args.trustedDeviceId,
    });
    return { claimed: true };
  },
  returns: v.object({ claimed: v.boolean() }),
});
