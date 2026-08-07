import type { EncryptedProductSyncPayload } from '@private-email/contracts/productSync';

import {
  encryptedProductSyncPayloadBodyValidator,
  encryptedProductSyncPayloadListResponseValidator,
  encryptedProductSyncPayloadValidator,
  maybeEncryptedProductSyncPayloadValidator,
} from '@private-email/contracts/productSync';
import { paginationOptsValidator } from 'convex/server';
import { v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx, QueryCtx } from './_generated/server.js';

import { internalMutation, mutation, query } from './_generated/server.js';
import {
  requireCurrentProductSyncKeyEpoch,
  requireAuthenticatedTrustedDevice,
  requireProductAccount,
  requireTrustedDevice,
} from './productAccountAuth.js';

const encryptedProductSyncPayloadPageSize = 100;
const recoveryPayloadIdentifier = 'product-account-recovery-v1';
function requireUnreservedPayloadIdentifier(payloadIdentifier: string): void {
  if (payloadIdentifier === recoveryPayloadIdentifier) {
    throw new Error('Recovery material requires recent authentication');
  }
}

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

async function preparePayloadWrite(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is generated mutable framework state.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Encrypted payloads are generated mutable contract types.
  args: Readonly<{
    encryptedPayload: EncryptedProductSyncPayload['encryptedPayload'];
    payloadIdentifier: string;
    trustedDeviceId: Doc<'encryptedProductSyncPayloads'>['trustedDeviceId'];
  }>,
): Promise<{
  existingPayload: Doc<'encryptedProductSyncPayloads'> | null;
  productAccountId: Doc<'encryptedProductSyncPayloads'>['productAccountId'];
}> {
  const account = await requireProductAccount(ctx);
  const { productAccountId } = account;
  await requireTrustedDevice(ctx, productAccountId, args.trustedDeviceId);
  requireCurrentProductSyncKeyEpoch(account, args.encryptedPayload.keyVersion);
  return {
    existingPayload: await findPayload(
      ctx,
      productAccountId,
      args.payloadIdentifier,
    ),
    productAccountId,
  };
}

async function updatePayload(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  existingPayload: Doc<'encryptedProductSyncPayloads'>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents are immutable inputs here.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Encrypted payloads are generated mutable contract types.
  args: {
    encryptedPayload: EncryptedProductSyncPayload['encryptedPayload'];
    trustedDeviceId: Doc<'encryptedProductSyncPayloads'>['trustedDeviceId'];
  },
): Promise<EncryptedProductSyncPayload> {
  const now = Math.max(Date.now(), existingPayload.updatedAt + 1);
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
}

export const putEncryptedPayloadIfUnchanged = mutation({
  args: {
    encryptedPayload: encryptedProductSyncPayloadBodyValidator,
    expectedUpdatedAt: v.optional(v.number()),
    payloadIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    requireUnreservedPayloadIdentifier(args.payloadIdentifier);
    // oxlint-disable-next-line eslint/no-use-before-define -- Shared CAS implementation is declared below the public mutations.
    return writeEncryptedPayloadIfUnchanged(ctx, args);
  },
  returns: encryptedProductSyncPayloadValidator,
});

export const replaceRecoveryMaterialIfUnchanged = internalMutation({
  args: {
    encryptedPayload: encryptedProductSyncPayloadBodyValidator,
    expectedUpdatedAt: v.optional(v.number()),
    trustedDeviceId: v.string(),
  },
  handler: async (ctx, args) => {
    const trustedDeviceId = ctx.db.normalizeId(
      'trustedDevices',
      args.trustedDeviceId,
    );
    if (trustedDeviceId === null) {
      throw new Error('Trusted device required');
    }
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      trustedDeviceId,
    );
    if (account.productSyncPendingKeyEpoch !== undefined) {
      throw new Error('Product Sync key rotation already in progress');
    }
    // oxlint-disable-next-line eslint/no-use-before-define -- Shared CAS implementation is declared below the public mutations.
    return writeEncryptedPayloadIfUnchanged(ctx, {
      ...args,
      payloadIdentifier: recoveryPayloadIdentifier,
      trustedDeviceId,
    });
  },
  returns: encryptedProductSyncPayloadValidator,
});

async function writeEncryptedPayloadIfUnchanged(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Encrypted payloads are generated mutable contract types.
  args: Readonly<{
    encryptedPayload: EncryptedProductSyncPayload['encryptedPayload'];
    expectedUpdatedAt?: number;
    payloadIdentifier: string;
    trustedDeviceId: Doc<'encryptedProductSyncPayloads'>['trustedDeviceId'];
  }>,
): Promise<EncryptedProductSyncPayload> {
  const { existingPayload, productAccountId } = await preparePayloadWrite(
    ctx,
    args,
  );
  if (existingPayload === null) {
    if (args.expectedUpdatedAt !== undefined) {
      throw new Error('Encrypted Product Sync payload changed');
    }
    return serializePayload(await insertPayload(ctx, args, productAccountId));
  }
  if (existingPayload.updatedAt !== args.expectedUpdatedAt) {
    return serializePayload(existingPayload);
  }

  return updatePayload(ctx, existingPayload, args);
}

