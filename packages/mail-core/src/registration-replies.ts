import type {
  ProductAccountDeletionResponse,
  SignInLinkRequestResponse,
  SignInLinkResponse,
  TrustedDeviceSummary as TrustedDeviceSummaryResponse,
  TrustedDeviceUnregistrationResponse,
} from '@private-email/contracts/productAccount';
import type {
  EncryptedProductSyncPayload,
  EncryptedProductSyncPayloadBody,
  EncryptedProductSyncPayloadPage,
  ProductSyncEnrollmentPendingRequest,
  ProductSyncEnrollmentStatus,
  ProductSyncInitializationResponse,
  ProductSyncKeyEnvelope,
  ProductSyncKeyRotationProposal,
} from '@private-email/contracts/productSync';

import * as Schema from 'effect/Schema';

const Provider = Schema.Literals(['google', 'apple']);
// These boundary schemas must remain assignable to the shared Convex validators' inferred types.
export const LinkRequest = Schema.Struct({
  linkTicket: Schema.optionalKey(Schema.String),
  signInProviders: Schema.mutable(Schema.Array(Provider)),
}) satisfies Schema.Codec<SignInLinkRequestResponse>;
export const LinkResponse = Schema.Struct({
  productAccountId: Schema.String,
  signInProviders: Schema.mutable(Schema.Array(Provider)),
}) satisfies Schema.Codec<SignInLinkResponse>;
export const Unregistration = Schema.Struct({
  registered: Schema.Boolean,
}) satisfies Schema.Codec<TrustedDeviceUnregistrationResponse>;
export const Deletion = Schema.Struct({
  deleted: Schema.Boolean,
}) satisfies Schema.Codec<ProductAccountDeletionResponse>;
export const EnrollmentStatus = Schema.Struct({
  approval: Schema.optionalKey(
    Schema.Struct({
      ciphertextBase64: Schema.String,
      encapsulatedKeyBase64: Schema.String,
      keyVersion: Schema.Finite,
    }),
  ),
  expiresAt: Schema.optionalKey(Schema.Finite),
  state: Schema.Literals(['pending', 'approved', 'cancelled', 'expired']),
}) satisfies Schema.Codec<ProductSyncEnrollmentStatus>;
export const EncryptedPayload = Schema.Struct({
  algorithm: Schema.Literal('AES-GCM-256'),
  ciphertextBase64: Schema.String,
  keyVersion: Schema.Finite,
  nonceBase64: Schema.String,
  schemaVersion: Schema.Finite,
  tagBase64: Schema.String,
}) satisfies Schema.Codec<EncryptedProductSyncPayloadBody>;
export const StoredPayload = Schema.Struct({
  encryptedPayload: EncryptedPayload,
  payloadIdentifier: Schema.String,
  updatedAt: Schema.Finite,
}) satisfies Schema.Codec<EncryptedProductSyncPayload>;
export const StoredPayloadPage = Schema.Struct({
  continueCursor: Schema.String,
  isDone: Schema.Boolean,
  page: Schema.mutable(Schema.Array(StoredPayload)),
}) satisfies Schema.Codec<EncryptedProductSyncPayloadPage>;
export const Initialization = Schema.Struct({
  initialized: Schema.Boolean,
}) satisfies Schema.Codec<ProductSyncInitializationResponse>;
export const EnrollmentRequested = Schema.Struct({
  expiresAt: Schema.Finite,
});
export const PendingEnrollment = Schema.Struct({
  createdAt: Schema.Finite,
  deviceEncryptionPublicKey: Schema.String,
  displayName: Schema.String,
  enrollmentPublicKey: Schema.String,
  expiresAt: Schema.Finite,
  pendingDeviceId: Schema.String,
  platform: Schema.String,
}) satisfies Schema.Codec<ProductSyncEnrollmentPendingRequest>;
export const Approved = Schema.Struct({ approved: Schema.Boolean });
export const Declined = Schema.Struct({ declined: Schema.Boolean });
export const TrustedDeviceSummary = Schema.Struct({
  deviceEncryptionPublicKey: Schema.optionalKey(Schema.String),
  displayName: Schema.String,
  id: Schema.String,
  lastSeenAt: Schema.Finite,
  platform: Schema.String,
  registeredAt: Schema.Finite,
}) satisfies Schema.Codec<TrustedDeviceSummaryResponse>;
export const KeyEnvelope = Schema.Struct({
  ciphertextBase64: Schema.String,
  encapsulatedKeyBase64: Schema.String,
  keyEpoch: Schema.Finite,
}) satisfies Schema.Codec<ProductSyncKeyEnvelope>;
export const KeyRotationProposal = Schema.Struct({
  keyEpoch: Schema.Finite,
  recoveryKeyCurrent: Schema.Boolean,
}) satisfies Schema.Codec<ProductSyncKeyRotationProposal>;
export const KeyRotationAcknowledgement = Schema.Struct({
  keyEpoch: Schema.Finite,
});
