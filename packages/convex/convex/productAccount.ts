import type { EncryptedProductSyncPayload } from '@private-email/contracts/productSync';

import {
  gmailProviderConnectionStatusValidator,
  productAccountConnectResponseValidator,
  productSyncMaterialInitializedResponseValidator,
  trustedDeviceUnregistrationResponseValidator,
  trustedDeviceSummaryValidator,
} from '@private-email/contracts/productAccount';
import { encryptedProductSyncPayloadBodyValidator } from '@private-email/contracts/productSync';
import { ConvexError, v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx, QueryCtx } from './_generated/server.js';

import { internalMutation, mutation, query } from './_generated/server.js';
import { opaqueGmailConnectionId } from './gmailRouting.js';
import {
  enrollmentLifetimeMilliseconds,
  initialProductSyncKeyEpoch,
  issueTrustedDeviceCredential,
  pendingDeviceProofArgs,
  productAccountForSignIn,
  requireAuthenticatedPendingDevice,
  requireAuthenticatedTrustedDevice,
  requireProductAccount,
  requireProductAccountNotDeleted,
  requireRecoveryVerifier,
  requireTrustedDevice,
  signInProvidersForAccount,
  trustedDeviceCredentialArgs,
  trustedDeviceCredentialDigest,
  throwTrustedDeviceRevoked,
} from './productAccountAuth.js';

const gmailConnectionLimitPerTrustedDevice = 20;
const microsoftGraphConnectionLimitPerTrustedDevice = 20;
export const gmailLegacyRouteFallbackLimit = 100;
export const trustedDeviceLimitPerProductAccount = 100;
const pendingDeviceLimitPerProductAccount = 3;
// Expired Pending Devices removed whenever another one is created.
const expiredPendingDeviceCleanupLimit = 10;
const trustedDeviceNameMaximumLength = 80;
const recoveryPayloadIdentifier = 'product-account-recovery-v1';
// The replacement opens only schema 3 recovery envelopes; prototype schemas 1 and 2 stay rejected.
const recoveryWrappedAccountKeySchemaVersion = 3;

type TrustedDeviceRegistration = Readonly<{
  deviceIdentifier: string;
  deviceName: string | undefined;
  now: number;
  platform: string;
  productSyncKeyEpoch: number;
}>;

type ProductAccountConnection = Readonly<{
  deviceIdentifier: string;
  // A device that already holds a Product Account may only reconnect to it.
  expectedProductAccountId: Id<'productAccounts'> | undefined;
  now: number;
  tokenIdentifier: string;
}>;

export const signInNotLinkedErrorCode = 'SIGN_IN_NOT_LINKED';
export const pendingDeviceLimitErrorCode = 'PENDING_DEVICE_LIMIT_REACHED';

type TrustedDeviceCredentialConnection = Readonly<{
  presentedCredential: string | undefined;
  supportsDeviceCredentials: boolean | undefined;
  trustedDeviceId: Id<'trustedDevices'>;
}>;

type TrustedDeviceRevocationTarget = Readonly<{
  credentialDigest?: string;
  deviceIdentifier: string;
  productAccountId: Id<'productAccounts'>;
}>;

type GmailConnectionDetails = Readonly<{
  emailAddress: string;
  lastVerifiedAt: number;
  provider: 'gmail';
  providerAccountIdentifier: string;
  trustedDeviceId: Id<'trustedDevices'>;
  updatedAt: number;
}>;

function normalizedTrustedDeviceName(displayName: string): string {
  const normalized = displayName.trim();
  if (
    normalized.length === 0 ||
    normalized.length > trustedDeviceNameMaximumLength
  ) {
    throw new Error(
      `Trusted Device name must be between 1 and ${trustedDeviceNameMaximumLength} characters`,
    );
  }
  return normalized;
}

function defaultTrustedDeviceName(platform: string): string {
  switch (platform) {
    case 'ios': {
      return 'Apple mobile device';
    }
    case 'macos': {
      return 'Mac';
    }
    default: {
      return 'Apple device';
    }
  }
}

async function preserveOrIssueTrustedDeviceCredential(
  ctx: MutationCtx,
  request: TrustedDeviceCredentialConnection,
): Promise<string | undefined> {
  if (!request.supportsDeviceCredentials) {
    return undefined;
  }
  const trustedDevice = await ctx.db.get(
    'trustedDevices',
    request.trustedDeviceId,
  );
  if (trustedDevice === null) {
    throw new Error('Trusted device required');
  }
  if (
    request.presentedCredential !== undefined &&
    trustedDevice.credentialDigest !== undefined &&
    (await trustedDeviceCredentialDigest(request.presentedCredential)) ===
      trustedDevice.credentialDigest
  ) {
    return request.presentedCredential;
  }
  const credential = issueTrustedDeviceCredential();
  await ctx.db.patch('trustedDevices', request.trustedDeviceId, {
    credentialDigest: await trustedDeviceCredentialDigest(credential),
  });
  return credential;
}

export function trustedDeviceDisplayName(
  device: Readonly<{ displayName?: string; platform: string }>,
): string {
  return device.displayName ?? defaultTrustedDeviceName(device.platform);
}

function trustedDeviceSummary(device: Readonly<Doc<'trustedDevices'>>): {
  displayName: string;
  id: string;
  lastSeenAt: number;
  platform: string;
  registeredAt: number;
} {
  return {
    displayName: trustedDeviceDisplayName(device),
    id: device._id,
    lastSeenAt: device.lastSeenAt,
    platform: device.platform,
    registeredAt: device.registeredAt,
  };
}

function gmailConnectionDetails(
  args: Readonly<{
    emailAddress: string;
    providerAccountIdentifier: string;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
  now: number,
): GmailConnectionDetails {
  return {
    emailAddress: args.emailAddress,
    lastVerifiedAt: now,
    provider: 'gmail',
    providerAccountIdentifier: args.providerAccountIdentifier,
    trustedDeviceId: args.trustedDeviceId,
    updatedAt: now,
  };
}

function gmailConnectionStatus(connection: Doc<'mailProviderConnections'>) {
  if (
    connection.emailAddress === undefined ||
    connection.providerAccountIdentifier === undefined
  ) {
    throw new Error('Legacy Gmail connection unavailable');
  }
  return {
    connectedAt: connection.connectedAt,
    emailAddress: connection.emailAddress,
    lastVerifiedAt: connection.lastVerifiedAt,
    provider: 'gmail' as const,
    providerAccountIdentifier: connection.providerAccountIdentifier,
    trustedDeviceId: connection.trustedDeviceId,
    updatedAt: connection.updatedAt,
  };
}

type GmailTrustedDeviceAuthentication = Readonly<{
  credential?: string;
  id: Id<'trustedDevices'>;
}>;

async function gmailConnectionsForTrustedDevice(
  ctx: MutationCtx | QueryCtx,
  trustedDevice: GmailTrustedDeviceAuthentication,
  limit: number,
): Promise<Array<Doc<'mailProviderConnections'>>> {
  const account = await requireAuthenticatedTrustedDevice(
    ctx,
    trustedDevice.id,
    trustedDevice.credential,
  );
  return ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productId_provider_deviceId_providerAccountId', (q) =>
      q
        .eq('productAccountId', account.productAccountId)
        .eq('provider', 'gmail')
        .eq('trustedDeviceId', trustedDevice.id),
    )
    .take(limit);
}

