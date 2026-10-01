import type { SignInProvider } from '@private-email/contracts/productAccount';

import {
  signInLinkRequestResponseValidator,
  signInLinkResponseValidator,
  signInProviderValidator,
} from '@private-email/contracts/productAccount';
import { ConvexError, v } from 'convex/values';

import type { Doc } from './_generated/dataModel.js';
import type { MutationCtx } from './_generated/server.js';

import { mutation } from './_generated/server.js';
import {
  issueTrustedDeviceCredential,
  requireAuthenticatedTrustedDevice,
  requireProductAccountNotDeleted,
  requireRecentAuthentication,
  requireTrustedDeviceProof,
  signInProviderForIssuer,
  signInProvidersForAccount,
  trustedDeviceCredentialArgs,
  trustedDeviceCredentialDigest,
} from './productAccountAuth.js';

// Both identities must be confirmed in one short interactive session.
const linkRequestLifetimeMilliseconds = 5 * 60 * 1000;
const linkRequestCleanupLimit = 10;

export const signInLinkErrorCodes = {
  alreadyLinked: 'SIGN_IN_PROVIDER_ALREADY_LINKED',
  expired: 'SIGN_IN_LINK_EXPIRED',
  identityOwned: 'SIGN_IN_IDENTITY_OWNED',
  recentAuthentication: 'SIGN_IN_RECENT_AUTHENTICATION_REQUIRED',
} as const;

function linkError(
  code: (typeof signInLinkErrorCodes)[keyof typeof signInLinkErrorCodes],
  message: string,
): ConvexError<{ code: string; message: string }> {
  return new ConvexError({ code, message });
}

async function requireRecentSignIn(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
): Promise<void> {
  try {
    await requireRecentAuthentication(ctx);
  } catch {
    throw linkError(
      signInLinkErrorCodes.recentAuthentication,
      'Sign in again to link another sign-in method.',
    );
  }
}

async function linkResponse(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  account: Readonly<Doc<'productAccounts'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
) {
  return {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    productAccountId: account._id,
    signInProviders: await signInProvidersForAccount(ctx, account),
  };
}

// Only the newest ticket for a provider remains usable.
async function supersedeLinkRequests(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  account: Readonly<Doc<'productAccounts'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  provider: SignInProvider,
): Promise<void> {
  const now = Date.now();
  const previous = await ctx.db
    .query('signInLinkRequests')
    .withIndex('by_productAccountId', (q) =>
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      q.eq('productAccountId', account._id),
    )
    .take(linkRequestCleanupLimit);
  const stale = previous.filter(
    (request) => request.provider === provider || request.expiresAt <= now,
  );
  for (const request of stale) {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete('signInLinkRequests', request._id);
  }
}

// Step one: a recently authenticated Trusted Device vouches for its Product Account.
export const request = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    provider: signInProviderValidator,
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    await requireRecentSignIn(ctx);
    const { productAccountId } = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    const account = await ctx.db.get('productAccounts', productAccountId);
    if (account === null) {
      throw new Error('Product Account required');
    }
    const signInProviders = await signInProvidersForAccount(ctx, account);
    if (signInProviders.includes(args.provider)) {
      return { signInProviders };
    }
    await supersedeLinkRequests(ctx, account, args.provider);
    // Link tickets share the device credential's 256-bit secret format; only the digest is stored.
    const linkTicket = issueTrustedDeviceCredential();
    await ctx.db.insert('signInLinkRequests', {
      expiresAt: Date.now() + linkRequestLifetimeMilliseconds,
      productAccountId,
      provider: args.provider,
      ticketDigest: await trustedDeviceCredentialDigest(linkTicket),
      trustedDeviceId: args.trustedDeviceId,
    });
    return { linkTicket, signInProviders };
  },
  returns: signInLinkRequestResponseValidator,
});

async function pendingLinkRequest(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  linkTicket: string,
): Promise<Doc<'signInLinkRequests'> | null> {
  if (!/^[0-9a-f]{64}$/u.test(linkTicket)) {
    return null;
  }
  const ticketDigest = await trustedDeviceCredentialDigest(linkTicket);
  return ctx.db
    .query('signInLinkRequests')
    .withIndex('by_ticketDigest', (q) => q.eq('ticketDigest', ticketDigest))
    .unique();
}

