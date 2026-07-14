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

describe('productAccount Gmail provider connection', () => {
  it('stores Gmail connection metadata without provider tokens', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    const status = await asUser.mutation(
      api.productAccount.connectGmailProvider,
      {
        emailAddress: 'user@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );

    expect(status).toMatchObject({
      emailAddress: 'user@example.com',
      provider: 'gmail',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: connect.trustedDeviceId,
    });
    expect(JSON.stringify(status)).not.toMatch(/accessToken|refreshToken/iu);

    const loadedStatus = await asUser.query(
      api.productAccount.getGmailProviderConnection,
      { trustedDeviceId: connect.trustedDeviceId },
    );

    expect(loadedStatus).toMatchObject({
      emailAddress: 'user@example.com',
      providerAccountIdentifier: 'gmail-user-001',
    });
    expect(JSON.stringify(loadedStatus)).not.toMatch(
      /accessToken|refreshToken/iu,
    );
    expect(loadedStatus?.connectedAt).toBe(status.connectedAt);
  });

  it('requires a trusted device owned by the Product Account', async () => {
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
      asUser.mutation(api.productAccount.connectGmailProvider, {
        emailAddress: 'user@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId: otherConnect.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
  });

  it('updates the existing Gmail connection for the trusted device', async () => {
    expect.assertions(4);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    const firstStatus = await asUser.mutation(
      api.productAccount.connectGmailProvider,
      {
        emailAddress: 'user@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );
    const secondStatus = await asUser.mutation(
      api.productAccount.connectGmailProvider,
      {
        emailAddress: 'renamed@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );

    expect(secondStatus.emailAddress).toBe('renamed@example.com');
    expect(secondStatus.connectedAt).toBe(firstStatus.connectedAt);
    expect(secondStatus.lastVerifiedAt).toBeGreaterThanOrEqual(
      firstStatus.lastVerifiedAt,
    );
    expect(secondStatus.updatedAt).toBeGreaterThanOrEqual(
      firstStatus.updatedAt,
    );
  });

  it('resets Gmail connection update time when the provider account changes', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    const firstStatus = await asUser.mutation(
      api.productAccount.connectGmailProvider,
      {
        emailAddress: 'user@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );
    const secondStatus = await asUser.mutation(
      api.productAccount.connectGmailProvider,
      {
        emailAddress: 'other@example.com',
        providerAccountIdentifier: 'gmail-user-002',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );

    expect(secondStatus.connectedAt).toBe(firstStatus.connectedAt);
    expect(secondStatus.updatedAt).toBeGreaterThanOrEqual(
      firstStatus.updatedAt,
    );
  });

  it('keeps Gmail connection metadata separate per trusted device', async () => {
    expect.assertions(4);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const firstDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const secondDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });

    await asUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'first@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: firstDevice.trustedDeviceId,
    });
    await asUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'second@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: secondDevice.trustedDeviceId,
    });

    const firstStatus = await asUser.query(
      api.productAccount.getGmailProviderConnection,
      { trustedDeviceId: firstDevice.trustedDeviceId },
    );
    const secondStatus = await asUser.query(
      api.productAccount.getGmailProviderConnection,
      { trustedDeviceId: secondDevice.trustedDeviceId },
    );

    expect(firstStatus?.emailAddress).toBe('first@example.com');
    expect(firstStatus?.trustedDeviceId).toBe(firstDevice.trustedDeviceId);
    expect(secondStatus?.emailAddress).toBe('second@example.com');
    expect(secondStatus?.trustedDeviceId).toBe(secondDevice.trustedDeviceId);
  });
});