function gmailRoutingIdentityChanged(
  existingConnection: Doc<'mailProviderConnections'>,
  connection: GmailConnectionDetails,
): boolean {
  return (
    existingConnection.providerAccountIdentifier !==
      connection.providerAccountIdentifier ||
    existingConnection.emailAddress !== connection.emailAddress
  );
}

async function updateGmailConnection(
  ctx: MutationCtx,
  existingConnection: Doc<'mailProviderConnections'>,
  connection: GmailConnectionDetails,
): Promise<{ connectedAt: number } & GmailConnectionDetails> {
  const routingIdentityChanged = gmailRoutingIdentityChanged(
    existingConnection,
    connection,
  );
  if (routingIdentityChanged) {
    await ctx.db.delete('mailProviderConnections', existingConnection._id);
    await ctx.db.insert('mailProviderConnections', {
      ...connection,
      connectedAt: existingConnection.connectedAt,
      productAccountId: existingConnection.productAccountId,
    });
    return {
      connectedAt: existingConnection.connectedAt,
      ...connection,
    };
  }
  await ctx.db.patch('mailProviderConnections', existingConnection._id, {
    ...connection,
    updatedAt: existingConnection.updatedAt,
  });
  return {
    connectedAt: existingConnection.connectedAt,
    ...connection,
    updatedAt: existingConnection.updatedAt,
  };
}

async function requireDeviceWasNotRevoked(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
  deviceIdentifier: string,
): Promise<void> {
  const tombstone = await ctx.db
    .query('revokedTrustedDevices')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('deviceIdentifier', deviceIdentifier),
    )
    .unique();
  if (tombstone !== null) {
    throwTrustedDeviceRevoked();
  }
}

async function upsertProductAccount(
  ctx: MutationCtx,
  connection: ProductAccountConnection,
): Promise<{
  accountCreated: boolean;
  productAccountId: Id<'productAccounts'>;
}> {
  const existingAccount = await productAccountForSignIn(
    ctx,
    connection.tokenIdentifier,
  );
  if (
    connection.expectedProductAccountId !== undefined &&
    existingAccount?._id !== connection.expectedProductAccountId
  ) {
    // Neither creates an account nor reveals another one for an unlinked identity.
    throw new ConvexError({
      code: signInNotLinkedErrorCode,
      message: 'This sign-in is not linked to this Product Account.',
    });
  }

  if (existingAccount === null) {
    return {
      accountCreated: true,
      productAccountId: await ctx.db.insert('productAccounts', {
        createdAt: connection.now,
        lastSeenAt: connection.now,
        tokenIdentifier: connection.tokenIdentifier,
      }),
    };
  }

  const productAccountId = existingAccount._id;
  await requireDeviceWasNotRevoked(
    ctx,
    productAccountId,
    connection.deviceIdentifier,
  );
  await ctx.db.patch('productAccounts', productAccountId, {
    lastSeenAt: connection.now,
  });

  return {
    accountCreated: false,
    productAccountId,
  };
}

export async function requireTrustedDeviceCapacity(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
): Promise<void> {
  const devices = await ctx.db
    .query('trustedDevices')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q.eq('productAccountId', productAccountId),
    )
    .take(trustedDeviceLimitPerProductAccount);
  if (devices.length >= trustedDeviceLimitPerProductAccount) {
    throw new Error('Trusted Device limit exceeded');
  }
}

async function registerTrustedDevice(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
  registration: TrustedDeviceRegistration,
): Promise<{
  deviceRegistered: true;
  trustedDeviceId: Id<'trustedDevices'>;
}> {
  const displayName =
    registration.deviceName === undefined
      ? undefined
      : normalizedTrustedDeviceName(registration.deviceName);
  await requireTrustedDeviceCapacity(ctx, productAccountId);
  return {
    deviceRegistered: true,
    trustedDeviceId: await ctx.db.insert('trustedDevices', {
      deviceIdentifier: registration.deviceIdentifier,
      ...(displayName === undefined ? {} : { displayName }),
      lastSeenAt: registration.now,
      platform: registration.platform,
      productAccountId,
      productSyncKeyEpoch: registration.productSyncKeyEpoch,
      registeredAt: registration.now,
    }),
  };
}

