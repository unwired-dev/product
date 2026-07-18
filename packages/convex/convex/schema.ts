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
    gmailPushProofsInvalidatedAt: v.optional(v.number()),
    pushCleanupGeneration: v.optional(v.number()),
    deviceIdentifier: v.string(),
    lastSeenAt: v.number(),
    platform: v.string(),
    productAccountId: v.id('productAccounts'),
    registeredAt: v.number(),
  })
    .index('by_productAccountId', ['productAccountId'])
    .index('by_apnsToken', ['apnsToken'])
    .index('by_apnsToken_and_lastSeenAt', ['apnsToken', 'lastSeenAt'])
    .index('by_productAccountId_and_deviceIdentifier', [
      'productAccountId',
      'deviceIdentifier',
    ]),

  devicePushRouteHeartbeats: defineTable({
    refreshedAt: v.number(),
    trustedDeviceId: v.id('trustedDevices'),
  }).index('by_trustedDeviceId', ['trustedDeviceId']),

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
    pushVerificationHistoryId: v.optional(v.string()),
    pushVerificationRequestedAt: v.optional(v.number()),
    pushVerifiedHistoryId: v.optional(v.string()),
    pushVerifiedAt: v.optional(v.number()),
    trustedDeviceId: v.id('trustedDevices'),
    updatedAt: v.number(),
  })
    .index('by_provider_and_emailAddress', ['provider', 'emailAddress'])
    .index('by_provider_and_emailAddress_and_pushVerifiedAt', [
      'provider',
      'emailAddress',
      'pushVerifiedAt',
    ])
    .index('by_provider_and_emailAddress_and_pushVerificationRequestedAt', [
      'provider',
      'emailAddress',
      'pushVerificationRequestedAt',
    ])
    .index('by_productAccountId_and_provider', ['productAccountId', 'provider'])
    .index('by_productAccountId_and_provider_and_emailAddress', [
      'productAccountId',
      'provider',
      'emailAddress',
    ])
    .index('by_productAccountId_and_provider_and_trustedDeviceId', [
      'productAccountId',
      'provider',
      'trustedDeviceId',
    ])
    .index('by_productAccountId_and_providerAccountIdentifier', [
      'productAccountId',
      'providerAccountIdentifier',
    ]),

  gmailPushVerificationSignals: defineTable({
    emailAddress: v.string(),
    historyId: v.string(),
    receivedAt: v.number(),
  })
    .index('by_emailAddress', ['emailAddress'])
    .index('by_emailAddress_and_historyId', ['emailAddress', 'historyId']),
});
