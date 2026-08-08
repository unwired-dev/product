import type { EncryptedProductSyncPayload } from '@private-email/contracts/productSync';

import {
  gmailProviderConnectionStatusValidator,
  productAccountConnectResponseValidator,
  productSyncMaterialInitializedResponseValidator,
  trustedDeviceUnregistrationResponseValidator,
  trustedDeviceSummaryValidator,
} from '@private-email/contracts/productAccount';
import { encryptedProductSyncPayloadBodyValidator } from '@private-email/contracts/productSync';
import { v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx, QueryCtx } from './_generated/server.js';

import { internalMutation, mutation, query } from './_generated/server.js';
import { opaqueGmailConnectionId } from './gmailRouting.js';
import {
  initialProductSyncKeyEpoch,
  issueTrustedDeviceCredential,
  requireAuthenticatedTrustedDevice,
  requireProductAccount,
  requireRecentAuthentication,
  requireProductAccountNotDeleted,
  requireTrustedDevice,
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
  now: number;
  tokenIdentifier: string;
}>;

type TrustedDeviceCredentialConnection = Readonly<{
  presentedCredential: string | undefined;
  supportsDeviceCredentials: boolean | undefined;
  trustedDeviceId: Id<'trustedDevices'>;
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
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Connection input is immutable.
  request: TrustedDeviceCredentialConnection,
): Promise<string | undefined> {
  if (!request.supportsDeviceCredentials) {
    return undefined;
  }
  const trustedDevice = await ctx.db.get(request.trustedDeviceId);
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
  await ctx.db.patch(request.trustedDeviceId, {
    credentialDigest: await trustedDeviceCredentialDigest(credential),
  });
  return credential;
}

function trustedDeviceSummary(
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable query results.
  device: Readonly<Doc<'trustedDevices'>>,
): {
  displayName: string;
  id: string;
  lastSeenAt: number;
  platform: string;
  registeredAt: number;
} {
  return {
    displayName:
      device.displayName ?? defaultTrustedDeviceName(device.platform),
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    id: device._id,
    lastSeenAt: device.lastSeenAt,
    platform: device.platform,
    registeredAt: device.registeredAt,
  };
}

function gmailConnectionDetails(
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex ids are immutable branded strings.
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

function gmailConnectionStatus(
  connection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
) {
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
  ctx: MutationCtx | QueryCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex contexts are immutable inputs here.
  trustedDevice: GmailTrustedDeviceAuthentication, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex identifiers are branded values.
  limit: number,
): Promise<Array<Doc<'mailProviderConnections'>>> {
  const account = await requireAuthenticatedTrustedDevice(
    ctx,
    trustedDevice.id,
    trustedDevice.credential,
  );
  return ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productAccountId_and_provider_and_trustedDeviceId', (q) =>
      q
        .eq('productAccountId', account.productAccountId)
        .eq('provider', 'gmail')
        .eq('trustedDeviceId', trustedDevice.id),
    )
    .take(limit);
}

function gmailRoutingIdentityChanged(
  existingConnection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  connection: GmailConnectionDetails, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Connection details are treated as immutable input.
): boolean {
  return (
    existingConnection.providerAccountIdentifier !==
      connection.providerAccountIdentifier ||
    existingConnection.emailAddress !== connection.emailAddress
  );
}