export async function preserveTrustedDeviceRevocationTarget(
  ctx: MutationCtx,
  target: Readonly<{
    credentialDigest?: string;
    deviceIdentifier: string;
    productAccountId: Id<'productAccounts'>;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<void> {
  const existingTarget = await ctx.db
    .query('trustedDeviceRevocationTargets')
    .withIndex('by_productAccountId_and_trustedDeviceId', (q) =>
      q
        .eq('productAccountId', target.productAccountId)
        .eq('trustedDeviceId', target.trustedDeviceId),
    )
    .unique();
  if (existingTarget === null) {
    await ctx.db.insert('trustedDeviceRevocationTargets', target);
  } else if (target.credentialDigest !== undefined) {
    await ctx.db.patch('trustedDeviceRevocationTargets', existingTarget._id, {
      credentialDigest: target.credentialDigest,
    });
  }
}

async function updateTrustedDevice(
  ctx: MutationCtx,
  existingDevice: Doc<'trustedDevices'>,
  registration: TrustedDeviceRegistration,
): Promise<{
  deviceRegistered: false;
  trustedDeviceId: Id<'trustedDevices'>;
}> {
  const displayName =
    registration.deviceName === undefined
      ? undefined
      : normalizedTrustedDeviceName(registration.deviceName);
  const trustedDeviceId = existingDevice._id;
  await ctx.db.patch('trustedDevices', trustedDeviceId, {
    ...(existingDevice.displayName === undefined && displayName !== undefined
      ? { displayName }
      : {}),
    lastSeenAt: registration.now,
  });

  return {
    deviceRegistered: false,
    trustedDeviceId,
  };
}

async function reconnectTrustedDevice(
  ctx: MutationCtx,
  existingDevice: Doc<'trustedDevices'>,
  registration: TrustedDeviceRegistration,
): Promise<{
  deviceRegistered: boolean;
  trustedDeviceId: Id<'trustedDevices'>;
}> {
  const result = await updateTrustedDevice(ctx, existingDevice, registration);
  await preserveTrustedDeviceRevocationTarget(ctx, {
    deviceIdentifier: registration.deviceIdentifier,
    productAccountId: existingDevice.productAccountId,
    trustedDeviceId: result.trustedDeviceId,
  });
  return result;
}

// Until a device creates the account's keys, the next device to sign in may create them instead.
async function awaitsFirstDevice(
  ctx: MutationCtx,
  account: Readonly<Doc<'productAccounts'>>,
): Promise<boolean> {
  if (account.productSyncMaterialInitializedAt !== undefined) {
    return false;
  }
  const trustedDevice = await ctx.db
    .query('trustedDevices')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q.eq('productAccountId', account._id),
    )
    .first();
  return trustedDevice === null;
}

async function deleteExpiredPendingDevices(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
  now: number,
): Promise<void> {
  const expired = await ctx.db
    .query('pendingDevices')
    .withIndex('by_productAccountId_and_expiresAt', (q) =>
      q.eq('productAccountId', productAccountId).lte('expiresAt', now),
    )
    .take(expiredPendingDeviceCleanupLimit);
  for (const pendingDevice of expired) {
    await ctx.db.delete('pendingDevices', pendingDevice._id);
  }
}

type PendingDeviceConnection = Readonly<{
  pendingDeviceCredential: string;
  pendingDeviceId: Id<'pendingDevices'>;
}>;

// A device the account has not admitted waits as a Pending Device: one per device identifier,
// a few per account, each ending with its Enrollment Code.
// fallow-ignore-next-line complexity -- Resume, credential renewal, expiry and limits share one record.
async function upsertPendingDevice(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
  registration: TrustedDeviceRegistration &
    Readonly<{ presentedCredential: string | undefined }>,
): Promise<PendingDeviceConnection> {
  const { now } = registration;
  const existing = await ctx.db
    .query('pendingDevices')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('deviceIdentifier', registration.deviceIdentifier),
    )
    .unique();
  if (existing !== null && existing.expiresAt > now) {
    if (
      registration.presentedCredential !== undefined &&
      (await trustedDeviceCredentialDigest(
        registration.presentedCredential,
      )) === existing.credentialDigest
    ) {
      return {
        pendingDeviceCredential: registration.presentedCredential,
        pendingDeviceId: existing._id,
      };
    }
    // After a lost reply, a new credential voids everything the earlier one could collect.
    const credential = issueTrustedDeviceCredential();
    await ctx.db.patch('pendingDevices', existing._id, {
      approval: undefined,
      credentialDigest: await trustedDeviceCredentialDigest(credential),
      enrollmentPublicKey: undefined,
      recoveryKeyVersion: undefined,
      requestedAt: undefined,
    });
    return {
      pendingDeviceCredential: credential,
      pendingDeviceId: existing._id,
    };
  }
  if (existing !== null) {
    await ctx.db.delete('pendingDevices', existing._id);
  }
  await deleteExpiredPendingDevices(ctx, productAccountId, now);
  const waiting = await ctx.db
    .query('pendingDevices')
    .withIndex('by_productAccountId_and_expiresAt', (q) =>
      q.eq('productAccountId', productAccountId).gt('expiresAt', now),
    )
    .take(pendingDeviceLimitPerProductAccount);
  if (waiting.length >= pendingDeviceLimitPerProductAccount) {
    throw new ConvexError({
      code: pendingDeviceLimitErrorCode,
      message: 'Too many devices are waiting for approval.',
    });
  }
  const displayName =
    registration.deviceName === undefined
      ? undefined
      : normalizedTrustedDeviceName(registration.deviceName);
  const credential = issueTrustedDeviceCredential();
  return {
    pendingDeviceCredential: credential,
    pendingDeviceId: await ctx.db.insert('pendingDevices', {
      createdAt: now,
      credentialDigest: await trustedDeviceCredentialDigest(credential),
      deviceIdentifier: registration.deviceIdentifier,
      ...(displayName === undefined ? {} : { displayName }),
      expiresAt: now + enrollmentLifetimeMilliseconds,
      platform: registration.platform,
      productAccountId,
    }),
  };
}

async function deleteTrustedDeviceHeartbeat(
  ctx: MutationCtx,
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<void> {
  const heartbeat = await ctx.db
    .query('devicePushRouteHeartbeats')
    .withIndex('by_trustedDeviceId', (q) =>
      q.eq('trustedDeviceId', trustedDeviceId),
    )
    .unique();
  if (heartbeat !== null) {
    await ctx.db.delete('devicePushRouteHeartbeats', heartbeat._id);
  }
}

async function legacyGmailRouteSnapshot(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
): Promise<
  Readonly<{
    complete: boolean;
    opaqueConnectionIds: ReadonlySet<string>;
  }>
> {
  const connections = await ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productAccountId_and_provider_and_emailAddress', (q) =>
      q.eq('productAccountId', productAccountId).eq('provider', 'gmail'),
    )
    .take(gmailLegacyRouteFallbackLimit + 1);
  const opaqueConnectionIds = await Promise.all(
    connections
      .slice(0, gmailLegacyRouteFallbackLimit)
      .flatMap((connection) =>
        connection.opaqueConnectionId === undefined &&
        connection.providerAccountIdentifier !== undefined
          ? [
              opaqueGmailConnectionId(
                productAccountId,
                connection.providerAccountIdentifier,
              ),
            ]
          : [],
      ),
  );
  return {
    complete: connections.length <= gmailLegacyRouteFallbackLimit,
    opaqueConnectionIds: new Set(opaqueConnectionIds),
  };
}

type GmailIdentityBindingRouteRequest = Readonly<{
  legacyRoutes: Readonly<{
    complete: boolean;
    opaqueConnectionIds: ReadonlySet<string>;
  }>;
  opaqueConnectionId: string;
  productAccountId: Id<'productAccounts'>;
}>;

function gmailIdentityBindingStillHasRoute(
  remainingConnectionExists: boolean,
  request: GmailIdentityBindingRouteRequest,
): boolean {
  return (
    remainingConnectionExists ||
    !request.legacyRoutes.complete ||
    request.legacyRoutes.opaqueConnectionIds.has(request.opaqueConnectionId)
  );
}

async function deleteGmailIdentityBindingIfOrphaned(
  ctx: MutationCtx,
  request: GmailIdentityBindingRouteRequest,
): Promise<void> {
  const remainingConnection = await ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productAccountId_and_provider_and_opaqueConnectionId', (q) =>
      q
        .eq('productAccountId', request.productAccountId)
        .eq('provider', 'gmail')
        .eq('opaqueConnectionId', request.opaqueConnectionId),
    )
    .first();
  if (
    gmailIdentityBindingStillHasRoute(remainingConnection !== null, request)
  ) {
    return;
  }
  const identityBinding = await ctx.db
    .query('gmailOpaqueIdentityBindings')
    .withIndex('by_productAccountId_and_opaqueConnectionId', (q) =>
      q
        .eq('productAccountId', request.productAccountId)
        .eq('opaqueConnectionId', request.opaqueConnectionId),
    )
    .unique();
  if (identityBinding !== null) {
    await ctx.db.delete('gmailOpaqueIdentityBindings', identityBinding._id);
  }
}

