import type { EncryptedProductSyncPayload } from '@private-email/contracts/productSync';

import {
  encryptedProductSyncPayloadBodyValidator,
  encryptedProductSyncPayloadListResponseValidator,
  encryptedProductSyncPayloadValidator,
  maybeEncryptedProductSyncPayloadValidator,
  productSyncInitializationResponseValidator,
  productSyncPayloadChangedErrorCode,
} from '@private-email/contracts/productSync';
import { paginationOptsValidator } from 'convex/server';
import { ConvexError, v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx, QueryCtx } from './_generated/server.js';
import type { AuthenticatedProductAccount } from './productAccountAuth.js';

import { internalMutation, mutation, query } from './_generated/server.js';
import {
  requireCurrentProductSyncKeyEpoch,
  requireAuthenticatedTrustedDevice,
  requireRecoveryVerifier,
  trustedDeviceCredentialArgs,
} from './productAccountAuth.js';

const encryptedProductSyncPayloadPageSize = 100;
const encryptedProductSyncAtomicMutationLimit = 100;
const recoveryPayloadIdentifier = 'product-account-recovery-v1';
function requireUnreservedPayloadIdentifier(payloadIdentifier: string): void {
  if (payloadIdentifier === recoveryPayloadIdentifier) {
    throw new Error('Recovery material requires recent authentication');
  }
}

function serializePayload(
  payload: Readonly<Doc<'encryptedProductSyncPayloads'>>,
): EncryptedProductSyncPayload {
  return {
    encryptedPayload: payload.encryptedPayload,
    payloadIdentifier: payload.payloadIdentifier,
    updatedAt: payload.updatedAt,
  };
}

