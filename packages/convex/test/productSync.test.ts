/// <reference types="vite/client" />

import { convexTest } from 'convex-test';

import { api } from '../convex/_generated/api.js';
import schema from '../convex/schema.js';

const modules = import.meta.glob('../convex/**/*.ts');

const appleIdentity = {
  issuer: 'https://appleid.apple.com',
  subject: 'apple-user-001',
  tokenIdentifier: 'https://appleid.apple.com|apple-user-001',
};

const otherAppleIdentity = {
  issuer: 'https://appleid.apple.com',
  subject: 'apple-user-002',
  tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
};

const encryptedPayload = {
  algorithm: 'AES-GCM-256' as const,
  ciphertextBase64: 'Y2lwaGVydGV4dA',
  keyVersion: 1,
  nonceBase64: 'bm9uY2U',
  schemaVersion: 1,
  tagBase64: 'dGFn',
};

async function connectAppleDevice() {
  const t = convexTest(schema, modules);
  const asUser = t.withIdentity(appleIdentity);
  const connect = await asUser.mutation(api.productAccount.connect, {
    deviceIdentifier: 'device-001',
    platform: 'ios',
  });

  return { asUser, connect, t };
}

describe('productSync encrypted payloads', () => {
  it('stores and returns opaque encrypted payloads for the signed-in Product Account', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();

    const stored = await asUser.mutation(api.productSync.putEncryptedPayload, {
      encryptedPayload,
      payloadIdentifier: 'payload-001',
      trustedDeviceId: connect.trustedDeviceId,
    });
    const listed = await asUser.query(api.productSync.listEncryptedPayloads);

    expect(stored).toMatchObject({
      encryptedPayload,
      payloadIdentifier: 'payload-001',
    });
    expect(listed).toStrictEqual([stored]);
  });

  it('replaces an encrypted payload by opaque payload identifier', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();

    await asUser.mutation(api.productSync.putEncryptedPayload, {
      encryptedPayload,
      payloadIdentifier: 'payload-001',
      trustedDeviceId: connect.trustedDeviceId,
    });
    const updated = await asUser.mutation(api.productSync.putEncryptedPayload, {
      encryptedPayload: {
        ...encryptedPayload,
        ciphertextBase64: 'bmV3LWNpcGhlcnRleHQ',
      },
      payloadIdentifier: 'payload-001',
      trustedDeviceId: connect.trustedDeviceId,
    });
    const listed = await asUser.query(api.productSync.listEncryptedPayloads);

    expect(listed).toHaveLength(1);
    expect(listed[0]).toStrictEqual(updated);
  });

  it('gets an encrypted payload by opaque payload identifier', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();

    const stored = await asUser.mutation(api.productSync.putEncryptedPayload, {
      encryptedPayload,
      payloadIdentifier: 'payload-001',
      trustedDeviceId: connect.trustedDeviceId,
    });
    const found = await asUser.query(api.productSync.getEncryptedPayload, {
      payloadIdentifier: 'payload-001',
    });
    const missing = await asUser.query(api.productSync.getEncryptedPayload, {
      payloadIdentifier: 'missing-payload',
    });

    expect(found).toStrictEqual(stored);
    expect(missing).toBeNull();
  });

  it('does not expose targeted encrypted payloads across Product Accounts', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const asOtherUser = t.withIdentity(otherAppleIdentity);
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await asOtherUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'ios',
    });

    await asUser.mutation(api.productSync.putEncryptedPayload, {
      encryptedPayload,
      payloadIdentifier: 'payload-001',
      trustedDeviceId: connect.trustedDeviceId,
    });

    await expect(
      asOtherUser.query(api.productSync.getEncryptedPayload, {
        payloadIdentifier: 'payload-001',
      }),
    ).resolves.toBeNull();
  });

  it('does not expose encrypted payloads across Product Accounts', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const asOtherUser = t.withIdentity(otherAppleIdentity);
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await asOtherUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'ios',
    });

    await asUser.mutation(api.productSync.putEncryptedPayload, {
      encryptedPayload,
      payloadIdentifier: 'payload-001',
      trustedDeviceId: connect.trustedDeviceId,
    });

    await expect(
      asOtherUser.query(api.productSync.listEncryptedPayloads),
    ).resolves.toStrictEqual([]);
  });

  it('rejects writes from a trusted device outside the signed-in Product Account', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const asOtherUser = t.withIdentity(otherAppleIdentity);
    const otherConnect = await asOtherUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-002',
        platform: 'ios',
      },
    );
    await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    await expect(
      asUser.mutation(api.productSync.putEncryptedPayload, {
        encryptedPayload,
        payloadIdentifier: 'payload-001',
        trustedDeviceId: otherConnect.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
  });

  it('rejects Product Sync access before the Product Account exists', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);

    await expect(
      t
        .withIdentity(appleIdentity)
        .query(api.productSync.listEncryptedPayloads),
    ).rejects.toThrow('Product Account required');
  });
});
