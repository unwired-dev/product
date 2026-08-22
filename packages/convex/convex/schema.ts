import { encryptedProductSyncPayloadBodyValidator } from '@private-email/contracts/productSync';
import { defineSchema, defineTable } from 'convex/server';
import { v } from 'convex/values';

export default defineSchema({
  productAccounts: defineTable({
    createdAt: v.number(),
    deviceCredentialEnforcementActivatedAt: v.optional(v.number()),
    legacyTrustedDeviceIdentifierMigrationCompletedAt: v.optional(v.number()),
    lastSeenAt: v.number(),
    productSyncKeyEpoch: v.optional(v.number()),
    productSyncMaterialInitializedAt: v.optional(v.number()),
    productSyncPendingEncryptedTransition: v.optional(
      encryptedProductSyncPayloadBodyValidator,
    ),
    productSyncPendingKeyEpoch: v.optional(v.number()),
    productSyncPendingRecoveryWrappedAccountKey: v.optional(
      encryptedProductSyncPayloadBodyValidator,
    ),
    tokenIdentifier: v.string(),
  }).index('by_tokenIdentifier', ['tokenIdentifier']),

  productAccountDeletionRequests: defineTable({
    activeAttemptId: v.optional(v.string()),
    phase: v.union(v.literal('revocation-pending'), v.literal('deleting-data')),
    productAccountId: v.id('productAccounts'),
    requestedAt: v.number(),
    requestedByTrustedDeviceId: v.id('trustedDevices'),
    revocationAttemptedAt: v.optional(v.number()),
    revocationSucceededAt: v.optional(v.number()),
    revocationMaterial: v.optional(
      v.union(
        v.object({ kind: v.literal('authorization-code'), value: v.string() }),
        v.object({ kind: v.literal('access-token'), value: v.string() }),
        v.object({ kind: v.literal('refresh-token'), value: v.string() }),
      ),
    ),
    revocationRecoveryScheduledAt: v.optional(v.number()),
    tokenIdentifier: v.string(),
    updatedAt: v.number(),
  })
    .index('by_productAccountId', ['productAccountId'])
    .index('by_tokenIdentifier', ['tokenIdentifier']),

  productAccountDeletionTombstones: defineTable({
    deletedAt: v.number(),
    productAccountId: v.id('productAccounts'),
    tokenIdentifier: v.string(),
  })
    .index('by_productAccountId', ['productAccountId'])
    .index('by_tokenIdentifier', ['tokenIdentifier']),

  trustedDevices: defineTable({
    apnsEnvironment: v.optional(
      v.union(v.literal('production'), v.literal('sandbox')),
    ),
    apnsToken: v.optional(v.string()),
    apnsTokenRegisteredAt: v.optional(v.number()),
    credentialDigest: v.optional(v.string()),
    displayName: v.optional(v.string()),
    gmailPushProofsInvalidatedAt: v.optional(v.number()),
    pushCleanupGeneration: v.optional(v.number()),
    deviceIdentifier: v.string(),
    lastSeenAt: v.number(),
    platform: v.string(),
    productAccountId: v.id('productAccounts'),
    productSyncKeyEpoch: v.optional(v.number()),
    registeredAt: v.number(),
    scheduledDeliveryAuthorizationDigest: v.optional(v.string()),
    scheduledDeliveryAuthorizationGeneration: v.optional(v.number()),
    scheduledDeliveryCapabilityVersion: v.optional(v.number()),
  })
    .index('by_productAccountId', ['productAccountId'])
    .index('by_apnsToken', ['apnsToken'])
    .index('by_apnsToken_and_apnsTokenRegisteredAt', [
      'apnsToken',
      'apnsTokenRegisteredAt',
    ])
    .index('by_apnsToken_and_lastSeenAt', ['apnsToken', 'lastSeenAt'])
    .index('by_productAccountId_and_deviceIdentifier', [
      'productAccountId',
      'deviceIdentifier',
    ]),

  trustedDeviceIdentifierHistory: defineTable({
    deviceIdentifier: v.string(),
    firstRegisteredAt: v.number(),
    productAccountId: v.id('productAccounts'),
  }).index('by_productAccountId_and_deviceIdentifier', [
    'productAccountId',
    'deviceIdentifier',
  ]),

  trustedDeviceRevocationTargets: defineTable({
    deviceIdentifier: v.string(),
    productAccountId: v.id('productAccounts'),
    trustedDeviceId: v.id('trustedDevices'),
  })
    .index('by_productAccountId', ['productAccountId'])
    .index('by_productAccountId_and_trustedDeviceId', [
      'productAccountId',
      'trustedDeviceId',
    ]),

  revokedTrustedDevices: defineTable({
    deviceIdentifier: v.string(),
    productAccountId: v.id('productAccounts'),
    productSyncKeyEpoch: v.number(),
    revokedAt: v.number(),
    trustedDeviceId: v.id('trustedDevices'),
  })
    .index('by_productAccountId', ['productAccountId'])
    .index('by_productAccountId_and_deviceIdentifier', [
      'productAccountId',
      'deviceIdentifier',
    ])
    .index('by_productAccountId_and_trustedDeviceId', [
      'productAccountId',
      'trustedDeviceId',
    ]),

  devicePushRouteHeartbeats: defineTable({
    refreshedAt: v.number(),
    trustedDeviceId: v.id('trustedDevices'),
  }).index('by_trustedDeviceId', ['trustedDeviceId']),

  scheduledSends: defineTable({
    deadlineAt: v.number(),
    dueAt: v.number(),
    encryptedPayloadIdentifier: v.string(),
    encryptedPayloadUpdatedAt: v.number(),
    claimAuthorizationGeneration: v.optional(v.number()),
    claimExpiresAt: v.optional(v.number()),
    claimGeneration: v.optional(v.number()),
    claimOwnerTrustedDeviceId: v.optional(v.id('trustedDevices')),
    claimPhase: v.optional(
      v.union(v.literal('pre-handoff'), v.literal('handing-off')),
    ),
    claimUpdatedAt: v.optional(v.number()),
    productAccountId: v.id('productAccounts'),
    revision: v.number(),
    scheduleId: v.string(),
    scheduledFunctionId: v.optional(v.id('_scheduled_functions')),
    state: v.union(
      v.literal('active'),
      v.literal('cancelled'),
      v.literal('completed'),
      v.literal('needs-attention'),
    ),
    trustedDeviceId: v.id('trustedDevices'),
    updatedAt: v.number(),
    wakeAttemptedAt: v.optional(v.number()),
  })
    .index('by_productAccountId_and_scheduleId', [
      'productAccountId',
      'scheduleId',
    ])
    .index('by_trustedDeviceId_and_state_and_dueAt', [
      'trustedDeviceId',
      'state',
      'dueAt',
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
    emailAddress: v.optional(v.string()),
    gmailPreviousRoutingDigest: v.optional(v.string()),
    gmailRoutingDigest: v.optional(v.string()),
    gmailRoutingKeyVersion: v.optional(v.number()),
    lastVerifiedAt: v.number(),
    microsoftClientStateDigest: v.optional(v.string()),
    microsoftPendingClientStateDigest: v.optional(v.string()),
    microsoftSubscriptionExpiresAt: v.optional(v.number()),
    microsoftSubscriptionId: v.optional(v.string()),
    opaqueConnectionId: v.optional(v.string()),
    productAccountId: v.id('productAccounts'),
    provider: v.union(v.literal('gmail'), v.literal('microsoft-graph')),
    providerAccountIdentifier: v.optional(v.string()),
    pushVerificationHistoryId: v.optional(v.string()),
    pushVerificationOwnershipVerifiedAt: v.optional(v.number()),
    pushVerificationRequestedAt: v.optional(v.number()),
    pushOwnershipVerifiedAt: v.optional(v.number()),
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
    .index('by_provider_email_gmailDigest_pushVerifiedAt', [
      'provider',
      'emailAddress',
      'gmailRoutingDigest',
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
    .index('by_productId_provider_deviceId_providerAccountId', [
      'productAccountId',
      'provider',
      'trustedDeviceId',
      'providerAccountIdentifier',
    ])
    .index('by_productAccountId_and_providerAccountIdentifier', [
      'productAccountId',
      'providerAccountIdentifier',
    ])
    .index('by_productId_provider_deviceId_connectionId', [
      'productAccountId',
      'provider',
      'trustedDeviceId',
      'opaqueConnectionId',
    ])
    .index('by_productAccountId_and_provider_and_opaqueConnectionId', [
      'productAccountId',
      'provider',
      'opaqueConnectionId',
    ])
    .index('by_gmailRoutingDigest_and_pushVerifiedAt', [
      'gmailRoutingDigest',
      'pushVerifiedAt',
    ])
    .index('by_gmailRoutingDigest_and_pushVerificationRequestedAt', [
      'gmailRoutingDigest',
      'pushVerificationRequestedAt',
    ])
    .index('by_gmailRoutingDigest', ['gmailRoutingDigest'])
    .index('by_gmailPreviousRoutingDigest_and_pushVerifiedAt', [
      'gmailPreviousRoutingDigest',
      'pushVerifiedAt',
    ]),

  microsoftGraphWakeupStates: defineTable({
    attemptCount: v.optional(v.number()),
    clientStateDigest: v.optional(v.string()),
    pendingAt: v.optional(v.number()),
    routeId: v.id('mailProviderConnections'),
    scheduledAt: v.number(),
    subscriptionId: v.optional(v.string()),
  }).index('by_routeId', ['routeId']),

  gmailOpaqueIdentityBindings: defineTable({
    identityBindingDigest: v.string(),
    opaqueConnectionId: v.string(),
    productAccountId: v.id('productAccounts'),
    updatedAt: v.number(),
  }).index('by_productAccountId_and_opaqueConnectionId', [
    'productAccountId',
    'opaqueConnectionId',
  ]),

  gmailPushVerificationSignals: defineTable({
    emailAddress: v.optional(v.string()),
    historyId: v.string(),
    receivedAt: v.number(),
    routingDigest: v.optional(v.string()),
  })
    .index('by_emailAddress', ['emailAddress'])
    .index('by_emailAddress_and_historyId', ['emailAddress', 'historyId'])
    .index('by_routingDigest', ['routingDigest'])
    .index('by_routingDigest_and_historyId', ['routingDigest', 'historyId']),
});