async function findPayload(
  ctx: MutationCtx,
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

async function requireRecoveryEnvelope(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
): Promise<void> {
  if (
    (await findPayload(ctx, productAccountId, recoveryPayloadIdentifier)) ===
    null
  ) {
    throw new Error('Product Sync is not initialized');
  }
}

async function insertPayload(
  ctx: MutationCtx,
  args: {
    encryptedPayload: EncryptedProductSyncPayload['encryptedPayload'];
    payloadIdentifier: string;
    trustedDeviceCredential?: string;
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
  const payload = await ctx.db.get('encryptedProductSyncPayloads', payloadId);
  if (payload === null) {
    throw new Error('Encrypted Product Sync payload was not stored');
  }
  return payload;
}

async function preparePayloadWrite(
  ctx: MutationCtx,
  args: Readonly<{
    encryptedPayload: EncryptedProductSyncPayload['encryptedPayload'];
    payloadIdentifier: string;
    trustedDeviceCredential?: string;
    trustedDeviceId: Doc<'encryptedProductSyncPayloads'>['trustedDeviceId'];
  }>,
): Promise<{
  account: AuthenticatedProductAccount;
  existingPayload: Doc<'encryptedProductSyncPayloads'> | null;
}> {
  const account = await requireAuthenticatedTrustedDevice(
    ctx,
    args.trustedDeviceId,
    args.trustedDeviceCredential,
  );
  requireCurrentProductSyncKeyEpoch(account, args.encryptedPayload.keyVersion);
  if (args.payloadIdentifier !== recoveryPayloadIdentifier) {
    await requireRecoveryEnvelope(ctx, account.productAccountId);
  }
  return {
    account,
    existingPayload: await findPayload(
      ctx,
      account.productAccountId,
      args.payloadIdentifier,
    ),
  };
}

async function updatePayload(
  ctx: MutationCtx,
  existingPayload: Doc<'encryptedProductSyncPayloads'>,
  args: {
    encryptedPayload: EncryptedProductSyncPayload['encryptedPayload'];
    trustedDeviceId: Doc<'encryptedProductSyncPayloads'>['trustedDeviceId'];
  },
): Promise<EncryptedProductSyncPayload> {
  const now = Math.max(Date.now(), existingPayload.updatedAt + 1);
  await ctx.db.patch('encryptedProductSyncPayloads', existingPayload._id, {
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
    ...trustedDeviceCredentialArgs,
    encryptedPayload: encryptedProductSyncPayloadBodyValidator,
    expectedUpdatedAt: v.optional(v.number()),
    payloadIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    requireUnreservedPayloadIdentifier(args.payloadIdentifier);
    return writeEncryptedPayloadIfUnchanged(ctx, args);
  },
  returns: encryptedProductSyncPayloadValidator,
});

const encryptedPayloadFields = [
  'algorithm',
  'ciphertextBase64',
  'keyVersion',
  'nonceBase64',
  'schemaVersion',
  'tagBase64',
] as const;

function sameEncryptedPayload(
  stored: EncryptedProductSyncPayload['encryptedPayload'],
  presented: EncryptedProductSyncPayload['encryptedPayload'],
): boolean {
  return encryptedPayloadFields.every(
    (field) => stored[field] === presented[field],
  );
}

// Repeating the winning publication is idempotent; other material is never replaced here.
async function adoptPublishedRecoveryMaterial(
  ctx: MutationCtx,
  account: AuthenticatedProductAccount,
  material: Readonly<{
    existing: EncryptedProductSyncPayload['encryptedPayload'];
    presented: EncryptedProductSyncPayload['encryptedPayload'];
  }>,
): Promise<boolean> {
  const initialized = sameEncryptedPayload(
    material.existing,
    material.presented,
  );
  if (initialized && account.productSyncMaterialInitializedAt === undefined) {
    await ctx.db.patch('productAccounts', account.productAccountId, {
      productSyncMaterialInitializedAt: Date.now(),
    });
  }
  return initialized;
}

// Creates Product Sync key material only for an account that has never had any: the first
// recovery envelope and the initialized marker commit together, and exactly one device wins.
async function publishFirstRecoveryEnvelope(
  ctx: MutationCtx,
  account: AuthenticatedProductAccount,
  args: Readonly<{
    encryptedPayload: EncryptedProductSyncPayload['encryptedPayload'];
    recoveryVerifier: string;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<Doc<'encryptedProductSyncPayloads'> | null> {
  // Records written under keys that predate the marker also rule out new key material.
  const existingRecord = await ctx.db
    .query('encryptedProductSyncPayloads')
    .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
      q.eq('productAccountId', account.productAccountId),
    )
    .first();
  if (
    existingRecord !== null ||
    account.productSyncMaterialInitializedAt !== undefined
  ) {
    return null;
  }
  const payload = await insertPayload(
    ctx,
    { ...args, payloadIdentifier: recoveryPayloadIdentifier },
    account.productAccountId,
  );
  await ctx.db.patch('productAccounts', account.productAccountId, {
    productSyncMaterialInitializedAt: payload.writtenAt,
    productSyncRecoveryVerifier: args.recoveryVerifier,
  });
  return payload;
}

export const initialize = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    encryptedPayload: encryptedProductSyncPayloadBodyValidator,
    // Published with the first recovery envelope so the Recovery Key can admit a Pending Device.
    recoveryVerifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    requireRecoveryVerifier(args.recoveryVerifier);
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    requireCurrentProductSyncKeyEpoch(
      account,
      args.encryptedPayload.keyVersion,
    );
    const existing = await findPayload(
      ctx,
      account.productAccountId,
      recoveryPayloadIdentifier,
    );
    if (existing !== null) {
      return {
        initialized: await adoptPublishedRecoveryMaterial(ctx, account, {
          existing: existing.encryptedPayload,
          presented: args.encryptedPayload,
        }),
      };
    }
    return {
      initialized:
        (await publishFirstRecoveryEnvelope(ctx, account, args)) !== null,
    };
  },
  returns: productSyncInitializationResponseValidator,
});