async function deleteOrphanedGmailIdentityBindings(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
  connections: ReadonlyArray<Doc<'mailProviderConnections'>>,
): Promise<void> {
  const candidateOpaqueConnectionIds = await Promise.all(
    connections.map(async (connection) => {
      if (connection.opaqueConnectionId !== undefined) {
        return connection.opaqueConnectionId;
      }
      return connection.providerAccountIdentifier === undefined
        ? undefined
        : opaqueGmailConnectionId(
            productAccountId,
            connection.providerAccountIdentifier,
          );
    }),
  );
  const opaqueConnectionIds = new Set(
    candidateOpaqueConnectionIds.filter(
      (opaqueConnectionId) => opaqueConnectionId !== undefined,
    ),
  );
  const legacyRoutes = await legacyGmailRouteSnapshot(ctx, productAccountId);
  for (const opaqueConnectionId of opaqueConnectionIds) {
    await deleteGmailIdentityBindingIfOrphaned(ctx, {
      legacyRoutes,
      opaqueConnectionId,
      productAccountId,
    });
  }
}

async function deleteGmailConnectionsForTrustedDevice(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<void> {
  const deletedConnections: Array<Doc<'mailProviderConnections'>> = [];
  for (;;) {
    const page = await ctx.db
      .query('mailProviderConnections')
      .withIndex('by_productId_provider_deviceId_providerAccountId', (q) =>
        q
          .eq('productAccountId', productAccountId)
          .eq('provider', 'gmail')
          .eq('trustedDeviceId', trustedDeviceId),
      )
      .take(gmailConnectionLimitPerTrustedDevice);
    if (page.length === 0) {
      break;
    }
    for (const connection of page) {
      await ctx.db.delete('mailProviderConnections', connection._id);
    }
    deletedConnections.push(...page);
  }
  await deleteOrphanedGmailIdentityBindings(
    ctx,
    productAccountId,
    deletedConnections,
  );
}

async function deleteMicrosoftGraphConnectionsForTrustedDevice(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<void> {
  for (;;) {
    const page = await ctx.db
      .query('mailProviderConnections')
      .withIndex('by_productId_provider_deviceId_providerAccountId', (q) =>
        q
          .eq('productAccountId', productAccountId)
          .eq('provider', 'microsoft-graph')
          .eq('trustedDeviceId', trustedDeviceId),
      )
      .take(microsoftGraphConnectionLimitPerTrustedDevice);
    if (page.length === 0) {
      break;
    }
    for (const connection of page) {
      const wakeupState = await ctx.db
        .query('microsoftGraphWakeupStates')
        .withIndex('by_routeId', (q) => q.eq('routeId', connection._id))
        .unique();
      if (wakeupState !== null) {
        await ctx.db.delete('microsoftGraphWakeupStates', wakeupState._id);
      }
      await ctx.db.delete('mailProviderConnections', connection._id);
    }
  }
}

async function deleteTrustedDeviceAndRoutes(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<void> {
  await deleteGmailConnectionsForTrustedDevice(
    ctx,
    productAccountId,
    trustedDeviceId,
  );
  await deleteMicrosoftGraphConnectionsForTrustedDevice(
    ctx,
    productAccountId,
    trustedDeviceId,
  );
  await deleteTrustedDeviceHeartbeat(ctx, trustedDeviceId);
  if ((await ctx.db.get('trustedDevices', trustedDeviceId)) !== null) {
    await ctx.db.delete('trustedDevices', trustedDeviceId);
  }
}

type RevocationTargetCleanup = Readonly<{
  productAccountId: Id<'productAccounts'>;
  target: Readonly<TrustedDeviceRevocationTarget>;
  trustedDeviceId: Id<'trustedDevices'>;
}>;

async function deleteRevocationTargetDevicesAndRoutes(
  ctx: MutationCtx,
  request: RevocationTargetCleanup,
): Promise<void> {
  const { productAccountId, target, trustedDeviceId } = request;
  const matchingDevices = await ctx.db
    .query('trustedDevices')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('deviceIdentifier', target.deviceIdentifier),
    )
    .take(trustedDeviceLimitPerProductAccount + 1);
  if (matchingDevices.length > trustedDeviceLimitPerProductAccount) {
    throw new Error('Trusted Device limit exceeded');
  }
  let selectedDeviceDeleted = false;
  for (const device of matchingDevices) {
    selectedDeviceDeleted ||= device._id === trustedDeviceId;
    await preserveTrustedDeviceRevocationTarget(ctx, {
      ...(device.credentialDigest === undefined
        ? {}
        : { credentialDigest: device.credentialDigest }),
      deviceIdentifier: device.deviceIdentifier,
      productAccountId,
      trustedDeviceId: device._id,
    });
    await deleteTrustedDeviceAndRoutes(ctx, productAccountId, device._id);
  }
  if (!selectedDeviceDeleted) {
    await deleteTrustedDeviceAndRoutes(ctx, productAccountId, trustedDeviceId);
  }
}

async function pendingRotationDeviceCount(
  ctx: QueryCtx | MutationCtx,
  productAccountId: Id<'productAccounts'>,
  keyEpoch: number,
): Promise<number> {
  const devices = await ctx.db
    .query('trustedDevices')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q.eq('productAccountId', productAccountId),
    )
    .take(trustedDeviceLimitPerProductAccount + 1);
  if (devices.length > trustedDeviceLimitPerProductAccount) {
    throw new Error('Trusted Device limit exceeded');
  }
  return devices.filter(
    (device) =>
      (device.productSyncKeyEpoch ?? initialProductSyncKeyEpoch) !== keyEpoch,
  ).length;
}

async function commitPendingProductSyncKeyRotation(
  ctx: MutationCtx,
  request: Readonly<{
    account: Doc<'productAccounts'>;
    keyEpoch: number;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<void> {
  if (
    request.account.productSyncPendingRecoveryWrappedAccountKey === undefined
  ) {
    throw new Error('Product Sync key rotation material is unavailable');
  }
  // The replacement Recovery Key now admits devices; the previous one no longer opens anything.
  const recoveryMaterial = await ctx.db
    .query('encryptedProductSyncPayloads')
    .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
      q
        .eq('productAccountId', request.account._id)
        .eq('payloadIdentifier', recoveryPayloadIdentifier),
    )
    .unique();
  if (recoveryMaterial === null) {
    throw new Error('Recovery material required');
  }
  const now = Math.max(Date.now(), recoveryMaterial.updatedAt + 1);
  await ctx.db.patch('encryptedProductSyncPayloads', recoveryMaterial._id, {
    encryptedPayload:
      request.account.productSyncPendingRecoveryWrappedAccountKey,
    trustedDeviceId: request.trustedDeviceId,
    updatedAt: now,
    writtenAt: now,
  });
  await ctx.db.patch('productAccounts', request.account._id, {
    productSyncKeyEpoch: request.keyEpoch,
    productSyncPendingEncryptedTransition: undefined,
    productSyncPendingKeyEpoch: undefined,
    productSyncPendingRecoveryVerifier: undefined,
    productSyncPendingRecoveryWrappedAccountKey: undefined,
    productSyncRecoveryVerifier:
      request.account.productSyncPendingRecoveryVerifier,
  });
}

export const connect = mutation({
  args: {
    deviceIdentifier: v.string(),
    deviceName: v.optional(v.string()),
    expectedProductAccountId: v.optional(v.id('productAccounts')),
    // A device presents the credential it last received, whether it is trusted or pending.
    pendingDeviceCredential: v.optional(v.string()),
    platform: v.string(),
    supportsDeviceCredentials: v.optional(v.boolean()),
    trustedDeviceCredential: v.optional(v.string()),
  },
  // fallow-ignore-next-line complexity -- One transaction decides between a new, returning or Pending Device.
  handler: async (ctx, args) => {
    const presentedCredential =
      args.trustedDeviceCredential ?? args.pendingDeviceCredential;
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error('Authentication required');
    }
    await requireProductAccountNotDeleted(ctx, identity.tokenIdentifier);

    const now = Date.now();
    const { accountCreated, productAccountId } = await upsertProductAccount(
      ctx,
      {
        deviceIdentifier: args.deviceIdentifier,
        expectedProductAccountId: args.expectedProductAccountId,
        now,
        tokenIdentifier: identity.tokenIdentifier,
      },
    );
    const productAccount = await ctx.db.get(
      'productAccounts',
      productAccountId,
    );
    if (productAccount === null) {
      throw new Error('Product Account required');
    }
    const registration = {
      deviceIdentifier: args.deviceIdentifier,
      deviceName: args.deviceName,
      now,
      platform: args.platform,
      productSyncKeyEpoch:
        productAccount.productSyncKeyEpoch ?? initialProductSyncKeyEpoch,
    };
    const connection = {
      accountCreated,
      productSyncMaterialInitialized:
        productAccount.productSyncMaterialInitializedAt !== undefined,
      productAccountId,
      signInProviders: await signInProvidersForAccount(ctx, productAccount),
    };
    const existingDevice = await ctx.db
      .query('trustedDevices')
      .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
        q
          .eq('productAccountId', productAccountId)
          .eq('deviceIdentifier', args.deviceIdentifier),
      )
      .unique();
    // Product Sign-In alone admits only the device that creates the account's keys.
    if (
      existingDevice === null &&
      !accountCreated &&
      !(await awaitsFirstDevice(ctx, productAccount))
    ) {
      return {
        ...connection,
        ...(await upsertPendingDevice(ctx, productAccountId, {
          ...registration,
          presentedCredential,
        })),
      };
    }
    const { deviceRegistered, trustedDeviceId } =
      existingDevice === null
        ? await registerTrustedDevice(ctx, productAccountId, registration)
        : await reconnectTrustedDevice(ctx, existingDevice, registration);
    if (existingDevice === null) {
      await preserveTrustedDeviceRevocationTarget(ctx, {
        deviceIdentifier: args.deviceIdentifier,
        productAccountId,
        trustedDeviceId,
      });
    }
    const trustedDeviceCredential =
      await preserveOrIssueTrustedDeviceCredential(ctx, {
        presentedCredential,
        supportsDeviceCredentials: args.supportsDeviceCredentials,
        trustedDeviceId,
      });
    if (
      trustedDeviceCredential !== undefined &&
      productAccount.deviceCredentialEnforcementActivatedAt === undefined
    ) {
      await ctx.db.patch('productAccounts', productAccountId, {
        deviceCredentialEnforcementActivatedAt: now,
      });
    }

    return {
      ...connection,
      deviceRegistered,
      ...(trustedDeviceCredential === undefined
        ? {}
        : { trustedDeviceCredential }),
      trustedDeviceId,
    };
  },
  returns: productAccountConnectResponseValidator,
});

