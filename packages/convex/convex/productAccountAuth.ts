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
  ctx: QueryCtx | MutationCtx,
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
  ctx: QueryCtx | MutationCtx,
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
  ctx: QueryCtx | MutationCtx,
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
  ctx: QueryCtx | MutationCtx,
  account: Readonly<Doc<'productAccounts'>>,
): Promise<SignInProvider[]> {
  // Prototype accounts predate Google sign-in and were created by Apple.
  const original =
    signInProviderForIssuer(account.tokenIdentifier.split('|', 1)[0] ?? '') ??
    'apple';
  const linked = await ctx.db
    .query('linkedSignIns')
    .withIndex('by_productAccountId_and_provider', (q) =>
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
  ctx: QueryCtx | MutationCtx,
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

export const initialProductSyncKeyEpoch = 1;
export const trustedDeviceRevokedErrorCode = 'TRUSTED_DEVICE_REVOKED';
export const trustedDeviceReconnectRequiredErrorCode =
  'TRUSTED_DEVICE_RECONNECT_REQUIRED';
export const trustedDeviceCredentialArgs = {
  trustedDeviceCredential: v.optional(v.string()),
};
export const pendingDeviceUnavailableErrorCode = 'PENDING_DEVICE_UNAVAILABLE';
// Long enough to read an Enrollment Code from one screen and type it on another. A Pending Device
// ends with its code unless it asks again.
export const enrollmentLifetimeMilliseconds = 15 * 60 * 1000;
export const pendingDeviceProofArgs = {
  pendingDeviceCredential: v.string(),
  pendingDeviceId: v.id('pendingDevices'),
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

// A SHA-256 digest, as hex, of the value the Recovery Key derives for admitting a Pending Device.
export function requireRecoveryVerifier(verifier: string): void {
  if (!/^[0-9a-f]{64}$/u.test(verifier)) {
    throw new Error('Recovery Key verifier is invalid');
  }
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
  ctx: QueryCtx | MutationCtx,
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
    productAccountId: account._id,
    productSyncKeyEpoch: account.productSyncKeyEpoch,
    productSyncMaterialInitializedAt: account.productSyncMaterialInitializedAt,
    productSyncPendingKeyEpoch: account.productSyncPendingKeyEpoch,
  };
}

export function requireCurrentProductSyncKeyEpoch(
  account: AuthenticatedProductAccount,
  keyVersion: number,
): void {
  if (keyVersion !== newestProductSyncKeyEpoch(account)) {
    throw new Error('Product Sync key rotation required');
  }
}

export async function requireTrustedDevice(
  ctx: QueryCtx | MutationCtx,
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
  ctx: QueryCtx | MutationCtx,
  account: TrustedDeviceProofAccount,
  proof: TrustedDeviceProof,
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
  ctx: QueryCtx | MutationCtx,
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

// A missing, foreign, expired or wrongly proven Pending Device fails the same way; the device
// signs in again for a new record.
function throwPendingDeviceUnavailable(): never {
  throw new ConvexError({ code: pendingDeviceUnavailableErrorCode });
}

export function newestProductSyncKeyEpoch(
  account: Readonly<{
    productSyncKeyEpoch?: number;
    productSyncPendingKeyEpoch?: number;
  }>,
): number {
  return (
    account.productSyncPendingKeyEpoch ??
    account.productSyncKeyEpoch ??
    initialProductSyncKeyEpoch
  );
}

type PendingDeviceProof = Readonly<{
  pendingDeviceCredential: string;
  pendingDeviceId: Id<'pendingDevices'>;
}>;

// The Pending Device's own credential for its record in this Product Account.
export async function requirePendingDeviceProof(
  ctx: QueryCtx | MutationCtx,
  productAccountId: Id<'productAccounts'>,
  proof: PendingDeviceProof & Readonly<{ allowExpired?: boolean }>,
): Promise<Doc<'pendingDevices'>> {
  const pendingDevice = await ctx.db.get(
    'pendingDevices',
    proof.pendingDeviceId,
  );
  if (
    pendingDevice === null ||
    pendingDevice.productAccountId !== productAccountId ||
    (proof.allowExpired !== true && pendingDevice.expiresAt <= Date.now()) ||
    !/^[0-9a-f]{64}$/u.test(proof.pendingDeviceCredential) ||
    (await trustedDeviceCredentialDigest(proof.pendingDeviceCredential)) !==
      pendingDevice.credentialDigest
  ) {
    throwPendingDeviceUnavailable();
  }
  return pendingDevice;
}

// A Pending Device proves Product Sign-In and its own credential. It reaches only its own
// enrollment, and an expired one only to leave.
export async function requireAuthenticatedPendingDevice(
  ctx: MutationCtx,
  proof: PendingDeviceProof,
  options: Readonly<{ allowExpired?: boolean }> = {},
): Promise<
  Readonly<{
    account: AuthenticatedProductAccount;
    pendingDevice: Doc<'pendingDevices'>;
  }>
> {
  const account = await requireProductAccount(ctx);
  return {
    account,
    pendingDevice: await requirePendingDeviceProof(
      ctx,
      account.productAccountId,
      { ...proof, ...options },
    ),
  };
}
