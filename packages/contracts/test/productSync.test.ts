import { encryptedProductSyncPayloadFixture } from '@private-email/contracts/productSync';

describe('encrypted product sync payload contract', () => {
  it('uses the shared encrypted payload fixture shape', () => {
    expect.assertions(1);

    expect(encryptedProductSyncPayloadFixture).toStrictEqual({
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
    });
  });
});
