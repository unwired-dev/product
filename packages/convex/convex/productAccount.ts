import {
  gmailProviderConnectionStatusValidator,
  productAccountConnectResponseValidator,
  productSyncMaterialInitializedResponseValidator,
} from '@private-email/contracts/productAccount';
import { v } from 'convex/values';

import type { Id } from './_generated/dataModel.js';
import type { MutationCtx } from './_generated/server.js';

import { mutation, query } from './_generated/server.js';
import {
  requireProductAccount,
  requireTrustedDevice,
} from './productAccountAuth.js';

type TrustedDeviceRegistration = Readonly<{
  deviceIdentifier: string;
  now: number;
  platform: string;
}>;

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
    const account = await requireProductAccount(ctx);
    await requireTrustedDevice(
      ctx,
      account.productAccountId,
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
    const account = await requireProductAccount(ctx);
    await requireTrustedDevice(
      ctx,
      account.productAccountId,
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

    const connection = {
      emailAddress: args.emailAddress,
      lastVerifiedAt: now,
      provider: 'gmail' as const,
      providerAccountIdentifier: args.providerAccountIdentifier,
      trustedDeviceId: args.trustedDeviceId,
      updatedAt: now,
    };

    if (existingConnection === null) {
      const connectedAt = now;
      await ctx.db.insert('mailProviderConnections', {
        ...connection,
        connectedAt,
        productAccountId: account.productAccountId,
      });

      return {
        ...connection,
        connectedAt,
      };
    }

    const providerAccountChanged =
      existingConnection.providerAccountIdentifier !==
      args.providerAccountIdentifier;
    const routingIdentityChanged =
      providerAccountChanged ||
      existingConnection.emailAddress !== args.emailAddress;
    const updatedAt = routingIdentityChanged
      ? now
      : existingConnection.updatedAt;

    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.patch(existingConnection._id, {
      ...connection,
      pushVerificationHistoryId: routingIdentityChanged
        ? undefined
        : existingConnection.pushVerificationHistoryId,
      pushVerificationRequestedAt: routingIdentityChanged
        ? undefined
        : existingConnection.pushVerificationRequestedAt,
      pushVerifiedHistoryId: routingIdentityChanged
        ? undefined
        : existingConnection.pushVerifiedHistoryId,
      pushVerifiedAt: routingIdentityChanged
        ? undefined
        : existingConnection.pushVerifiedAt,
      updatedAt,
    });

    return {
      connectedAt: existingConnection.connectedAt,
      ...connection,
      updatedAt,
    };
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
