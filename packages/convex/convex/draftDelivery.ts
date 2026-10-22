import { v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx } from './_generated/server.js';

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

// The account a claim names, or for a build from before #983, which names none, its device's.
function accountOf(
  productAccountId: Id<'productAccounts'> | undefined,
  trustedDevice: Readonly<
    Pick<Doc<'trustedDevices'>, 'productAccountId'>
  > | null,
): Id<'productAccounts'> {
  const accountId = productAccountId ?? trustedDevice?.productAccountId;
  if (accountId === undefined) {
    throw new Error('Trusted device required');
  }
  return accountId;
}

// The claiming device's Product Account, proven by the Trusted Device's own credential without a
// Product Sign-In, while it is not being deleted. A device without a credential digest, as one
// that predates device credentials, must reconnect.
async function requireDeviceCredential(
  ctx: MutationCtx,
  {
    productAccountId,
    trustedDeviceCredential,
    trustedDeviceId,
  }: Readonly<{
    productAccountId?: Id<'productAccounts'>;
    trustedDeviceCredential: string;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<Id<'productAccounts'>> {
  const trustedDevice = await ctx.db.get('trustedDevices', trustedDeviceId);
  const accountId = accountOf(productAccountId, trustedDevice);
  await requireTrustedDevice(ctx, accountId, trustedDeviceId);
  if (
    trustedDevice?.credentialDigest !==
    (await trustedDeviceCredentialDigest(trustedDeviceCredential))
  ) {
    throwTrustedDeviceReconnectRequired();
  }
  const account = await ctx.db.get('productAccounts', accountId);
  if (account === null) {
    throw productAccountDeletedError();
  }
  await requireProductAccountNotDeleted(ctx, account.tokenIdentifier);
  return accountId;
}

// Permission for one Trusted Device to hand a Draft to its mail provider. The first device to claim
// a Draft holds the claim for good, and asking again from it keeps it, so a device that lost the
// reply can learn its claim; every other device is refused. The device's own credential is the
// proof, without a Product Sign-In: Sign in with Apple cannot renew one after a relaunch, and a
// queued message must still send.
export const claim = mutation({
  args: {
    claimIdentifier: v.string(),
    productAccountId: v.optional(v.id('productAccounts')),
    trustedDeviceCredential: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const { trustedDeviceId } = args;
    const productAccountId = await requireDeviceCredential(ctx, args);
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