export const listTrustedDevices = query({
  args: {
    ...trustedDeviceCredentialArgs,
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    const devices = await ctx.db
      .query('trustedDevices')
      .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
        q.eq('productAccountId', account.productAccountId),
      )
      .take(trustedDeviceLimitPerProductAccount + 1);
    if (devices.length > trustedDeviceLimitPerProductAccount) {
      throw new Error('Trusted Device limit exceeded');
    }
    return devices.map(trustedDeviceSummary);
  },
  returns: v.array(trustedDeviceSummaryValidator),
});

export const renameTrustedDevice = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    displayName: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
    trustedDeviceToRenameId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    await requireTrustedDevice(
      ctx,
      account.productAccountId,
      args.trustedDeviceToRenameId,
    );
    const device = await ctx.db.get(
      'trustedDevices',
      args.trustedDeviceToRenameId,
    );
    if (device === null) {
      throw new Error('Trusted device required');
    }
    const displayName = normalizedTrustedDeviceName(args.displayName);
    await ctx.db.patch('trustedDevices', args.trustedDeviceToRenameId, {
      displayName,
    });
    return trustedDeviceSummary({ ...device, displayName });
  },
  returns: trustedDeviceSummaryValidator,
});

type RevokeTrustedDeviceArgs = Readonly<{
  encryptedTransition: EncryptedProductSyncPayload['encryptedPayload'];
  expectedRecoveryUpdatedAt: number;
  recoveryVerifier: string;
  recoveryWrappedAccountKey: EncryptedProductSyncPayload['encryptedPayload'];
  trustedDeviceId: Id<'trustedDevices'>;
  trustedDeviceToRevokeId: Id<'trustedDevices'>;
}>;

type ProductSyncKeyRotationResponse = Readonly<{
  keyEpoch: number;
  pendingDeviceCount: number;
  state: 'complete' | 'pending';
}>;

function productSyncKeyRotationResponse(
  keyEpoch: number,
  pendingDeviceCount: number,
): ProductSyncKeyRotationResponse {
  return {
    keyEpoch,
    pendingDeviceCount,
    state: pendingDeviceCount === 0 ? 'complete' : 'pending',
  };
}

async function completedRevocationResponse(
  ctx: MutationCtx,
  account: Readonly<Doc<'productAccounts'>>,
): Promise<ProductSyncKeyRotationResponse> {
  if (account.productSyncPendingKeyEpoch !== undefined) {
    return productSyncKeyRotationResponse(
      account.productSyncPendingKeyEpoch,
      await pendingRotationDeviceCount(
        ctx,
        account._id,
        account.productSyncPendingKeyEpoch,
      ),
    );
  }
  return productSyncKeyRotationResponse(
    account.productSyncKeyEpoch ?? initialProductSyncKeyEpoch,
    0,
  );
}

type PendingKeyRotationRevocation = Readonly<{
  account: Readonly<Doc<'productAccounts'>>;
  args: RevokeTrustedDeviceArgs;
  pendingKeyEpoch: number;
  target: TrustedDeviceRevocationTarget;
}>;

async function requireUnchangedRecoveryMaterial(
  ctx: MutationCtx,
  request: Readonly<{
    expectedKeyVersion?: number;
    expectedUpdatedAt: number;
    productAccountId: Id<'productAccounts'>;
  }>,
): Promise<void> {
  const { expectedKeyVersion, expectedUpdatedAt, productAccountId } = request;
  const recoveryMaterial = await ctx.db
    .query('encryptedProductSyncPayloads')
    .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('payloadIdentifier', recoveryPayloadIdentifier),
    )
    .unique();
  if (
    recoveryMaterial === null ||
    recoveryMaterial.updatedAt !== expectedUpdatedAt ||
    (expectedKeyVersion !== undefined &&
      recoveryMaterial.encryptedPayload.keyVersion !== expectedKeyVersion)
  ) {
    throw new Error('Recovery material changed');
  }
}

