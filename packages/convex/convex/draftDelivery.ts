import { v } from 'convex/values';

import { mutation } from './_generated/server.js';
import {
  productAccountDeletedError,
  requireProductAccountNotDeleted,
  requireTrustedDevice,
  throwTrustedDeviceReconnectRequired,
  trustedDeviceCredentialDigest,
} from './productAccountAuth.js';

// Native code derives the identifier from the Draft's identifier with the account's Product Sync
// keys, so the claim names no message, recipient or content.
const claimIdentifierPattern = /^draft-delivery\.[\da-f]{32}$/u;

// Permission for one Trusted Device to hand a Draft to its mail provider. The first device to claim
// a Draft holds the claim for good, and asking again from it keeps it, so a device that lost the
// reply can learn its claim; every other device is refused. The device's own credential is the
// proof, without a Product Sign-In: Sign in with Apple cannot renew one after a relaunch, and a
// queued message must still send.
export const claim = mutation({
  args: {
    claimIdentifier: v.string(),
    productAccountId: v.id('productAccounts'),
    trustedDeviceCredential: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const { productAccountId, trustedDeviceId } = args;
    await requireTrustedDevice(ctx, productAccountId, trustedDeviceId);
    const trustedDevice = await ctx.db.get('trustedDevices', trustedDeviceId);
    if (
      trustedDevice?.credentialDigest === undefined ||
      !/^[0-9a-f]{64}$/u.test(args.trustedDeviceCredential) ||
      (await trustedDeviceCredentialDigest(args.trustedDeviceCredential)) !==
        trustedDevice.credentialDigest
    ) {
      throwTrustedDeviceReconnectRequired();
    }
    const account = await ctx.db.get('productAccounts', productAccountId);
    if (account === null) {
      throw productAccountDeletedError();
    }
    await requireProductAccountNotDeleted(ctx, account.tokenIdentifier);
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
      return { claimed: existing.trustedDeviceId === trustedDeviceId };
    }
    await ctx.db.insert('draftDeliveryClaims', {
      claimIdentifier: args.claimIdentifier,
      claimedAt: Date.now(),
      productAccountId,
      trustedDeviceId,
    });
    return { claimed: true };
  },
  returns: v.object({ claimed: v.boolean() }),
});