// Accounts are never merged, and each provider subject has exactly one owner.
async function requireUnownedIdentity(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  tokenIdentifier: string,
  existing: Readonly<Doc<'linkedSignIns'>> | null, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
): Promise<void> {
  const owner = await ctx.db
    .query('productAccounts')
    .withIndex('by_tokenIdentifier', (q) =>
      q.eq('tokenIdentifier', tokenIdentifier),
    )
    .unique();
  if (existing !== null || owner !== null) {
    throw linkError(
      signInLinkErrorCodes.identityOwned,
      'This sign-in already belongs to another Product Account.',
    );
  }
  await requireProductAccountNotDeleted(ctx, tokenIdentifier);
}

const expiredLink = () =>
  linkError(
    signInLinkErrorCodes.expired,
    'This link request expired. Start linking again.',
  );

type LinkCompletion = Readonly<{
  linkTicket: string;
  trustedDeviceId: Doc<'signInLinkRequests'>['trustedDeviceId'];
}>;

// The account a ticket (or a committed link being retried) names, with the ticket still live.
// fallow-ignore-next-line complexity -- Every unusable ticket fails closed with the same expired response.
async function linkTarget(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  identity: Readonly<{ issuer: string; tokenIdentifier: string }>,
  args: LinkCompletion, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex identifiers are branded values.
) {
  const provider = signInProviderForIssuer(identity.issuer);
  const pending = await pendingLinkRequest(ctx, args.linkTicket);
  const existing = await ctx.db
    .query('linkedSignIns')
    .withIndex('by_tokenIdentifier', (q) =>
      q.eq('tokenIdentifier', identity.tokenIdentifier),
    )
    .unique();
  const productAccountId =
    pending?.productAccountId ?? existing?.productAccountId;
  const account =
    productAccountId === undefined
      ? null
      : await ctx.db.get('productAccounts', productAccountId);
  const usable =
    pending === null ||
    (pending.expiresAt > Date.now() &&
      pending.trustedDeviceId === args.trustedDeviceId &&
      pending.provider === provider);
  if (account === null || provider === undefined || !usable) {
    throw expiredLink();
  }
  return { account, existing, pending, provider };
}

async function requireOpenProviderSlot(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  account: Readonly<Doc<'productAccounts'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  provider: SignInProvider,
): Promise<void> {
  const occupied = await ctx.db
    .query('linkedSignIns')
    .withIndex('by_productAccountId_and_provider', (q) =>
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      q.eq('productAccountId', account._id).eq('provider', provider),
    )
    .first();
  if (occupied !== null) {
    throw linkError(
      signInLinkErrorCodes.alreadyLinked,
      'This Product Account already has a sign-in for this provider.',
    );
  }
}

// Step two: the identity being linked authenticates and redeems the ticket on the same device.
export const complete = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    linkTicket: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  // fallow-ignore-next-line complexity -- Ownership checks run in order inside one serializable transaction.
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error('Authentication required');
    }
    await requireRecentSignIn(ctx);
    const { account, existing, pending, provider } = await linkTarget(
      ctx,
      identity,
      args,
    );
    await requireProductAccountNotDeleted(ctx, account.tokenIdentifier);
    await requireTrustedDeviceProof(
      ctx,
      {
        deviceCredentialEnforcementActivatedAt:
          account.deviceCredentialEnforcementActivatedAt,
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        productAccountId: account._id,
      },
      {
        trustedDeviceCredential: args.trustedDeviceCredential,
        trustedDeviceId: args.trustedDeviceId,
      },
    );
    // A retried completion whose response was lost finds its committed link.
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    if (existing?.productAccountId === account._id) {
      return linkResponse(ctx, account);
    }
    if (pending === null) {
      throw expiredLink();
    }
    await requireUnownedIdentity(ctx, identity.tokenIdentifier, existing);
    await requireOpenProviderSlot(ctx, account, provider);
    await ctx.db.insert('linkedSignIns', {
      linkedAt: Date.now(),
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      productAccountId: account._id,
      provider,
      tokenIdentifier: identity.tokenIdentifier,
    });
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete('signInLinkRequests', pending._id);
    return linkResponse(ctx, account);
  },
  returns: signInLinkResponseValidator,
});
