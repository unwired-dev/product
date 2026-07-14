import {
  gmailProviderConnectionStatusValidator,
  productAccountConnectResponseValidator,
  productSyncMaterialInitializedResponseValidator,
} from '@private-email/contracts/productAccount';
import { v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx } from './_generated/server.js';

import { mutation, query } from './_generated/server.js';
import {
  requireAuthenticatedTrustedDevice,
  requireProductAccount,
  requireTrustedDevice,
} from './productAccountAuth.js';

type TrustedDeviceRegistration = Readonly<{
  deviceIdentifier: string;
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

async function createGmailConnection(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  productAccountId: Id<'productAccounts'>,
  connection: GmailConnectionDetails, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Connection details are treated as immutable input.
): Promise<{ connectedAt: number } & GmailConnectionDetails> {
  await ctx.db.insert('mailProviderConnections', {
    ...connection,
    connectedAt: connection.updatedAt,
    productAccountId,
  });
  return {
    connectedAt: connection.updatedAt,
    ...connection,
  };
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

function gmailPushProofPatch(
  existingConnection: Doc<'mailProviderConnections'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  routingIdentityChanged: boolean,
) {
  if (routingIdentityChanged) {
    return {
      pushVerificationHistoryId: undefined,
      pushVerificationRequestedAt: undefined,
      pushVerifiedHistoryId: undefined,
      pushVerifiedAt: undefined,
    };
  }
  return {
    pushVerificationHistoryId: existingConnection.pushVerificationHistoryId,
    pushVerificationRequestedAt: existingConnection.pushVerificationRequestedAt,
    pushVerifiedHistoryId: existingConnection.pushVerifiedHistoryId,
    pushVerifiedAt: existingConnection.pushVerifiedAt,
  };
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
  const updatedAt = routingIdentityChanged
    ? connection.updatedAt
    : existingConnection.updatedAt;
  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  await ctx.db.patch(existingConnection._id, {
    ...connection,
    ...gmailPushProofPatch(existingConnection, routingIdentityChanged),
    updatedAt,
  });
  return {
    connectedAt: existingConnection.connectedAt,
    ...connection,
    updatedAt,
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
    return {
      deviceRegistered: true,
      trustedDeviceId: await ctx.db.insert('trustedDevices', {
        deviceIdentifier: registration.deviceIdentifier,
        lastSeenAt: registration.now,
        platform: registration.platform,
        productAccountId,
        registeredAt: registration.now,
      }),
    };
  }

  // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
  const trustedDeviceId = existingDevice._id;
  await ctx.db.patch(trustedDeviceId, { lastSeenAt: registration.now });

  return {
    deviceRegistered: false,
    trustedDeviceId,
  };
}

export const connect = mutation({
  args: {
    deviceIdentifier: v.string(),
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

export const connectGmailProvider = mutation({
  args: {
    emailAddress: v.string(),
    providerAccountIdentifier: v.string(),
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
      .withIndex('by_productAccountId_and_provider_and_trustedDeviceId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('provider', 'gmail')
          .eq('trustedDeviceId', args.trustedDeviceId),
      )
      .unique();

    const connection = gmailConnectionDetails(args, now);

    if (existingConnection === null) {
      return createGmailConnection(ctx, account.productAccountId, connection);
    }
    return updateGmailConnection(ctx, existingConnection, connection);
  },
  returns: gmailProviderConnectionStatusValidator,
});

export const getGmailProviderConnection = query({
  args: {
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireProductAccount(ctx);
    await requireTrustedDevice(
      ctx,
      account.productAccountId,
      args.trustedDeviceId,
    );
    const connection = await ctx.db
      .query('mailProviderConnections')
      .withIndex('by_productAccountId_and_provider_and_trustedDeviceId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('provider', 'gmail')
          .eq('trustedDeviceId', args.trustedDeviceId),
      )
      .unique();

    return connection === null
      ? null
      : {
          connectedAt: connection.connectedAt,
          emailAddress: connection.emailAddress,
          lastVerifiedAt: connection.lastVerifiedAt,
          provider: connection.provider,
          providerAccountIdentifier: connection.providerAccountIdentifier,
          trustedDeviceId: connection.trustedDeviceId,
          updatedAt: connection.updatedAt,
        };
  },
  returns: v.union(v.null(), gmailProviderConnectionStatusValidator),
});
