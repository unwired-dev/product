import type { EncryptedProductSyncPayload } from '@private-email/contracts/productSync';

import {
  encryptedProductSyncPayloadBodyValidator,
  encryptedProductSyncPayloadListResponseValidator,
  encryptedProductSyncPayloadValidator,
  maybeEncryptedProductSyncPayloadValidator,
} from '@private-email/contracts/productSync';
import { paginationOptsValidator } from 'convex/server';
import { v } from 'convex/values';

import type { Doc } from './_generated/dataModel.js';
import type { MutationCtx } from './_generated/server.js';

import { mutation, query } from './_generated/server.js';
import {
  requireProductAccount,
  requireTrustedDevice,
} from './productAccountAuth.js';

const encryptedProductSyncPayloadPageSize = 100;

function serializePayload(
  payload: Readonly<Doc<'encryptedProductSyncPayloads'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents contain generated mutable fields.
): EncryptedProductSyncPayload {
  return {
    encryptedPayload: payload.encryptedPayload,
    payloadIdentifier: payload.payloadIdentifier,
    updatedAt: payload.updatedAt,
  };
}

async function findPayload(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is generated mutable framework state.
  productAccountId: Doc<'encryptedProductSyncPayloads'>['productAccountId'],
  payloadIdentifier: string,
) {
  return ctx.db
    .query('encryptedProductSyncPayloads')
    .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('payloadIdentifier', payloadIdentifier),
    )
    .unique();
}

async function insertPayload(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is generated mutable framework state.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Encrypted payloads are generated mutable contract types.
  args: {
    encryptedPayload: EncryptedProductSyncPayload['encryptedPayload'];
    payloadIdentifier: string;
    trustedDeviceId: Doc<'encryptedProductSyncPayloads'>['trustedDeviceId'];
  },
  productAccountId: Doc<'encryptedProductSyncPayloads'>['productAccountId'],
): Promise<Doc<'encryptedProductSyncPayloads'>> {
  const now = Date.now();
  const payloadId = await ctx.db.insert('encryptedProductSyncPayloads', {
    encryptedPayload: args.encryptedPayload,
    payloadIdentifier: args.payloadIdentifier,
    productAccountId,
    trustedDeviceId: args.trustedDeviceId,
    updatedAt: now,
    writtenAt: now,
  });
  const payload = await ctx.db.get(payloadId);
  if (payload === null) {
    throw new Error('Encrypted Product Sync payload was not stored');
  }
  return payload;
}

async function writePayload(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is generated mutable framework state.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Encrypted payloads are generated mutable contract types.
  args: {
    encryptedPayload: EncryptedProductSyncPayload['encryptedPayload'];
    payloadIdentifier: string;
    trustedDeviceId: Doc<'encryptedProductSyncPayloads'>['trustedDeviceId'];
  },
  onExisting: (
    payload: Readonly<Doc<'encryptedProductSyncPayloads'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents contain generated mutable fields.
  ) => Promise<EncryptedProductSyncPayload>,
): Promise<EncryptedProductSyncPayload> {
  const { productAccountId } = await requireProductAccount(ctx);
  await requireTrustedDevice(ctx, productAccountId, args.trustedDeviceId);
  const existingPayload = await findPayload(
    ctx,
    productAccountId,
    args.payloadIdentifier,
  );
  if (existingPayload !== null) {
    return onExisting(existingPayload);
  }
  return serializePayload(await insertPayload(ctx, args, productAccountId));
}

export const putEncryptedPayload = mutation({
  args: {
    encryptedPayload: encryptedProductSyncPayloadBodyValidator,
    payloadIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: (ctx, args) =>
    writePayload(ctx, args, async (existingPayload) => {
      const now = Date.now();
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
    }),
  returns: encryptedProductSyncPayloadValidator,
});

export const putEncryptedPayloadIfAbsent = mutation({
  args: {
    encryptedPayload: encryptedProductSyncPayloadBodyValidator,
    payloadIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: (ctx, args) =>
    writePayload(ctx, args, async (existingPayload) =>
      serializePayload(existingPayload),
    ),
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

export const getEncryptedPayload = query({
  args: {
    payloadIdentifier: v.string(),
  },
  handler: async (ctx, args) => {
    const { productAccountId } = await requireProductAccount(ctx);
    const payload = await ctx.db
      .query('encryptedProductSyncPayloads')
      .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
        q
          .eq('productAccountId', productAccountId)
          .eq('payloadIdentifier', args.payloadIdentifier),
      )
      .unique();

    return payload === null ? null : serializePayload(payload);
  },
  returns: maybeEncryptedProductSyncPayloadValidator,
});
