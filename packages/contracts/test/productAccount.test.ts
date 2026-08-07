import {
  gmailProviderConnectionStatusFixture,
  productAccountConnectResponseFixture,
} from '@private-email/contracts/productAccount';

describe('product account connect response contract', () => {
  it('uses the shared connect response fixture shape', () => {
    expect.assertions(1);

    expect(productAccountConnectResponseFixture).toStrictEqual({
      accountCreated: true,
      deviceRegistered: true,
      productSyncMaterialInitialized: false,
      productAccountId: 'productAccountFixtureId',
      trustedDeviceCredential: 'trustedDeviceCredentialFixture',
      trustedDeviceId: 'trustedDeviceFixtureId',
    });
  });
});

describe('gmail provider connection status contract', () => {
  it('uses backend-readable Gmail metadata without provider tokens', () => {
    expect.assertions(2);

    expect(gmailProviderConnectionStatusFixture).toStrictEqual({
      connectedAt: 1_781_200_000_000,
      emailAddress: 'user@example.com',
      lastVerifiedAt: 1_781_200_000_000,
      provider: 'gmail',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: 'trustedDeviceFixtureId',
      updatedAt: 1_781_200_000_000,
    });
    expect(JSON.stringify(gmailProviderConnectionStatusFixture)).not.toMatch(
      /accessToken|refreshToken|token/iu,
    );
  });
});
