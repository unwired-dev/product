import {
  productAccountConnectResponseValidator,
  productSyncMaterialInitializedResponseValidator,
} from '@private-email/contracts/productAccount';
import { v } from 'convex/values';

import type { Id } from './_generated/dataModel.js';
import type { MutationCtx } from './_generated/server.js';

import { mutation } from './_generated/server.js';
import { requireAuthenticatedTrustedDevice } from './productAccountAuth.js';

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