type TrustedDeviceRevocation = Readonly<{
  account: Readonly<Doc<'productAccounts'>>;
  args: RevokeTrustedDeviceArgs;
  nextKeyEpoch: number;
  target: TrustedDeviceRevocationTarget;
}>;

async function applyTrustedDeviceRevocation(
  ctx: MutationCtx,
  request: TrustedDeviceRevocation,
): Promise<Id<'productAccounts'>> {
  const { account, args, nextKeyEpoch, target } = request;
  if (
    args.recoveryWrappedAccountKey.keyVersion !== nextKeyEpoch ||
    args.recoveryWrappedAccountKey.schemaVersion !==
      recoveryWrappedAccountKeySchemaVersion
  ) {
    throw new Error('Product Sync key rotation material is invalid');
  }
  requireRecoveryVerifier(args.recoveryVerifier);
  const productAccountId = account._id;
  await requireUnchangedRecoveryMaterial(ctx, {
    expectedKeyVersion:
      account.productSyncKeyEpoch ?? initialProductSyncKeyEpoch,
    expectedUpdatedAt: args.expectedRecoveryUpdatedAt,
    productAccountId,
  });
  await ctx.db.insert('revokedTrustedDevices', {
    ...(target.credentialDigest === undefined
      ? {}
      : { credentialDigest: target.credentialDigest }),
    deviceIdentifier: target.deviceIdentifier,
    productAccountId,
    productSyncKeyEpoch: nextKeyEpoch,
    revokedAt: Date.now(),
    trustedDeviceId: args.trustedDeviceToRevokeId,
  });
  await deleteRevocationTargetDevicesAndRoutes(ctx, {
    productAccountId,
    target,
    trustedDeviceId: args.trustedDeviceToRevokeId,
  });
  return productAccountId;
}

async function revokeDuringPendingKeyRotation(
  ctx: MutationCtx,
  request: PendingKeyRotationRevocation,
): Promise<ProductSyncKeyRotationResponse> {
  const { account, args, pendingKeyEpoch, target } = request;
  const currentKeyEpoch =
    account.productSyncKeyEpoch ?? initialProductSyncKeyEpoch;
  const nextKeyEpoch = pendingKeyEpoch + 1;
  if (
    account.productSyncPendingEncryptedTransition === undefined ||
    args.encryptedTransition.keyVersion !== currentKeyEpoch
  ) {
    throw new Error('Product Sync key rotation transition is stale');
  }
  const productAccountId = await applyTrustedDeviceRevocation(ctx, {
    account,
    args,
    nextKeyEpoch,
    target,
  });
  await ctx.db.patch('productAccounts', productAccountId, {
    productSyncPendingEncryptedTransition: args.encryptedTransition,
    productSyncPendingKeyEpoch: nextKeyEpoch,
    productSyncPendingRecoveryVerifier: args.recoveryVerifier,
    productSyncPendingRecoveryWrappedAccountKey: args.recoveryWrappedAccountKey,
  });

  return productSyncKeyRotationResponse(
    nextKeyEpoch,
    await pendingRotationDeviceCount(ctx, productAccountId, nextKeyEpoch),
  );
}

type NewKeyRotationRevocation = Readonly<{
  account: Readonly<Doc<'productAccounts'>>;
  args: RevokeTrustedDeviceArgs;
  target: TrustedDeviceRevocationTarget;
}>;

async function startProductSyncKeyRotation(
  ctx: MutationCtx,
  request: NewKeyRotationRevocation,
): Promise<ProductSyncKeyRotationResponse> {
  const { account, args, target } = request;
  const currentKeyEpoch =
    account.productSyncKeyEpoch ?? initialProductSyncKeyEpoch;
  const nextKeyEpoch = currentKeyEpoch + 1;
  if (args.encryptedTransition.keyVersion !== currentKeyEpoch) {
    throw new Error('Product Sync key rotation transition is stale');
  }
  const productAccountId = await applyTrustedDeviceRevocation(ctx, {
    account,
    args,
    nextKeyEpoch,
    target,
  });
  await ctx.db.patch('productAccounts', productAccountId, {
    productSyncKeyEpoch: currentKeyEpoch,
    productSyncPendingEncryptedTransition: args.encryptedTransition,
    productSyncPendingKeyEpoch: nextKeyEpoch,
    productSyncPendingRecoveryVerifier: args.recoveryVerifier,
    productSyncPendingRecoveryWrappedAccountKey: args.recoveryWrappedAccountKey,
  });

  return productSyncKeyRotationResponse(
    nextKeyEpoch,
    await pendingRotationDeviceCount(ctx, productAccountId, nextKeyEpoch),
  );
}

const productSyncKeyRotationResponseValidator = v.object({
  keyEpoch: v.number(),
  pendingDeviceCount: v.number(),
  state: v.union(v.literal('pending'), v.literal('complete')),
});

