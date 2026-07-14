import { defineSchema, defineTable } from 'convex/server';
import { v } from 'convex/values';

export default defineSchema({
  productAccounts: defineTable({
    createdAt: v.number(),
    lastSeenAt: v.number(),
    productSyncMaterialInitializedAt: v.optional(v.number()),
    tokenIdentifier: v.string(),
  }).index('by_tokenIdentifier', ['tokenIdentifier']),

  trustedDevices: defineTable({
    apnsEnvironment: v.optional(
      v.union(v.literal('production'), v.literal('sandbox')),
    ),
    apnsToken: v.optional(v.string()),
    deviceIdentifier: v.string(),
    lastSeenAt: v.number(),
    platform: v.string(),
    productAccountId: v.id('productAccounts'),
    registeredAt: v.number(),
  })
    .index('by_productAccountId', ['productAccountId'])
    .index('by_productAccountId_and_deviceIdentifier', [
      'productAccountId',
      'deviceIdentifier',
    ]),

  encryptedProductSyncPayloads: defineTable({
    encryptedPayload: v.object({
      algorithm: v.literal('AES-GCM-256'),
      ciphertextBase64: v.string(),
      keyVersion: v.number(),
      nonceBase64: v.string(),
      schemaVersion: v.number(),
      tagBase64: v.string(),
    }),
    payloadIdentifier: v.string(),
    productAccountId: v.id('productAccounts'),
    trustedDeviceId: v.id('trustedDevices'),
    updatedAt: v.number(),
    writtenAt: v.number(),
  })
    .index('by_productAccountId', ['productAccountId'])
    .index('by_productAccountId_and_payloadIdentifier', [
      'productAccountId',
      'payloadIdentifier',
    ]),

  mailProviderConnections: defineTable({
    connectedAt: v.number(),
    emailAddress: v.string(),
    lastVerifiedAt: v.number(),
    productAccountId: v.id('productAccounts'),
    provider: v.literal('gmail'),
    providerAccountIdentifier: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
    updatedAt: v.number(),
  })
    .index('by_provider_and_emailAddress', ['provider', 'emailAddress'])
    .index('by_productAccountId_and_provider', ['productAccountId', 'provider'])
    .index('by_productAccountId_and_provider_and_trustedDeviceId', [
      'productAccountId',
      'provider',
      'trustedDeviceId',
    ])
    .index('by_productAccountId_and_providerAccountIdentifier', [
      'productAccountId',
      'providerAccountIdentifier',
    ]),
});