const encryptedPayloadRevisionValidator = v.object({
  expectedUpdatedAt: v.number(),
  payloadIdentifier: v.string(),
});

const encryptedPayloadAtomicWriteValidator = v.object({
  encryptedPayload: encryptedProductSyncPayloadBodyValidator,
  expectedUpdatedAt: v.optional(v.number()),
  payloadIdentifier: v.string(),
});

type EncryptedPayloadRevision = Readonly<{
  expectedUpdatedAt: number;
  payloadIdentifier: string;
}>;

type EncryptedPayloadAtomicWrite = Readonly<{
  encryptedPayload: EncryptedProductSyncPayload['encryptedPayload'];
  expectedUpdatedAt?: number;
  payloadIdentifier: string;
}>;

type EncryptedPayloadAtomicMutation = Readonly<{
  checks: readonly EncryptedPayloadRevision[];
  deletes: readonly EncryptedPayloadRevision[];
  trustedDeviceCredential?: string;
  trustedDeviceId: Id<'trustedDevices'>;
  writes: readonly EncryptedPayloadAtomicWrite[];
}>;

function requireValidAtomicMutationCount(
  args: EncryptedPayloadAtomicMutation,
): void {
  const mutationCount =
    args.checks.length + args.deletes.length + args.writes.length;
  if (
    mutationCount === 0 ||
    mutationCount > encryptedProductSyncAtomicMutationLimit
  ) {
    throw new Error(
      'Encrypted Product Sync transaction has an invalid record count',
    );
  }
}

function validateAtomicPayloadIdentifiers(
  args: EncryptedPayloadAtomicMutation,
): string[] {
  requireValidAtomicMutationCount(args);
  const identifiers = [
    ...args.checks.map(({ payloadIdentifier }) => payloadIdentifier),
    ...args.deletes.map(({ payloadIdentifier }) => payloadIdentifier),
    ...args.writes.map(({ payloadIdentifier }) => payloadIdentifier),
  ];
  if (new Set(identifiers).size !== identifiers.length) {
    throw new Error(
      'Encrypted Product Sync transaction contains duplicate records',
    );
  }
  for (const payloadIdentifier of identifiers) {
    requireUnreservedPayloadIdentifier(payloadIdentifier);
  }
  return identifiers;
}

async function findAtomicPayloads(
  ctx: MutationCtx,
  productAccountId: Id<'productAccounts'>,
  identifiers: readonly string[],
): Promise<{
  existingByIdentifier: Map<string, Doc<'encryptedProductSyncPayloads'>>;
  existingPayloads: Array<Doc<'encryptedProductSyncPayloads'> | null>;
}> {
  const existingPayloads = await Promise.all(
    identifiers.map((payloadIdentifier) =>
      findPayload(ctx, productAccountId, payloadIdentifier),
    ),
  );
  return {
    existingByIdentifier: new Map(
      existingPayloads
        .filter((payload) => payload !== null)
        .map((payload) => [payload.payloadIdentifier, payload]),
    ),
    existingPayloads,
  };
}

function atomicPayloadRevisionsMatch(
  args: EncryptedPayloadAtomicMutation,
  existingByIdentifier: ReadonlyMap<
    string,
    Doc<'encryptedProductSyncPayloads'>
  >,
): boolean {
  return [...args.checks, ...args.deletes, ...args.writes].every(
    ({ expectedUpdatedAt, payloadIdentifier }) =>
      existingByIdentifier.get(payloadIdentifier)?.updatedAt ===
      expectedUpdatedAt,
  );
}

async function deleteAtomicPayloads(
  ctx: MutationCtx,
  deletions: readonly EncryptedPayloadRevision[],
  existingByIdentifier: ReadonlyMap<
    string,
    Doc<'encryptedProductSyncPayloads'>
  >,
): Promise<void> {
  for (const deletion of deletions) {
    const existing = existingByIdentifier.get(deletion.payloadIdentifier);
    if (existing === undefined) {
      throw new Error(
        'Encrypted Product Sync transaction lost a deletion target',
      );
    }
    await ctx.db.delete('encryptedProductSyncPayloads', existing._id);
  }
}

