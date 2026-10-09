import type { Infer } from 'convex/values';

import { v } from 'convex/values';

// A conditional write expected a record that no longer exists; other failures are not conflicts.
export const productSyncPayloadChangedErrorCode =
  'PRODUCT_SYNC_PAYLOAD_CHANGED';

export const encryptedProductSyncPayloadBodyValidator = v.object({
  algorithm: v.literal('AES-GCM-256'),
  ciphertextBase64: v.string(),
  keyVersion: v.number(),
  nonceBase64: v.string(),
  schemaVersion: v.number(),
  tagBase64: v.string(),
});

export type EncryptedProductSyncPayloadBody = Infer<
  typeof encryptedProductSyncPayloadBodyValidator
>;

// False when the Product Account already holds other key material; the device must enroll or recover.
export const productSyncInitializationResponseValidator = v.object({
  initialized: v.boolean(),
});

export type ProductSyncInitializationResponse = Infer<
  typeof productSyncInitializationResponseValidator
>;

// A Pending Device asks a Trusted Device to seal the key ring to its one-time key.
export const productSyncEnrollmentRequestResponseValidator = v.object({
  expiresAt: v.number(),
});

export const productSyncEnrollmentPendingRequestValidator = v.object({
  createdAt: v.number(),
  displayName: v.string(),
  enrollmentPublicKey: v.string(),
  expiresAt: v.number(),
  pendingDeviceId: v.string(),
  platform: v.string(),
});

export type ProductSyncEnrollmentPendingRequest = Infer<
  typeof productSyncEnrollmentPendingRequestValidator
>;

// The HPKE-sealed key ring; the server never holds the code that authenticates it.
export const productSyncEnrollmentApprovalValidator = v.object({
  ciphertextBase64: v.string(),
  encapsulatedKeyBase64: v.string(),
  keyVersion: v.number(),
});

// A missing, foreign, superseded or declined request is indistinguishably cancelled.
export const productSyncEnrollmentStatusValidator = v.object({
  approval: v.optional(productSyncEnrollmentApprovalValidator),
  expiresAt: v.optional(v.number()),
  state: v.union(
    v.literal('pending'),
    v.literal('approved'),
    v.literal('cancelled'),
    v.literal('expired'),
  ),
});

export type ProductSyncEnrollmentStatus = Infer<
  typeof productSyncEnrollmentStatusValidator
>;

// The Pending Device becomes a Trusted Device only after it stored the keys it was authorized to
// receive; otherwise the authorization is void and it stays pending.
export const productSyncEnrollmentCompletionValidator = v.union(
  v.object({ admitted: v.literal(true), trustedDeviceId: v.string() }),
  v.object({ admitted: v.literal(false) }),
);

export const encryptedProductSyncPayloadValidator = v.object({
  encryptedPayload: encryptedProductSyncPayloadBodyValidator,
  payloadIdentifier: v.string(),
  updatedAt: v.number(),
});

export type EncryptedProductSyncPayload = Infer<
  typeof encryptedProductSyncPayloadValidator
>;

export const maybeEncryptedProductSyncPayloadValidator = v.union(
  encryptedProductSyncPayloadValidator,
  v.null(),
);

export const encryptedProductSyncPayloadPageValidator = v.object({
  continueCursor: v.string(),
  isDone: v.boolean(),
  page: v.array(encryptedProductSyncPayloadValidator),
});

export type EncryptedProductSyncPayloadPage = Infer<
  typeof encryptedProductSyncPayloadPageValidator
>;

export const encryptedProductSyncPayloadListResponseValidator = v.union(
  encryptedProductSyncPayloadPageValidator,
  v.array(encryptedProductSyncPayloadValidator),
);

export type EncryptedProductSyncPayloadListResponse = Infer<
  typeof encryptedProductSyncPayloadListResponseValidator
>;

export const encryptedProductSyncPayloadFixture: EncryptedProductSyncPayload = {
  encryptedPayload: {
    algorithm: 'AES-GCM-256',
    ciphertextBase64: 'Y2lwaGVydGV4dA',
    keyVersion: 1,
    nonceBase64: 'bm9uY2U',
    schemaVersion: 1,
    tagBase64: 'dGFn',
  },
  payloadIdentifier: 'fixture-payload-001',
  updatedAt: 1_781_200_000_000,
};

export const encryptedProductSyncPayloadPageFixture: EncryptedProductSyncPayloadPage =
  {
    continueCursor: '',
    isDone: true,
    page: [encryptedProductSyncPayloadFixture],
  };
