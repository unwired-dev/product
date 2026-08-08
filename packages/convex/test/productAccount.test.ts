/// <reference types="vite/client" />

import { createHash, generateKeyPairSync, sign } from 'node:crypto';

import { convexTest } from 'convex-test';

import type { Id } from '../convex/_generated/dataModel.js';

import { api, internal } from '../convex/_generated/api.js';
import { opaqueGmailConnectionId } from '../convex/gmailRouting.js';
import { gmailLegacyRouteFallbackLimit } from '../convex/productAccount.js';
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
const { privateKey: appleSignInPrivateKey } = generateKeyPairSync('ec', {
  namedCurve: 'P-256',
});
const {
  privateKey: appleIdentityPrivateKey,
  publicKey: appleIdentityPublicKey,
} = generateKeyPairSync('rsa', { modulusLength: 2048 });
const googleIdentitySigningKey = {
  ...googleIdentityPublicKey.export({ format: 'jwk' }),
  alg: 'RS256',
  kid: 'google-product-account-test-key',
  use: 'sig',
};
const appleIdentitySigningKey = {
  ...appleIdentityPublicKey.export({ format: 'jwk' }),
  alg: 'RS256',
  kid: 'apple-identity-test-key',
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

function appleIdToken(subject: string): string {
  const header = Buffer.from(
    JSON.stringify({ alg: 'RS256', kid: 'apple-identity-test-key' }),
  ).toString('base64url');
  const claims = Buffer.from(
    JSON.stringify({
      aud: 'dev.unwired.mail',
      exp: Math.floor(Date.now() / 1000) + 300,
      iss: 'https://appleid.apple.com',
      sub: subject,
    }),
  ).toString('base64url');
  const signingInput = `${header}.${claims}`;
  const signature = sign(
    'RSA-SHA256',
    Buffer.from(signingInput),
    appleIdentityPrivateKey,
  );
  return `${signingInput}.${signature.toString('base64url')}`;
}

function appleTokenResponse(subject = appleIdentity.subject): Response {
  return Response.json({
    access_token: 'apple-access-token',
    expires_in: 3600,
    id_token: appleIdToken(subject),
    refresh_token: 'apple-refresh-token',
    token_type: 'Bearer',
  });
}

function appleAccessTokenOnlyResponse(
  subject = appleIdentity.subject,
): Response {
  return Response.json({
    access_token: 'apple-access-token',
    expires_in: 3600,
    id_token: appleIdToken(subject),
    token_type: 'Bearer',
  });
}

vi.stubEnv('GMAIL_OAUTH_CLIENT_ID', 'gmail-client-id');
vi.stubEnv('GMAIL_ROUTING_KEY', 'gmail-routing-test-key');
vi.stubEnv('GMAIL_IDENTITY_BINDING_KEY', 'gmail-identity-binding-test-key');
vi.stubEnv('APPLE_BUNDLE_ID', 'dev.unwired.mail');
vi.stubEnv('APPLE_SIGN_IN_KEY_ID', 'apple-sign-in-key');
vi.stubEnv(
  'APPLE_SIGN_IN_PRIVATE_KEY',
  appleSignInPrivateKey.export({ format: 'pem', type: 'pkcs8' }),
);
vi.stubEnv('APPLE_TEAM_ID', 'apple-team-id');
vi.stubGlobal(
  'fetch',
  vi.fn<(input: RequestInfo | URL) => Promise<Response>>(async (input) => {
    const url = input instanceof Request ? input.url : String(input);
    if (url === 'https://appleid.apple.com/auth/token') {
      return appleTokenResponse();
    }
    if (url === 'https://appleid.apple.com/auth/revoke') {
      return new Response(null, { status: 200 });
    }
    if (url === 'https://appleid.apple.com/auth/keys') {
      return Response.json({ keys: [appleIdentitySigningKey] });
    }
    return Response.json(
      { keys: [googleIdentitySigningKey] },
      { headers: { 'cache-control': 'public, max-age=3600' } },
    );
  }),
);

const encryptedPayload = {
  algorithm: 'AES-GCM-256' as const,
  ciphertextBase64: 'Y2lwaGVydGV4dA',
  keyVersion: 1,
  nonceBase64: 'bm9uY2U',
  schemaVersion: 1,
  tagBase64: 'dGFn',
};

function pendingDeletionRequestId(result: {
  requestId?: Id<'productAccountDeletionRequests'>;
  state: string;
}): Id<'productAccountDeletionRequests'> {
  if (result.state !== 'pending' || result.requestId === undefined) {
    throw new Error('Expected a pending deletion request');
  }
  return result.requestId;
}

function requiredTrustedDeviceCredential(response: {
  trustedDeviceCredential?: string;
}): string {
  const { trustedDeviceCredential } = response;
  if (trustedDeviceCredential === undefined) {
    throw new Error('Expected a Trusted Device Credential');
  }
  return trustedDeviceCredential;
}

async function expectLegacyIdentifierMigration(
  existingRevocationTombstone: boolean,
): Promise<void> {
  const t = convexTest(schema, modules);
  const asUser = t.withIdentity(appleIdentity);
  const legacyDevice = await asUser.mutation(api.productAccount.connect, {
    deviceIdentifier: 'device-legacy-signed-out',
    platform: 'ios',
  });
  const revokedDevice = await asUser.mutation(api.productAccount.connect, {
    deviceIdentifier: 'device-revoked',
    platform: 'macos',
  });
  await t.run(async (ctx) => {
    const legacyHistory = await ctx.db
      .query('trustedDeviceIdentifierHistory')
      .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
        q
          .eq('productAccountId', legacyDevice.productAccountId)
          .eq('deviceIdentifier', 'device-legacy-signed-out'),
      )
      .unique();
    if (legacyHistory === null) {
      throw new Error('Legacy identifier history required');
    }
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete(legacyHistory._id);
    await ctx.db.delete(legacyDevice.trustedDeviceId);
    await ctx.db.patch(legacyDevice.productAccountId, {
      legacyTrustedDeviceIdentifierMigrationCompletedAt: undefined,
    });
    if (existingRevocationTombstone) {
      await ctx.db.insert('revokedTrustedDevices', {
        deviceIdentifier: 'device-revoked',
        productAccountId: legacyDevice.productAccountId,
        productSyncKeyEpoch: 1,
        revokedAt: Date.now(),
        trustedDeviceId: revokedDevice.trustedDeviceId,
      });
      await ctx.db.delete(revokedDevice.trustedDeviceId);
    }
  });

  await expect(
    t.mutation(internal.productAccount.migrateLegacyTrustedDeviceIdentifiers, {
      identifiers: [
        {
          deviceIdentifier: 'device-legacy-signed-out',
          firstRegisteredAt: 1,
        },
      ],
      migrationComplete: true,
      tokenIdentifier: appleIdentity.tokenIdentifier,
    }),
  ).resolves.toMatchObject({
    migrationComplete: true,
    migratedIdentifierCount: 1,
    productAccountId: legacyDevice.productAccountId,
  });
  await expect(
    t.mutation(internal.productAccount.migrateLegacyTrustedDeviceIdentifiers, {
      identifiers: [
        {
          deviceIdentifier: 'device-genuinely-unseen',
          firstRegisteredAt: 2,
        },
      ],
      migrationComplete: true,
      tokenIdentifier: appleIdentity.tokenIdentifier,
    }),
  ).rejects.toThrow('Trusted Device identifier migration is complete');

  if (!existingRevocationTombstone) {
    await t.run(async (ctx) => {
      await ctx.db.insert('revokedTrustedDevices', {
        deviceIdentifier: 'device-revoked',
        productAccountId: legacyDevice.productAccountId,
        productSyncKeyEpoch: 1,
        revokedAt: Date.now(),
        trustedDeviceId: revokedDevice.trustedDeviceId,
      });
      await ctx.db.delete(revokedDevice.trustedDeviceId);
    });
  }

  await expect(
    asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-legacy-signed-out',
      platform: 'ios',
    }),
  ).resolves.toMatchObject({
    deviceRegistered: true,
    productAccountId: legacyDevice.productAccountId,
  });
  await expect(
    asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-genuinely-unseen',
      platform: 'ios',
    }),
  ).rejects.toMatchObject({
    data: { code: 'TRUSTED_DEVICE_REVOKED' },
  });
  await expect(
    asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-revoked',
      platform: 'macos',
    }),
  ).rejects.toMatchObject({
    data: { code: 'TRUSTED_DEVICE_REVOKED' },
  });
}