type EncryptedPayloadAtomicWriteContext = Readonly<{
  args: EncryptedPayloadAtomicMutation;
  existingByIdentifier: ReadonlyMap<
    string,
    Doc<'encryptedProductSyncPayloads'>
  >;
  productAccountId: Id<'productAccounts'>;
}>;

async function writeAtomicPayload(
  ctx: MutationCtx,
  writeContext: EncryptedPayloadAtomicWriteContext,
  write: EncryptedPayloadAtomicWrite,
): Promise<EncryptedProductSyncPayload> {
  const { args, existingByIdentifier, productAccountId } = writeContext;
  const existing = existingByIdentifier.get(write.payloadIdentifier);
  return existing === undefined
    ? serializePayload(
        await insertPayload(
          ctx,
          {
            encryptedPayload: write.encryptedPayload,
            payloadIdentifier: write.payloadIdentifier,
            trustedDeviceCredential: args.trustedDeviceCredential,
            trustedDeviceId: args.trustedDeviceId,
          },
          productAccountId,
        ),
      )
    : updatePayload(ctx, existing, {
        encryptedPayload: write.encryptedPayload,
        trustedDeviceId: args.trustedDeviceId,
      });
}

async function writeAtomicPayloads(
  ctx: MutationCtx,
  writeContext: EncryptedPayloadAtomicWriteContext,
): Promise<EncryptedProductSyncPayload[]> {
  const writtenPayloads: EncryptedProductSyncPayload[] = [];
  for (const write of writeContext.args.writes) {
    writtenPayloads.push(await writeAtomicPayload(ctx, writeContext, write));
  }
  return writtenPayloads;
}

export const putEncryptedPayloadsAtomically = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    checks: v.array(encryptedPayloadRevisionValidator),
    deletes: v.array(encryptedPayloadRevisionValidator),
    trustedDeviceId: v.id('trustedDevices'),
    writes: v.array(encryptedPayloadAtomicWriteValidator),
  },
  handler: async (ctx, args) => {
    const identifiers = validateAtomicPayloadIdentifiers(args);
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    await requireRecoveryEnvelope(ctx, account.productAccountId);
    for (const write of args.writes) {
      requireCurrentProductSyncKeyEpoch(
        account,
        write.encryptedPayload.keyVersion,
      );
    }
    const { existingByIdentifier, existingPayloads } = await findAtomicPayloads(
      ctx,
      account.productAccountId,
      identifiers,
    );
    if (!atomicPayloadRevisionsMatch(args, existingByIdentifier)) {
      return {
        committed: false,
        payloads: existingPayloads
          .filter((payload) => payload !== null)
          .map(serializePayload),
      };
    }
    await deleteAtomicPayloads(ctx, args.deletes, existingByIdentifier);
    const writtenPayloads = await writeAtomicPayloads(ctx, {
      args,
      existingByIdentifier,
      productAccountId: account.productAccountId,
    });
    return { committed: true, payloads: writtenPayloads };
  },
  returns: v.object({
    committed: v.boolean(),
    payloads: v.array(encryptedProductSyncPayloadValidator),
  }),
});