async function updateGmailConnection(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  existingConnection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  connection: GmailConnectionDetails, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Connection details are treated as immutable input.
): Promise<{ connectedAt: number } & GmailConnectionDetails> {
  const routingIdentityChanged = gmailRoutingIdentityChanged(
    existingConnection,
    connection,
  );
  if (routingIdentityChanged) {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete(existingConnection._id);
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
  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  await ctx.db.patch(existingConnection._id, {
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
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
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
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  connection: ProductAccountConnection,
): Promise<{
  accountCreated: boolean;
  productAccountId: Id<'productAccounts'>;
}> {
  const existingAccount = await ctx.db
    .query('productAccounts')
    .withIndex('by_tokenIdentifier', (q) =>
      q.eq('tokenIdentifier', connection.tokenIdentifier),
    )
    .unique();

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

  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  const productAccountId = existingAccount._id;
  await requireDeviceWasNotRevoked(
    ctx,
    productAccountId,
    connection.deviceIdentifier,
  );
  await ctx.db.patch(productAccountId, { lastSeenAt: connection.now });

  return {
    accountCreated: false,
    productAccountId,
  };
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
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    const productAccountId = account._id;
    let migratedIdentifierCount = 0;
    for (const identifier of args.identifiers) {
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
          account.legacyTrustedDeviceIdentifierMigrationCompletedAt !==
          undefined
        ) {
          throw new Error('Trusted Device identifier migration is complete');
        }
        await ctx.db.insert('trustedDeviceIdentifierHistory', {
          ...identifier,
          productAccountId,
        });
        migratedIdentifierCount += 1;
      } else if (
        account.legacyTrustedDeviceIdentifierMigrationCompletedAt ===
          undefined &&
        identifier.firstRegisteredAt < existingHistory.firstRegisteredAt
      ) {
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        await ctx.db.patch(existingHistory._id, {
          firstRegisteredAt: identifier.firstRegisteredAt,
        });
        migratedIdentifierCount += 1;
      }
    }
    if (
      args.migrationComplete &&
      account.legacyTrustedDeviceIdentifierMigrationCompletedAt === undefined
    ) {
      await ctx.db.patch(productAccountId, {
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
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
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
    .withIndex('by_productAccountId', (q) =>
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

async function updateTrustedDevice(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  existingDevice: Doc<'trustedDevices'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  registration: TrustedDeviceRegistration,
): Promise<{
  deviceRegistered: false;
  trustedDeviceId: Id<'trustedDevices'>;
}> {
  const displayName =
    registration.deviceName === undefined
      ? undefined
      : normalizedTrustedDeviceName(registration.deviceName);
  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  const trustedDeviceId = existingDevice._id;
  await ctx.db.patch(trustedDeviceId, {
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
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
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
      .withIndex('by_productAccountId', (q) =>
        q.eq('productAccountId', productAccountId),
      )
      .first();
    if (priorRevocation !== null) {
      const account = await ctx.db.get(productAccountId);
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

  if (existingDevice === null) {
    return registerTrustedDevice(ctx, productAccountId, registration);
  }

  return updateTrustedDevice(ctx, existingDevice, registration);
}

async function deleteTrustedDeviceHeartbeat(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<void> {
  const heartbeat = await ctx.db
    .query('devicePushRouteHeartbeats')
    .withIndex('by_trustedDeviceId', (q) =>
      q.eq('trustedDeviceId', trustedDeviceId),
    )
    .unique();
  if (heartbeat !== null) {
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete(heartbeat._id);
  }
}

async function legacyGmailRouteSnapshot(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  productAccountId: Id<'productAccounts'>,
): Promise<
  Readonly<{
    complete: boolean;
    opaqueConnectionIds: ReadonlySet<string>;
  }>
> {
  const connections = await ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productAccountId_and_provider', (q) =>
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
  request: GmailIdentityBindingRouteRequest, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex ids are immutable branded strings.
): boolean {
  return (
    remainingConnectionExists ||
    !request.legacyRoutes.complete ||
    request.legacyRoutes.opaqueConnectionIds.has(request.opaqueConnectionId)
  );
}

async function deleteGmailIdentityBindingIfOrphaned(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  request: GmailIdentityBindingRouteRequest, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex ids are immutable branded strings.
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
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete(identityBinding._id);
  }
}

async function deleteOrphanedGmailIdentityBindings(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  productAccountId: Id<'productAccounts'>,
  connections: ReadonlyArray<Doc<'mailProviderConnections'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
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
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  productAccountId: Id<'productAccounts'>,
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<void> {
  const deletedConnections: Array<Doc<'mailProviderConnections'>> = [];
  for (;;) {
    const page = await ctx.db
      .query('mailProviderConnections')
      .withIndex('by_productAccountId_and_provider_and_trustedDeviceId', (q) =>
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
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.delete(connection._id);
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
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  productAccountId: Id<'productAccounts'>,
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<void> {
  for (;;) {
    const page = await ctx.db
      .query('mailProviderConnections')
      .withIndex('by_productAccountId_and_provider_and_trustedDeviceId', (q) =>
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
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        .withIndex('by_routeId', (q) => q.eq('routeId', connection._id))
        .unique();
      if (wakeupState !== null) {
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        await ctx.db.delete(wakeupState._id);
      }
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.delete(connection._id);
    }
  }
}

async function deleteTrustedDeviceAndRoutes(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
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
  await ctx.db.delete(trustedDeviceId);
}

async function pendingRotationDeviceCount(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  productAccountId: Id<'productAccounts'>,
  keyEpoch: number,
): Promise<number> {
  const devices = await ctx.db
    .query('trustedDevices')
    .withIndex('by_productAccountId', (q) =>
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
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
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
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        .eq('productAccountId', request.account._id)
        .eq('payloadIdentifier', recoveryPayloadIdentifier),
    )
    .unique();
  if (recoveryMaterial === null) {
    throw new Error('Recovery material required');
  }
  const now = Math.max(Date.now(), recoveryMaterial.updatedAt + 1);
  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  await ctx.db.patch(recoveryMaterial._id, {
    encryptedPayload:
      request.account.productSyncPendingRecoveryWrappedAccountKey,
    trustedDeviceId: request.trustedDeviceId,
    updatedAt: now,
    writtenAt: now,
  });
  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  await ctx.db.patch(request.account._id, {
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
        now,
        tokenIdentifier: identity.tokenIdentifier,
      },
    );
    const productAccount = await ctx.db.get(productAccountId);
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
      await ctx.db.patch(productAccountId, {
        deviceCredentialEnforcementActivatedAt: now,
      });
    }

    return {
      accountCreated,
      deviceRegistered,
      productSyncMaterialInitialized:
        productAccount.productSyncMaterialInitializedAt !== undefined,
      productAccountId,
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
      .withIndex('by_productAccountId', (q) =>
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
    const device = await ctx.db.get(args.trustedDeviceToRenameId);
    if (device === null) {
      throw new Error('Trusted device required');
    }
    const displayName = normalizedTrustedDeviceName(args.displayName);
    await ctx.db.patch(args.trustedDeviceToRenameId, { displayName });
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
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  account: Readonly<Doc<'productAccounts'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents contain generated mutable fields.
): Promise<ProductSyncKeyRotationResponse> {
  if (account.productSyncPendingKeyEpoch !== undefined) {
    return productSyncKeyRotationResponse(
      account.productSyncPendingKeyEpoch,
      await pendingRotationDeviceCount(
        ctx,
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
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
  target: Readonly<Doc<'trustedDevices'>>;
}>;

async function requireUnchangedRecoveryMaterial(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex ids are immutable branded strings.
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

async function revokeDuringPendingKeyRotation(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  request: PendingKeyRotationRevocation, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents contain generated mutable fields.
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
  if (
    args.recoveryWrappedAccountKey.keyVersion !== nextKeyEpoch ||
    args.recoveryWrappedAccountKey.schemaVersion !==
      recoveryWrappedAccountKeySchemaVersion
  ) {
    throw new Error('Product Sync key rotation material is invalid');
  }
  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  const productAccountId = account._id;
  await requireUnchangedRecoveryMaterial(ctx, {
    expectedKeyVersion: currentKeyEpoch,
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
  await deleteTrustedDeviceAndRoutes(
    ctx,
    productAccountId,
    args.trustedDeviceToRevokeId,
  );
  await ctx.db.patch(productAccountId, {
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
  target: Readonly<Doc<'trustedDevices'>>;
}>;

async function startProductSyncKeyRotation(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  request: NewKeyRotationRevocation, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents contain generated mutable fields.
): Promise<ProductSyncKeyRotationResponse> {
  const { account, args, target } = request;
  const currentKeyEpoch =
    account.productSyncKeyEpoch ?? initialProductSyncKeyEpoch;
  const nextKeyEpoch = currentKeyEpoch + 1;
  if (args.encryptedTransition.keyVersion !== currentKeyEpoch) {
    throw new Error('Product Sync key rotation transition is stale');
  }
  if (
    args.recoveryWrappedAccountKey.keyVersion !== nextKeyEpoch ||
    args.recoveryWrappedAccountKey.schemaVersion !==
      recoveryWrappedAccountKeySchemaVersion
  ) {
    throw new Error('Product Sync key rotation material is invalid');
  }
  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  const productAccountId = account._id;
  await requireUnchangedRecoveryMaterial(ctx, {
    expectedKeyVersion: currentKeyEpoch,
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
  await deleteTrustedDeviceAndRoutes(
    ctx,
    productAccountId,
    args.trustedDeviceToRevokeId,
  );
  await ctx.db.patch(productAccountId, {
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
    const account = await ctx.db.get(authenticatedAccount.productAccountId);
    if (account === null) {
      throw new Error('Product Account required');
    }
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
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

    const target = await ctx.db.get(args.trustedDeviceToRevokeId);
    if (
      target === null ||
      target.productAccountId !== authenticatedAccount.productAccountId
    ) {
      throw new Error('Trusted device required');
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
    const account = await ctx.db.get(authenticatedAccount.productAccountId);
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
    const account = await ctx.db.get(authenticatedAccount.productAccountId);
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
    await ctx.db.patch(args.trustedDeviceId, {
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
    const device = await ctx.db.get(args.trustedDeviceId);
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
    await deleteTrustedDeviceAndRoutes(
      ctx,
      account.productAccountId,
      args.trustedDeviceId,
    );
    const productAccount = await ctx.db.get(account.productAccountId);
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
    await ctx.db.patch(account.productAccountId, {
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
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.delete(connection._id);
    }
    const remainingConnection = await ctx.db
      .query('mailProviderConnections')
      .withIndex('by_productAccountId_and_provider_and_trustedDeviceId', (q) =>
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
