import type { Infer } from 'convex/values';

import { v } from 'convex/values';

export const signInProviderValidator = v.union(
  v.literal('apple'),
  v.literal('google'),
);

export type SignInProvider = Infer<typeof signInProviderValidator>;

export const productAccountConnectResponseValidator = v.object({
  accountCreated: v.boolean(),
  deviceRegistered: v.boolean(),
  productSyncMaterialInitialized: v.boolean(),
  productAccountId: v.string(),
  // Every Sign-In Provider that can open this Product Account, original first.
  signInProviders: v.array(signInProviderValidator),
  trustedDeviceCredential: v.optional(v.string()),
  trustedDeviceId: v.string(),
});

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

export const productAccountConnectResponseFixture: ProductAccountConnectResponse =
  {
    accountCreated: true,
    deviceRegistered: true,
    productSyncMaterialInitialized: false,
    productAccountId: 'productAccountFixtureId',
    signInProviders: ['apple'],
    trustedDeviceCredential: 'trustedDeviceCredentialFixture',
    trustedDeviceId: 'trustedDeviceFixtureId',
  };

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

export const gmailProviderConnectionStatusFixture: GmailProviderConnectionStatus =
  {
    connectedAt: 1_781_200_000_000,
    emailAddress: 'user@example.com',
    lastVerifiedAt: 1_781_200_000_000,
    provider: 'gmail',
    providerAccountIdentifier: 'gmail-user-001',
    trustedDeviceId: 'trustedDeviceFixtureId',
    updatedAt: 1_781_200_000_000,
  };
