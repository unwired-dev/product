import type { Infer } from 'convex/values';

import { v } from 'convex/values';

export const signInProviderValidator = v.union(
  v.literal('apple'),
  v.literal('google'),
);

export type SignInProvider = Infer<typeof signInProviderValidator>;

const productAccountConnectionFields = {
  accountCreated: v.boolean(),
  productSyncMaterialInitialized: v.boolean(),
  productAccountId: v.string(),
  // Every Sign-In Provider that can open this Product Account, original first.
  signInProviders: v.array(signInProviderValidator),
};

// The device that creates a Product Account, or one already admitted, is a Trusted Device. Any
// other device is a Pending Device until a Trusted Device approves it or the Recovery Key unlocks it.
export const productAccountConnectResponseValidator = v.union(
  v.object({
    ...productAccountConnectionFields,
    deviceRegistered: v.boolean(),
    trustedDeviceCredential: v.optional(v.string()),
    trustedDeviceId: v.string(),
  }),
  v.object({
    ...productAccountConnectionFields,
    pendingDeviceCredential: v.string(),
    pendingDeviceId: v.string(),
  }),
);

export type ProductAccountConnectResponse = Infer<
  typeof productAccountConnectResponseValidator
>;

export const productAccountDeletionResponseValidator = v.object({
  deleted: v.boolean(),
});

export type ProductAccountDeletionResponse = Infer<
  typeof productAccountDeletionResponseValidator
>;

export const trustedDeviceSummaryValidator = v.object({
  // Absent until setup, enrollment or the Recovery Key binds it; never replaced afterwards.
  deviceEncryptionPublicKey: v.optional(v.string()),
  displayName: v.string(),
  id: v.string(),
  lastSeenAt: v.number(),
  platform: v.string(),
  registeredAt: v.number(),
});

export type TrustedDeviceSummary = Infer<typeof trustedDeviceSummaryValidator>;

export const trustedDeviceUnregistrationResponseValidator = v.object({
  registered: v.boolean(),
});

export type TrustedDeviceUnregistrationResponse = Infer<
  typeof trustedDeviceUnregistrationResponseValidator
>;

export const signInLinkRequestResponseValidator = v.object({
  // Absent when the requested Sign-In Provider is already linked.
  linkTicket: v.optional(v.string()),
  signInProviders: v.array(signInProviderValidator),
});

export type SignInLinkRequestResponse = Infer<
  typeof signInLinkRequestResponseValidator
>;

export const signInLinkResponseValidator = v.object({
  productAccountId: v.string(),
  signInProviders: v.array(signInProviderValidator),
});

export type SignInLinkResponse = Infer<typeof signInLinkResponseValidator>;

export const productSyncMaterialInitializedResponseValidator = v.object({
  productSyncMaterialInitialized: v.boolean(),
});

export type ProductSyncMaterialInitializedResponse = Infer<
  typeof productSyncMaterialInitializedResponseValidator
>;

// Legacy: the Swift prototype's backend-readable Gmail connection, mailbox address included. No
// replacement client reads it; it is removed with the prototype at cutover (#627).
export const gmailProviderConnectionStatusValidator = v.object({
  connectedAt: v.number(),
  emailAddress: v.string(),
  lastVerifiedAt: v.number(),
  provider: v.literal('gmail'),
  providerAccountIdentifier: v.string(),
  trustedDeviceId: v.string(),
  updatedAt: v.number(),
});

export type GmailProviderConnectionStatus = Infer<
  typeof gmailProviderConnectionStatusValidator
>;
