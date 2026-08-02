import { ConvexError } from 'convex/values';

import type { Id } from './_generated/dataModel.js';
import type { MutationCtx, QueryCtx } from './_generated/server.js';

export const productAccountDeletedCode = 'PRODUCT_ACCOUNT_DELETED';

export function productAccountDeletedError(): ConvexError<{
  code: typeof productAccountDeletedCode;
  message: string;
}> {
  return new ConvexError({
    code: productAccountDeletedCode,
    message: 'This Product Account was deleted.',
  });
}

export async function requireProductAccountNotDeleted(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex contexts are immutable inputs.
  tokenIdentifier: string,
): Promise<void> {
  const [deletionRequest, tombstone] = await Promise.all([
    ctx.db
      .query('productAccountDeletionRequests')
      .withIndex('by_tokenIdentifier', (q) =>
        q.eq('tokenIdentifier', tokenIdentifier),
      )
      .unique(),
    ctx.db
      .query('productAccountDeletionTombstones')
      .withIndex('by_tokenIdentifier', (q) =>
        q.eq('tokenIdentifier', tokenIdentifier),
      )
      .unique(),
  ]);
  if (deletionRequest !== null || tombstone !== null) {
    throw productAccountDeletedError();
  }
}

export type AuthenticatedProductAccount = Readonly<{
  productAccountId: Id<'productAccounts'>;
  productSyncMaterialInitializedAt: number | undefined;
}>;

export async function requireProductAccount(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
): Promise<AuthenticatedProductAccount> {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error('Authentication required');
  }
  await requireProductAccountNotDeleted(ctx, identity.tokenIdentifier);

  const account = await ctx.db
    .query('productAccounts')
    .withIndex('by_tokenIdentifier', (q) =>
      q.eq('tokenIdentifier', identity.tokenIdentifier),
    )
    .unique();
  if (account === null) {
    throw new Error('Product Account required');
  }

  return {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    productAccountId: account._id,
    productSyncMaterialInitializedAt: account.productSyncMaterialInitializedAt,
  };
}

export async function requireTrustedDevice(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  productAccountId: Id<'productAccounts'>,
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<void> {
  const trustedDevice = await ctx.db.get(trustedDeviceId);
  if (
    trustedDevice === null ||
    trustedDevice.productAccountId !== productAccountId
  ) {
    throw new Error('Trusted device required');
  }
}

export async function requireAuthenticatedTrustedDevice(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<AuthenticatedProductAccount> {
  const account = await requireProductAccount(ctx);
  await requireTrustedDevice(ctx, account.productAccountId, trustedDeviceId);
  return account;
}
