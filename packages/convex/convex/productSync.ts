import type { EncryptedProductSyncPayload } from '@private-email/contracts/productSync';

import {
  encryptedProductSyncPayloadBodyValidator,
  encryptedProductSyncPayloadValidator,
} from '@private-email/contracts/productSync';
import { v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx, QueryCtx } from './_generated/server.js';

import { mutation, query } from './_generated/server.js';

type AuthenticatedProductAccount = Readonly<{
  productAccountId: Id<'productAccounts'>;
}>;

async function requireProductAccount(
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
  };
}

async function requireTrustedDevice(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  productAccountId: Id<'productAccounts'>,
  trustedDeviceId: Id<'trustedDevices'>,
): Promise<void> {
  const trustedDevice = await ctx.db.get(trustedDeviceId);
  if (
    trustedDevice === null ||
    trustedDevice.productAccountId !== productAccountId
  ) {
    throw new Error('Trusted device required');
  }
}

function serializePayload(
  payload: Doc<'encryptedProductSyncPayloads'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are generated mutable framework types.
): EncryptedProductSyncPayload {
  return {
    encryptedPayload: payload.encryptedPayload,
    payloadIdentifier: payload.payloadIdentifier,
    updatedAt: payload.updatedAt,
  };
}

export const putEncryptedPayload = mutation({
  args: {
    encryptedPayload: encryptedProductSyncPayloadBodyValidator,
    payloadIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const { productAccountId } = await requireProductAccount(ctx);
    await requireTrustedDevice(ctx, productAccountId, args.trustedDeviceId);

    const now = Date.now();
    const existingPayload = await ctx.db
      .query('encryptedProductSyncPayloads')
      .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
        q
          .eq('productAccountId', productAccountId)
          .eq('payloadIdentifier', args.payloadIdentifier),
      )
      .unique();

    if (existingPayload === null) {
      const payloadId = await ctx.db.insert('encryptedProductSyncPayloads', {
        encryptedPayload: args.encryptedPayload,
        payloadIdentifier: args.payloadIdentifier,
        productAccountId,
        trustedDeviceId: args.trustedDeviceId,
        updatedAt: now,
        writtenAt: now,
      });
      const insertedPayload = await ctx.db.get(payloadId);
      if (insertedPayload === null) {
        throw new Error('Encrypted Product Sync payload was not stored');
      }
      return serializePayload(insertedPayload);
    }

    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.patch(existingPayload._id, {
      encryptedPayload: args.encryptedPayload,
      trustedDeviceId: args.trustedDeviceId,
      updatedAt: now,
      writtenAt: now,
    });

    return serializePayload({
      ...existingPayload,
      encryptedPayload: args.encryptedPayload,
      trustedDeviceId: args.trustedDeviceId,
      updatedAt: now,
      writtenAt: now,
    });
  },
  returns: encryptedProductSyncPayloadValidator,
});

export const listEncryptedPayloads = query({
  args: {},
  handler: async (ctx) => {
    const { productAccountId } = await requireProductAccount(ctx);
    const payloads = await ctx.db
      .query('encryptedProductSyncPayloads')
      .withIndex('by_productAccountId', (q) =>
        q.eq('productAccountId', productAccountId),
      )
      .order('asc')
      .take(100);

    return payloads.map(serializePayload);
  },
  returns: v.array(encryptedProductSyncPayloadValidator),
});
