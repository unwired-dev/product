import type { Infer } from 'convex/values';

import { v } from 'convex/values';

export const productAccountConnectResponseValidator = v.object({
  accountCreated: v.boolean(),
  deviceRegistered: v.boolean(),
  productSyncMaterialInitialized: v.boolean(),
  productAccountId: v.string(),
  trustedDeviceId: v.string(),
});

export type ProductAccountConnectResponse = Infer<
  typeof productAccountConnectResponseValidator
>;

export const productAccountConnectResponseFixture: ProductAccountConnectResponse =
  {
    accountCreated: true,
    deviceRegistered: true,
    productSyncMaterialInitialized: false,
    productAccountId: 'productAccountFixtureId',
    trustedDeviceId: 'trustedDeviceFixtureId',
  };

export const productSyncMaterialInitializedResponseValidator = v.object({
  productSyncMaterialInitialized: v.boolean(),
});

export type ProductSyncMaterialInitializedResponse = Infer<
  typeof productSyncMaterialInitializedResponseValidator
>;
