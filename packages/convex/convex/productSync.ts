import type { EncryptedProductSyncPayload } from '@private-email/contracts/productSync';

import {
  encryptedProductSyncPayloadBodyValidator,
  encryptedProductSyncPayloadListResponseValidator,
  encryptedProductSyncPayloadValidator,
} from '@private-email/contracts/productSync';
import { paginationOptsValidator } from 'convex/server';
import { v } from 'convex/values';

import type { Doc } from './_generated/dataModel.js';

import { mutation, query } from './_generated/server.js';
import {
  requireProductAccount,
  requireTrustedDevice,
} from './productAccountAuth.js';

const encryptedProductSyncPayloadPageSize = 100;

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
  args: {
    paginationOpts: v.optional(paginationOptsValidator),
  },
  handler: async (ctx, args) => {
    const { productAccountId } = await requireProductAccount(ctx);
    if (args.paginationOpts === undefined) {
      const payloads = await ctx.db
        .query('encryptedProductSyncPayloads')
        .withIndex('by_productAccountId', (q) =>
          q.eq('productAccountId', productAccountId),
        )
        .order('asc')
        .take(encryptedProductSyncPayloadPageSize);

      return payloads.map(serializePayload);
    }

    const paginationOpts = {
      cursor: args.paginationOpts.cursor,
      numItems: Math.min(
        Math.max(args.paginationOpts.numItems, 1),
        encryptedProductSyncPayloadPageSize,
      ),
    };
    const payloads = await ctx.db
      .query('encryptedProductSyncPayloads')
      .withIndex('by_productAccountId', (q) =>
        q.eq('productAccountId', productAccountId),
      )
      .order('asc')
      .paginate(paginationOpts);

    return {
      continueCursor: payloads.continueCursor,
      isDone: payloads.isDone,
      page: payloads.page.map(serializePayload),
    };
  },
  returns: encryptedProductSyncPayloadListResponseValidator,
});
