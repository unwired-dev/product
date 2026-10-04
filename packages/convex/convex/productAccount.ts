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
  initialProductSyncKeyEpoch,
  issueTrustedDeviceCredential,
  productAccountForSignIn,
  requireAuthenticatedTrustedDevice,
  requireProductAccount,
  requireRecentAuthentication,
  requireProductAccountNotDeleted,
  requireTrustedDevice,
  signInProvidersForAccount,
  trustedDeviceCredentialArgs,
  trustedDeviceCredentialDigest,
  throwTrustedDeviceRevoked,
} from './productAccountAuth.js';

const gmailConnectionLimitPerTrustedDevice = 20;
const microsoftGraphConnectionLimitPerTrustedDevice = 20;
export const gmailLegacyRouteFallbackLimit = 100;
const trustedDeviceLimitPerProductAccount = 100;
const trustedDeviceIdentifierMigrationBatchLimit = 100;
const trustedDeviceNameMaximumLength = 80;
// Each new enrollment request replaces the device's earlier ones.
const enrollmentRequestCleanupLimit = 10;
const recoveryPayloadIdentifier = 'product-account-recovery-v1';
const recoveryWrappedAccountKeySchemaVersion = 2;

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

type LegacyTrustedDeviceIdentifier = Readonly<{
  deviceIdentifier: string;
  firstRegisteredAt: number;
}>;

type TrustedDeviceCredentialConnection = Readonly<{
  presentedCredential: string | undefined;
  supportsDeviceCredentials: boolean | undefined;
  trustedDeviceId: Id<'trustedDevices'>;
}>;

type TrustedDeviceRevocationTarget = Readonly<{
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
  device: Readonly<Pick<Doc<'trustedDevices'>, 'displayName' | 'platform'>>,
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
        legacyTrustedDeviceIdentifierMigrationCompletedAt: connection.now,
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

async function migrateLegacyTrustedDeviceIdentifier(
  ctx: MutationCtx,
  account: Doc<'productAccounts'>,
  identifier: LegacyTrustedDeviceIdentifier,
): Promise<boolean> {
  const productAccountId = account._id;
  const existingHistory = await ctx.db
    .query('trustedDeviceIdentifierHistory')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('deviceIdentifier', identifier.deviceIdentifier),
    )
    .unique();
  if (existingHistory === null) {
    if (
      account.legacyTrustedDeviceIdentifierMigrationCompletedAt !== undefined
    ) {
      throw new Error('Trusted Device identifier migration is complete');
    }
    await ctx.db.insert('trustedDeviceIdentifierHistory', {
      ...identifier,
      productAccountId,
    });
    return true;
  }
  if (
    account.legacyTrustedDeviceIdentifierMigrationCompletedAt === undefined &&
    identifier.firstRegisteredAt < existingHistory.firstRegisteredAt
  ) {
    await ctx.db.patch('trustedDeviceIdentifierHistory', existingHistory._id, {
      firstRegisteredAt: identifier.firstRegisteredAt,
    });
    return true;
  }
  return false;
}

async function migrateLegacyTrustedDeviceIdentifierBatch(
  ctx: MutationCtx,
  account: Doc<'productAccounts'>,
  identifiers: readonly LegacyTrustedDeviceIdentifier[],
): Promise<number> {
  let migratedIdentifierCount = 0;
  for (const identifier of identifiers) {
    if (await migrateLegacyTrustedDeviceIdentifier(ctx, account, identifier)) {
      migratedIdentifierCount += 1;
    }
  }
  return migratedIdentifierCount;
}

export const migrateLegacyTrustedDeviceIdentifiers = internalMutation({
  args: {
    identifiers: v.array(
      v.object({
        deviceIdentifier: v.string(),
        firstRegisteredAt: v.number(),
      }),
    ),
    migrationComplete: v.boolean(),
    tokenIdentifier: v.string(),
  },
  handler: async (ctx, args) => {
    if (args.identifiers.length > trustedDeviceIdentifierMigrationBatchLimit) {
      throw new Error('Trusted Device identifier migration batch is too large');
    }
    const account = await ctx.db
      .query('productAccounts')
      .withIndex('by_tokenIdentifier', (q) =>
        q.eq('tokenIdentifier', args.tokenIdentifier),
      )
      .unique();
    if (account === null) {
      throw new Error('Product Account required');
    }
    const productAccountId = account._id;
    const migratedIdentifierCount =
      await migrateLegacyTrustedDeviceIdentifierBatch(
        ctx,
        account,
        args.identifiers,
      );
    if (
      args.migrationComplete &&
      account.legacyTrustedDeviceIdentifierMigrationCompletedAt === undefined
    ) {
      await ctx.db.patch('productAccounts', productAccountId, {
        legacyTrustedDeviceIdentifierMigrationCompletedAt: Date.now(),
      });
    }
    return {
      migrationComplete:
        args.migrationComplete ||
        account.legacyTrustedDeviceIdentifierMigrationCompletedAt !== undefined,
      migratedIdentifierCount,
      productAccountId,
    };
  },
  returns: v.object({
    migrationComplete: v.boolean(),
    migratedIdentifierCount: v.number(),
    productAccountId: v.id('productAccounts'),
  }),
});

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
  const devices = await ctx.db
    .query('trustedDevices')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q.eq('productAccountId', productAccountId),
    )
    .take(trustedDeviceLimitPerProductAccount);
  if (devices.length >= trustedDeviceLimitPerProductAccount) {
    throw new Error('Trusted Device limit exceeded');
  }
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

