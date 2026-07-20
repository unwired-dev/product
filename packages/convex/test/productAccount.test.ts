/// <reference types="vite/client" />

import { generateKeyPairSync, sign } from 'node:crypto';

import { convexTest } from 'convex-test';

import { api } from '../convex/_generated/api.js';
import schema from '../convex/schema.js';

const modules = import.meta.glob('../convex/**/*.ts');

const appleIdentity = {
  issuer: 'https://appleid.apple.com',
  subject: 'apple-user-001',
  tokenIdentifier: 'https://appleid.apple.com|apple-user-001',
};

const {
  privateKey: googleIdentityPrivateKey,
  publicKey: googleIdentityPublicKey,
} = generateKeyPairSync('rsa', { modulusLength: 2048 });
const googleIdentitySigningKey = {
  ...googleIdentityPublicKey.export({ format: 'jwk' }),
  alg: 'RS256',
  kid: 'google-product-account-test-key',
  use: 'sig',
};

function createGoogleIdentityToken(
  emailAddress: string,
  providerAccountIdentifier: string,
): string {
  const header = Buffer.from(
    JSON.stringify({
      alg: 'RS256',
      kid: 'google-product-account-test-key',
      typ: 'JWT',
    }),
  ).toString('base64url');
  const claims = Buffer.from(
    JSON.stringify({
      aud: 'gmail-client-id',
      email: emailAddress,
      email_verified: true,
      exp: 4_102_444_800,
      iss: 'accounts.google.com',
      sub: providerAccountIdentifier,
    }),
  ).toString('base64url');
  const signingInput = `${header}.${claims}`;
  const signature = sign(
    'RSA-SHA256',
    Buffer.from(signingInput),
    googleIdentityPrivateKey,
  );
  return `${signingInput}.${signature.toString('base64url')}`;
}

const otherIdentityToken = createGoogleIdentityToken(
  'other@example.com',
  'gmail-user-002',
);
const userIdentityToken = createGoogleIdentityToken(
  'user@example.com',
  'gmail-user-001',
);

vi.stubEnv('GMAIL_OAUTH_CLIENT_ID', 'gmail-client-id');
vi.stubGlobal(
  'fetch',
  vi.fn<() => Promise<Response>>(async () =>
    Response.json(
      { keys: [googleIdentitySigningKey] },
      { headers: { 'cache-control': 'public, max-age=3600' } },
    ),
  ),
);

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

  it('keeps two Gmail connections on one trusted device without duplicating either identity', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    const firstStatus = await asUser.mutation(
      api.productAccount.connectGmailProvider,
      {
        emailAddress: 'first@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );
    await asUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'second@example.com',
      providerAccountIdentifier: 'gmail-user-002',
      trustedDeviceId: connect.trustedDeviceId,
    });
    const repairedFirstStatus = await asUser.mutation(
      api.productAccount.connectGmailProvider,
      {
        emailAddress: 'renamed-first@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );

    const connections = await asUser.query(
      api.productAccount.listGmailProviderConnections,
      { trustedDeviceId: connect.trustedDeviceId },
    );

    expect(connections).toHaveLength(2);
    expect(
      connections.map((connection) => connection.providerAccountIdentifier),
    ).toStrictEqual(['gmail-user-001', 'gmail-user-002']);
    expect(
      connections.map((connection) => connection.emailAddress),
    ).toStrictEqual(['renamed-first@example.com', 'second@example.com']);
    expect(repairedFirstStatus.connectedAt).toBe(firstStatus.connectedAt);
    expect(
      connections.filter(
        (connection) =>
          connection.providerAccountIdentifier === 'gmail-user-001',
      ),
    ).toHaveLength(1);
  });

  it('rejects a new Gmail identity when the trusted-device limit is reached', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    for (let index = 0; index < 20; index += 1) {
      await asUser.mutation(api.productAccount.connectGmailProvider, {
        emailAddress: `user-${String(index)}@example.com`,
        providerAccountIdentifier: `gmail-user-${String(index)}`,
        trustedDeviceId: connect.trustedDeviceId,
      });
    }

    await expect(
      asUser.mutation(api.productAccount.connectGmailProvider, {
        emailAddress: 'overflow@example.com',
        providerAccountIdentifier: 'gmail-user-overflow',
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).rejects.toThrow('Gmail connection limit reached');
    await expect(
      asUser.query(api.productAccount.listGmailProviderConnections, {
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).resolves.toHaveLength(20);
  });

  it('removes only the requested Gmail connection from a trusted device', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    for (const providerAccountIdentifier of [
      'gmail-user-001',
      'gmail-user-002',
    ]) {
      await asUser.mutation(api.productAccount.connectGmailProvider, {
        emailAddress: `${providerAccountIdentifier}@example.com`,
        providerAccountIdentifier,
        trustedDeviceId: connect.trustedDeviceId,
      });
    }

    await expect(
      asUser.mutation(api.productAccount.removeGmailProviderConnection, {
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ removed: true });
    await expect(
      asUser.query(api.productAccount.listGmailProviderConnections, {
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).resolves.toMatchObject([{ providerAccountIdentifier: 'gmail-user-002' }]);
  });

  it('creates another Gmail connection when the provider account changes', async () => {
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

    expect(secondStatus.providerAccountIdentifier).not.toBe(
      firstStatus.providerAccountIdentifier,
    );
    await expect(
      asUser.query(api.productAccount.listGmailProviderConnections, {
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).resolves.toHaveLength(2);
  });

  it('rotates the Gmail push route when the routing identity changes', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await asUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'user@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: connect.trustedDeviceId,
    });
    const firstRoute = await asUser.action(api.pushRelay.verifyGmailWatch, {
      gmailIdentityToken: userIdentityToken,
      historyId: '1',
      trustedDeviceId: connect.trustedDeviceId,
    });

    await asUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'other@example.com',
      providerAccountIdentifier: 'gmail-user-002',
      trustedDeviceId: connect.trustedDeviceId,
    });
    const secondRoute = await asUser.action(api.pushRelay.verifyGmailWatch, {
      gmailIdentityToken: otherIdentityToken,
      historyId: '2',
      trustedDeviceId: connect.trustedDeviceId,
    });

    expect(secondRoute.routeId).not.toBe(firstRoute.routeId);
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
