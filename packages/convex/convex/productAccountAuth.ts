import type { SignInProvider } from '@private-email/contracts/productAccount';

import { ConvexError, v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
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

const signInProviderIssuers: Readonly<Record<string, SignInProvider>> = {
  'https://accounts.google.com': 'google',
  'accounts.google.com': 'google',
  'https://appleid.apple.com': 'apple',
};

export function signInProviderForIssuer(
  issuer: string,
): SignInProvider | undefined {
  return Object.hasOwn(signInProviderIssuers, issuer)
    ? signInProviderIssuers[issuer]
    : undefined;
}

async function linkedSignIn(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex contexts are immutable inputs.
  tokenIdentifier: string,
): Promise<Doc<'linkedSignIns'> | null> {
  return ctx.db
    .query('linkedSignIns')
    .withIndex('by_tokenIdentifier', (q) =>
      q.eq('tokenIdentifier', tokenIdentifier),
    )
    .unique();
}

// A verified issuer and subject reach only the account that created or explicitly linked them.
export async function productAccountForSignIn(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex contexts are immutable inputs.
  tokenIdentifier: string,
): Promise<Doc<'productAccounts'> | null> {
  const owned = await ctx.db
    .query('productAccounts')
    .withIndex('by_tokenIdentifier', (q) =>
      q.eq('tokenIdentifier', tokenIdentifier),
    )
    .unique();
  if (owned !== null) {
    return owned;
  }
  const linked = await linkedSignIn(ctx, tokenIdentifier);
  return linked === null
    ? null
    : ctx.db.get('productAccounts', linked.productAccountId);
}

// Deletion state is keyed by the identity that created the Product Account.
export async function accountTokenIdentifier(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex contexts are immutable inputs.
  tokenIdentifier: string,
): Promise<string> {
  const linked = await linkedSignIn(ctx, tokenIdentifier);
  const account =
    linked === null
      ? null
      : await ctx.db.get('productAccounts', linked.productAccountId);
  return account?.tokenIdentifier ?? tokenIdentifier;
}

// The original Sign-In Provider first, followed by any Linked Sign-In.
export async function signInProvidersForAccount(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex contexts are immutable inputs.
  account: Readonly<Doc<'productAccounts'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
): Promise<SignInProvider[]> {
  // Prototype accounts predate Google sign-in and were created by Apple.
  const original =
    signInProviderForIssuer(account.tokenIdentifier.split('|', 1)[0] ?? '') ??
    'apple';
  const linked = await ctx.db
    .query('linkedSignIns')
    .withIndex('by_productAccountId_and_provider', (q) =>
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      q.eq('productAccountId', account._id),
    )
    .take(2);
  return [
    original,
    ...linked
      .map(({ provider }) => provider)
      .filter((provider) => provider !== original),
  ];
}

export async function requireProductAccountNotDeleted(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex contexts are immutable inputs.
  signInTokenIdentifier: string,
): Promise<void> {
  const tokenIdentifier = await accountTokenIdentifier(
    ctx,
    signInTokenIdentifier,
  );
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
  if (
    deletionRequest?.phase === 'deleting-data' ||
    deletionRequest?.revocationSucceededAt !== undefined ||
    tombstone !== null
  ) {
    throw productAccountDeletedError();
  }
}

export type AuthenticatedProductAccount = Readonly<{
  deviceCredentialEnforcementActivatedAt: number | undefined;
  productAccountId: Id<'productAccounts'>;
  productSyncKeyEpoch: number | undefined;
  productSyncMaterialInitializedAt: number | undefined;
  productSyncPendingKeyEpoch: number | undefined;
}>;

const recentAuthenticationMaximumAgeSeconds = 5 * 60;
const recentAuthenticationFutureLeewaySeconds = 60;
export const initialProductSyncKeyEpoch = 1;
export const trustedDeviceRevokedErrorCode = 'TRUSTED_DEVICE_REVOKED';
export const trustedDeviceReconnectRequiredErrorCode =
  'TRUSTED_DEVICE_RECONNECT_REQUIRED';
export const trustedDeviceCredentialArgs = {
  trustedDeviceCredential: v.optional(v.string()),
};

const trustedDeviceCredentialByteCount = 32;

function bytesToHex(bytes: Readonly<Uint8Array>): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

export function issueTrustedDeviceCredential(): string {
  return bytesToHex(
    crypto.getRandomValues(new Uint8Array(trustedDeviceCredentialByteCount)),
  );
}

export async function trustedDeviceCredentialDigest(
  credential: string,
): Promise<string> {
  return bytesToHex(
    new Uint8Array(
      await crypto.subtle.digest(
        'SHA-256',
        new TextEncoder().encode(credential),
      ),
    ),
  );
}

export function throwTrustedDeviceRevoked(): never {
  throw new ConvexError({ code: trustedDeviceRevokedErrorCode });
}

export function throwTrustedDeviceReconnectRequired(): never {
  throw new ConvexError({
    code: trustedDeviceReconnectRequiredErrorCode,
    message: 'Reconnect this Trusted Device to continue.',
  });
}

export async function requireProductAccount(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
): Promise<AuthenticatedProductAccount> {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    throw new Error('Authentication required');
  }
  await requireProductAccountNotDeleted(ctx, identity.tokenIdentifier);

  const account = await productAccountForSignIn(ctx, identity.tokenIdentifier);
  if (account === null) {
    throw new Error('Product Account required');
  }

  return {
    deviceCredentialEnforcementActivatedAt:
      account.deviceCredentialEnforcementActivatedAt,
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
  const trustedDevice = await ctx.db.get('trustedDevices', trustedDeviceId);
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

type TrustedDeviceProofAccount = Readonly<{
  deviceCredentialEnforcementActivatedAt: number | undefined;
  productAccountId: Id<'productAccounts'>;
}>;

type TrustedDeviceProof = Readonly<{
  trustedDeviceCredential?: string;
  trustedDeviceId: Id<'trustedDevices'>;
}>;

export async function requireTrustedDeviceProof(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  account: TrustedDeviceProofAccount, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex identifiers are branded values.
  proof: TrustedDeviceProof, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex identifiers are branded values.
): Promise<void> {
  await requireTrustedDevice(
    ctx,
    account.productAccountId,
    proof.trustedDeviceId,
  );
  const trustedDevice = await ctx.db.get(
    'trustedDevices',
    proof.trustedDeviceId,
  );
  if (trustedDevice === null) {
    throw new Error('Trusted device required');
  }
  if (trustedDevice.credentialDigest !== undefined) {
    if (
      proof.trustedDeviceCredential === undefined ||
      !/^[0-9a-f]{64}$/u.test(proof.trustedDeviceCredential) ||
      (await trustedDeviceCredentialDigest(proof.trustedDeviceCredential)) !==
        trustedDevice.credentialDigest
    ) {
      throwTrustedDeviceReconnectRequired();
    }
    return;
  }
  if (account.deviceCredentialEnforcementActivatedAt !== undefined) {
    throwTrustedDeviceReconnectRequired();
  }
  const priorRevocation = await ctx.db
    .query('revokedTrustedDevices')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q.eq('productAccountId', account.productAccountId),
    )
    .first();
  if (priorRevocation !== null) {
    throwTrustedDeviceReconnectRequired();
  }
}

export async function requireAuthenticatedTrustedDevice(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  trustedDeviceId: Id<'trustedDevices'>,
  trustedDeviceCredential?: string,
): Promise<AuthenticatedProductAccount> {
  const account = await requireProductAccount(ctx);
  await requireTrustedDeviceProof(ctx, account, {
    trustedDeviceCredential,
    trustedDeviceId,
  });
  return account;
}
