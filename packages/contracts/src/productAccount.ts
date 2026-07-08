import type { Infer } from 'convex/values';

import { v } from 'convex/values';

export const productAccountConnectResponseValidator = v.object({
  accountCreated: v.boolean(),
  deviceRegistered: v.boolean(),
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
    productAccountId: 'productAccountFixtureId',
    trustedDeviceId: 'trustedDeviceFixtureId',
  };