async function preserveTrustedDeviceRevocationTarget(
  ctx: MutationCtx,
  target: Readonly<{
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

async function upsertTrustedDevice(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
  registration: TrustedDeviceRegistration,
): Promise<{
  deviceRegistered: boolean;
  trustedDeviceId: Id<'trustedDevices'>;
}> {
  const identifierHistory = await ctx.db
    .query('trustedDeviceIdentifierHistory')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('deviceIdentifier', registration.deviceIdentifier),
    )
    .unique();
  const existingDevice = await ctx.db
    .query('trustedDevices')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('deviceIdentifier', registration.deviceIdentifier),
    )
    .unique();

  if (existingDevice === null) {
    const priorRevocation = await ctx.db
      .query('revokedTrustedDevices')
      .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
        q.eq('productAccountId', productAccountId),
      )
      .first();
    if (priorRevocation !== null) {
      const account = await ctx.db.get('productAccounts', productAccountId);
      if (
        identifierHistory === null ||
        account?.legacyTrustedDeviceIdentifierMigrationCompletedAt === undefined
      ) {
        throwTrustedDeviceRevoked();
      }
    }
  }

  if (identifierHistory === null) {
    await ctx.db.insert('trustedDeviceIdentifierHistory', {
      deviceIdentifier: registration.deviceIdentifier,
      firstRegisteredAt: registration.now,
      productAccountId,
    });
  }

  const result =
    existingDevice === null
      ? await registerTrustedDevice(ctx, productAccountId, registration)
      : await updateTrustedDevice(ctx, existingDevice, registration);
  await preserveTrustedDeviceRevocationTarget(ctx, {
    deviceIdentifier: registration.deviceIdentifier,
    productAccountId,
    trustedDeviceId: result.trustedDeviceId,
  });
  return result;
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

// A removed device's pending or approved enrollment can no longer be collected.
async function deleteTrustedDeviceEnrollmentRequests(
  ctx: MutationCtx,
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<void> {
  const requests = await ctx.db
    .query('productSyncEnrollmentRequests')
    .withIndex('by_trustedDeviceId', (q) =>
      q.eq('trustedDeviceId', trustedDeviceId),
    )
    .take(enrollmentRequestCleanupLimit);
  for (const request of requests) {
    await ctx.db.delete('productSyncEnrollmentRequests', request._id);
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
  await deleteTrustedDeviceEnrollmentRequests(ctx, trustedDeviceId);
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
    productSyncPendingRecoveryWrappedAccountKey: undefined,
  });
}

export const connect = mutation({
  args: {
    deviceIdentifier: v.string(),
    deviceName: v.optional(v.string()),
    expectedProductAccountId: v.optional(v.id('productAccounts')),
    platform: v.string(),
    supportsDeviceCredentials: v.optional(v.boolean()),
    trustedDeviceCredential: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
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
    const { deviceRegistered, trustedDeviceId } = await upsertTrustedDevice(
      ctx,
      productAccountId,
      {
        deviceIdentifier: args.deviceIdentifier,
        deviceName: args.deviceName,
        now,
        platform: args.platform,
        productSyncKeyEpoch:
          productAccount.productSyncKeyEpoch ?? initialProductSyncKeyEpoch,
      },
    );
    const trustedDeviceCredential =
      await preserveOrIssueTrustedDeviceCredential(ctx, {
        presentedCredential: args.trustedDeviceCredential,
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
      accountCreated,
      deviceRegistered,
      productSyncMaterialInitialized:
        productAccount.productSyncMaterialInitializedAt !== undefined,
      productAccountId,
      signInProviders: await signInProvidersForAccount(ctx, productAccount),
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
  const productAccountId = account._id;
  await requireUnchangedRecoveryMaterial(ctx, {
    expectedKeyVersion:
      account.productSyncKeyEpoch ?? initialProductSyncKeyEpoch,
    expectedUpdatedAt: args.expectedRecoveryUpdatedAt,
    productAccountId,
  });
  await ctx.db.insert('revokedTrustedDevices', {
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

export const revokeTrustedDevice = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    encryptedTransition: encryptedProductSyncPayloadBodyValidator,
    expectedRecoveryUpdatedAt: v.number(),
    recoveryWrappedAccountKey: encryptedProductSyncPayloadBodyValidator,
    trustedDeviceId: v.id('trustedDevices'),
    trustedDeviceToRevokeId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    await requireRecentAuthentication(ctx);
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
    if (
      account.legacyTrustedDeviceIdentifierMigrationCompletedAt === undefined
    ) {
      throw new Error('Trusted Device identifier migration required');
    }

    const target = await findTrustedDeviceRevocationTarget(ctx, {
      productAccountId,
      trustedDeviceId: args.trustedDeviceToRevokeId,
    });
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
    const identifierHistory = await ctx.db
      .query('trustedDeviceIdentifierHistory')
      .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('deviceIdentifier', device.deviceIdentifier),
      )
      .unique();
    if (identifierHistory === null) {
      await ctx.db.insert('trustedDeviceIdentifierHistory', {
        deviceIdentifier: device.deviceIdentifier,
        firstRegisteredAt: device.registeredAt,
        productAccountId: account.productAccountId,
      });
    }
    await preserveTrustedDeviceRevocationTarget(ctx, {
      deviceIdentifier: device.deviceIdentifier,
      productAccountId: account.productAccountId,
      trustedDeviceId: args.trustedDeviceId,
    });
    await deleteTrustedDeviceAndRoutes(
      ctx,
      account.productAccountId,
      args.trustedDeviceId,
    );
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
          trustedDeviceId: args.trustedDeviceId,
        });
      }
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
