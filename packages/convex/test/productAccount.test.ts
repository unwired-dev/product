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

const encryptedPayload = {
  algorithm: 'AES-GCM-256' as const,
  ciphertextBase64: 'Y2lwaGVydGV4dA',
  keyVersion: 1,
  nonceBase64: 'bm9uY2U',
  schemaVersion: 1,
  tagBase64: 'dGFn',
};

describe('productAccount.connect', () => {
  it('creates a product account and registers a trusted device', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);

    const firstConnect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    expect(firstConnect).toMatchObject({
      accountCreated: true,
      deviceRegistered: true,
      productSyncMaterialInitialized: false,
    });

    const secondConnect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    expect(secondConnect).toMatchObject({
      accountCreated: false,
      deviceRegistered: false,
      productSyncMaterialInitialized: false,
    });
  });

  it('resumes the same product account for the same Apple identity', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);

    const firstConnect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    const resumedConnect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });

    expect(resumedConnect.productAccountId).toBe(firstConnect.productAccountId);
    expect(resumedConnect.deviceRegistered).toBe(true);
  });

  it('marks Product Sync material initialized for the trusted device', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    await expect(
      asUser.mutation(api.productAccount.markProductSyncMaterialInitialized, {
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({
      productSyncMaterialInitialized: true,
    });

    await expect(
      asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      }),
    ).resolves.toMatchObject({
      productSyncMaterialInitialized: true,
    });
  });

  it('rejects Product Sync material initialization from another account device', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const asOtherUser = t.withIdentity({
      issuer: 'https://appleid.apple.com',
      subject: 'apple-user-002',
      tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
    });
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
      asUser.mutation(api.productAccount.markProductSyncMaterialInitialized, {
        trustedDeviceId: otherConnect.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
  });

  it('does not treat encrypted payload presence as sync material initialization', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await asUser.mutation(api.productSync.putEncryptedPayload, {
      encryptedPayload,
      payloadIdentifier: 'payload-001',
      trustedDeviceId: connect.trustedDeviceId,
    });

    await expect(
      asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      }),
    ).resolves.toMatchObject({
      productSyncMaterialInitialized: false,
    });
  });

  it('rejects unauthenticated connect requests', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);

    await expect(
      t.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      }),
    ).rejects.toThrow('Authentication required');
  });
});
