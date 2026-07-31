import {
  gmailProviderConnectionStatusValidator,
  productAccountConnectResponseValidator,
  productSyncMaterialInitializedResponseValidator,
  trustedDeviceUnregistrationResponseValidator,
  trustedDeviceSummaryValidator,
} from '@private-email/contracts/productAccount';
import { v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx, QueryCtx } from './_generated/server.js';

import { mutation, query } from './_generated/server.js';
import { opaqueGmailConnectionId } from './gmailRouting.js';
import {
  requireAuthenticatedTrustedDevice,
  requireProductAccount,
  requireTrustedDevice,
} from './productAccountAuth.js';

const gmailConnectionLimitPerTrustedDevice = 20;
export const gmailLegacyRouteFallbackLimit = 100;
const trustedDeviceLimitPerProductAccount = 100;
const trustedDeviceNameMaximumLength = 80;

type TrustedDeviceRegistration = Readonly<{
  deviceIdentifier: string;
  deviceName: string | undefined;
  now: number;
  platform: string;
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

async function gmailConnectionsForTrustedDevice(
  ctx: MutationCtx | QueryCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex contexts are immutable inputs here.
  trustedDeviceId: Id<'trustedDevices'>,
  limit: number,
): Promise<Array<Doc<'mailProviderConnections'>>> {
  const account = await requireProductAccount(ctx);
  await requireTrustedDevice(ctx, account.productAccountId, trustedDeviceId);
  return ctx.db
    .query('mailProviderConnections')
    .withIndex('by_productAccountId_and_provider_and_trustedDeviceId', (q) =>
      q
        .eq('productAccountId', account.productAccountId)
        .eq('provider', 'gmail')
        .eq('trustedDeviceId', trustedDeviceId),
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

async function upsertProductAccount(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  tokenIdentifier: string,
  now: number,
): Promise<{
  accountCreated: boolean;
  productAccountId: Id<'productAccounts'>;
}> {
  const existingAccount = await ctx.db
    .query('productAccounts')
    .withIndex('by_tokenIdentifier', (q) =>
      q.eq('tokenIdentifier', tokenIdentifier),
    )
    .unique();

  if (existingAccount === null) {
    return {
      accountCreated: true,
      productAccountId: await ctx.db.insert('productAccounts', {
        createdAt: now,
        lastSeenAt: now,
        tokenIdentifier,
      }),
    };
  }

  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  const productAccountId = existingAccount._id;
  await ctx.db.patch(productAccountId, { lastSeenAt: now });

  return {
    accountCreated: false,
    productAccountId,
  };
}

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
  const existingDevice = await ctx.db
    .query('trustedDevices')
    .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('deviceIdentifier', registration.deviceIdentifier),
    )
    .unique();

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
  const opaqueConnectionIds = new Set(
    connections.flatMap((connection) =>
      connection.opaqueConnectionId === undefined
        ? []
        : [connection.opaqueConnectionId],
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

export const connect = mutation({
  args: {
    deviceIdentifier: v.string(),
    deviceName: v.optional(v.string()),
    platform: v.string(),
  },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error('Authentication required');
    }

    const now = Date.now();
    const { accountCreated, productAccountId } = await upsertProductAccount(
      ctx,
      identity.tokenIdentifier,
      now,
    );
    const { deviceRegistered, trustedDeviceId } = await upsertTrustedDevice(
      ctx,
      productAccountId,
      {
        deviceIdentifier: args.deviceIdentifier,
        deviceName: args.deviceName,
        now,
        platform: args.platform,
      },
    );
    const productAccount = await ctx.db.get(productAccountId);

    return {
      accountCreated,
      deviceRegistered,
      productSyncMaterialInitialized:
        productAccount?.productSyncMaterialInitializedAt !== undefined,
      productAccountId,
      trustedDeviceId,
    };
  },
  returns: productAccountConnectResponseValidator,
});

export const listTrustedDevices = query({
  args: {
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
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
    displayName: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
    trustedDeviceToRenameId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
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

export const unregisterTrustedDevice = mutation({
  args: {
    deviceIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireProductAccount(ctx);
    const device = await ctx.db.get(args.trustedDeviceId);
    if (device === null) {
      return { registered: false };
    }
    if (device.productAccountId !== account.productAccountId) {
      throw new Error('Trusted device required');
    }
    if (device.deviceIdentifier !== args.deviceIdentifier) {
      throw new Error('Current trusted device required');
    }
    await deleteGmailConnectionsForTrustedDevice(
      ctx,
      account.productAccountId,
      args.trustedDeviceId,
    );
    await deleteTrustedDeviceHeartbeat(ctx, args.trustedDeviceId);
    await ctx.db.delete(args.trustedDeviceId);
    return { registered: false };
  },
  returns: trustedDeviceUnregistrationResponseValidator,
});

export const markProductSyncMaterialInitialized = mutation({
  args: {
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
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
    emailAddress: v.string(),
    providerAccountIdentifier: v.string(),
    supportsMultipleConnections: v.optional(v.boolean()),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
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
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const connections = await gmailConnectionsForTrustedDevice(
      ctx,
      args.trustedDeviceId,
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
    providerAccountIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
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
