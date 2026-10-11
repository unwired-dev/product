import type {
  ProductAccountDeletionResponse,
  SignInLinkRequestResponse,
  SignInLinkResponse,
  TrustedDeviceUnregistrationResponse,
} from '@private-email/contracts/productAccount';
import type { ProductSyncEnrollmentStatus } from '@private-email/contracts/productSync';

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
