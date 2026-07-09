import { productAccountConnectResponseFixture } from '@private-email/contracts/productAccount';

describe('product account connect response contract', () => {
  it('uses the shared connect response fixture shape', () => {
    expect.assertions(1);

    expect(productAccountConnectResponseFixture).toStrictEqual({
      accountCreated: true,
      deviceRegistered: true,
      productSyncMaterialInitialized: false,
      productAccountId: 'productAccountFixtureId',
      trustedDeviceId: 'trustedDeviceFixtureId',
    });
  });
});