async function findTrustedDeviceRevocationTarget(
  ctx: MutationCtx,
  request: Readonly<{
    productAccountId: Id<'productAccounts'>;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<TrustedDeviceRevocationTarget> {
  const liveTarget = await ctx.db.get(
    'trustedDevices',
    request.trustedDeviceId,
  );
  const target =
    liveTarget ??
    (await ctx.db
      .query('trustedDeviceRevocationTargets')
      .withIndex('by_productAccountId_and_trustedDeviceId', (q) =>
        q
          .eq('productAccountId', request.productAccountId)
          .eq('trustedDeviceId', request.trustedDeviceId),
      )
      .unique());
  if (target === null || target.productAccountId !== request.productAccountId) {
    throw new Error('Trusted device required');
  }
  return target;
}

// Compares installations, not row ids, which a sign-out and reconnect replace. A retained id of
// the caller's own installation would remove its current row too, so it is refused. An installation
// already removed under another id is complete: another rotation would only replace the Recovery
// Key and add a second tombstone for the installation.
async function installationAlreadyRevoked(
  ctx: MutationCtx,
  request: Readonly<{
    currentTrustedDeviceId: Id<'trustedDevices'>;
    productAccountId: Id<'productAccounts'>;
    target: TrustedDeviceRevocationTarget;
  }>,
): Promise<boolean> {
  const currentDevice = await ctx.db.get(
    'trustedDevices',
    request.currentTrustedDeviceId,
  );
  if (currentDevice?.deviceIdentifier === request.target.deviceIdentifier) {
    throw new Error('Use sign out to remove the current Trusted Device');
  }
  const revocation = await ctx.db
    .query('revokedTrustedDevices')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q
        .eq('productAccountId', request.productAccountId)
        .eq('deviceIdentifier', request.target.deviceIdentifier),
    )
    .first();
  return revocation !== null;
}

// Only the HTTP action reaches this, after proving recent authentication from the bearer token.
export const revokeTrustedDevice = internalMutation({
  args: {
    ...trustedDeviceCredentialArgs,
    encryptedTransition: encryptedProductSyncPayloadBodyValidator,
    expectedRecoveryUpdatedAt: v.number(),
    recoveryVerifier: v.string(),
    recoveryWrappedAccountKey: encryptedProductSyncPayloadBodyValidator,
    trustedDeviceId: v.string(),
    trustedDeviceToRevokeId: v.string(),
  },
  handler: async (ctx, rawArgs) => {
    const trustedDeviceId = ctx.db.normalizeId(
      'trustedDevices',
      rawArgs.trustedDeviceId,
    );
    const trustedDeviceToRevokeId = ctx.db.normalizeId(
      'trustedDevices',
      rawArgs.trustedDeviceToRevokeId,
    );
    if (trustedDeviceId === null || trustedDeviceToRevokeId === null) {
      throw new Error('Trusted device required');
    }
    const args = { ...rawArgs, trustedDeviceId, trustedDeviceToRevokeId };
    const authenticatedAccount = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    if (args.trustedDeviceId === args.trustedDeviceToRevokeId) {
      throw new Error('Use sign out to remove the current Trusted Device');
    }
    const account = await ctx.db.get(
      'productAccounts',
      authenticatedAccount.productAccountId,
    );
    if (account === null) {
      throw new Error('Product Account required');
    }
    const productAccountId = account._id;
    const completedRevocation = await ctx.db
      .query('revokedTrustedDevices')
      .withIndex('by_productAccountId_and_trustedDeviceId', (q) =>
        q
          .eq('productAccountId', productAccountId)
          .eq('trustedDeviceId', args.trustedDeviceToRevokeId),
      )
      .unique();
    if (completedRevocation !== null) {
      return completedRevocationResponse(ctx, account);
    }

    const target = await findTrustedDeviceRevocationTarget(ctx, {
      productAccountId,
      trustedDeviceId: args.trustedDeviceToRevokeId,
    });
    if (
      await installationAlreadyRevoked(ctx, {
        currentTrustedDeviceId: args.trustedDeviceId,
        productAccountId,
        target,
      })
    ) {
      return completedRevocationResponse(ctx, account);
    }
    if (account.productSyncPendingKeyEpoch !== undefined) {
      return revokeDuringPendingKeyRotation(ctx, {
        account,
        args,
        pendingKeyEpoch: account.productSyncPendingKeyEpoch,
        target,
      });
    }
    return startProductSyncKeyRotation(ctx, { account, args, target });
  },
  returns: productSyncKeyRotationResponseValidator,
});

// Without a Product Sign-In, as on an Apple relaunch: only the device holding the revoked
// credential learns of its revocation, so it can purge its account data.
export const isTrustedDeviceRevoked = query({
  args: {
    productAccountId: v.string(),
    trustedDeviceCredential: v.string(),
    trustedDeviceId: v.string(),
  },
  handler: async (ctx, args) => {
    const productAccountId = ctx.db.normalizeId(
      'productAccounts',
      args.productAccountId,
    );
    const trustedDeviceId = ctx.db.normalizeId(
      'trustedDevices',
      args.trustedDeviceId,
    );
    if (productAccountId === null || trustedDeviceId === null) {
      return false;
    }
    const revocation = await ctx.db
      .query('revokedTrustedDevices')
      .withIndex('by_productAccountId_and_trustedDeviceId', (q) =>
        q
          .eq('productAccountId', productAccountId)
          .eq('trustedDeviceId', trustedDeviceId),
      )
      .unique();
    const digest = await trustedDeviceCredentialDigest(
      args.trustedDeviceCredential,
    );
    if (revocation?.credentialDigest === digest) {
      return true;
    }
    // A selected installation can unregister and reconnect under a new row ID before removal.
    // Its retained proof identifies only that installation's rejection, never live account access.
    const target = await ctx.db
      .query('trustedDeviceRevocationTargets')
      .withIndex('by_productAccountId_and_trustedDeviceId', (q) =>
        q
          .eq('productAccountId', productAccountId)
          .eq('trustedDeviceId', trustedDeviceId),
      )
      .unique();
    if (target?.credentialDigest !== digest) {
      return false;
    }
    return (
      (await ctx.db
        .query('revokedTrustedDevices')
        .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
          q
            .eq('productAccountId', productAccountId)
            .eq('deviceIdentifier', target.deviceIdentifier),
        )
        .first()) !== null
    );
  },
  returns: v.boolean(),
});

export const getProductSyncKeyRotation = query({
  args: {
    ...trustedDeviceCredentialArgs,
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const authenticatedAccount = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    const account = await ctx.db.get(
      'productAccounts',
      authenticatedAccount.productAccountId,
    );
    if (
      account === null ||
      account.productSyncPendingEncryptedTransition === undefined ||
      account.productSyncPendingKeyEpoch === undefined
    ) {
      return null;
    }
    return {
      encryptedTransition: account.productSyncPendingEncryptedTransition,
      keyEpoch: account.productSyncPendingKeyEpoch,
      pendingDeviceCount: await pendingRotationDeviceCount(
        ctx,
        authenticatedAccount.productAccountId,
        account.productSyncPendingKeyEpoch,
      ),
    };
  },
  returns: v.union(
    v.null(),
    v.object({
      encryptedTransition: encryptedProductSyncPayloadBodyValidator,
      keyEpoch: v.number(),
      pendingDeviceCount: v.number(),
    }),
  ),
});

export const acknowledgeProductSyncKeyRotation = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    keyEpoch: v.number(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const authenticatedAccount = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    const account = await ctx.db.get(
      'productAccounts',
      authenticatedAccount.productAccountId,
    );
    if (account === null) {
      throw new Error('Product Account required');
    }
    if (account.productSyncPendingKeyEpoch === undefined) {
      if (
        (account.productSyncKeyEpoch ?? initialProductSyncKeyEpoch) ===
        args.keyEpoch
      ) {
        return {
          keyEpoch: args.keyEpoch,
          pendingDeviceCount: 0,
          state: 'complete' as const,
        };
      }
      throw new Error('Product Sync key rotation required');
    }
    if (account.productSyncPendingKeyEpoch !== args.keyEpoch) {
      throw new Error('Product Sync key rotation changed');
    }
    await ctx.db.patch('trustedDevices', args.trustedDeviceId, {
      productSyncKeyEpoch: args.keyEpoch,
    });
    const pendingDeviceCount = await pendingRotationDeviceCount(
      ctx,
      authenticatedAccount.productAccountId,
      args.keyEpoch,
    );
    if (pendingDeviceCount > 0) {
      return {
        keyEpoch: args.keyEpoch,
        pendingDeviceCount,
        state: 'pending' as const,
      };
    }
    await commitPendingProductSyncKeyRotation(ctx, {
      account,
      keyEpoch: args.keyEpoch,
      trustedDeviceId: args.trustedDeviceId,
    });
    return {
      keyEpoch: args.keyEpoch,
      pendingDeviceCount: 0,
      state: 'complete' as const,
    };
  },
  returns: productSyncKeyRotationResponseValidator,
});

