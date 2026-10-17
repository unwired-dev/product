import {
  mailProfileCapabilityVersion,
  mailProfilesUpgradeRequiredErrorCode,
} from '@private-email/contracts/productSync';
import { ConvexError, v } from 'convex/values';

import type { MutationCtx, QueryCtx } from './_generated/server.js';
import type { AuthenticatedProductAccount } from './productAccountAuth.js';

import { trustedDeviceLimitPerProductAccount } from './productAccount.js';

// The Mail Profile capability a client presents with each payload call; older clients send none.
export const mailProfileCapabilityArgs = {
  mailProfileCapability: v.optional(v.number()),
};

function throwMailProfilesUpgradeRequired(): never {
  throw new ConvexError({
    code: mailProfilesUpgradeRequiredErrorCode,
    message: 'Update Unwired Mail to use Mail Profiles.',
  });
}

const capable = (version: number | undefined) =>
  (version ?? 0) >= mailProfileCapabilityVersion;

// Once an account holds Mail Profile records, a client that cannot keep them apart reads and writes
// nothing: it would show every Profile's connections in its one window.
export async function requireMailProfileCapability(
  ctx: QueryCtx | MutationCtx,
  account: AuthenticatedProductAccount,
  presented: number | undefined,
): Promise<void> {
  if (!capable(presented) && (await mailProfilesEnabled(ctx, account))) {
    throwMailProfilesUpgradeRequired();
  }
}

export const isMailProfileRecord = (payloadIdentifier: string) =>
  payloadIdentifier.startsWith('profile.') ||
  payloadIdentifier.startsWith('mailbox-profile.');

// An account's first Mail Profile record waits until every Trusted Device declared the capability,
// so no device still running an older client ever sees one Profile's connections in another's.
export async function fencesMailProfiles(
  ctx: MutationCtx,
  account: AuthenticatedProductAccount,
): Promise<boolean> {
  if (await mailProfilesEnabled(ctx, account)) {
    return false;
  }
  const devices = ctx.db
    .query('trustedDevices')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q.eq('productAccountId', account.productAccountId),
    );
  const roster = await devices.take(trustedDeviceLimitPerProductAccount + 1);
  if (roster.length > trustedDeviceLimitPerProductAccount) {
    throw new Error('Trusted Device limit exceeded');
  }
  return roster.some((device) => !capable(device.mailProfileCapabilityVersion));
}

// Whether a transaction touches Mail Profile records, which need the writer's capability and, for an
// account's first, every Trusted Device's.
export async function admitMailProfileWrites(
  ctx: MutationCtx,
  account: AuthenticatedProductAccount,
  {
    identifiers,
    presented,
  }: Readonly<{
    identifiers: readonly string[];
    presented: number | undefined;
  }>,
): Promise<boolean> {
  if (!identifiers.some(isMailProfileRecord)) {
    return false;
  }
  if (!capable(presented) || (await fencesMailProfiles(ctx, account))) {
    throwMailProfilesUpgradeRequired();
  }
  return true;
}

async function mailProfilesEnabled(
  ctx: QueryCtx | MutationCtx,
  account: AuthenticatedProductAccount,
): Promise<boolean> {
  if (account.mailProfilesEnabledAt !== undefined) {
    return true;
  }
  for (const prefix of ['profile.', 'mailbox-profile.']) {
    const record = await ctx.db
      .query('encryptedProductSyncPayloads')
      .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .gte('payloadIdentifier', prefix)
          // '/' follows '.', so the range holds exactly the identifiers with this prefix.
          .lt('payloadIdentifier', `${prefix.slice(0, -1)}/`),
      )
      .first();
    if (record !== null) {
      return true;
    }
  }
  return false;
}

// Records an earlier release wrote without setting the marker enable the fence too.
export async function enablesEarlierMailProfiles(
  ctx: MutationCtx,
  account: AuthenticatedProductAccount,
): Promise<boolean> {
  if (
    account.mailProfilesEnabledAt !== undefined ||
    !(await mailProfilesEnabled(ctx, account))
  ) {
    return false;
  }
  await enableMailProfiles(ctx, account);
  return true;
}

// From the account's first committed Mail Profile record on, only capable clients sync.
export async function enableMailProfiles(
  ctx: MutationCtx,
  account: AuthenticatedProductAccount,
): Promise<void> {
  if (account.mailProfilesEnabledAt === undefined) {
    await ctx.db.patch('productAccounts', account.productAccountId, {
      mailProfilesEnabledAt: Date.now(),
    });
  }
}
