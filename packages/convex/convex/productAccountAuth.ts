import { ConvexError } from 'convex/values';

import type { Id } from './_generated/dataModel.js';
import type { MutationCtx, QueryCtx } from './_generated/server.js';

export type AuthenticatedProductAccount = Readonly<{
  productAccountId: Id<'productAccounts'>;
  productSyncKeyEpoch: number | undefined;
  productSyncMaterialInitializedAt: number | undefined;
  productSyncPendingKeyEpoch: number | undefined;
}>;

const recentAuthenticationMaximumAgeSeconds = 5 * 60;
const recentAuthenticationFutureLeewaySeconds = 60;
export const initialProductSyncKeyEpoch = 1;
export const trustedDeviceRevokedErrorCode = 'TRUSTED_DEVICE_REVOKED';

export function throwTrustedDeviceRevoked(): never {
  throw new ConvexError({ code: trustedDeviceRevokedErrorCode });
}

export async function requireProductAccount(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
): Promise<AuthenticatedProductAccount> {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error('Authentication required');
  }

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
    productSyncKeyEpoch: account.productSyncKeyEpoch,
    productSyncMaterialInitializedAt: account.productSyncMaterialInitializedAt,
    productSyncPendingKeyEpoch: account.productSyncPendingKeyEpoch,
  };
}

export async function requireRecentAuthentication(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
): Promise<void> {
  const identity = await ctx.auth.getUserIdentity();
  // oxlint-disable-next-line typescript/dot-notation -- iat is exposed through UserIdentity's additional-claims index signature.
  const issuedAt = identity?.['iat'];
  if (typeof issuedAt !== 'number' || !Number.isFinite(issuedAt)) {
    throw new TypeError('Recent authentication required');
  }
  const now = Math.floor(Date.now() / 1000);
  if (
    issuedAt > now + recentAuthenticationFutureLeewaySeconds ||
    now - issuedAt > recentAuthenticationMaximumAgeSeconds
  ) {
    throw new Error('Recent authentication required');
  }
}

export function requireCurrentProductSyncKeyEpoch(
  account: AuthenticatedProductAccount, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- The alias is deeply readonly.
  keyVersion: number,
): void {
  const requiredKeyEpoch =
    account.productSyncPendingKeyEpoch ??
    account.productSyncKeyEpoch ??
    initialProductSyncKeyEpoch;
  if (keyVersion !== requiredKeyEpoch) {
    throw new Error('Product Sync key rotation required');
  }
}

export async function requireTrustedDevice(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  productAccountId: Id<'productAccounts'>,
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<void> {
  const trustedDevice = await ctx.db.get(trustedDeviceId);
  if (trustedDevice === null) {
    const revokedDevice = await ctx.db
      .query('revokedTrustedDevices')
      .withIndex('by_productAccountId_and_trustedDeviceId', (q) =>
        q
          .eq('productAccountId', productAccountId)
          .eq('trustedDeviceId', trustedDeviceId),
      )
      .unique();
    if (revokedDevice !== null) {
      throwTrustedDeviceRevoked();
    }
    throw new Error('Trusted device required');
  }
  if (trustedDevice.productAccountId !== productAccountId) {
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