describe('productAccount.connect', () => {
  it('preserves a valid device credential without exposing it in device summaries', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const firstConnect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
      supportsDeviceCredentials: true,
    });
    const firstCredential = requiredTrustedDeviceCredential(firstConnect);

    expect(firstCredential).toMatch(/^[0-9a-f]{64}$/u);
    const storedDevice = await t.run((ctx) =>
      ctx.db.get(firstConnect.trustedDeviceId),
    );
    expect(storedDevice?.credentialDigest).toMatch(/^[0-9a-f]{64}$/u);
    expect(storedDevice?.credentialDigest).toBe(
      createHash('sha256').update(firstCredential).digest('hex'),
    );

    const secondConnect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
      supportsDeviceCredentials: true,
      trustedDeviceCredential: firstCredential,
    });
    expect(secondConnect.trustedDeviceCredential).toBe(firstCredential);
    await expect(
      asUser.query(api.productAccount.listTrustedDevices, {
        trustedDeviceCredential: firstCredential,
        trustedDeviceId: secondConnect.trustedDeviceId,
      }),
    ).resolves.not.toHaveProperty('0.trustedDeviceCredential');
  });

  it('rejects a revoked credential substituted with a surviving device id', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const revokedDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-revoked',
      platform: 'ios',
      supportsDeviceCredentials: true,
    });
    const survivingDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-surviving',
      platform: 'macos',
      supportsDeviceCredentials: true,
    });
    await t.run(async (ctx) => {
      await ctx.db.insert('revokedTrustedDevices', {
        deviceIdentifier: 'device-revoked',
        productAccountId: revokedDevice.productAccountId,
        productSyncKeyEpoch: 1,
        revokedAt: Date.now(),
        trustedDeviceId: revokedDevice.trustedDeviceId,
      });
      await ctx.db.delete(revokedDevice.trustedDeviceId);
    });

    await expect(
      asUser.query(api.productAccount.listTrustedDevices, {
        trustedDeviceCredential: revokedDevice.trustedDeviceCredential,
        trustedDeviceId: survivingDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Reconnect this Trusted Device');
    await expect(
      asUser.query(api.productAccount.listTrustedDevices, {
        trustedDeviceCredential: survivingDevice.trustedDeviceCredential,
        trustedDeviceId: survivingDevice.trustedDeviceId,
      }),
    ).resolves.toHaveLength(1);
  });

  it('fails legacy sessions closed after activation until each device reconnects', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const firstDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const legacyDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
      supportsDeviceCredentials: true,
    });

    await expect(
      asUser.query(api.productAccount.listTrustedDevices, {
        trustedDeviceId: legacyDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Reconnect this Trusted Device');
    const reconnected = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
      supportsDeviceCredentials: true,
    });
    await expect(
      asUser.query(api.productAccount.listTrustedDevices, {
        trustedDeviceCredential: reconnected.trustedDeviceCredential,
        trustedDeviceId: reconnected.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(
      expect.arrayContaining([
        expect.objectContaining({ id: firstDevice.trustedDeviceId }),
      ]),
    );
  });

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

  it('lists every trusted device with its user-facing name', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      deviceName: 'Jans iPhone',
      platform: 'ios',
    });
    const otherDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      deviceName: 'Desk Mac',
      platform: 'macos',
    });

    await expect(
      asUser.query(api.productAccount.listTrustedDevices, {
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual([
      expect.objectContaining({
        displayName: 'Jans iPhone',
        id: currentDevice.trustedDeviceId,
        platform: 'ios',
      }),
      expect.objectContaining({
        displayName: 'Desk Mac',
        id: otherDevice.trustedDeviceId,
        platform: 'macos',
      }),
    ]);
  });

  it('renames a trusted device without changing its registration identity', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });

    await expect(
      asUser.mutation(api.productAccount.renameTrustedDevice, {
        displayName: '  Work Mac  ',
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRenameId: otherDevice.trustedDeviceId,
      }),
    ).resolves.toMatchObject({
      displayName: 'Work Mac',
      id: otherDevice.trustedDeviceId,
      platform: 'macos',
    });
  });

  it('rejects renaming a trusted device owned by another Product Account', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const asOtherUser = t.withIdentity({
      issuer: 'https://appleid.apple.com',
      subject: 'apple-user-002',
      tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await asOtherUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });

    await expect(
      asUser.mutation(api.productAccount.renameTrustedDevice, {
        displayName: 'Not Mine',
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRenameId: otherDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
  });

  it('requires recent authentication to revoke a trusted device', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      ...appleIdentity,
      iat: Math.floor(Date.now() / 1000) - 301,
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });

    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: encryptedPayload,
        expectedRecoveryUpdatedAt: 0,
        recoveryWrappedAccountKey: encryptedPayload,
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: otherDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Recent authentication required');
  });

  it('rejects revoking the current trusted device while allowing bounded clock skew', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      ...appleIdentity,
      iat: Math.floor(Date.now() / 1000) + 30,
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: encryptedPayload,
        expectedRecoveryUpdatedAt: 0,
        recoveryWrappedAccountKey: encryptedPayload,
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: currentDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Use sign out to remove the current Trusted Device');
  });

  it('rejects trusted-device revocation beyond the accepted future clock skew', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      ...appleIdentity,
      iat: Math.floor(Date.now() / 1000) + 3600,
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });

    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: encryptedPayload,
        expectedRecoveryUpdatedAt: 0,
        recoveryWrappedAccountKey: encryptedPayload,
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: otherDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Recent authentication required');
  });

  it('rejects revoking a trusted device owned by another Product Account', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      ...appleIdentity,
      iat: Math.floor(Date.now() / 1000),
    });
    const asOtherUser = t.withIdentity({
      issuer: 'https://appleid.apple.com',
      subject: 'apple-user-002',
      tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await asOtherUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });

    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: encryptedPayload,
        expectedRecoveryUpdatedAt: 0,
        recoveryWrappedAccountKey: encryptedPayload,
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: otherDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
  });

  it('revokes another device immediately and fences future Product Sync writes on the new key epoch', async () => {
    expect.assertions(8);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      ...appleIdentity,
      iat: Math.floor(Date.now() / 1000),
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.patch(otherDevice.trustedDeviceId, {
        apnsEnvironment: 'production',
        apnsToken: 'revoked-device-token',
        apnsTokenRegisteredAt: now,
      });
      await ctx.db.insert('devicePushRouteHeartbeats', {
        refreshedAt: now,
        trustedDeviceId: otherDevice.trustedDeviceId,
      });
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        lastVerifiedAt: now,
        productAccountId: currentDevice.productAccountId,
        provider: 'gmail',
        trustedDeviceId: otherDevice.trustedDeviceId,
        updatedAt: now,
      });
    });
    const recoveryMaterial = await asUser.mutation(
      internal.productSync.replaceRecoveryMaterialIfUnchanged,
      {
        encryptedPayload,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    const nextRecoveryMaterial = {
      ...encryptedPayload,
      keyVersion: 2,
      schemaVersion: 2,
    };
    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: encryptedPayload,
        expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
        recoveryWrappedAccountKey: nextRecoveryMaterial,
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: otherDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({
      keyEpoch: 2,
      pendingDeviceCount: 1,
      state: 'pending',
    });
    await expect(
      t.run(async (ctx) => ({
        heartbeats: await ctx.db
          .query('devicePushRouteHeartbeats')
          .withIndex('by_trustedDeviceId', (q) =>
            q.eq('trustedDeviceId', otherDevice.trustedDeviceId),
          )
          .collect(),
        routes: await ctx.db
          .query('mailProviderConnections')
          .withIndex(
            'by_productAccountId_and_provider_and_trustedDeviceId',
            (q) =>
              q
                .eq('productAccountId', currentDevice.productAccountId)
                .eq('provider', 'gmail')
                .eq('trustedDeviceId', otherDevice.trustedDeviceId),
          )
          .collect(),
      })),
    ).resolves.toStrictEqual({ heartbeats: [], routes: [] });
    const reconnectedCurrentDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
        supportsDeviceCredentials: true,
      },
    );
    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: encryptedPayload,
        expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
        recoveryWrappedAccountKey: nextRecoveryMaterial,
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: otherDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({
      keyEpoch: 2,
      pendingDeviceCount: 1,
      state: 'pending',
    });
    await expect(
      asUser.query(api.productAccount.listTrustedDevices, {
        trustedDeviceId: otherDevice.trustedDeviceId,
      }),
    ).rejects.toMatchObject({ data: { code: 'TRUSTED_DEVICE_REVOKED' } });
    await expect(
      asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-002',
        platform: 'macos',
      }),
    ).rejects.toMatchObject({ data: { code: 'TRUSTED_DEVICE_REVOKED' } });
    // oxlint-disable-next-line vitest/max-expects -- Full revocation contract includes identifier-minting bypass coverage.
    await expect(
      asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-reenrollment-attempt',
        platform: 'macos',
      }),
    ).rejects.toMatchObject({ data: { code: 'TRUSTED_DEVICE_REVOKED' } });
    // oxlint-disable-next-line vitest/max-expects -- Full revocation contract spans fencing and rotated writes.
    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
        encryptedPayload,
        expectedUpdatedAt: undefined,
        payloadIdentifier: 'stale-key-write',
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Product Sync key rotation required');
    // oxlint-disable-next-line vitest/max-expects -- Full revocation contract spans fencing and rotated writes.
    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
        encryptedPayload: nextRecoveryMaterial,
        expectedUpdatedAt: undefined,
        payloadIdentifier: 'rotated-key-write',
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toMatchObject({
      encryptedPayload: nextRecoveryMaterial,
      payloadIdentifier: 'rotated-key-write',
    });
  });

  it('returns the current rotation state when retrying an older completed revocation', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      ...appleIdentity,
      iat: Math.floor(Date.now() / 1000),
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const firstTarget = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    const secondTarget = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-003',
      platform: 'ios',
    });
    await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-004',
      platform: 'macos',
    });
    const recoveryMaterial = await asUser.mutation(
      internal.productSync.replaceRecoveryMaterialIfUnchanged,
      {
        encryptedPayload,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    const secondEpochRecovery = {
      ...encryptedPayload,
      keyVersion: 2,
      schemaVersion: 2,
    };
    await asUser.mutation(api.productAccount.revokeTrustedDevice, {
      encryptedTransition: encryptedPayload,
      expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
      recoveryWrappedAccountKey: secondEpochRecovery,
      trustedDeviceId: currentDevice.trustedDeviceId,
      trustedDeviceToRevokeId: firstTarget.trustedDeviceId,
    });
    const survivingDevices = await Promise.all(
      [
        ['device-001', 'ios'],
        ['device-003', 'ios'],
        ['device-004', 'macos'],
      ].map(async ([deviceIdentifier, platform]) =>
        asUser.mutation(api.productAccount.connect, {
          deviceIdentifier: deviceIdentifier!,
          platform: platform!,
          supportsDeviceCredentials: true,
        }),
      ),
    );
    for (const device of survivingDevices) {
      await asUser.mutation(
        api.productAccount.acknowledgeProductSyncKeyRotation,
        {
          keyEpoch: 2,
          trustedDeviceCredential: device.trustedDeviceCredential,
          trustedDeviceId: device.trustedDeviceId,
        },
      );
    }
    const committedRecoveryUpdatedAt = await t.run(async (ctx) => {
      const recovery = await ctx.db
        .query('encryptedProductSyncPayloads')
        .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
          q
            .eq('productAccountId', currentDevice.productAccountId)
            .eq('payloadIdentifier', 'product-account-recovery-v1'),
        )
        .unique();
      return recovery!.updatedAt;
    });
    expect(committedRecoveryUpdatedAt).toBeGreaterThan(0);
    const thirdEpochRecovery = {
      ...encryptedPayload,
      keyVersion: 3,
      schemaVersion: 2,
    };

    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: { ...encryptedPayload, keyVersion: 2 },
        expectedRecoveryUpdatedAt: committedRecoveryUpdatedAt,
        recoveryWrappedAccountKey: thirdEpochRecovery,
        trustedDeviceCredential: survivingDevices[0]!.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: secondTarget.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({
      keyEpoch: 3,
      pendingDeviceCount: 2,
      state: 'pending',
    });
    const recoveryBeforeReplay = await t.run(async (ctx) =>
      ctx.db
        .query('encryptedProductSyncPayloads')
        .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
          q
            .eq('productAccountId', currentDevice.productAccountId)
            .eq('payloadIdentifier', 'product-account-recovery-v1'),
        )
        .unique(),
    );
    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: encryptedPayload,
        expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
        recoveryWrappedAccountKey: secondEpochRecovery,
        trustedDeviceCredential: survivingDevices[0]!.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: firstTarget.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({
      keyEpoch: 3,
      pendingDeviceCount: 2,
      state: 'pending',
    });
    const recoveryAfterReplay = await t.run(async (ctx) =>
      ctx.db
        .query('encryptedProductSyncPayloads')
        .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
          q
            .eq('productAccountId', currentDevice.productAccountId)
            .eq('payloadIdentifier', 'product-account-recovery-v1'),
        )
        .unique(),
    );
    expect(recoveryAfterReplay?.encryptedPayload).toStrictEqual(
      recoveryBeforeReplay?.encryptedPayload,
    );
    for (const device of [survivingDevices[0]!, survivingDevices[2]!]) {
      await asUser.mutation(
        api.productAccount.acknowledgeProductSyncKeyRotation,
        {
          keyEpoch: 3,
          trustedDeviceCredential: device.trustedDeviceCredential,
          trustedDeviceId: device.trustedDeviceId,
        },
      );
    }
    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: encryptedPayload,
        expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
        recoveryWrappedAccountKey: secondEpochRecovery,
        trustedDeviceCredential: survivingDevices[0]!.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: firstTarget.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({
      keyEpoch: 3,
      pendingDeviceCount: 0,
      state: 'complete',
    });
  });

  it('delivers a pending key transition to remaining devices and commits recovery after every acknowledgement', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      ...appleIdentity,
      iat: Math.floor(Date.now() / 1000),
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const remainingDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    const revokedDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-003',
      platform: 'ios',
    });
    const recoveryMaterial = await asUser.mutation(
      internal.productSync.replaceRecoveryMaterialIfUnchanged,
      {
        encryptedPayload,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    const nextRecoveryMaterial = {
      ...encryptedPayload,
      keyVersion: 2,
      schemaVersion: 2,
    };
    await asUser.mutation(api.productAccount.revokeTrustedDevice, {
      encryptedTransition: encryptedPayload,
      expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
      recoveryWrappedAccountKey: nextRecoveryMaterial,
      trustedDeviceId: currentDevice.trustedDeviceId,
      trustedDeviceToRevokeId: revokedDevice.trustedDeviceId,
    });
    const reconnectedCurrentDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
        supportsDeviceCredentials: true,
      },
    );
    const reconnectedRemainingDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-002',
        platform: 'macos',
        supportsDeviceCredentials: true,
      },
    );

    await expect(
      asUser.query(api.productAccount.getProductSyncKeyRotation, {
        trustedDeviceCredential:
          reconnectedRemainingDevice.trustedDeviceCredential,
        trustedDeviceId: remainingDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({
      encryptedTransition: encryptedPayload,
      keyEpoch: 2,
      pendingDeviceCount: 2,
    });
    await expect(
      asUser.mutation(api.productAccount.acknowledgeProductSyncKeyRotation, {
        keyEpoch: 2,
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({
      keyEpoch: 2,
      pendingDeviceCount: 1,
      state: 'pending',
    });
    await expect(
      asUser.mutation(api.productAccount.acknowledgeProductSyncKeyRotation, {
        keyEpoch: 2,
        trustedDeviceCredential:
          reconnectedRemainingDevice.trustedDeviceCredential,
        trustedDeviceId: remainingDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({
      keyEpoch: 2,
      pendingDeviceCount: 0,
      state: 'complete',
    });
    await expect(
      asUser.query(api.productAccount.getProductSyncKeyRotation, {
        trustedDeviceCredential:
          reconnectedRemainingDevice.trustedDeviceCredential,
        trustedDeviceId: remainingDevice.trustedDeviceId,
      }),
    ).resolves.toBeNull();
    await expect(
      asUser.query(api.productSync.getEncryptedPayloadForTrustedDevice, {
        payloadIdentifier: 'product-account-recovery-v1',
        trustedDeviceCredential:
          reconnectedRemainingDevice.trustedDeviceCredential,
        trustedDeviceId: remainingDevice.trustedDeviceId,
      }),
    ).resolves.toMatchObject({ encryptedPayload: nextRecoveryMaterial });
  });

  it('supersedes a pending rotation when revoking another offline device', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      ...appleIdentity,
      iat: Math.floor(Date.now() / 1000),
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const firstOfflineDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-002',
        platform: 'macos',
      },
    );
    const secondOfflineDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-003',
        platform: 'ios',
      },
    );
    const recoveryMaterial = await asUser.mutation(
      internal.productSync.replaceRecoveryMaterialIfUnchanged,
      {
        encryptedPayload,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    const nextRecoveryMaterial = {
      ...encryptedPayload,
      keyVersion: 2,
      schemaVersion: 2,
    };
    const replacementRecoveryMaterial = {
      ...nextRecoveryMaterial,
      ciphertextBase64: 'replacement-ciphertext',
      keyVersion: 3,
    };
    await asUser.mutation(api.productAccount.revokeTrustedDevice, {
      encryptedTransition: encryptedPayload,
      expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
      recoveryWrappedAccountKey: nextRecoveryMaterial,
      trustedDeviceId: currentDevice.trustedDeviceId,
      trustedDeviceToRevokeId: firstOfflineDevice.trustedDeviceId,
    });
    const reconnectedCurrentDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
        supportsDeviceCredentials: true,
      },
    );
    await asUser.mutation(
      api.productAccount.acknowledgeProductSyncKeyRotation,
      {
        keyEpoch: 2,
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );

    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: encryptedPayload,
        expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt + 1,
        recoveryWrappedAccountKey: replacementRecoveryMaterial,
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: secondOfflineDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Recovery material changed');

    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: encryptedPayload,
        expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
        recoveryWrappedAccountKey: replacementRecoveryMaterial,
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: secondOfflineDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({
      keyEpoch: 3,
      pendingDeviceCount: 1,
      state: 'pending',
    });
    await expect(
      asUser.mutation(api.productAccount.acknowledgeProductSyncKeyRotation, {
        keyEpoch: 3,
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({
      keyEpoch: 3,
      pendingDeviceCount: 0,
      state: 'complete',
    });
    await expect(
      asUser.query(api.productAccount.getProductSyncKeyRotation, {
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toBeNull();
    await expect(
      asUser.query(api.productSync.getEncryptedPayloadForTrustedDevice, {
        payloadIdentifier: 'product-account-recovery-v1',
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toMatchObject({ encryptedPayload: replacementRecoveryMaterial });
  });

  it('supersedes a pending rotation before revoking a device that adopted it', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      ...appleIdentity,
      iat: Math.floor(Date.now() / 1000),
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const targetDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    const remainingDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-003',
      platform: 'ios',
    });
    const initiallyRevokedDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-004',
        platform: 'macos',
      },
    );
    const recoveryMaterial = await asUser.mutation(
      internal.productSync.replaceRecoveryMaterialIfUnchanged,
      {
        encryptedPayload,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    const nextRecoveryMaterial = {
      ...encryptedPayload,
      keyVersion: 2,
      schemaVersion: 2,
    };
    const finalRecoveryMaterial = {
      ...encryptedPayload,
      ciphertextBase64: 'final-recovery-material',
      keyVersion: 3,
      schemaVersion: 2,
    };
    const finalTransition = {
      ...encryptedPayload,
      ciphertextBase64: 'final-transition',
    };
    await asUser.mutation(api.productAccount.revokeTrustedDevice, {
      encryptedTransition: encryptedPayload,
      expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
      recoveryWrappedAccountKey: nextRecoveryMaterial,
      trustedDeviceId: currentDevice.trustedDeviceId,
      trustedDeviceToRevokeId: initiallyRevokedDevice.trustedDeviceId,
    });
    const reconnectedCurrentDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
        supportsDeviceCredentials: true,
      },
    );
    const reconnectedTargetDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-002',
        platform: 'macos',
        supportsDeviceCredentials: true,
      },
    );
    const reconnectedRemainingDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-003',
        platform: 'ios',
        supportsDeviceCredentials: true,
      },
    );
    await asUser.mutation(
      api.productAccount.acknowledgeProductSyncKeyRotation,
      {
        keyEpoch: 2,
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    await asUser.mutation(
      api.productAccount.acknowledgeProductSyncKeyRotation,
      {
        keyEpoch: 2,
        trustedDeviceCredential:
          reconnectedTargetDevice.trustedDeviceCredential,
        trustedDeviceId: targetDevice.trustedDeviceId,
      },
    );

    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: finalTransition,
        expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
        recoveryWrappedAccountKey: finalRecoveryMaterial,
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: targetDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({
      keyEpoch: 3,
      pendingDeviceCount: 2,
      state: 'pending',
    });
    await expect(
      asUser.query(api.productAccount.listTrustedDevices, {
        trustedDeviceId: targetDevice.trustedDeviceId,
      }),
    ).rejects.toMatchObject({ data: { code: 'TRUSTED_DEVICE_REVOKED' } });
    await expect(
      asUser.query(api.productAccount.getProductSyncKeyRotation, {
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toMatchObject({
      encryptedTransition: finalTransition,
      keyEpoch: 3,
      pendingDeviceCount: 2,
    });
    await expect(
      asUser.query(api.productAccount.getProductSyncKeyRotation, {
        trustedDeviceCredential:
          reconnectedRemainingDevice.trustedDeviceCredential,
        trustedDeviceId: remainingDevice.trustedDeviceId,
      }),
    ).resolves.toMatchObject({
      encryptedTransition: finalTransition,
      keyEpoch: 3,
      pendingDeviceCount: 2,
    });
    const currentAcknowledgement = await asUser.mutation(
      api.productAccount.acknowledgeProductSyncKeyRotation,
      {
        keyEpoch: 3,
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    const remainingAcknowledgement = await asUser.mutation(
      api.productAccount.acknowledgeProductSyncKeyRotation,
      {
        keyEpoch: 3,
        trustedDeviceCredential:
          reconnectedRemainingDevice.trustedDeviceCredential,
        trustedDeviceId: remainingDevice.trustedDeviceId,
      },
    );
    const committedRecoveryMaterial = await asUser.query(
      api.productSync.getEncryptedPayloadForTrustedDevice,
      {
        payloadIdentifier: 'product-account-recovery-v1',
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    expect([
      currentAcknowledgement,
      remainingAcknowledgement,
      committedRecoveryMaterial?.encryptedPayload,
    ]).toStrictEqual([
      {
        keyEpoch: 3,
        pendingDeviceCount: 1,
        state: 'pending',
      },
      {
        keyEpoch: 3,
        pendingDeviceCount: 0,
        state: 'complete',
      },
      finalRecoveryMaterial,
    ]);
  });

  it('rejects recovery material for a different epoch during a pending rotation', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      ...appleIdentity,
      iat: Math.floor(Date.now() / 1000),
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const firstTarget = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    const secondTarget = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-003',
      platform: 'ios',
    });
    const recoveryMaterial = await asUser.mutation(
      internal.productSync.replaceRecoveryMaterialIfUnchanged,
      {
        encryptedPayload,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    const nextRecoveryMaterial = {
      ...encryptedPayload,
      keyVersion: 2,
      schemaVersion: 2,
    };
    await asUser.mutation(api.productAccount.revokeTrustedDevice, {
      encryptedTransition: encryptedPayload,
      expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
      recoveryWrappedAccountKey: nextRecoveryMaterial,
      trustedDeviceId: currentDevice.trustedDeviceId,
      trustedDeviceToRevokeId: firstTarget.trustedDeviceId,
    });
    const reconnectedCurrentDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
        supportsDeviceCredentials: true,
      },
    );

    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: encryptedPayload,
        expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
        recoveryWrappedAccountKey: { ...nextRecoveryMaterial, keyVersion: 4 },
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: secondTarget.trustedDeviceId,
      }),
    ).rejects.toThrow('Product Sync key rotation material is invalid');
  });

  it('rejects a stale transition during a concurrent pending rotation', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      ...appleIdentity,
      iat: Math.floor(Date.now() / 1000),
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const firstTarget = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    const secondTarget = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-003',
      platform: 'ios',
    });
    const recoveryMaterial = await asUser.mutation(
      internal.productSync.replaceRecoveryMaterialIfUnchanged,
      {
        encryptedPayload,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    const nextRecoveryMaterial = {
      ...encryptedPayload,
      keyVersion: 2,
      schemaVersion: 2,
    };
    await asUser.mutation(api.productAccount.revokeTrustedDevice, {
      encryptedTransition: encryptedPayload,
      expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
      recoveryWrappedAccountKey: nextRecoveryMaterial,
      trustedDeviceId: currentDevice.trustedDeviceId,
      trustedDeviceToRevokeId: firstTarget.trustedDeviceId,
    });
    const reconnectedCurrentDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
        supportsDeviceCredentials: true,
      },
    );

    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: {
          ...encryptedPayload,
          ciphertextBase64: 'concurrent-transition',
          keyVersion: 2,
        },
        expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
        recoveryWrappedAccountKey: {
          ...nextRecoveryMaterial,
          ciphertextBase64: 'concurrent-wrapper',
          keyVersion: 3,
        },
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: secondTarget.trustedDeviceId,
      }),
    ).rejects.toThrow('Product Sync key rotation transition is stale');
  });

  it('completes a pending rotation when its last unacknowledged device signs out', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      ...appleIdentity,
      iat: Math.floor(Date.now() / 1000),
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const signingOutDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    const revokedDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-003',
      platform: 'ios',
    });
    const recoveryMaterial = await asUser.mutation(
      internal.productSync.replaceRecoveryMaterialIfUnchanged,
      {
        encryptedPayload,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    const nextRecoveryMaterial = {
      ...encryptedPayload,
      keyVersion: 2,
      schemaVersion: 2,
    };
    await asUser.mutation(api.productAccount.revokeTrustedDevice, {
      encryptedTransition: encryptedPayload,
      expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
      recoveryWrappedAccountKey: nextRecoveryMaterial,
      trustedDeviceId: currentDevice.trustedDeviceId,
      trustedDeviceToRevokeId: revokedDevice.trustedDeviceId,
    });
    const reconnectedCurrentDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
        supportsDeviceCredentials: true,
      },
    );
    const reconnectedSigningOutDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-002',
        platform: 'macos',
        supportsDeviceCredentials: true,
      },
    );
    await asUser.mutation(
      api.productAccount.acknowledgeProductSyncKeyRotation,
      {
        keyEpoch: 2,
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );

    await expect(
      asUser.mutation(api.productAccount.unregisterTrustedDevice, {
        deviceIdentifier: 'device-002',
        trustedDeviceCredential:
          reconnectedSigningOutDevice.trustedDeviceCredential,
        trustedDeviceId: signingOutDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ registered: false });
    await expect(
      asUser.query(api.productAccount.getProductSyncKeyRotation, {
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toBeNull();
    await expect(
      asUser.query(api.productSync.getEncryptedPayloadForTrustedDevice, {
        payloadIdentifier: 'product-account-recovery-v1',
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toMatchObject({ encryptedPayload: nextRecoveryMaterial });
  });

  it('allows a non-revoked device to reconnect after signing out', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      ...appleIdentity,
      iat: Math.floor(Date.now() / 1000),
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const revokedDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    await t.run(async (ctx) => {
      const legacyIdentifierHistory = await ctx.db
        .query('trustedDeviceIdentifierHistory')
        .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
          q
            .eq('productAccountId', currentDevice.productAccountId)
            .eq('deviceIdentifier', 'device-001'),
        )
        .collect();
      await Promise.all(
        legacyIdentifierHistory.map(
          // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
          async (history) => ctx.db.delete(history._id),
        ),
      );
    });
    const recoveryMaterial = await asUser.mutation(
      internal.productSync.replaceRecoveryMaterialIfUnchanged,
      {
        encryptedPayload,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    await asUser.mutation(api.productAccount.revokeTrustedDevice, {
      encryptedTransition: encryptedPayload,
      expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt,
      recoveryWrappedAccountKey: {
        ...encryptedPayload,
        keyVersion: 2,
        schemaVersion: 2,
      },
      trustedDeviceId: currentDevice.trustedDeviceId,
      trustedDeviceToRevokeId: revokedDevice.trustedDeviceId,
    });
    const reconnectedCurrentDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
        supportsDeviceCredentials: true,
      },
    );
    await asUser.mutation(
      api.productAccount.acknowledgeProductSyncKeyRotation,
      {
        keyEpoch: 2,
        trustedDeviceCredential:
          reconnectedCurrentDevice.trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
      deviceIdentifier: 'device-001',
      trustedDeviceCredential: reconnectedCurrentDevice.trustedDeviceCredential,
      trustedDeviceId: currentDevice.trustedDeviceId,
    });

    await expect(
      asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
        supportsDeviceCredentials: true,
      }),
    ).resolves.toMatchObject({
      deviceRegistered: true,
      productAccountId: currentDevice.productAccountId,
    });
  });

  it('requires legacy identifier migration before the first revocation', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      ...appleIdentity,
      iat: Math.floor(Date.now() / 1000),
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const targetDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    await t.run(async (ctx) =>
      ctx.db.patch(currentDevice.productAccountId, {
        legacyTrustedDeviceIdentifierMigrationCompletedAt: undefined,
      }),
    );

    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: encryptedPayload,
        expectedRecoveryUpdatedAt: Date.now(),
        recoveryWrappedAccountKey: {
          ...encryptedPayload,
          keyVersion: 2,
          schemaVersion: 2,
        },
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: targetDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted Device identifier migration required');
  });

  it('migrates a legacy signed-out identifier before the first tombstone', async () => {
    expect.assertions(5);

    await expectLegacyIdentifierMigration(false);
  });

  it('migrates a legacy signed-out identifier after an existing tombstone', async () => {
    expect.assertions(5);

    await expectLegacyIdentifierMigration(true);
  });

  it('keeps the target trusted when recovery material changes before revocation', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity({
      ...appleIdentity,
      iat: Math.floor(Date.now() / 1000),
    });
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    const recoveryMaterial = await asUser.mutation(
      internal.productSync.replaceRecoveryMaterialIfUnchanged,
      {
        encryptedPayload,
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );

    await expect(
      asUser.mutation(api.productAccount.revokeTrustedDevice, {
        encryptedTransition: encryptedPayload,
        expectedRecoveryUpdatedAt: recoveryMaterial.updatedAt + 1,
        recoveryWrappedAccountKey: {
          ...encryptedPayload,
          keyVersion: 2,
          schemaVersion: 2,
        },
        trustedDeviceId: currentDevice.trustedDeviceId,
        trustedDeviceToRevokeId: otherDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Recovery material changed');
    await expect(
      asUser.query(api.productAccount.listTrustedDevices, {
        trustedDeviceId: otherDevice.trustedDeviceId,
      }),
    ).resolves.toHaveLength(2);
    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
        encryptedPayload,
        expectedUpdatedAt: undefined,
        payloadIdentifier: 'write-after-failed-revocation',
        trustedDeviceId: otherDevice.trustedDeviceId,
      }),
    ).resolves.toMatchObject({
      payloadIdentifier: 'write-after-failed-revocation',
    });
  });

  it('unregisters only the current Trusted Device', async () => {
    expect.assertions(4);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });

    await expect(
      asUser.mutation(api.productAccount.unregisterTrustedDevice, {
        deviceIdentifier: 'device-001',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ registered: false });
    await expect(
      asUser.mutation(api.productAccount.unregisterTrustedDevice, {
        deviceIdentifier: 'device-001',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ registered: false });
    await expect(
      asUser.query(api.productAccount.listTrustedDevices, {
        trustedDeviceId: otherDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual([
      expect.objectContaining({ id: otherDevice.trustedDeviceId }),
    ]);
    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
        encryptedPayload,
        expectedUpdatedAt: undefined,
        payloadIdentifier: 'payload-after-unregistration',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
  });

  it('deletes Gmail routes and orphaned identity bindings owned by an unregistered device', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    await t.run(async (ctx) => {
      const now = Date.now();
      for (const [index, trustedDeviceId] of [
        currentDevice.trustedDeviceId,
        otherDevice.trustedDeviceId,
      ].entries()) {
        const opaqueConnectionId = `connection-${index}`;
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: now,
          lastVerifiedAt: now,
          opaqueConnectionId,
          productAccountId: currentDevice.productAccountId,
          provider: 'gmail',
          trustedDeviceId,
          updatedAt: now,
        });
        await ctx.db.insert('gmailOpaqueIdentityBindings', {
          identityBindingDigest: `digest-${index}`,
          opaqueConnectionId,
          productAccountId: currentDevice.productAccountId,
          updatedAt: now,
        });
      }
    });

    await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
      deviceIdentifier: 'device-001',
      trustedDeviceId: currentDevice.trustedDeviceId,
    });

    const remainingDeviceIds = await t.run(async (ctx) => {
      const routes = await ctx.db.query('mailProviderConnections').collect();
      return routes.map((route) => route.trustedDeviceId);
    });
    expect(remainingDeviceIds).toStrictEqual([otherDevice.trustedDeviceId]);
    const remainingBindingIds = await t.run(async (ctx) => {
      const bindings = await ctx.db
        .query('gmailOpaqueIdentityBindings')
        .collect();
      return bindings.map((binding) => binding.opaqueConnectionId);
    });
    expect(remainingBindingIds).toStrictEqual(['connection-1']);
  });

  it('deletes paginated Microsoft Graph routes and wakeup states owned by an unregistered device', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    await t.run(async (ctx) => {
      const now = Date.now();
      for (let index = 0; index < 21; index += 1) {
        const routeId = await ctx.db.insert('mailProviderConnections', {
          connectedAt: now,
          lastVerifiedAt: now,
          productAccountId: currentDevice.productAccountId,
          provider: 'microsoft-graph',
          trustedDeviceId: currentDevice.trustedDeviceId,
          updatedAt: now,
        });
        await ctx.db.insert('microsoftGraphWakeupStates', {
          routeId,
          scheduledAt: now,
        });
      }
      const otherRouteId = await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        lastVerifiedAt: now,
        productAccountId: currentDevice.productAccountId,
        provider: 'microsoft-graph',
        trustedDeviceId: otherDevice.trustedDeviceId,
        updatedAt: now,
      });
      await ctx.db.insert('microsoftGraphWakeupStates', {
        routeId: otherRouteId,
        scheduledAt: now,
      });
    });

    await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
      deviceIdentifier: 'device-001',
      trustedDeviceId: currentDevice.trustedDeviceId,
    });

    const remaining = await t.run(async (ctx) => ({
      routes: await ctx.db.query('mailProviderConnections').collect(),
      wakeupStates: await ctx.db.query('microsoftGraphWakeupStates').collect(),
    }));
    expect(
      remaining.routes.map((route) => route.trustedDeviceId),
    ).toStrictEqual([otherDevice.trustedDeviceId]);
    expect(remaining.wakeupStates).toHaveLength(1);
  });

  /* oxlint-disable vitest/no-conditional-in-test -- table-driven cases select distinct public skip-path fixtures. */
  it.each([
    'remaining route',
    'incomplete legacy snapshot',
    'matching legacy route',
  ] as const)(
    'keeps Gmail identity bindings for the %s skip path',
    async (scenario) => {
      expect.assertions(1);

      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      const otherDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-002',
        platform: 'macos',
      });
      const legacyProviderAccountIdentifier = 'gmail-user-legacy';
      const opaqueConnectionId =
        scenario === 'matching legacy route'
          ? await opaqueGmailConnectionId(
              currentDevice.productAccountId,
              legacyProviderAccountIdentifier,
            )
          : `connection-${scenario}`;
      await t.run(async (ctx) => {
        const now = Date.now();
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: now,
          lastVerifiedAt: now,
          opaqueConnectionId,
          productAccountId: currentDevice.productAccountId,
          provider: 'gmail',
          trustedDeviceId: currentDevice.trustedDeviceId,
          updatedAt: now,
        });
        await ctx.db.insert('gmailOpaqueIdentityBindings', {
          identityBindingDigest: `digest-${scenario}`,
          opaqueConnectionId,
          productAccountId: currentDevice.productAccountId,
          updatedAt: now,
        });
        if (scenario === 'remaining route') {
          await ctx.db.insert('mailProviderConnections', {
            connectedAt: now,
            lastVerifiedAt: now,
            opaqueConnectionId,
            productAccountId: currentDevice.productAccountId,
            provider: 'gmail',
            trustedDeviceId: otherDevice.trustedDeviceId,
            updatedAt: now,
          });
        } else if (scenario === 'incomplete legacy snapshot') {
          for (
            let index = 0;
            index <= gmailLegacyRouteFallbackLimit;
            index += 1
          ) {
            await ctx.db.insert('mailProviderConnections', {
              connectedAt: now,
              lastVerifiedAt: now,
              productAccountId: currentDevice.productAccountId,
              provider: 'gmail',
              providerAccountIdentifier: `legacy-${index}`,
              trustedDeviceId: otherDevice.trustedDeviceId,
              updatedAt: now,
            });
          }
        } else {
          await ctx.db.insert('mailProviderConnections', {
            connectedAt: now,
            lastVerifiedAt: now,
            productAccountId: currentDevice.productAccountId,
            provider: 'gmail',
            providerAccountIdentifier: legacyProviderAccountIdentifier,
            trustedDeviceId: otherDevice.trustedDeviceId,
            updatedAt: now,
          });
        }
      });

      await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
        deviceIdentifier: 'device-001',
        trustedDeviceId: currentDevice.trustedDeviceId,
      });

      const remainingBindingIds = await t.run(async (ctx) => {
        const bindings = await ctx.db
          .query('gmailOpaqueIdentityBindings')
          .collect();
        return bindings.map((binding) => binding.opaqueConnectionId);
      });
      expect(remainingBindingIds).toContain(opaqueConnectionId);
    },
  );
  /* oxlint-enable vitest/no-conditional-in-test */

  it('deletes a Gmail identity binding after its final legacy route is removed', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const providerAccountIdentifier = 'gmail-user-legacy';
    const opaqueConnectionId = await opaqueGmailConnectionId(
      currentDevice.productAccountId,
      providerAccountIdentifier,
    );
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        lastVerifiedAt: now,
        productAccountId: currentDevice.productAccountId,
        provider: 'gmail',
        providerAccountIdentifier,
        trustedDeviceId: currentDevice.trustedDeviceId,
        updatedAt: now,
      });
      await ctx.db.insert('gmailOpaqueIdentityBindings', {
        identityBindingDigest: 'digest-legacy',
        opaqueConnectionId,
        productAccountId: currentDevice.productAccountId,
        updatedAt: now,
      });
    });

    await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
      deviceIdentifier: 'device-001',
      trustedDeviceId: currentDevice.trustedDeviceId,
    });

    await expect(
      t.run(async (ctx) =>
        ctx.db.query('gmailOpaqueIdentityBindings').collect(),
      ),
    ).resolves.toStrictEqual([]);
  });

  it('drains over-limit legacy Gmail routes during device unregistration', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await t.run(async (ctx) => {
      const now = Date.now();
      for (let index = 0; index <= 20; index += 1) {
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: now,
          lastVerifiedAt: now,
          opaqueConnectionId: `connection-${index}`,
          productAccountId: currentDevice.productAccountId,
          provider: 'gmail',
          trustedDeviceId: currentDevice.trustedDeviceId,
          updatedAt: now,
        });
      }
    });

    await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
      deviceIdentifier: 'device-001',
      trustedDeviceId: currentDevice.trustedDeviceId,
    });

    await expect(
      t.run(async (ctx) => ctx.db.query('mailProviderConnections').collect()),
    ).resolves.toStrictEqual([]);
  });

  it('rejects unregistering another trusted device on the same Product Account', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });

    await expect(
      asUser.mutation(api.productAccount.unregisterTrustedDevice, {
        deviceIdentifier: 'device-001',
        trustedDeviceId: otherDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Current trusted device required');
  });

  it('rejects unregistering another Product Account trusted device', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const asOtherUser = t.withIdentity({
      issuer: 'https://appleid.apple.com',
      subject: 'apple-user-002',
      tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
    });
    const otherDevice = await asOtherUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    await expect(
      asUser.mutation(api.productAccount.unregisterTrustedDevice, {
        deviceIdentifier: 'device-001',
        trustedDeviceId: otherDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
  });

  it('rejects registration beyond the Trusted Device list limit', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    for (let index = 0; index < 100; index += 1) {
      await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: `device-${index}`,
        platform: 'ios',
      });
    }

    await expect(
      asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-over-limit',
        platform: 'ios',
      }),
    ).rejects.toThrow('Trusted Device limit exceeded');
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
    await asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
      encryptedPayload,
      expectedUpdatedAt: undefined,
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