export const replaceRecoveryMaterialIfUnchanged = internalMutation({
  args: {
    ...trustedDeviceCredentialArgs,
    encryptedPayload: encryptedProductSyncPayloadBodyValidator,
    expectedUpdatedAt: v.optional(v.number()),
    recoveryVerifier: v.string(),
    trustedDeviceId: v.string(),
  },
  handler: async (ctx, args) => {
    requireRecoveryVerifier(args.recoveryVerifier);
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
      args.trustedDeviceCredential,
    );
    if (account.productSyncPendingKeyEpoch !== undefined) {
      throw new Error('Product Sync key rotation already in progress');
    }
    const payload = await writeEncryptedPayloadIfUnchanged(ctx, {
      ...args,
      payloadIdentifier: recoveryPayloadIdentifier,
      trustedDeviceId,
    });
    // The verifier follows the envelope that won; a lost compare-and-set publishes nothing.
    if (sameEncryptedPayload(payload.encryptedPayload, args.encryptedPayload)) {
      await ctx.db.patch('productAccounts', account.productAccountId, {
        productSyncRecoveryVerifier: args.recoveryVerifier,
      });
    }
    return payload;
  },
  returns: encryptedProductSyncPayloadValidator,
});

// A legacy first recovery envelope follows the same single-initialization rule as initialize.
async function insertMissingPayload(
  ctx: MutationCtx,
  account: AuthenticatedProductAccount,
  args: Readonly<{
    encryptedPayload: EncryptedProductSyncPayload['encryptedPayload'];
    payloadIdentifier: string;
    recoveryVerifier?: string;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Promise<Doc<'encryptedProductSyncPayloads'>> {
  const { recoveryVerifier } = args;
  if (args.payloadIdentifier !== recoveryPayloadIdentifier) {
    return insertPayload(ctx, args, account.productAccountId);
  }
  if (recoveryVerifier === undefined) {
    throw new Error('Recovery Key verifier is invalid');
  }
  const payload = await publishFirstRecoveryEnvelope(ctx, account, {
    ...args,
    recoveryVerifier,
  });
  if (payload === null) {
    throw new Error('Product Sync key material already exists');
  }
  return payload;
}

async function writeEncryptedPayloadIfUnchanged(
  ctx: MutationCtx,
  args: Readonly<{
    encryptedPayload: EncryptedProductSyncPayload['encryptedPayload'];
    expectedUpdatedAt?: number;
    payloadIdentifier: string;
    recoveryVerifier?: string;
    trustedDeviceCredential?: string;
    trustedDeviceId: Doc<'encryptedProductSyncPayloads'>['trustedDeviceId'];
  }>,
): Promise<EncryptedProductSyncPayload> {
  const { account, existingPayload } = await preparePayloadWrite(ctx, args);
  if (existingPayload === null) {
    if (args.expectedUpdatedAt !== undefined) {
      throw new ConvexError({ code: productSyncPayloadChangedErrorCode });
    }
    return serializePayload(await insertMissingPayload(ctx, account, args));
  }
  if (existingPayload.updatedAt !== args.expectedUpdatedAt) {
    return serializePayload(existingPayload);
  }

  return updatePayload(ctx, existingPayload, args);
}

async function listEncryptedPayloadsForProductAccount(
  ctx: QueryCtx,
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
          .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
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

export const listEncryptedPayloadsForTrustedDevice = query({
  args: {
    ...encryptedPayloadListArgs,
    ...trustedDeviceCredentialArgs,
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const { productAccountId } = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    return listEncryptedPayloadsForProductAccount(ctx, args, productAccountId);
  },
  returns: encryptedProductSyncPayloadListResponseValidator,
});

async function getEncryptedPayloadForProductAccount(
  ctx: QueryCtx,
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

export const getEncryptedPayloadForTrustedDevice = query({
  args: {
    ...trustedDeviceCredentialArgs,
    payloadIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const { productAccountId } = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
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
  ctx: QueryCtx,
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

export const getEncryptedPayloadsForTrustedDevice = query({
  args: {
    ...trustedDeviceCredentialArgs,
    payloadIdentifiers: v.array(v.string()),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const { productAccountId } = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    return getEncryptedPayloadsForProductAccount(
      ctx,
      productAccountId,
      args.payloadIdentifiers,
    );
  },
  returns: v.array(encryptedProductSyncPayloadValidator),
});