async function listEncryptedPayloadsForProductAccount(
  ctx: QueryCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex query context is generated mutable framework state.
  args: Readonly<{
    paginationOpts?: Readonly<{ cursor: string | null; numItems: number }>;
    payloadIdentifierPrefix?: string;
  }>,
  productAccountId: Id<'productAccounts'>,
) {
  const { payloadIdentifierPrefix } = args;
  const payloadsQuery =
    payloadIdentifierPrefix === undefined
      ? ctx.db
          .query('encryptedProductSyncPayloads')
          .withIndex('by_productAccountId', (q) =>
            q.eq('productAccountId', productAccountId),
          )
      : ctx.db
          .query('encryptedProductSyncPayloads')
          .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
            q
              .eq('productAccountId', productAccountId)
              .gte('payloadIdentifier', payloadIdentifierPrefix)
              .lt('payloadIdentifier', `${payloadIdentifierPrefix}\uFFFF`),
          );
  if (args.paginationOpts === undefined) {
    const payloads = await payloadsQuery
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
  const payloads = await payloadsQuery.order('asc').paginate(paginationOpts);

  return {
    continueCursor: payloads.continueCursor,
    isDone: payloads.isDone,
    page: payloads.page.map(serializePayload),
  };
}

const encryptedPayloadListArgs = {
  paginationOpts: v.optional(paginationOptsValidator),
  payloadIdentifierPrefix: v.optional(v.string()),
};

async function requireLegacyProductSyncReadAccount(
  ctx: QueryCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex query context is generated mutable framework state.
): Promise<Id<'productAccounts'>> {
  const account = await requireProductAccount(ctx);
  const revocation = await ctx.db
    .query('revokedTrustedDevices')
    .withIndex('by_productAccountId', (q) =>
      q.eq('productAccountId', account.productAccountId),
    )
    .first();
  if (revocation !== null) {
    throw new Error('Trusted device required');
  }
  return account.productAccountId;
}

export const listEncryptedPayloads = query({
  args: encryptedPayloadListArgs,
  handler: async (ctx, args) => {
    const productAccountId = await requireLegacyProductSyncReadAccount(ctx);
    return listEncryptedPayloadsForProductAccount(ctx, args, productAccountId);
  },
  returns: encryptedProductSyncPayloadListResponseValidator,
});

export const listEncryptedPayloadsForTrustedDevice = query({
  args: {
    ...encryptedPayloadListArgs,
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const { productAccountId } = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
    );
    return listEncryptedPayloadsForProductAccount(ctx, args, productAccountId);
  },
  returns: encryptedProductSyncPayloadListResponseValidator,
});

async function getEncryptedPayloadForProductAccount(
  ctx: QueryCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex query context is generated mutable framework state.
  productAccountId: Id<'productAccounts'>,
  payloadIdentifier: string,
): Promise<EncryptedProductSyncPayload | null> {
  const payload = await ctx.db
    .query('encryptedProductSyncPayloads')
    .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
      q
        .eq('productAccountId', productAccountId)
        .eq('payloadIdentifier', payloadIdentifier),
    )
    .unique();

  return payload === null ? null : serializePayload(payload);
}

export const getEncryptedPayload = query({
  args: {
    payloadIdentifier: v.string(),
  },
  handler: async (ctx, args) => {
    const productAccountId = await requireLegacyProductSyncReadAccount(ctx);
    return getEncryptedPayloadForProductAccount(
      ctx,
      productAccountId,
      args.payloadIdentifier,
    );
  },
  returns: maybeEncryptedProductSyncPayloadValidator,
});

export const getEncryptedPayloadForTrustedDevice = query({
  args: {
    payloadIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const { productAccountId } = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
    );
    return getEncryptedPayloadForProductAccount(
      ctx,
      productAccountId,
      args.payloadIdentifier,
    );
  },
  returns: maybeEncryptedProductSyncPayloadValidator,
});

async function getEncryptedPayloadsForProductAccount(
  ctx: QueryCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex query context is generated mutable framework state.
  productAccountId: Id<'productAccounts'>,
  payloadIdentifiers: readonly string[],
): Promise<EncryptedProductSyncPayload[]> {
  const payloads = await Promise.all(
    payloadIdentifiers.map(async (payloadIdentifier) =>
      ctx.db
        .query('encryptedProductSyncPayloads')
        .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
          q
            .eq('productAccountId', productAccountId)
            .eq('payloadIdentifier', payloadIdentifier),
        )
        .unique(),
    ),
  );

  return payloads.filter((payload) => payload !== null).map(serializePayload);
}

export const getEncryptedPayloads = query({
  args: {
    payloadIdentifiers: v.array(v.string()),
  },
  handler: async (ctx, args) => {
    const productAccountId = await requireLegacyProductSyncReadAccount(ctx);
    return getEncryptedPayloadsForProductAccount(
      ctx,
      productAccountId,
      args.payloadIdentifiers,
    );
  },
  returns: v.array(encryptedProductSyncPayloadValidator),
});

export const getEncryptedPayloadsForTrustedDevice = query({
  args: {
    payloadIdentifiers: v.array(v.string()),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const { productAccountId } = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
    );
    return getEncryptedPayloadsForProductAccount(
      ctx,
      productAccountId,
      args.payloadIdentifiers,
    );
  },
  returns: v.array(encryptedProductSyncPayloadValidator),
});