// Unregistration also resolves an admission whose reply was lost, with the same cleanup and
// rotation completion as an ordinary Trusted Device sign-out.
async function unregisterOwnedTrustedDevice(
  ctx: MutationCtx,
  account: Readonly<{ productAccountId: Id<'productAccounts'> }>,
  device: Doc<'trustedDevices'>,
): Promise<void> {
  await preserveTrustedDeviceRevocationTarget(ctx, {
    ...(device.credentialDigest === undefined
      ? {}
      : { credentialDigest: device.credentialDigest }),
    deviceIdentifier: device.deviceIdentifier,
    productAccountId: account.productAccountId,
    trustedDeviceId: device._id,
  });
  await deleteTrustedDeviceAndRoutes(ctx, account.productAccountId, device._id);
  const productAccount = await ctx.db.get(
    'productAccounts',
    account.productAccountId,
  );
  if (productAccount?.productSyncPendingKeyEpoch !== undefined) {
    const pendingDeviceCount = await pendingRotationDeviceCount(
      ctx,
      account.productAccountId,
      productAccount.productSyncPendingKeyEpoch,
    );
    if (pendingDeviceCount === 0) {
      await commitPendingProductSyncKeyRotation(ctx, {
        account: productAccount,
        keyEpoch: productAccount.productSyncPendingKeyEpoch,
        trustedDeviceId: device._id,
      });
    }
  }
}

export const unregisterTrustedDevice = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    deviceIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireProductAccount(ctx);
    const device = await ctx.db.get('trustedDevices', args.trustedDeviceId);
    if (device === null) {
      return { registered: false };
    }
    await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    if (device.productAccountId !== account.productAccountId) {
      throw new Error('Trusted device required');
    }
    if (device.deviceIdentifier !== args.deviceIdentifier) {
      throw new Error('Current trusted device required');
    }
    await unregisterOwnedTrustedDevice(ctx, account, device);
    return { registered: false };
  },
  returns: trustedDeviceUnregistrationResponseValidator,
});

// Sign-out races with admission transactionally: either the Pending Device is deleted before
// confirmation, or its same-credential Trusted Device is unregistered after confirmation.
export const unregisterPendingDevice = mutation({
  args: { ...pendingDeviceProofArgs, deviceIdentifier: v.string() },
  handler: async (ctx, args) => {
    const account = await requireProductAccount(ctx);
    if ((await ctx.db.get('pendingDevices', args.pendingDeviceId)) === null) {
      const device = await ctx.db
        .query('trustedDevices')
        .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
          q
            .eq('productAccountId', account.productAccountId)
            .eq('deviceIdentifier', args.deviceIdentifier),
        )
        .unique();
      if (device !== null) {
        await requireAuthenticatedTrustedDevice(
          ctx,
          device._id,
          args.pendingDeviceCredential,
        );
        await unregisterOwnedTrustedDevice(ctx, account, device);
      }
    } else {
      const { pendingDevice } = await requireAuthenticatedPendingDevice(
        ctx,
        args,
        {
          allowExpired: true,
        },
      );
      if (pendingDevice.deviceIdentifier !== args.deviceIdentifier) {
        throw new Error('Current pending device required');
      }
      await ctx.db.delete('pendingDevices', args.pendingDeviceId);
    }
    return { registered: false };
  },
  returns: trustedDeviceUnregistrationResponseValidator,
});

export const markProductSyncMaterialInitialized = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    // The marker only records a published recovery envelope; it never stands in for one.
    const recoveryMaterial = await ctx.db
      .query('encryptedProductSyncPayloads')
      .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('payloadIdentifier', recoveryPayloadIdentifier),
      )
      .unique();
    if (recoveryMaterial === null) {
      throw new Error('Recovery material required');
    }
    await ctx.db.patch('productAccounts', account.productAccountId, {
      productSyncMaterialInitializedAt:
        account.productSyncMaterialInitializedAt ?? Date.now(),
    });

    return {
      productSyncMaterialInitialized: true,
    };
  },
  returns: productSyncMaterialInitializedResponseValidator,
});

// Temporary rollout compatibility for installed clients that still use the
// pre-opaque Gmail registration endpoints.
export const connectGmailProvider = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    emailAddress: v.string(),
    providerAccountIdentifier: v.string(),
    supportsMultipleConnections: v.optional(v.boolean()),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    const now = Date.now();
    const existingConnection = await ctx.db
      .query('mailProviderConnections')
      .withIndex('by_productId_provider_deviceId_providerAccountId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('provider', 'gmail')
          .eq('trustedDeviceId', args.trustedDeviceId)
          .eq('providerAccountIdentifier', args.providerAccountIdentifier),
      )
      .unique();
    const connection = gmailConnectionDetails(args, now);
    if (existingConnection === null) {
      throw new Error('Legacy Gmail registration is disabled');
    }
    return updateGmailConnection(ctx, existingConnection, connection);
  },
  returns: gmailProviderConnectionStatusValidator,
});

export const listGmailProviderConnections = query({
  args: {
    ...trustedDeviceCredentialArgs,
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const connections = await gmailConnectionsForTrustedDevice(
      ctx,
      {
        credential: args.trustedDeviceCredential,
        id: args.trustedDeviceId,
      },
      gmailConnectionLimitPerTrustedDevice + 1,
    );
    if (connections.length > gmailConnectionLimitPerTrustedDevice) {
      throw new Error('Gmail connection limit exceeded');
    }
    return connections
      .filter(
        (connection) =>
          connection.emailAddress !== undefined &&
          connection.providerAccountIdentifier !== undefined,
      )
      .map(gmailConnectionStatus)
      .toSorted((left, right) =>
        left.providerAccountIdentifier.localeCompare(
          right.providerAccountIdentifier,
        ),
      );
  },
  returns: v.array(gmailProviderConnectionStatusValidator),
});

export const removeGmailProviderConnection = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    providerAccountIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    const connection = await ctx.db
      .query('mailProviderConnections')
      .withIndex('by_productId_provider_deviceId_providerAccountId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('provider', 'gmail')
          .eq('trustedDeviceId', args.trustedDeviceId)
          .eq('providerAccountIdentifier', args.providerAccountIdentifier),
      )
      .unique();
    if (connection !== null) {
      await ctx.db.delete('mailProviderConnections', connection._id);
    }
    const remainingConnection = await ctx.db
      .query('mailProviderConnections')
      .withIndex('by_productId_provider_deviceId_providerAccountId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('provider', 'gmail')
          .eq('trustedDeviceId', args.trustedDeviceId),
      )
      .first();
    return {
      hasRemainingGmailConnections: remainingConnection !== null,
      removed: connection !== null,
    };
  },
  returns: v.object({
    hasRemainingGmailConnections: v.boolean(),
    removed: v.boolean(),
  }),
});