describe('gmail operational connection registration', () => {
  it('keeps legacy Gmail handlers available during the opaque rollout', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        emailAddress: 'user@example.com',
        lastVerifiedAt: now,
        productAccountId: connect.productAccountId,
        provider: 'gmail',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId: connect.trustedDeviceId,
        updatedAt: now,
      });
    });

    await expect(
      asUser.query(api.productAccount.listGmailProviderConnections, {
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).resolves.toMatchObject([
      {
        emailAddress: 'user@example.com',
        providerAccountIdentifier: 'gmail-user-001',
      },
    ]);
    await expect(
      asUser.mutation(api.productAccount.connectGmailProvider, {
        emailAddress: 'updated@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        supportsMultipleConnections: true,
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).resolves.toMatchObject({
      emailAddress: 'updated@example.com',
      providerAccountIdentifier: 'gmail-user-001',
    });
    await expect(
      asUser.mutation(api.productAccount.removeGmailProviderConnection, {
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({
      hasRemainingGmailConnections: false,
      removed: true,
    });
  });

  it('stores only opaque operational data for two Gmail connections', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    const firstStatus = await asUser.action(
      api.pushRelay.registerGmailConnection,
      {
        gmailIdentityToken: userIdentityToken,
        opaqueConnectionId: 'opaque-gmail-001',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );
    const secondStatus = await asUser.action(
      api.pushRelay.registerGmailConnection,
      {
        gmailIdentityToken: otherIdentityToken,
        opaqueConnectionId: 'opaque-gmail-002',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );

    expect(firstStatus.opaqueConnectionId).toBe('opaque-gmail-001');
    expect(secondStatus.opaqueConnectionId).toBe('opaque-gmail-002');
    expect(JSON.stringify([firstStatus, secondStatus])).not.toMatch(
      /emailAddress|providerAccountIdentifier|user@example\.com|gmail-user-/iu,
    );

    const stored = await t.run(async (ctx) =>
      ctx.db
        .query('mailProviderConnections')
        .withIndex(
          'by_productAccountId_and_provider_and_trustedDeviceId',
          (q) =>
            q
              .eq('productAccountId', connect.productAccountId)
              .eq('provider', 'gmail')
              .eq('trustedDeviceId', connect.trustedDeviceId),
        )
        .take(3),
    );
    expect(stored).toHaveLength(2);
    expect(
      stored.map((connection) => ({
        emailAddress: connection.emailAddress,
        providerAccountIdentifier: connection.providerAccountIdentifier,
      })),
    ).toStrictEqual([
      { emailAddress: undefined, providerAccountIdentifier: undefined },
      { emailAddress: undefined, providerAccountIdentifier: undefined },
    ]);
  });

  it('rejects rebinding an opaque connection to another Google identity', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await asUser.action(api.pushRelay.registerGmailConnection, {
      gmailIdentityToken: userIdentityToken,
      opaqueConnectionId: 'opaque-gmail-001',
      trustedDeviceId: connect.trustedDeviceId,
    });

    await expect(
      asUser.action(api.pushRelay.registerGmailConnection, {
        gmailIdentityToken: otherIdentityToken,
        opaqueConnectionId: 'opaque-gmail-001',
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).rejects.toThrow('Gmail mailbox ownership proof rejected');
  });

  it('rejects rebinding an opaque connection from another trusted device', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const firstDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const secondDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'ios',
    });
    await asUser.action(api.pushRelay.registerGmailConnection, {
      gmailIdentityToken: userIdentityToken,
      opaqueConnectionId: 'opaque-gmail-001',
      trustedDeviceId: firstDevice.trustedDeviceId,
    });

    await expect(
      asUser.action(api.pushRelay.registerGmailConnection, {
        gmailIdentityToken: otherIdentityToken,
        opaqueConnectionId: 'opaque-gmail-001',
        trustedDeviceId: secondDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Gmail mailbox ownership proof rejected');
  });

  it('migrates an owned legacy row and drains readable signals in batches', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const legacyId = await t.run(async (ctx) => {
      const now = Date.now();
      const connectionId = await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        emailAddress: 'user@example.com',
        lastVerifiedAt: now,
        productAccountId: connect.productAccountId,
        provider: 'gmail',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId: connect.trustedDeviceId,
        updatedAt: now,
      });
      for (let index = 0; index < 101; index += 1) {
        await ctx.db.insert('gmailPushVerificationSignals', {
          emailAddress: 'user@example.com',
          historyId: String(index),
          receivedAt: now,
        });
      }
      return connectionId;
    });

    await asUser.action(api.pushRelay.registerGmailConnection, {
      gmailIdentityToken: userIdentityToken,
      opaqueConnectionId: 'opaque-gmail-001',
      trustedDeviceId: connect.trustedDeviceId,
    });

    const migrated = await t.run(async (ctx) => ({
      connection: await ctx.db.get(legacyId),
      signals: await ctx.db
        .query('gmailPushVerificationSignals')
        .withIndex('by_emailAddress', (q) =>
          q.eq('emailAddress', 'user@example.com'),
        )
        .take(1),
    }));
    expect(migrated.connection).toHaveProperty('_id', legacyId);
    expect(migrated.connection?.opaqueConnectionId).toBe('opaque-gmail-001');
    expect(migrated.connection?.emailAddress).toBeUndefined();
    expect(migrated.connection?.providerAccountIdentifier).toBeUndefined();
    expect(migrated.signals).toStrictEqual([]);
  });

  it('accepts an escaped single-line Apple private key', async () => {
    expect.assertions(1);

    const privateKey = appleSignInPrivateKey.export({
      format: 'pem',
      type: 'pkcs8',
    });
    vi.stubEnv(
      'APPLE_SIGN_IN_PRIVATE_KEY',
      privateKey.replaceAll('\n', String.raw`\n`),
    );
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });

      await expect(
        asUser.action(api.productAccountDeletion.deleteProductAccount, {
          authorizationCode: 'recent-apple-authorization-code',
          trustedDeviceId: currentDevice.trustedDeviceId,
        }),
      ).resolves.toStrictEqual({ deleted: true });
    } finally {
      vi.stubEnv('APPLE_SIGN_IN_PRIVATE_KEY', privateKey);
    }
  });

  it('schedules continuation when deletion exceeds the action batch limit', async () => {
    expect.assertions(4);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      await t.run(async (ctx) => {
        const now = Date.now();
        await ctx.db.insert('revokedTrustedDevices', {
          deviceIdentifier: 'revoked-device',
          productAccountId: currentDevice.productAccountId,
          productSyncKeyEpoch: 1,
          revokedAt: now,
          trustedDeviceId: currentDevice.trustedDeviceId,
        });
        for (let index = 0; index < 101; index += 1) {
          await ctx.db.insert('encryptedProductSyncPayloads', {
            encryptedPayload,
            payloadIdentifier: `payload-${index}`,
            productAccountId: currentDevice.productAccountId,
            trustedDeviceId: currentDevice.trustedDeviceId,
            updatedAt: now,
            writtenAt: now,
          });
        }
      });
      const reconnectedCurrentDevice = await asUser.mutation(
        api.productAccount.connect,
        {
          deviceIdentifier: 'device-001',
          platform: 'ios',
          supportsDeviceCredentials: true,
        },
      );

      await expect(
        asUser.action(api.productAccountDeletion.deleteProductAccount, {
          authorizationCode: 'recent-apple-authorization-code',
          trustedDeviceCredential:
            reconnectedCurrentDevice.trustedDeviceCredential,
          trustedDeviceId: currentDevice.trustedDeviceId,
        }),
      ).resolves.toStrictEqual({ deleted: false });
      await t.finishAllScheduledFunctions(vi.runAllTimers);
      await expect(
        t.run(async (ctx) => ctx.db.query('productAccounts').collect()),
      ).resolves.toStrictEqual([]);
      await expect(
        t.run(async (ctx) => ctx.db.query('revokedTrustedDevices').collect()),
      ).resolves.toStrictEqual([]);
      await expect(
        t.run(async (ctx) =>
          ctx.db.query('trustedDeviceIdentifierHistory').collect(),
        ),
      ).resolves.toStrictEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('irreversibly deletes Product Account data and fences reconnection', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    await asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
      encryptedPayload,
      expectedUpdatedAt: undefined,
      payloadIdentifier: 'encrypted-preference',
      trustedDeviceId: currentDevice.trustedDeviceId,
    });
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.patch(otherDevice.trustedDeviceId, {
        apnsEnvironment: 'production',
        apnsToken: 'other-device-token',
        apnsTokenRegisteredAt: now,
      });
      await ctx.db.insert('devicePushRouteHeartbeats', {
        refreshedAt: now,
        trustedDeviceId: otherDevice.trustedDeviceId,
      });
      const routeId = await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        lastVerifiedAt: now,
        productAccountId: currentDevice.productAccountId,
        provider: 'microsoft-graph',
        trustedDeviceId: otherDevice.trustedDeviceId,
        updatedAt: now,
      });
      await ctx.db.insert('microsoftGraphWakeupStates', {
        routeId,
        scheduledAt: now,
      });
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        gmailRoutingDigest: 'shared-gmail-routing-digest',
        lastVerifiedAt: now,
        opaqueConnectionId: 'opaque-gmail-connection',
        productAccountId: currentDevice.productAccountId,
        provider: 'gmail',
        trustedDeviceId: otherDevice.trustedDeviceId,
        updatedAt: now,
      });
      await ctx.db.insert('gmailPushVerificationSignals', {
        historyId: 'shared-history-id',
        receivedAt: now,
        routingDigest: 'shared-gmail-routing-digest',
      });
      await ctx.db.insert('gmailOpaqueIdentityBindings', {
        identityBindingDigest: 'identity-binding',
        opaqueConnectionId: 'opaque-connection',
        productAccountId: currentDevice.productAccountId,
        updatedAt: now,
      });
    });

    await expect(
      asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'recent-apple-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ deleted: true });
    await expect(
      t.run(async (ctx) => ({
        accounts: await ctx.db.query('productAccounts').collect(),
        bindings: await ctx.db.query('gmailOpaqueIdentityBindings').collect(),
        devices: await ctx.db.query('trustedDevices').collect(),
        heartbeats: await ctx.db.query('devicePushRouteHeartbeats').collect(),
        payloads: await ctx.db.query('encryptedProductSyncPayloads').collect(),
        routes: await ctx.db.query('mailProviderConnections').collect(),
        wakeups: await ctx.db.query('microsoftGraphWakeupStates').collect(),
      })),
    ).resolves.toStrictEqual({
      accounts: [],
      bindings: [],
      devices: [],
      heartbeats: [],
      payloads: [],
      routes: [],
      wakeups: [],
    });
    await expect(
      t.run(async (ctx) => {
        const signals = await ctx.db
          .query('gmailPushVerificationSignals')
          .collect();
        const tombstones = await ctx.db
          .query('productAccountDeletionTombstones')
          .collect();
        return { signals: signals.length, tombstones: tombstones.length };
      }),
    ).resolves.toStrictEqual({ signals: 1, tombstones: 1 });
    await expect(
      asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-003',
        platform: 'ios',
      }),
    ).rejects.toMatchObject({ data: { code: 'PRODUCT_ACCOUNT_DELETED' } });
    await expect(
      asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'retry-after-lost-response',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ deleted: true });
  });

  it('keeps account data when Apple token revocation fails terminally', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const fetchMock = vi.mocked(fetch);
    fetchMock.mockImplementationOnce(async () => appleTokenResponse());
    fetchMock.mockImplementationOnce(async () =>
      Response.json({ keys: [appleIdentitySigningKey] }),
    );
    fetchMock.mockImplementationOnce(async () =>
      Response.json({ error: 'invalid_client' }, { status: 400 }),
    );

    await expect(
      asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'recent-apple-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Apple authorization revocation failed');
    await expect(
      t.run(async (ctx) => ctx.db.query('productAccounts').collect()),
    ).resolves.toHaveLength(1);
    await expect(
      t.run(async (ctx) =>
        ctx.db.query('productAccountDeletionRequests').collect(),
      ),
    ).resolves.toStrictEqual([]);
  });

  it('rejects an Apple exchange without a recoverable refresh token', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const fetchMock = vi.mocked(fetch);
    fetchMock.mockImplementationOnce(async () =>
      appleAccessTokenOnlyResponse(),
    );
    fetchMock.mockImplementationOnce(async () =>
      Response.json({ keys: [appleIdentitySigningKey] }),
    );
    const fetchCallCount = fetchMock.mock.calls.length;

    await expect(
      asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'recent-apple-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Apple authorization exchange failed');
    expect(fetch).toHaveBeenCalledTimes(fetchCallCount + 2);
    await expect(
      t.run(async (ctx) => ctx.db.query('productAccounts').collect()),
    ).resolves.toHaveLength(1);
  });

  it('retains revocation-only material across retryable Apple failures', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const fetchMock = vi.mocked(fetch);
    fetchMock.mockImplementationOnce(async () => appleTokenResponse());
    fetchMock.mockImplementationOnce(async () =>
      Response.json({ keys: [appleIdentitySigningKey] }),
    );
    fetchMock.mockImplementationOnce(
      async () => new Response(null, { status: 503 }),
    );

    await expect(
      asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'recent-apple-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).rejects.toThrow(
      'Apple authorization revocation is temporarily unavailable',
    );
    await expect(
      t.run(async (ctx) =>
        ctx.db.query('productAccountDeletionRequests').collect(),
      ),
    ).resolves.toMatchObject([
      {
        phase: 'revocation-pending',
        revocationMaterial: {
          kind: 'refresh-token',
          value: 'apple-refresh-token',
        },
      },
    ]);
    await expect(
      asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      }),
    ).resolves.toMatchObject({
      productAccountId: currentDevice.productAccountId,
    });
    fetchMock.mockImplementationOnce(async (input) => {
      expect(input).toBe('https://appleid.apple.com/auth/revoke');
      return new Response(null, { status: 200 });
    });
    await expect(
      asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'replacement-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ deleted: true });
  });

  it.each([429, 503])(
    'retains the deletion attempt when Apple signing keys return %i',
    async (status) => {
      expect.assertions(2);

      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      const fetchMock = vi.mocked(fetch);
      fetchMock.mockImplementationOnce(async () => appleTokenResponse());
      fetchMock.mockImplementationOnce(
        async () => new Response(null, { status }),
      );

      await expect(
        asUser.action(api.productAccountDeletion.deleteProductAccount, {
          authorizationCode: 'recent-apple-authorization-code',
          trustedDeviceId: currentDevice.trustedDeviceId,
        }),
      ).rejects.toThrow(
        'Apple authorization revocation is temporarily unavailable',
      );
      await expect(
        t.run((ctx) =>
          ctx.db.query('productAccountDeletionRequests').collect(),
        ),
      ).resolves.toMatchObject([
        {
          phase: 'revocation-pending',
          revocationMaterial: {
            kind: 'authorization-code',
            value: 'recent-apple-authorization-code',
          },
        },
      ]);
    },
  );

  it('completes deletion when Apple reports a previously attempted revoke as invalid', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const prepared = await asUser.mutation(
      internal.productAccountDeletionData.prepareDeletion,
      {
        attemptId: 'deletion-attempt-001',
        authorizationCode: 'recent-apple-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    const requestId = pendingDeletionRequestId(prepared);
    await asUser.mutation(
      internal.productAccountDeletionData.storeRevocationToken,
      {
        attemptId: 'deletion-attempt-001',
        requestId,
        token: {
          kind: 'refresh-token',
          value: 'already-revoked-refresh-token',
        },
      },
    );
    await asUser.mutation(
      internal.productAccountDeletionData.markRevocationAttemptStarted,
      { attemptId: 'deletion-attempt-001', requestId },
    );
    await asUser.mutation(
      internal.productAccountDeletionData.releaseDeletionAttempt,
      { attemptId: 'deletion-attempt-001', requestId },
    );
    vi.mocked(fetch).mockImplementationOnce(async (input) => {
      expect(input).toBe('https://appleid.apple.com/auth/revoke');
      return Response.json({ error: 'invalid_grant' }, { status: 400 });
    });

    await expect(
      asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'unused-retry-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ deleted: true });
    await expect(
      t.run(async (ctx) => ctx.db.query('productAccounts').collect()),
    ).resolves.toStrictEqual([]);
  });

  it('does not treat an invalid access token as proof of revocation', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const prepared = await asUser.mutation(
      internal.productAccountDeletionData.prepareDeletion,
      {
        attemptId: 'deletion-attempt-001',
        authorizationCode: 'recent-apple-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    const requestId = pendingDeletionRequestId(prepared);
    await asUser.mutation(
      internal.productAccountDeletionData.storeRevocationToken,
      {
        attemptId: 'deletion-attempt-001',
        requestId,
        token: { kind: 'access-token', value: 'expired-access-token' },
      },
    );
    await asUser.mutation(
      internal.productAccountDeletionData.markRevocationAttemptStarted,
      { attemptId: 'deletion-attempt-001', requestId },
    );
    await asUser.mutation(
      internal.productAccountDeletionData.releaseDeletionAttempt,
      { attemptId: 'deletion-attempt-001', requestId },
    );
    vi.mocked(fetch).mockImplementationOnce(async (input) => {
      expect(input).toBe('https://appleid.apple.com/auth/revoke');
      return Response.json({ error: 'invalid_grant' }, { status: 400 });
    });

    await expect(
      asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'unused-retry-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Apple authorization revocation failed');
    await expect(
      t.run(async (ctx) => ctx.db.query('productAccounts').collect()),
    ).resolves.toHaveLength(1);
  });

  it('resumes deletion without retaining or revoking an access token after durable success', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const prepared = await asUser.mutation(
      internal.productAccountDeletionData.prepareDeletion,
      {
        attemptId: 'deletion-attempt-001',
        authorizationCode: 'recent-apple-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    const requestId = pendingDeletionRequestId(prepared);
    await asUser.mutation(
      internal.productAccountDeletionData.storeRevocationToken,
      {
        attemptId: 'deletion-attempt-001',
        requestId,
        token: { kind: 'access-token', value: 'revoked-access-token' },
      },
    );
    await asUser.mutation(
      internal.productAccountDeletionData.markRevocationAttemptStarted,
      { attemptId: 'deletion-attempt-001', requestId },
    );
    await asUser.mutation(
      internal.productAccountDeletionData.markRevocationSucceeded,
      { attemptId: 'deletion-attempt-001', requestId },
    );
    const succeededRequest = await t.run(async (ctx) => ctx.db.get(requestId));
    expect(succeededRequest).not.toHaveProperty('revocationMaterial');
    await expect(
      asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-002',
        platform: 'ios',
      }),
    ).rejects.toMatchObject({ data: { code: 'PRODUCT_ACCOUNT_DELETED' } });
    await asUser.mutation(
      internal.productAccountDeletionData.releaseDeletionAttempt,
      { attemptId: 'deletion-attempt-001', requestId },
    );

    const fetchCallCount = vi.mocked(fetch).mock.calls.length;
    await expect(
      asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'unused-retry-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ deleted: true });
    expect(fetch).toHaveBeenCalledTimes(fetchCallCount);
    await expect(
      t.run(async (ctx) => ctx.db.query('productAccounts').collect()),
    ).resolves.toStrictEqual([]);
  });

  it('resumes a previously attempted Apple revocation without a client', async () => {
    expect.assertions(3);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      const prepared = await asUser.mutation(
        internal.productAccountDeletionData.prepareDeletion,
        {
          attemptId: 'deletion-attempt-001',
          authorizationCode: 'recent-apple-authorization-code',
          trustedDeviceId: currentDevice.trustedDeviceId,
        },
      );
      const requestId = pendingDeletionRequestId(prepared);
      await asUser.mutation(
        internal.productAccountDeletionData.storeRevocationToken,
        {
          attemptId: 'deletion-attempt-001',
          requestId,
          token: {
            kind: 'refresh-token',
            value: 'already-revoked-refresh-token',
          },
        },
      );
      vi.mocked(fetch).mockImplementationOnce(async (input) => {
        expect(input).toBe('https://appleid.apple.com/auth/revoke');
        return Response.json({ error: 'invalid_grant' }, { status: 400 });
      });

      await asUser.mutation(
        internal.productAccountDeletionData.markRevocationAttemptStarted,
        { attemptId: 'deletion-attempt-001', requestId },
      );
      await t.finishAllScheduledFunctions(() => vi.advanceTimersByTime(60_000));

      await expect(
        t.run(async (ctx) => ctx.db.query('productAccounts').collect()),
      ).resolves.toStrictEqual([]);
      await expect(
        t.run(async (ctx) =>
          ctx.db.query('productAccountDeletionRequests').collect(),
        ),
      ).resolves.toStrictEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('schedules durable cleanup with the revocation-complete transition', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      const prepared = await asUser.mutation(
        internal.productAccountDeletionData.prepareDeletion,
        {
          attemptId: 'deletion-attempt-001',
          authorizationCode: 'recent-apple-authorization-code',
          trustedDeviceId: currentDevice.trustedDeviceId,
        },
      );
      const requestId = pendingDeletionRequestId(prepared);

      await asUser.mutation(
        internal.productAccountDeletionData.markRevocationComplete,
        { attemptId: 'deletion-attempt-001', requestId },
      );
      await t.finishAllScheduledFunctions(vi.runAllTimers);

      await expect(
        t.run(async (ctx) => ctx.db.query('productAccounts').collect()),
      ).resolves.toStrictEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('commits the revocation fence before draining push routes in batches', async () => {
    expect.assertions(4);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.patch(currentDevice.trustedDeviceId, {
        apnsEnvironment: 'production',
        apnsToken: 'device-token',
        apnsTokenRegisteredAt: now,
      });
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        lastVerifiedAt: now,
        productAccountId: currentDevice.productAccountId,
        provider: 'gmail',
        trustedDeviceId: currentDevice.trustedDeviceId,
        updatedAt: now,
      });
      for (let index = 0; index < 5; index += 1) {
        await ctx.db.insert('encryptedProductSyncPayloads', {
          encryptedPayload,
          payloadIdentifier: `payload-${index}`,
          productAccountId: currentDevice.productAccountId,
          trustedDeviceId: currentDevice.trustedDeviceId,
          updatedAt: now,
          writtenAt: now,
        });
      }
    });
    const prepared = await asUser.mutation(
      internal.productAccountDeletionData.prepareDeletion,
      {
        attemptId: 'deletion-attempt-001',
        authorizationCode: 'recent-apple-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    const requestId = pendingDeletionRequestId(prepared);
    await asUser.mutation(
      internal.productAccountDeletionData.markRevocationComplete,
      { attemptId: 'deletion-attempt-001', requestId },
    );

    await expect(
      t.run(async (ctx) => ctx.db.query('mailProviderConnections').collect()),
    ).resolves.toHaveLength(1);
    await expect(
      t.run(async (ctx) => ctx.db.query('trustedDevices').collect()),
    ).resolves.toHaveLength(1);
    await expect(
      t.run(async (ctx) =>
        ctx.db.query('encryptedProductSyncPayloads').collect(),
      ),
    ).resolves.toHaveLength(5);
    await expect(
      asUser.mutation(internal.productAccountDeletionData.deleteNextBatch, {
        requestId,
      }),
    ).resolves.toStrictEqual({ complete: false });
  });

  it('authenticates every retry of an existing deletion request', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
      supportsDeviceCredentials: true,
    });
    const otherDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
      supportsDeviceCredentials: true,
    });
    const trustedDeviceCredential =
      requiredTrustedDeviceCredential(currentDevice);
    await expect(
      asUser.mutation(internal.productAccountDeletionData.prepareDeletion, {
        attemptId: 'deletion-attempt-001',
        authorizationCode: 'recent-apple-authorization-code',
        trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toMatchObject({ state: 'pending' });

    await expect(
      asUser.mutation(internal.productAccountDeletionData.prepareDeletion, {
        attemptId: 'deletion-attempt-002',
        authorizationCode: 'replacement-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Reconnect this Trusted Device');
    await expect(
      asUser.mutation(internal.productAccountDeletionData.prepareDeletion, {
        attemptId: 'deletion-attempt-002',
        authorizationCode: 'replacement-authorization-code',
        trustedDeviceCredential: 'malformed',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Reconnect this Trusted Device');
    await expect(
      asUser.mutation(internal.productAccountDeletionData.prepareDeletion, {
        attemptId: 'deletion-attempt-002',
        authorizationCode: 'replacement-authorization-code',
        trustedDeviceCredential,
        trustedDeviceId: otherDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Reconnect this Trusted Device');

    await t.run(async (ctx) => {
      await ctx.db.insert('revokedTrustedDevices', {
        deviceIdentifier: 'device-001',
        productAccountId: currentDevice.productAccountId,
        productSyncKeyEpoch: 1,
        revokedAt: Date.now(),
        trustedDeviceId: currentDevice.trustedDeviceId,
      });
      await ctx.db.delete(currentDevice.trustedDeviceId);
    });
    await expect(
      asUser.mutation(internal.productAccountDeletionData.prepareDeletion, {
        attemptId: 'deletion-attempt-002',
        authorizationCode: 'replacement-authorization-code',
        trustedDeviceCredential,
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).rejects.toMatchObject({ data: { code: 'TRUSTED_DEVICE_REVOKED' } });
  });

  it('rejects a deletion retry after its trusted device was already removed', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const prepared = await asUser.mutation(
      internal.productAccountDeletionData.prepareDeletion,
      {
        attemptId: 'deletion-attempt-001',
        authorizationCode: 'recent-apple-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    expect(prepared).toMatchObject({ state: 'pending' });
    const requestId = pendingDeletionRequestId(prepared);
    await asUser.mutation(
      internal.productAccountDeletionData.markRevocationComplete,
      { attemptId: 'deletion-attempt-001', requestId },
    );
    await asUser.mutation(internal.productAccountDeletionData.deleteNextBatch, {
      requestId,
    });
    await expect(
      t.run(async (ctx) => ctx.db.query('trustedDevices').collect()),
    ).resolves.toStrictEqual([]);
    await expect(
      asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'unused-retry-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
  });

  it('does not let a superseded revocation attempt cancel deletion', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const first = await asUser.mutation(
      internal.productAccountDeletionData.prepareDeletion,
      {
        attemptId: 'deletion-attempt-001',
        authorizationCode: 'recent-apple-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    expect(first).toMatchObject({ state: 'pending' });
    const requestId = pendingDeletionRequestId(first);
    await asUser.mutation(
      internal.productAccountDeletionData.releaseDeletionAttempt,
      { attemptId: 'deletion-attempt-001', requestId },
    );
    const second = await asUser.mutation(
      internal.productAccountDeletionData.prepareDeletion,
      {
        attemptId: 'deletion-attempt-002',
        authorizationCode: 'replacement-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      },
    );
    expect(second).toMatchObject({ state: 'pending' });
    await asUser.mutation(internal.productAccountDeletionData.abortDeletion, {
      attemptId: 'deletion-attempt-001',
      requestId,
    });
    await expect(
      t.run(async (ctx) =>
        ctx.db.query('productAccountDeletionRequests').collect(),
      ),
    ).resolves.toHaveLength(1);
  });

  it('does not let revocation recovery abort a newer foreground attempt', async () => {
    expect.assertions(3);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      const first = await asUser.mutation(
        internal.productAccountDeletionData.prepareDeletion,
        {
          attemptId: 'deletion-attempt-001',
          authorizationCode: 'recent-apple-authorization-code',
          trustedDeviceId: currentDevice.trustedDeviceId,
        },
      );
      const requestId = pendingDeletionRequestId(first);
      await asUser.mutation(
        internal.productAccountDeletionData.storeRevocationToken,
        {
          attemptId: 'deletion-attempt-001',
          requestId,
          token: { kind: 'access-token', value: 'apple-access-token' },
        },
      );
      await asUser.mutation(
        internal.productAccountDeletionData.markRevocationAttemptStarted,
        { attemptId: 'deletion-attempt-001', requestId },
      );
      await asUser.mutation(
        internal.productAccountDeletionData.releaseDeletionAttempt,
        { attemptId: 'deletion-attempt-001', requestId },
      );
      await expect(
        asUser.mutation(
          internal.productAccountDeletionData.prepareRevocationRecovery,
          { attemptId: 'recovery-attempt', requestId },
        ),
      ).resolves.toMatchObject({
        token: { kind: 'access-token', value: 'apple-access-token' },
      });

      vi.setSystemTime(Date.now() + 60_001);
      await expect(
        asUser.mutation(internal.productAccountDeletionData.prepareDeletion, {
          attemptId: 'deletion-attempt-002',
          authorizationCode: 'replacement-authorization-code',
          trustedDeviceId: currentDevice.trustedDeviceId,
        }),
      ).resolves.toMatchObject({ state: 'pending' });
      await asUser.mutation(
        internal.productAccountDeletionData.abortRecoveredRevocation,
        { attemptId: 'recovery-attempt', requestId },
      );

      await expect(
        t.run(async (ctx) => ctx.db.get(requestId)),
      ).resolves.toMatchObject({ activeAttemptId: 'deletion-attempt-002' });
    } finally {
      vi.useRealTimers();
    }
  });

  it('preserves an active deletion attempt when the request lifetime expires', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const device = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      const prepared = await asUser.mutation(
        internal.productAccountDeletionData.prepareDeletion,
        {
          attemptId: 'deletion-attempt-001',
          authorizationCode: 'recent-apple-authorization-code',
          trustedDeviceId: device.trustedDeviceId,
        },
      );
      const requestId = pendingDeletionRequestId(prepared);
      await asUser.mutation(
        internal.productAccountDeletionData.storeRevocationToken,
        {
          attemptId: 'deletion-attempt-001',
          requestId,
          token: { kind: 'access-token', value: 'apple-access-token' },
        },
      );
      await asUser.mutation(
        internal.productAccountDeletionData.markRevocationAttemptStarted,
        { attemptId: 'deletion-attempt-001', requestId },
      );

      vi.setSystemTime(Date.now() + 24 * 60 * 60 * 1000);
      await asUser.mutation(
        internal.productAccountDeletionData.prepareDeletion,
        {
          attemptId: 'deletion-attempt-002',
          authorizationCode: 'replacement-authorization-code',
          trustedDeviceId: device.trustedDeviceId,
        },
      );
      await asUser.mutation(
        internal.productAccountDeletionData.scheduleRevocationRecovery,
        { requestId },
      );

      await expect(
        t.run(async (ctx) => ctx.db.get(requestId)),
      ).resolves.toMatchObject({
        activeAttemptId: 'deletion-attempt-002',
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it('expires a stalled authorization code after the request lifetime', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const device = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      const prepared = await asUser.mutation(
        internal.productAccountDeletionData.prepareDeletion,
        {
          attemptId: 'deletion-attempt-001',
          authorizationCode: 'recent-apple-authorization-code',
          trustedDeviceId: device.trustedDeviceId,
        },
      );
      const requestId = pendingDeletionRequestId(prepared);
      await asUser.mutation(
        internal.productAccountDeletionData.releaseDeletionAttempt,
        { attemptId: 'deletion-attempt-001', requestId },
      );

      vi.setSystemTime(Date.now() + 24 * 60 * 60 * 1000);
      await asUser.mutation(
        internal.productAccountDeletionData.scheduleRevocationRecovery,
        { requestId },
      );

      await expect(
        t.run(async (ctx) => ctx.db.get(requestId)),
      ).resolves.toBeNull();
    } finally {
      vi.useRealTimers();
    }
  });

  it('preserves an ambiguous revocation attempt after the request lifetime', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const device = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      const prepared = await asUser.mutation(
        internal.productAccountDeletionData.prepareDeletion,
        {
          attemptId: 'deletion-attempt-001',
          authorizationCode: 'recent-apple-authorization-code',
          trustedDeviceId: device.trustedDeviceId,
        },
      );
      const requestId = pendingDeletionRequestId(prepared);
      await asUser.mutation(
        internal.productAccountDeletionData.storeRevocationToken,
        {
          attemptId: 'deletion-attempt-001',
          requestId,
          token: { kind: 'access-token', value: 'apple-access-token' },
        },
      );
      await asUser.mutation(
        internal.productAccountDeletionData.markRevocationAttemptStarted,
        { attemptId: 'deletion-attempt-001', requestId },
      );
      await asUser.mutation(
        internal.productAccountDeletionData.releaseDeletionAttempt,
        { attemptId: 'deletion-attempt-001', requestId },
      );

      vi.setSystemTime(Date.now() + 24 * 60 * 60 * 1000);
      await asUser.mutation(
        internal.productAccountDeletionData.scheduleRevocationRecovery,
        { requestId },
      );

      await expect(
        t.run(async (ctx) => ctx.db.get(requestId)),
      ).resolves.toMatchObject({
        phase: 'revocation-pending',
        revocationAttemptedAt: expect.any(Number),
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it('expires a durable revocation token stored before the attempt marker', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const device = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      const prepared = await asUser.mutation(
        internal.productAccountDeletionData.prepareDeletion,
        {
          attemptId: 'deletion-attempt-001',
          authorizationCode: 'recent-apple-authorization-code',
          trustedDeviceId: device.trustedDeviceId,
        },
      );
      const requestId = pendingDeletionRequestId(prepared);
      await asUser.mutation(
        internal.productAccountDeletionData.storeRevocationToken,
        {
          attemptId: 'deletion-attempt-001',
          requestId,
          token: { kind: 'access-token', value: 'apple-access-token' },
        },
      );

      vi.setSystemTime(Date.now() + 24 * 60 * 60 * 1000);
      await t.finishAllScheduledFunctions(vi.runAllTimers);

      await expect(
        t.run(async (ctx) => ctx.db.get(requestId)),
      ).resolves.toBeNull();
    } finally {
      vi.useRealTimers();
    }
  });

  it('rejects an Apple authorization code for another identity', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    vi.mocked(fetch).mockImplementationOnce(async () =>
      appleTokenResponse('apple-user-002'),
    );

    await expect(
      asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'other-users-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Recent authentication must match the Product Account');
    await expect(
      t.run(async (ctx) => ctx.db.query('productAccounts').collect()),
    ).resolves.toHaveLength(1);
  });

  it('rejects an Apple identity token with an invalid signature', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const token = appleIdToken(appleIdentity.subject);
    const [header, claims] = token.split('.');
    const invalidSignature = Buffer.alloc(256).toString('base64url');
    const invalidToken = `${header}.${claims}.${invalidSignature}`;
    vi.mocked(fetch).mockImplementationOnce(async () =>
      Response.json({
        access_token: 'apple-access-token',
        id_token: invalidToken,
        token_type: 'Bearer',
      }),
    );

    await expect(
      asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'invalid-signature-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Apple authorization exchange failed');
    await expect(
      t.run(async (ctx) => ctx.db.query('productAccounts').collect()),
    ).resolves.toHaveLength(1);
  });
});
