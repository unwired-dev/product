/// <reference types="vite/client" />

import { createHash, generateKeyPairSync, sign } from 'node:crypto';

import type { TestConvex } from 'convex-test';

import { convexTest } from 'convex-test';

import type { Id } from '../convex/_generated/dataModel.js';

import { api, internal } from '../convex/_generated/api.js';
import { env } from '../convex/_generated/server.js';
import { opaqueGmailConnectionId } from '../convex/gmailRouting.js';
import { gmailLegacyRouteFallbackLimit } from '../convex/productAccount.js';
import schema from '../convex/schema.js';
import {
  connectTrusted,
  deviceEncryptionPublicKey,
  pendingConnection,
  preparedRemoval,
  recoveryVerifier,
  replacementRecoveryVerifier,
} from './devices.js';

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

function appleIdToken(subject: string, audience = 'dev.unwired.mail'): string {
  const header = Buffer.from(
    JSON.stringify({ alg: 'RS256', kid: 'apple-identity-test-key' }),
  ).toString('base64url');
  const claims = Buffer.from(
    JSON.stringify({
      aud: audience,
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

function appleTokenResponse(
  subject = appleIdentity.subject,
  audience?: string,
): Response {
  return Response.json({
    access_token: 'apple-access-token',
    expires_in: 3600,
    id_token: appleIdToken(subject, audience),
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
  appleSignInPrivateKey.export({ format: 'pem', type: 'pkcs8' }).toString(),
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

function appleIdentityToken(issuedAt: number): string {
  const encode = (value: Readonly<Record<string, unknown>>) =>
    Buffer.from(JSON.stringify(value), 'utf8').toString('base64url');
  return `${encode({ alg: 'RS256', kid: 'apple-key-fixture' })}.${encode({
    aud: 'dev.unwired.mail',
    exp: issuedAt + 600,
    iat: issuedAt,
    iss: appleIdentity.issuer,
    sub: appleIdentity.subject,
  })}.signature`;
}

// Convex omits iat from the identity, so freshness comes only from the bearer token.
async function postRevocation(
  asUser: ReturnType<ReturnType<typeof convexTest>['withIdentity']>,
  body: Readonly<Record<string, unknown>>,
  issuedAt = Math.floor(Date.now() / 1000),
): Promise<Response> {
  return asUser.fetch('/trusted-devices/revoke', {
    body: JSON.stringify(body),
    headers: {
      authorization: `Bearer ${appleIdentityToken(issuedAt)}`,
      'content-type': 'application/json',
    },
    method: 'POST',
  });
}

async function revokeTrustedDevice(
  asUser: ReturnType<ReturnType<typeof convexTest>['withIdentity']>,
  body: Readonly<Record<string, unknown>>,
  issuedAt?: number,
): Promise<unknown> {
  const response = await postRevocation(asUser, body, issuedAt);
  if (!response.ok) {
    throw new Error(`${response.status} ${await response.text()}`);
  }
  return response.json();
}

const recoveryEnvelope = {
  ...encryptedPayload,
  ciphertextBase64: 'cmVjb3Zlcnk',
  schemaVersion: 3,
};

function deviceProof(
  connection: Readonly<{
    trustedDeviceCredential?: string;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
): Readonly<{
  trustedDeviceCredential?: string;
  trustedDeviceId: Id<'trustedDevices'>;
}> {
  return {
    trustedDeviceCredential: connection.trustedDeviceCredential,
    trustedDeviceId: connection.trustedDeviceId,
  };
}

// An initialized Product Account whose devices each bound an encryption key, as setup and
// enrollment do. The first device created the account's keys.
async function rotationAccount(
  installations: readonly string[] = ['device-001', 'device-002', 'device-003'],
  {
    identity = appleIdentity,
    t = convexTest(schema, modules),
  }: Readonly<{
    identity?: Readonly<{
      issuer: string;
      subject: string;
      tokenIdentifier: string;
    }>;
    t?: TestConvex<typeof schema>;
  }> = {},
) {
  const asUser = t.withIdentity(identity);
  const devices: Array<ReturnType<typeof deviceProof>> = [];
  for (const deviceIdentifier of installations) {
    const connection = await connectTrusted(t, asUser, {
      deviceIdentifier,
      platform: 'ios',
      supportsDeviceCredentials: true,
    });
    devices.push(deviceProof(connection));
    if (devices.length === 1) {
      await asUser.mutation(api.productSync.initialize, {
        ...devices[0]!,
        deviceEncryptionPublicKey: deviceEncryptionPublicKey(deviceIdentifier),
        encryptedPayload: recoveryEnvelope,
        recoveryVerifier,
      });
    }
  }
  const productAccountId = await t.run(
    async (ctx) =>
      (await ctx.db.get('trustedDevices', devices[0]!.trustedDeviceId))!
        .productAccountId,
  );
  return { asUser, devices, productAccountId, t };
}

// Everything a removal changes, so a refused one can be shown to have changed nothing.
async function rotationState(
  t: TestConvex<typeof schema>,
  productAccountId: Id<'productAccounts'>,
) {
  return t.run(async (ctx) => {
    const [account, devices, envelopes, receipts, recovery, revoked] =
      await Promise.all([
        ctx.db.get('productAccounts', productAccountId),
        ctx.db
          .query('trustedDevices')
          .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
            q.eq('productAccountId', productAccountId),
          )
          .collect(),
        ctx.db.query('productSyncKeyEnvelopes').collect(),
        ctx.db.query('productSyncKeyRotationProposals').collect(),
        ctx.db
          .query('encryptedProductSyncPayloads')
          .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
            q
              .eq('productAccountId', productAccountId)
              .eq('payloadIdentifier', 'product-account-recovery-v1'),
          )
          .unique(),
        ctx.db
          .query('revokedTrustedDevices')
          .withIndex('by_productAccountId_and_trustedDeviceId', (q) =>
            q.eq('productAccountId', productAccountId),
          )
          .collect(),
      ]);
    return {
      account,
      devices: devices.map(({ _id, productSyncKeyEpoch }) => [
        _id,
        productSyncKeyEpoch,
      ]),
      envelopes: envelopes
        .filter((envelope) => envelope.productAccountId === productAccountId)
        .map(
          ({
            ciphertextBase64,
            encapsulatedKeyBase64,
            keyEpoch,
            trustedDeviceId,
          }) => ({
            ciphertextBase64,
            encapsulatedKeyBase64,
            keyEpoch,
            trustedDeviceId,
          }),
        ),
      receipts: receipts.filter(
        (receipt) => receipt.productAccountId === productAccountId,
      ),
      recovery,
      revoked: revoked.map(({ productSyncKeyEpoch, trustedDeviceId }) => [
        trustedDeviceId,
        productSyncKeyEpoch,
      ]),
    };
  });
}

const googleIdentity = {
  issuer: 'https://accounts.google.com',
  subject: 'google-user-001',
  tokenIdentifier: 'https://accounts.google.com|google-user-001',
};

// Convex omits iat from the identity, so freshness comes only from the bearer token.
async function deleteRecentlyAuthenticated(
  asUser: ReturnType<ReturnType<typeof convexTest>['withIdentity']>,
  args: Readonly<Record<string, unknown>>,
  {
    identity = googleIdentity,
    issuedAt = Math.floor(Date.now() / 1000),
  }: Readonly<{
    identity?: Readonly<{ issuer: string; subject: string }>;
    issuedAt?: number;
  }> = {},
): Promise<Response> {
  const encode = (value: Readonly<Record<string, unknown>>) =>
    Buffer.from(JSON.stringify(value), 'utf8').toString('base64url');
  const token = `${encode({ alg: 'RS256' })}.${encode({
    iat: issuedAt,
    iss: identity.issuer,
    sub: identity.subject,
  })}.signature`;
  return asUser.fetch('/product-account/delete', {
    body: JSON.stringify(args),
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
    },
    method: 'POST',
  });
}

async function storedAccountData(t: ReturnType<typeof convexTest>) {
  return t.run(async (ctx) => {
    const [accounts, linked, payloads, tombstones] = await Promise.all([
      ctx.db.query('productAccounts').collect(),
      ctx.db.query('linkedSignIns').collect(),
      ctx.db.query('encryptedProductSyncPayloads').collect(),
      ctx.db.query('productAccountDeletionTombstones').collect(),
    ]);
    return {
      accounts: accounts.length,
      linked: linked.length,
      payloads: payloads.length,
      tombstones: tombstones.length,
    };
  });
}

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

describe('productAccount.connect', () => {
  it('preserves a valid device credential without exposing it in device summaries', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const firstConnect = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
      supportsDeviceCredentials: true,
    });
    const firstCredential = requiredTrustedDeviceCredential(firstConnect);

    expect(firstCredential).toMatch(/^[0-9a-f]{64}$/u);
    const storedDevice = await t.run((ctx) =>
      ctx.db.get('trustedDevices', firstConnect.trustedDeviceId),
    );
    expect(storedDevice?.credentialDigest).toMatch(/^[0-9a-f]{64}$/u);
    expect(storedDevice?.credentialDigest).toBe(
      createHash('sha256').update(firstCredential).digest('hex'),
    );

    const secondConnect = await connectTrusted(t, asUser, {
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
    const revokedDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-revoked',
      platform: 'ios',
      supportsDeviceCredentials: true,
    });
    const survivingDevice = await connectTrusted(t, asUser, {
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
      await ctx.db.delete('trustedDevices', revokedDevice.trustedDeviceId);
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
    const firstDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const legacyDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
      supportsDeviceCredentials: true,
    });

    await expect(
      asUser.query(api.productAccount.listTrustedDevices, {
        trustedDeviceId: legacyDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Reconnect this Trusted Device');
    const reconnected = await connectTrusted(t, asUser, {
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

    const firstConnect = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    expect(firstConnect).toMatchObject({
      accountCreated: true,
      deviceRegistered: true,
      productSyncMaterialInitialized: false,
    });

    const secondConnect = await connectTrusted(t, asUser, {
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

    const firstConnect = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    const resumedConnect = await connectTrusted(t, asUser, {
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
    const currentDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      deviceName: 'Jans iPhone',
      platform: 'ios',
    });
    const otherDevice = await connectTrusted(t, asUser, {
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
    const currentDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await connectTrusted(t, asUser, {
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
    const currentDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await connectTrusted(t, asOtherUser, {
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

  /* oxlint-disable vitest/max-expects -- Each removal journey proves one atomic transition and that refusals change nothing. */
  it('requires recent authentication from the bearer token to revoke a trusted device', async () => {
    expect.assertions(3);

    const { asUser, devices, productAccountId, t } = await rotationAccount();
    const [initiator, target] = devices;
    const body = await preparedRemoval(t, initiator!, target!.trustedDeviceId);
    const before = await rotationState(t, productAccountId);
    const missingToken = await asUser.fetch('/trusted-devices/revoke', {
      body: JSON.stringify(body),
      headers: { 'content-type': 'application/json' },
      method: 'POST',
    });

    expect(missingToken.status).toBe(401);
    await expect(
      revokeTrustedDevice(asUser, body, Math.floor(Date.now() / 1000) - 301),
    ).rejects.toThrow('401 Recent authentication required');
    await expect(rotationState(t, productAccountId)).resolves.toStrictEqual(
      before,
    );
  });

  it('rejects a malformed revocation request from a recently authenticated device', async () => {
    expect.assertions(2);

    const asUser = convexTest(schema, modules).withIdentity(appleIdentity);
    const statuses = await Promise.all(
      ['not-json', JSON.stringify({ trustedDeviceId: 'device' })].map(
        async (body) => {
          const response = await asUser.fetch('/trusted-devices/revoke', {
            body,
            headers: {
              authorization: `Bearer ${appleIdentityToken(Math.floor(Date.now() / 1000))}`,
              'content-type': 'application/json',
            },
            method: 'POST',
          });
          return response.status;
        },
      ),
    );

    expect(statuses[0]).toBe(400);
    expect(statuses[1]).toBe(400);
  });

  it('rejects revoking the current trusted device while allowing bounded clock skew', async () => {
    expect.assertions(1);

    const { asUser, devices, t } = await rotationAccount(['device-001']);
    const [initiator] = devices;

    await expect(
      revokeTrustedDevice(
        asUser,
        await preparedRemoval(t, initiator!, initiator!.trustedDeviceId),
        Math.floor(Date.now() / 1000) + 5,
      ),
    ).rejects.toThrow('Use sign out to remove the current Trusted Device');
  });

  it('rejects trusted-device revocation beyond the accepted future clock skew', async () => {
    expect.assertions(1);

    const { asUser, devices, t } = await rotationAccount();
    const [initiator, target] = devices;

    await expect(
      revokeTrustedDevice(
        asUser,
        await preparedRemoval(t, initiator!, target!.trustedDeviceId),
        Math.floor(Date.now() / 1000) + 3600,
      ),
    ).rejects.toThrow('401 Recent authentication required');
  });

  it('rejects revoking a trusted device owned by another Product Account', async () => {
    expect.assertions(1);

    const { asUser, devices, t } = await rotationAccount(['device-001']);
    const otherDevice = await connectTrusted(
      t,
      t.withIdentity({
        issuer: 'https://appleid.apple.com',
        subject: 'apple-user-002',
        tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
      }),
      { deviceIdentifier: 'device-002', platform: 'macos' },
    );

    await expect(
      revokeTrustedDevice(
        asUser,
        await preparedRemoval(t, devices[0]!, otherDevice.trustedDeviceId),
      ),
    ).rejects.toThrow('403 Trusted device required');
  });

  it('atomically removes a device, activates the new epoch with exact survivor envelopes and replaces the Recovery Key', async () => {
    expect.hasAssertions();

    const { asUser, devices, productAccountId, t } = await rotationAccount();
    const [initiator, target, survivor] = devices;
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.patch('trustedDevices', target!.trustedDeviceId, {
        apnsEnvironment: 'production',
        apnsToken: 'revoked-device-token',
        apnsTokenRegisteredAt: now,
      });
      await ctx.db.insert('devicePushRouteHeartbeats', {
        refreshedAt: now,
        trustedDeviceId: target!.trustedDeviceId,
      });
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        lastVerifiedAt: now,
        productAccountId,
        provider: 'gmail',
        trustedDeviceId: target!.trustedDeviceId,
        updatedAt: now,
      });
    });
    const before = await rotationState(t, productAccountId);
    const body = await preparedRemoval(t, initiator!, target!.trustedDeviceId);

    await expect(revokeTrustedDevice(asUser, body)).resolves.toStrictEqual({
      keyEpoch: 2,
    });
    const after = await rotationState(t, productAccountId);
    expect(after).toMatchObject({
      account: {
        productSyncKeyEpoch: 2,
        productSyncRecoveryProposalId: body.proposalId,
        productSyncRecoveryVerifier: replacementRecoveryVerifier,
      },
      devices: [
        [initiator!.trustedDeviceId, 2],
        [survivor!.trustedDeviceId, 1],
      ],
      envelopes: body.keyEnvelopes.map(
        ({ ciphertextBase64, encapsulatedKeyBase64, trustedDeviceId }) => ({
          ciphertextBase64,
          encapsulatedKeyBase64,
          keyEpoch: 2,
          trustedDeviceId,
        }),
      ),
      receipts: [
        {
          initiatorTrustedDeviceId: initiator!.trustedDeviceId,
          keyEpoch: 2,
          proposalId: body.proposalId,
          trustedDeviceToRevokeId: target!.trustedDeviceId,
        },
      ],
      recovery: {
        encryptedPayload: body.recoveryWrappedAccountKey,
        trustedDeviceId: initiator!.trustedDeviceId,
      },
      revoked: [[target!.trustedDeviceId, 2]],
    });
    // The survivors are exactly the initiator and the other remaining device.
    expect(
      after.envelopes.map(({ trustedDeviceId }) => trustedDeviceId),
    ).toStrictEqual([initiator!.trustedDeviceId, survivor!.trustedDeviceId]);
    expect(after.recovery!.updatedAt).toBeGreaterThan(
      before.recovery!.updatedAt,
    );
    await expect(
      t.run(async (ctx) => ({
        heartbeats: await ctx.db.query('devicePushRouteHeartbeats').collect(),
        routes: await ctx.db.query('mailProviderConnections').collect(),
      })),
    ).resolves.toStrictEqual({ heartbeats: [], routes: [] });
    await expect(
      asUser.query(api.productAccount.listTrustedDevices, target!),
    ).rejects.toMatchObject({ data: { code: 'TRUSTED_DEVICE_REVOKED' } });
    await expect(
      asUser.query(api.productAccount.getProductSyncKeyRotation, target!),
    ).rejects.toMatchObject({ data: { code: 'TRUSTED_DEVICE_REVOKED' } });
    await expect(
      connectTrusted(t, asUser, {
        deviceIdentifier: 'device-002',
        platform: 'macos',
      }),
    ).rejects.toMatchObject({ data: { code: 'TRUSTED_DEVICE_REVOKED' } });
    // A removed device that mints a new identifier waits like any other Pending Device.
    await expect(
      asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-reenrollment-attempt',
        platform: 'macos',
      }),
    ).resolves.toMatchObject({ pendingDeviceId: expect.any(String) });
    // The removed device's credential still learns of its removal, and nothing else.
    await expect(
      t.query(api.productAccount.isTrustedDeviceRevoked, {
        productAccountId,
        trustedDeviceCredential: target!.trustedDeviceCredential!,
        trustedDeviceId: target!.trustedDeviceId,
      }),
    ).resolves.toBe(true);
  });

  it('fences writes sealed under the previous epoch immediately while current-epoch writes keep their compare-and-set', async () => {
    expect.hasAssertions();

    const { asUser, devices, t } = await rotationAccount();
    const [initiator, target, survivor] = devices;
    const written = await asUser.mutation(
      api.productSync.putEncryptedPayloadIfUnchanged,
      {
        ...survivor!,
        encryptedPayload,
        payloadIdentifier: 'mailbox.preferences',
      },
    );
    await revokeTrustedDevice(
      asUser,
      await preparedRemoval(t, initiator!, target!.trustedDeviceId),
    );
    const rotationRequired = {
      data: { code: 'PRODUCT_SYNC_KEY_ROTATION_REQUIRED' },
    };
    const rotated = { ...encryptedPayload, keyVersion: 2 };

    // Neither the initiator nor a device that has not adopted the new ring writes the old epoch.
    for (const device of [initiator!, survivor!]) {
      await expect(
        asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
          ...device,
          encryptedPayload,
          expectedUpdatedAt: written.updatedAt,
          payloadIdentifier: 'mailbox.preferences',
        }),
      ).rejects.toMatchObject(rotationRequired);
    }
    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadsAtomically, {
        ...survivor!,
        checks: [],
        deletes: [],
        writes: [{ encryptedPayload, payloadIdentifier: 'mailbox.other' }],
      }),
    ).rejects.toMatchObject(rotationRequired);
    // A resealed write still loses to a newer record, then wins against the current one.
    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
        ...survivor!,
        encryptedPayload: rotated,
        expectedUpdatedAt: written.updatedAt - 1,
        payloadIdentifier: 'mailbox.preferences',
      }),
    ).resolves.toMatchObject({
      encryptedPayload,
      updatedAt: written.updatedAt,
    });
    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
        ...survivor!,
        encryptedPayload: rotated,
        expectedUpdatedAt: written.updatedAt,
        payloadIdentifier: 'mailbox.preferences',
      }),
    ).resolves.toMatchObject({ encryptedPayload: rotated });
  });

  it.each(['live', 'unregistered', 'reconnected'])(
    'tells only the revoked device holding its credential that it was revoked, without a sign-in (target state: %s)',
    async (targetState) => {
      expect.assertions(4);

      const { asUser, devices, productAccountId, t } = await rotationAccount();
      const [currentDevice, otherDevice] = devices;
      let observedDevice = otherDevice!;
      const status = (credential: string) =>
        t.query(api.productAccount.isTrustedDeviceRevoked, {
          productAccountId,
          trustedDeviceCredential: credential,
          trustedDeviceId: observedDevice.trustedDeviceId,
        });
      await expect(status(otherDevice!.trustedDeviceCredential!)).resolves.toBe(
        false,
      );
      // oxlint-disable-next-line vitest/no-conditional-in-test -- Both live and unregistered target states exercise the same revocation-proof contract.
      if (targetState !== 'live') {
        await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
          ...otherDevice!,
          deviceIdentifier: 'device-002',
        });
      }
      // oxlint-disable-next-line vitest/no-conditional-in-test -- A cached revocation target can reconnect before its owner removes it.
      if (targetState === 'reconnected') {
        observedDevice = deviceProof(
          await connectTrusted(t, asUser, {
            deviceIdentifier: 'device-002',
            platform: 'macos',
            supportsDeviceCredentials: true,
          }),
        );
      }
      await revokeTrustedDevice(
        asUser,
        await preparedRemoval(t, currentDevice!, otherDevice!.trustedDeviceId),
      );
      await expect(
        status(observedDevice.trustedDeviceCredential!),
      ).resolves.toBe(true);
      // Neither another credential nor a malformed id learns anything.
      await expect(
        status(currentDevice!.trustedDeviceCredential!),
      ).resolves.toBe(false);
      await expect(
        t.query(api.productAccount.isTrustedDeviceRevoked, {
          productAccountId: 'not-an-account',
          trustedDeviceCredential: observedDevice.trustedDeviceCredential!,
          trustedDeviceId: otherDevice!.trustedDeviceId,
        }),
      ).resolves.toBe(false);
    },
  );

  it('refuses material that could never activate, changing nothing', async () => {
    expect.hasAssertions();

    const { asUser, devices, productAccountId, t } = await rotationAccount();
    const [initiator, target] = devices;
    const pending = pendingConnection(
      await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-pending',
        platform: 'ios',
        supportsDeviceCredentials: true,
      }),
    );
    const body = await preparedRemoval(t, initiator!, target!.trustedDeviceId);
    const [initiatorEnvelope, survivorEnvelope] = body.keyEnvelopes;
    const invalid: ReadonlyArray<Readonly<Record<string, unknown>>> = [
      // Prototype schemas 1 and 2 are never opened by the replacement.
      ...[1, 2].map((schemaVersion) => ({
        recoveryWrappedAccountKey: {
          ...body.recoveryWrappedAccountKey,
          schemaVersion,
        },
      })),
      {
        recoveryWrappedAccountKey: {
          ...body.recoveryWrappedAccountKey,
          keyVersion: 1,
        },
      },
      { proposalId: 'not-a-proposal' },
      { recoveryVerifier: 'not-a-verifier' },
      {
        keyEnvelopes: [
          initiatorEnvelope!,
          { ...survivorEnvelope!, ciphertextBase64: 'not base64!' },
        ],
      },
      {
        keyEnvelopes: [
          initiatorEnvelope!,
          { ...survivorEnvelope!, encapsulatedKeyBase64: 'short' },
        ],
      },
      {
        keyEnvelopes: [
          initiatorEnvelope!,
          { ...survivorEnvelope!, deviceEncryptionPublicKey: 'short' },
        ],
      },
      // A duplicate recipient, the removed device, or a Pending Device never receives the ring.
      {
        keyEnvelopes: [
          initiatorEnvelope!,
          survivorEnvelope!,
          survivorEnvelope!,
        ],
      },
      {
        keyEnvelopes: [
          ...body.keyEnvelopes,
          {
            ...survivorEnvelope!,
            deviceEncryptionPublicKey: deviceEncryptionPublicKey('device-002'),
            trustedDeviceId: target!.trustedDeviceId,
          },
        ],
      },
      {
        keyEnvelopes: [
          ...body.keyEnvelopes,
          {
            ...survivorEnvelope!,
            deviceEncryptionPublicKey: `${'A'.repeat(43)}=`,
            trustedDeviceId: pending.pendingDeviceId,
          },
        ],
      },
    ];
    const before = await rotationState(t, productAccountId);
    for (const change of invalid) {
      const response = await postRevocation(asUser, { ...body, ...change });
      expect(response.status).toBe(400);
    }
    await expect(rotationState(t, productAccountId)).resolves.toStrictEqual(
      before,
    );
    await expect(revokeTrustedDevice(asUser, body)).resolves.toStrictEqual({
      keyEpoch: 2,
    });
  });

  it('rejects a recipient set that differs from the remaining roster or its bound keys, changing nothing', async () => {
    expect.hasAssertions();

    const { asUser, devices, productAccountId, t } = await rotationAccount();
    const [initiator, target] = devices;
    const foreignDevice = await connectTrusted(
      t,
      t.withIdentity(googleIdentity),
      {
        deviceIdentifier: 'foreign-device',
        platform: 'ios',
      },
    );
    const body = await preparedRemoval(t, initiator!, target!.trustedDeviceId);
    const [initiatorEnvelope, survivorEnvelope] = body.keyEnvelopes;
    const stale: ReadonlyArray<Readonly<Record<string, unknown>>> = [
      { keyEnvelopes: [initiatorEnvelope!] },
      { keyEnvelopes: [survivorEnvelope!] },
      {
        keyEnvelopes: [
          ...body.keyEnvelopes,
          {
            ...survivorEnvelope!,
            deviceEncryptionPublicKey:
              deviceEncryptionPublicKey('foreign-device'),
            trustedDeviceId: foreignDevice.trustedDeviceId,
          },
        ],
      },
      {
        keyEnvelopes: [
          initiatorEnvelope!,
          {
            ...survivorEnvelope!,
            deviceEncryptionPublicKey: deviceEncryptionPublicKey('substitute'),
          },
        ],
      },
      {
        expectedKeyEpoch: 2,
        recoveryWrappedAccountKey: {
          ...body.recoveryWrappedAccountKey,
          keyVersion: 3,
        },
      },
      { expectedRecoveryUpdatedAt: body.expectedRecoveryUpdatedAt + 1 },
    ];
    const before = await rotationState(t, productAccountId);
    for (const change of stale) {
      const response = await postRevocation(asUser, { ...body, ...change });
      expect(response.status).toBe(409);
      await expect(response.json()).resolves.toStrictEqual({
        code: 'KEY_ROTATION_CONFLICT',
      });
    }
    await expect(rotationState(t, productAccountId)).resolves.toStrictEqual(
      before,
    );
  });

  it('refuses to omit an unbound surviving Trusted Device from activation', async () => {
    expect.hasAssertions();

    const { asUser, devices, productAccountId, t } = await rotationAccount();
    const [initiator, target, survivor] = devices;
    const body = await preparedRemoval(t, initiator!, target!.trustedDeviceId);
    await t.run(async (ctx) => {
      await ctx.db.patch('trustedDevices', survivor!.trustedDeviceId, {
        deviceEncryptionPublicKey: undefined,
      });
    });
    const before = await rotationState(t, productAccountId);
    const response = await postRevocation(asUser, {
      ...body,
      keyEnvelopes: body.keyEnvelopes.filter(
        ({ trustedDeviceId }) => trustedDeviceId !== survivor!.trustedDeviceId,
      ),
    });
    expect(response.status).toBe(409);
    await expect(response.json()).resolves.toStrictEqual({
      code: 'KEY_ROTATION_CONFLICT',
    });
    await expect(rotationState(t, productAccountId)).resolves.toStrictEqual(
      before,
    );
  });

  it('commits nothing from a snapshot a concurrent enrollment, removal or recovery change made stale', async () => {
    expect.hasAssertions();

    const { asUser, devices, productAccountId, t } = await rotationAccount([
      'device-001',
      'device-002',
      'device-003',
      'device-004',
    ]);
    const [initiator, firstTarget, secondTarget, otherInitiator] = devices;
    const conflict = async (body: Readonly<Record<string, unknown>>) => {
      const before = await rotationState(t, productAccountId);
      const response = await postRevocation(asUser, body);
      expect(response.status).toBe(409);
      await expect(response.json()).resolves.toStrictEqual({
        code: 'KEY_ROTATION_CONFLICT',
      });
      await expect(rotationState(t, productAccountId)).resolves.toStrictEqual(
        before,
      );
    };

    // Enrollment: a device admitted after preparation has no envelope in the proposal.
    const beforeEnrollment = await preparedRemoval(
      t,
      initiator!,
      firstTarget!.trustedDeviceId,
    );
    await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-005',
      platform: 'ios',
      supportsDeviceCredentials: true,
    });
    await conflict(beforeEnrollment);

    // Removal: two devices prepare from the same snapshot; only the first commits.
    const first = await preparedRemoval(
      t,
      initiator!,
      firstTarget!.trustedDeviceId,
    );
    const second = await preparedRemoval(
      t,
      otherInitiator!,
      secondTarget!.trustedDeviceId,
    );
    await expect(revokeTrustedDevice(asUser, first)).resolves.toStrictEqual({
      keyEpoch: 2,
    });
    await conflict(second);

    // Recovery change: the Recovery Key was replaced after preparation.
    const beforeRecoveryChange = await preparedRemoval(
      t,
      initiator!,
      secondTarget!.trustedDeviceId,
    );
    const recovery = await asUser.query(
      api.productSync.getEncryptedPayloadForTrustedDevice,
      { ...initiator!, payloadIdentifier: 'product-account-recovery-v1' },
    );
    await asUser.mutation(
      internal.productSync.replaceRecoveryMaterialIfUnchanged,
      {
        ...initiator!,
        encryptedPayload: {
          ...recoveryEnvelope,
          ciphertextBase64: 'cmVzZXQ',
          keyVersion: 2,
        },
        expectedUpdatedAt: recovery!.updatedAt,
        recoveryVerifier,
      },
    );
    await conflict(beforeRecoveryChange);

    // A proposal prepared afresh activates.
    await expect(
      revokeTrustedDevice(
        asUser,
        await preparedRemoval(t, initiator!, secondTarget!.trustedDeviceId),
      ),
    ).resolves.toStrictEqual({ keyEpoch: 3 });
  });

  it('reconciles a repeated activation with its original result, even after a later rotation', async () => {
    expect.hasAssertions();

    const { asUser, devices, productAccountId, t } = await rotationAccount();
    const [initiator, firstTarget, secondTarget] = devices;
    const proposal = (proposalId: string) =>
      asUser.query(api.productAccount.getKeyRotationProposal, {
        ...initiator!,
        proposalId,
      });
    const first = await preparedRemoval(
      t,
      initiator!,
      firstTarget!.trustedDeviceId,
    );
    await expect(proposal(first.proposalId)).resolves.toBeNull();
    await expect(revokeTrustedDevice(asUser, first)).resolves.toStrictEqual({
      keyEpoch: 2,
    });
    await expect(proposal(first.proposalId)).resolves.toStrictEqual({
      keyEpoch: 2,
      recoveryKeyCurrent: true,
    });
    const committed = await rotationState(t, productAccountId);
    // A lost reply retried as is rotates nothing twice.
    await expect(revokeTrustedDevice(asUser, first)).resolves.toStrictEqual({
      keyEpoch: 2,
    });
    await expect(rotationState(t, productAccountId)).resolves.toStrictEqual(
      committed,
    );
    // The same proposal identity cannot activate a different removal.
    const reused = await postRevocation(asUser, {
      ...first,
      keyEnvelopes: first.keyEnvelopes.filter(
        ({ trustedDeviceId }) =>
          trustedDeviceId !== secondTarget!.trustedDeviceId,
      ),
      trustedDeviceToRevokeId: secondTarget!.trustedDeviceId,
    });
    expect(reused.status).toBe(409);
    await expect(reused.json()).resolves.toStrictEqual({
      code: 'KEY_ROTATION_CONFLICT',
    });
    // A fresh proposal for the device already removed is refused as such.
    const again = await postRevocation(
      asUser,
      await preparedRemoval(t, initiator!, firstTarget!.trustedDeviceId),
    );
    expect(again.status).toBe(409);
    await expect(again.json()).resolves.toStrictEqual({
      code: 'TRUSTED_DEVICE_ALREADY_REMOVED',
    });

    const second = await preparedRemoval(
      t,
      initiator!,
      secondTarget!.trustedDeviceId,
    );
    await expect(revokeTrustedDevice(asUser, second)).resolves.toStrictEqual({
      keyEpoch: 3,
    });
    // The first proposal committed, but its Recovery Key is no longer the current one.
    await expect(proposal(first.proposalId)).resolves.toStrictEqual({
      keyEpoch: 2,
      recoveryKeyCurrent: false,
    });
    await expect(proposal(second.proposalId)).resolves.toStrictEqual({
      keyEpoch: 3,
      recoveryKeyCurrent: true,
    });
    await expect(revokeTrustedDevice(asUser, first)).resolves.toStrictEqual({
      keyEpoch: 2,
    });
    await expect(proposal('f'.repeat(32))).resolves.toBeNull();
    // Replacing the Recovery Key later supersedes the removal's key too.
    const recovery = await asUser.query(
      api.productSync.getEncryptedPayloadForTrustedDevice,
      { ...initiator!, payloadIdentifier: 'product-account-recovery-v1' },
    );
    await asUser.mutation(
      internal.productSync.replaceRecoveryMaterialIfUnchanged,
      {
        ...initiator!,
        encryptedPayload: {
          ...recoveryEnvelope,
          ciphertextBase64: 'cmVzZXQ',
          keyVersion: 3,
        },
        expectedUpdatedAt: recovery!.updatedAt,
        recoveryVerifier,
      },
    );
    await expect(proposal(second.proposalId)).resolves.toStrictEqual({
      keyEpoch: 3,
      recoveryKeyCurrent: false,
    });
    // Another Product Account learns nothing about this account's proposals.
    const { asUser: asOther, devices: otherDevices } = await rotationAccount(
      ['other-device'],
      { identity: googleIdentity, t },
    );
    await expect(
      asOther.query(api.productAccount.getKeyRotationProposal, {
        ...otherDevices[0]!,
        proposalId: second.proposalId,
      }),
    ).resolves.toBeNull();
  });

  it('lets an offline device catch up directly from its latest envelope while acknowledgements never block or regress', async () => {
    expect.hasAssertions();

    const { asUser, devices, t } = await rotationAccount([
      'device-001',
      'device-002',
      'device-003',
      'device-004',
    ]);
    const [initiator, offline, firstTarget, secondTarget] = devices;
    const historical = await asUser.mutation(
      api.productSync.putEncryptedPayloadIfUnchanged,
      { ...initiator!, encryptedPayload, payloadIdentifier: 'mailbox.archive' },
    );
    await revokeTrustedDevice(
      asUser,
      await preparedRemoval(t, initiator!, firstTarget!.trustedDeviceId),
    );
    // The offline device never acknowledged epoch 2; the next removal still commits.
    const latest = await preparedRemoval(
      t,
      initiator!,
      secondTarget!.trustedDeviceId,
    );
    await expect(revokeTrustedDevice(asUser, latest)).resolves.toStrictEqual({
      keyEpoch: 3,
    });
    const latestForOffline = latest.keyEnvelopes.find(
      ({ trustedDeviceId }) => trustedDeviceId === offline!.trustedDeviceId,
    );
    await expect(
      asUser.query(api.productAccount.getProductSyncKeyRotation, offline!),
    ).resolves.toStrictEqual({
      ciphertextBase64: latestForOffline!.ciphertextBase64,
      encapsulatedKeyBase64: latestForOffline!.encapsulatedKeyBase64,
      keyEpoch: 3,
    });
    // Historical records stay readable for the complete ring it adopts.
    await expect(
      asUser.query(api.productSync.getEncryptedPayloadForTrustedDevice, {
        ...offline!,
        payloadIdentifier: 'mailbox.archive',
      }),
    ).resolves.toStrictEqual(historical);

    const acknowledge = (keyEpoch: number) =>
      asUser.mutation(api.productAccount.acknowledgeProductSyncKeyRotation, {
        ...offline!,
        keyEpoch,
      });
    await expect(acknowledge(2)).resolves.toStrictEqual({ keyEpoch: 2 });
    await expect(acknowledge(3)).resolves.toStrictEqual({ keyEpoch: 3 });
    await expect(acknowledge(3)).resolves.toStrictEqual({ keyEpoch: 3 });
    await expect(acknowledge(2)).resolves.toStrictEqual({ keyEpoch: 3 });
    await expect(acknowledge(4)).rejects.toThrow(
      'Product Sync key epoch is unknown',
    );
    // Acknowledging never discards the envelope; signing out does.
    await expect(
      asUser.query(api.productAccount.getProductSyncKeyRotation, offline!),
    ).resolves.toMatchObject({ keyEpoch: 3 });
    await asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
      ...offline!,
      encryptedPayload: { ...encryptedPayload, keyVersion: 3 },
      payloadIdentifier: 'mailbox.after-catch-up',
    });
    await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
      ...offline!,
      deviceIdentifier: 'device-002',
    });
    const envelopes = await t.run(async (ctx) =>
      ctx.db.query('productSyncKeyEnvelopes').collect(),
    );
    expect(
      envelopes.map(({ trustedDeviceId }) => trustedDeviceId),
    ).toStrictEqual([initiator!.trustedDeviceId]);
  });

  it('revokes a reconnected trusted device through its retained target', async () => {
    expect.assertions(4);

    const { asUser, devices, productAccountId, t } = await rotationAccount();
    const [currentDevice, signedOutDevice] = devices;
    await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
      ...signedOutDevice!,
      deviceIdentifier: 'device-002',
    });
    await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
      supportsDeviceCredentials: true,
    });

    // The installation's current row is removed too and receives no envelope.
    await expect(
      revokeTrustedDevice(
        asUser,
        await preparedRemoval(
          t,
          currentDevice!,
          signedOutDevice!.trustedDeviceId,
        ),
      ),
    ).resolves.toStrictEqual({ keyEpoch: 2 });
    await expect(
      t.run(async (ctx) => ctx.db.query('revokedTrustedDevices').collect()),
    ).resolves.toStrictEqual([
      expect.objectContaining({
        deviceIdentifier: 'device-002',
        trustedDeviceId: signedOutDevice!.trustedDeviceId,
      }),
    ]);
    await expect(rotationState(t, productAccountId)).resolves.toMatchObject({
      devices: [
        [currentDevice!.trustedDeviceId, 2],
        [devices[2]!.trustedDeviceId, 1],
      ],
    });
    await expect(
      connectTrusted(t, asUser, {
        deviceIdentifier: 'device-002',
        platform: 'macos',
      }),
    ).rejects.toMatchObject({ data: { code: 'TRUSTED_DEVICE_REVOKED' } });
  });

  it('refuses removing the current installation through its own retained id', async () => {
    expect.assertions(2);

    const { asUser, devices, t } = await rotationAccount();
    const [staleDevice] = devices;
    await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
      ...staleDevice!,
      deviceIdentifier: 'device-001',
    });
    const currentDevice = deviceProof(
      await connectTrusted(t, asUser, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
        supportsDeviceCredentials: true,
      }),
    );
    await expect(
      revokeTrustedDevice(
        asUser,
        await preparedRemoval(t, currentDevice, staleDevice!.trustedDeviceId),
      ),
    ).rejects.toThrow('Use sign out to remove the current Trusted Device');
    await expect(
      t.run(async (ctx) => ({
        current: await ctx.db.get(
          'trustedDevices',
          currentDevice.trustedDeviceId,
        ),
        tombstones: await ctx.db.query('revokedTrustedDevices').collect(),
      })),
    ).resolves.toMatchObject({
      current: { deviceIdentifier: 'device-001' },
      tombstones: [],
    });
  });

  it('refuses a removal by a stale id once the reconnected installation is removed', async () => {
    expect.assertions(3);

    const { asUser, devices, productAccountId, t } = await rotationAccount();
    const [currentDevice, staleDevice] = devices;
    await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
      ...staleDevice!,
      deviceIdentifier: 'device-002',
    });
    const reconnectedDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
      supportsDeviceCredentials: true,
    });
    // One device removes the installation's current id; another still lists its earlier one.
    await revokeTrustedDevice(
      asUser,
      await preparedRemoval(
        t,
        currentDevice!,
        reconnectedDevice.trustedDeviceId,
      ),
    );
    const removed = await rotationState(t, productAccountId);
    const response = await postRevocation(
      asUser,
      await preparedRemoval(t, currentDevice!, staleDevice!.trustedDeviceId),
    );

    expect(response.status).toBe(409);
    await expect(response.json()).resolves.toStrictEqual({
      code: 'TRUSTED_DEVICE_ALREADY_REMOVED',
    });
    await expect(rotationState(t, productAccountId)).resolves.toStrictEqual(
      removed,
    );
  });

  it('keeps revocation durable when unregister arrives after revocation', async () => {
    expect.assertions(3);

    const { asUser, devices, t } = await rotationAccount();
    const [currentDevice, revokedDevice] = devices;
    await revokeTrustedDevice(
      asUser,
      await preparedRemoval(t, currentDevice!, revokedDevice!.trustedDeviceId),
    );

    await expect(
      asUser.mutation(api.productAccount.unregisterTrustedDevice, {
        ...revokedDevice!,
        deviceIdentifier: 'device-002',
      }),
    ).resolves.toStrictEqual({ registered: false });
    await expect(
      t.run(async (ctx) => ctx.db.query('revokedTrustedDevices').collect()),
    ).resolves.toHaveLength(1);
    await expect(
      connectTrusted(t, asUser, {
        deviceIdentifier: 'device-002',
        platform: 'macos',
      }),
    ).rejects.toMatchObject({ data: { code: 'TRUSTED_DEVICE_REVOKED' } });
  });

  it('signs a device back in as a Pending Device after its sign-out', async () => {
    expect.assertions(1);

    const { asUser, devices, productAccountId, t } = await rotationAccount();
    const [currentDevice, revokedDevice] = devices;
    await revokeTrustedDevice(
      asUser,
      await preparedRemoval(t, currentDevice!, revokedDevice!.trustedDeviceId),
    );
    await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
      ...currentDevice!,
      deviceIdentifier: 'device-001',
    });

    // Signing out left no Trusted Device record; only an approval or the Recovery Key admits it.
    await expect(
      asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
        supportsDeviceCredentials: true,
      }),
    ).resolves.toMatchObject({
      pendingDeviceId: expect.any(String),
      productAccountId,
    });
  });

  /* oxlint-enable vitest/max-expects */

  it('unregisters only the current Trusted Device', async () => {
    expect.assertions(4);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await connectTrusted(t, asUser, {
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
    const currentDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await connectTrusted(t, asUser, {
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
    const currentDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await connectTrusted(t, asUser, {
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
      const currentDevice = await connectTrusted(t, asUser, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      const otherDevice = await connectTrusted(t, asUser, {
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
    const currentDevice = await connectTrusted(t, asUser, {
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
    const currentDevice = await connectTrusted(t, asUser, {
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
    await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await connectTrusted(t, asUser, {
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
    const otherDevice = await connectTrusted(t, asOtherUser, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    await connectTrusted(t, asUser, {
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

  it('marks Product Sync material initialized once a recovery envelope exists', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connect = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    // Earlier legacy publications stored the envelope without the marker.
    await t.run(async (ctx) => {
      await ctx.db.insert('encryptedProductSyncPayloads', {
        encryptedPayload,
        payloadIdentifier: 'product-account-recovery-v1',
        productAccountId: connect.productAccountId,
        trustedDeviceId: connect.trustedDeviceId,
        updatedAt: 1,
        writtenAt: 1,
      });
    });

    await expect(
      asUser.mutation(api.productAccount.markProductSyncMaterialInitialized, {
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({
      productSyncMaterialInitialized: true,
    });

    await expect(
      connectTrusted(t, asUser, {
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
    const otherConnect = await connectTrusted(t, asOtherUser, {
      deviceIdentifier: 'device-002',
      platform: 'ios',
    });

    await connectTrusted(t, asUser, {
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
    const connect = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    // Earlier backends accepted records before the recovery envelope.
    await t.run(async (ctx) => {
      await ctx.db.insert('encryptedProductSyncPayloads', {
        encryptedPayload,
        payloadIdentifier: 'payload-001',
        productAccountId: connect.productAccountId,
        trustedDeviceId: connect.trustedDeviceId,
        updatedAt: 1,
        writtenAt: 1,
      });
    });

    await expect(
      connectTrusted(t, asUser, {
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
      connectTrusted(t, t, {
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
    const connect = await connectTrusted(t, asUser, {
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
    const connect = await connectTrusted(t, asUser, {
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
        .withIndex('by_productId_provider_deviceId_providerAccountId', (q) =>
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
    const connect = await connectTrusted(t, asUser, {
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
    const firstDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const secondDevice = await connectTrusted(t, asUser, {
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
    const connect = await connectTrusted(t, asUser, {
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
      connection: await ctx.db.get('mailProviderConnections', legacyId),
      signals: await ctx.db
        .query('gmailPushVerificationSignals')
        .withIndex('by_emailAddress_and_historyId', (q) =>
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

    const privateKey = appleSignInPrivateKey
      .export({
        format: 'pem',
        type: 'pkcs8',
      })
      .toString();
    vi.stubEnv(
      'APPLE_SIGN_IN_PRIVATE_KEY',
      privateKey.replaceAll('\n', String.raw`\n`),
    );
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await connectTrusted(t, asUser, {
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
    expect.assertions(5);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await connectTrusted(t, asUser, {
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
      const reconnectedCurrentDevice = await connectTrusted(t, asUser, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
        supportsDeviceCredentials: true,
      });

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
        t.run(async (ctx) => ctx.db.query('pendingDevices').collect()),
      ).resolves.toStrictEqual([]);
      await expect(
        t.run(async (ctx) =>
          ctx.db.query('trustedDeviceRevocationTargets').collect(),
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
    const currentDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    await asUser.mutation(api.productSync.initialize, {
      deviceEncryptionPublicKey: deviceEncryptionPublicKey(
        'initializing-device',
      ),
      recoveryVerifier,
      encryptedPayload: { ...encryptedPayload, schemaVersion: 3 },
      trustedDeviceId: currentDevice.trustedDeviceId,
    });
    await asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
      encryptedPayload,
      expectedUpdatedAt: undefined,
      payloadIdentifier: 'encrypted-preference',
      trustedDeviceId: currentDevice.trustedDeviceId,
    });
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.patch('trustedDevices', otherDevice.trustedDeviceId, {
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
      await ctx.db.insert('draftDeliveryClaims', {
        claimIdentifier: `draft-delivery.${'a'.repeat(32)}`,
        claimedAt: now,
        productAccountId: currentDevice.productAccountId,
        trustedDeviceId: otherDevice.trustedDeviceId,
      });
      await ctx.db.insert('scheduledSends', {
        deadlineAt: now + 86_400_000,
        dueAt: now + 60_000,
        encryptedPayloadIdentifier: 'scheduled-send.v3.schedule-001.1',
        encryptedPayloadUpdatedAt: now,
        productAccountId: currentDevice.productAccountId,
        revision: 1,
        scheduleId: 'schedule-001',
        state: 'active',
        trustedDeviceId: otherDevice.trustedDeviceId,
        updatedAt: now,
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
      await ctx.db.insert('productSyncKeyEnvelopes', {
        ciphertextBase64: 'cmluZw==',
        encapsulatedKeyBase64: `${'E'.repeat(43)}=`,
        keyEpoch: 2,
        productAccountId: currentDevice.productAccountId,
        trustedDeviceId: otherDevice.trustedDeviceId,
      });
      await ctx.db.insert('productSyncKeyRotationProposals', {
        activatedAt: now,
        initiatorTrustedDeviceId: currentDevice.trustedDeviceId,
        keyEpoch: 2,
        productAccountId: currentDevice.productAccountId,
        proposalId: 'a'.repeat(32),
        trustedDeviceToRevokeId: otherDevice.trustedDeviceId,
      });
      await ctx.db.insert('pendingDevices', {
        approval: {
          approvedAt: now,
          approvedByTrustedDeviceId: currentDevice.trustedDeviceId,
          ciphertextBase64: 'c2VhbGVkIGtleSByaW5n',
          encapsulatedKeyBase64: `${'B'.repeat(43)}=`,
          keyVersion: 1,
        },
        createdAt: now,
        credentialDigest: 'c'.repeat(64),
        deviceIdentifier: 'device-pending',
        enrollmentPublicKey: `${'A'.repeat(43)}=`,
        expiresAt: now + 15 * 60 * 1000,
        platform: 'ios',
        productAccountId: currentDevice.productAccountId,
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
        claims: await ctx.db.query('draftDeliveryClaims').collect(),
        devices: await ctx.db.query('trustedDevices').collect(),
        enrollments: await ctx.db.query('pendingDevices').collect(),
        envelopes: await ctx.db.query('productSyncKeyEnvelopes').collect(),
        heartbeats: await ctx.db.query('devicePushRouteHeartbeats').collect(),
        payloads: await ctx.db.query('encryptedProductSyncPayloads').collect(),
        receipts: await ctx.db
          .query('productSyncKeyRotationProposals')
          .collect(),
        routes: await ctx.db.query('mailProviderConnections').collect(),
        schedules: await ctx.db.query('scheduledSends').collect(),
        wakeups: await ctx.db.query('microsoftGraphWakeupStates').collect(),
      })),
    ).resolves.toStrictEqual({
      accounts: [],
      bindings: [],
      claims: [],
      devices: [],
      enrollments: [],
      envelopes: [],
      heartbeats: [],
      payloads: [],
      receipts: [],
      routes: [],
      schedules: [],
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
      connectTrusted(t, asUser, {
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

  it('deletes a Google Product Account after a recent sign-in and fences it', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(googleIdentity);
    const device = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
      supportsDeviceCredentials: true,
    });
    const proof = {
      trustedDeviceCredential: requiredTrustedDeviceCredential(device),
      trustedDeviceId: device.trustedDeviceId,
    };
    await asUser.mutation(api.productSync.initialize, {
      deviceEncryptionPublicKey: deviceEncryptionPublicKey(
        'initializing-device',
      ),
      recoveryVerifier,
      ...proof,
      encryptedPayload: { ...encryptedPayload, schemaVersion: 3 },
    });

    const stale = await deleteRecentlyAuthenticated(asUser, proof, {
      issuedAt: Math.floor(Date.now() / 1000) - 301,
    });
    const missingProof = await deleteRecentlyAuthenticated(asUser, {
      trustedDeviceId: device.trustedDeviceId,
    });

    expect([stale.status, missingProof.status]).toStrictEqual([401, 403]);
    await expect(storedAccountData(t)).resolves.toStrictEqual({
      accounts: 1,
      linked: 0,
      payloads: 1,
      tombstones: 0,
    });

    const deleted = await deleteRecentlyAuthenticated(asUser, proof);

    await expect(
      Promise.all([deleted.json(), storedAccountData(t)]),
    ).resolves.toStrictEqual([
      { deleted: true },
      { accounts: 0, linked: 0, payloads: 0, tombstones: 1 },
    ]);
    await expect(
      connectTrusted(t, asUser, {
        deviceIdentifier: 'device-002',
        platform: 'ios',
        supportsDeviceCredentials: true,
      }),
    ).rejects.toMatchObject({ data: { code: 'PRODUCT_ACCOUNT_DELETED' } });

    // A retry after a lost reply reports the completed deletion.
    const retried = await deleteRecentlyAuthenticated(asUser, proof);

    await expect(retried.json()).resolves.toStrictEqual({ deleted: true });
  });

  it('resumes authorized deletion after device cleanup without allowing another account to resume it', async () => {
    expect.hasAssertions();
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(googleIdentity);
    const asOther = t.withIdentity({
      ...googleIdentity,
      subject: 'google-other',
      tokenIdentifier: 'https://accounts.google.com|google-other',
    });
    const device = await connectTrusted(t, asUser, {
      deviceIdentifier: 'deleting-device',
      platform: 'ios',
      supportsDeviceCredentials: true,
    });
    const other = await connectTrusted(t, asOther, {
      deviceIdentifier: 'other-device',
      platform: 'ios',
      supportsDeviceCredentials: true,
    });
    const proof = {
      trustedDeviceId: device.trustedDeviceId,
      trustedDeviceCredential: requiredTrustedDeviceCredential(device),
    };
    const malformed = await deleteRecentlyAuthenticated(asUser, {
      trustedDeviceId: 42,
    });
    const unauthenticated = await t.fetch('/product-account/delete', {
      method: 'POST',
      body: JSON.stringify(proof),
    });
    const foreignProof = await deleteRecentlyAuthenticated(asUser, {
      trustedDeviceId: other.trustedDeviceId,
      trustedDeviceCredential: requiredTrustedDeviceCredential(other),
    });
    // Stop at the durable deletion checkpoint after its requesting device was drained.
    await asUser.mutation(internal.productAccountDeletionData.prepareDeletion, {
      ...proof,
      attemptId: 'interrupted-cleanup',
    });
    await t.run(async (ctx) =>
      ctx.db.delete('trustedDevices', device.trustedDeviceId),
    );
    const forbidden = await deleteRecentlyAuthenticated(asOther, proof, {
      identity: { issuer: googleIdentity.issuer, subject: 'google-other' },
    });
    expect([
      malformed.status,
      unauthenticated.status,
      foreignProof.status,
      forbidden.status,
    ]).toStrictEqual([400, 401, 403, 403]);
    const resumed = await deleteRecentlyAuthenticated(asUser, proof);
    await expect(resumed.json()).resolves.toStrictEqual({ deleted: true });
    await expect(storedAccountData(t)).resolves.toStrictEqual({
      accounts: 1,
      linked: 0,
      payloads: 0,
      tombstones: 1,
    });
    await expect(
      asOther.query(api.productAccount.listTrustedDevices, {
        trustedDeviceId: other.trustedDeviceId,
        trustedDeviceCredential: requiredTrustedDeviceCredential(other),
      }),
    ).resolves.toHaveLength(1);
  });

  it('requires Apple authorization to delete an account Sign in with Apple opens', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asGoogle = t.withIdentity(googleIdentity);
    const device = await connectTrusted(t, asGoogle, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await t.run(async (ctx) => {
      await ctx.db.insert('linkedSignIns', {
        linkedAt: Date.now(),
        productAccountId: device.productAccountId,
        provider: 'apple',
        tokenIdentifier: appleIdentity.tokenIdentifier,
      });
    });
    const proof = { trustedDeviceId: device.trustedDeviceId };

    const viaGoogle = await deleteRecentlyAuthenticated(asGoogle, proof);
    const asApple = t.withIdentity(appleIdentity);
    const withoutCode = await deleteRecentlyAuthenticated(asApple, proof, {
      identity: appleIdentity,
    });

    expect([viaGoogle.status, withoutCode.status]).toStrictEqual([409, 409]);
    await expect(storedAccountData(t)).resolves.toMatchObject({
      accounts: 1,
      linked: 1,
    });

    const withCode = await deleteRecentlyAuthenticated(
      asApple,
      {
        ...proof,
        appleClientId: 'dev.unwired.mail',
        authorizationCode: 'recent-apple-authorization-code',
      },
      { identity: appleIdentity },
    );

    await expect(
      Promise.all([withCode.json(), storedAccountData(t)]),
    ).resolves.toMatchObject([{ deleted: true }, { accounts: 0, linked: 0 }]);
  });

  it('keeps account data when Apple token revocation fails terminally', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await connectTrusted(t, asUser, {
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
    const currentDevice = await connectTrusted(t, asUser, {
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
    const currentDevice = await connectTrusted(t, asUser, {
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
      connectTrusted(t, asUser, {
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

  it.each<readonly [string, ReadonlyArray<() => Response>]>([
    [
      'Apple signing keys return 429',
      [appleTokenResponse, () => new Response(null, { status: 429 })],
    ],
    [
      'Apple signing keys return 503',
      [appleTokenResponse, () => new Response(null, { status: 503 })],
    ],
    [
      'the Apple token endpoint returns 503',
      [() => new Response(null, { status: 503 })],
    ],
    [
      'Apple cannot be reached',
      [
        () => {
          throw new TypeError('fetch failed');
        },
      ],
    ],
  ])('retains the deletion attempt when %s', async (_case, appleResponses) => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const fetchMock = vi.mocked(fetch);
    for (const appleResponse of appleResponses) {
      fetchMock.mockImplementationOnce(async () => appleResponse());
    }

    await expect(
      asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'recent-apple-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).rejects.toThrow(
      'Apple authorization revocation is temporarily unavailable',
    );
    await expect(
      t.run((ctx) => ctx.db.query('productAccountDeletionRequests').collect()),
    ).resolves.toMatchObject([
      {
        phase: 'revocation-pending',
        revocationMaterial: {
          kind: 'authorization-code',
          value: 'recent-apple-authorization-code',
        },
      },
    ]);
  });

  it('completes deletion when Apple reports a previously attempted revoke as invalid', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await connectTrusted(t, asUser, {
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
    const currentDevice = await connectTrusted(t, asUser, {
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
    const currentDevice = await connectTrusted(t, asUser, {
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
    const succeededRequest = await t.run(async (ctx) =>
      ctx.db.get('productAccountDeletionRequests', requestId),
    );
    expect(succeededRequest).not.toHaveProperty('revocationMaterial');
    await expect(
      connectTrusted(t, asUser, {
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

  it('resumes a previously attempted Apple revocation without a client after Apple is unavailable', async () => {
    expect.assertions(3);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await connectTrusted(t, asUser, {
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
      // Apple is unavailable for the first recovery, which keeps the request for the next one.
      vi.mocked(fetch).mockImplementationOnce(
        async () => new Response(null, { status: 503 }),
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

  it('logs an allow-listed diagnostic before a misconfigured revocation recovery aborts', async () => {
    expect.assertions(4);
    vi.useFakeTimers();
    // Convex records console.error output at error level, which alerts depend on.
    const errors = vi.spyOn(console, 'error').mockReturnValue();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await connectTrusted(t, asUser, {
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
          token: { kind: 'refresh-token', value: 'recovery-refresh-token' },
        },
      );
      vi.stubEnv('APPLE_SIGN_IN_PRIVATE_KEY', '');

      await asUser.mutation(
        internal.productAccountDeletionData.markRevocationAttemptStarted,
        { attemptId: 'deletion-attempt-001', requestId },
      );
      await t.finishAllScheduledFunctions(() => vi.advanceTimersByTime(60_000));

      await expect(
        t.run(async (ctx) => ctx.db.query('productAccounts').collect()),
      ).resolves.toHaveLength(1);
      await expect(
        t.run(async (ctx) =>
          ctx.db.query('productAccountDeletionRequests').collect(),
        ),
      ).resolves.toStrictEqual([]);
      expect(errors.mock.calls).toContainEqual([
        expect.any(String),
        'Apple revocation recovery failed:',
        'Error',
      ]);
      expect(JSON.stringify(errors.mock.calls)).not.toMatch(
        /recovery-refresh-token|recent-apple-authorization-code/u,
      );
    } finally {
      vi.stubEnv(
        'APPLE_SIGN_IN_PRIVATE_KEY',
        appleSignInPrivateKey
          .export({ format: 'pem', type: 'pkcs8' })
          .toString(),
      );
      errors.mockRestore();
      vi.useRealTimers();
    }
  });

  it('schedules durable cleanup with the revocation-complete transition', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await connectTrusted(t, asUser, {
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
    const currentDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.patch('trustedDevices', currentDevice.trustedDeviceId, {
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
    const currentDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
      supportsDeviceCredentials: true,
    });
    const otherDevice = await connectTrusted(t, asUser, {
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
      await ctx.db.delete('trustedDevices', currentDevice.trustedDeviceId);
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

  it('resumes committed deletion after cleanup already removed its trusted device', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await connectTrusted(t, asUser, {
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
    ).resolves.toStrictEqual({ deleted: true });
  });

  it('does not let a superseded revocation attempt cancel deletion', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await connectTrusted(t, asUser, {
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
      const currentDevice = await connectTrusted(t, asUser, {
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
        t.run(async (ctx) =>
          ctx.db.get('productAccountDeletionRequests', requestId),
        ),
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
      const device = await connectTrusted(t, asUser, {
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
        t.run(async (ctx) =>
          ctx.db.get('productAccountDeletionRequests', requestId),
        ),
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
      const device = await connectTrusted(t, asUser, {
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
        t.run(async (ctx) =>
          ctx.db.get('productAccountDeletionRequests', requestId),
        ),
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
      const device = await connectTrusted(t, asUser, {
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
        t.run(async (ctx) =>
          ctx.db.get('productAccountDeletionRequests', requestId),
        ),
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
      const device = await connectTrusted(t, asUser, {
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
        t.run(async (ctx) =>
          ctx.db.get('productAccountDeletionRequests', requestId),
        ),
      ).resolves.toBeNull();
    } finally {
      vi.useRealTimers();
    }
  });

  it('deletes an Apple account registered through a replacement client ID', async () => {
    expect.assertions(5);
    const replacementClientId = 'dev.unwired.mail.replacement';
    const previousBundleId = env.APPLE_BUNDLE_ID;
    const previousClientIds = env.APPLE_PRODUCT_CLIENT_IDS;
    vi.stubEnv('APPLE_BUNDLE_ID', '');
    vi.stubEnv('APPLE_PRODUCT_CLIENT_IDS', ` ${replacementClientId} ,`);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await connectTrusted(t, asUser, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      const fetchMock = vi.mocked(fetch);
      const earlierFetches = fetchMock.mock.calls.length;
      fetchMock
        .mockImplementationOnce(async () =>
          appleTokenResponse(appleIdentity.subject, replacementClientId),
        )
        .mockImplementationOnce(async () =>
          Response.json({ keys: [appleIdentitySigningKey] }),
        )
        // Apple is unavailable for the first revocation, so recovery revokes the stored token.
        .mockImplementationOnce(
          async () => new Response(null, { status: 503 }),
        );

      // An unconfigured client is rejected before Apple is contacted.
      await expect(
        asUser.action(api.productAccountDeletion.deleteProductAccount, {
          appleClientId: 'dev.unwired.mail.unconfigured',
          authorizationCode: 'recent-apple-authorization-code',
          trustedDeviceId: currentDevice.trustedDeviceId,
        }),
      ).rejects.toThrow('Recent authentication must match the Product Account');
      await expect(
        asUser.action(api.productAccountDeletion.deleteProductAccount, {
          appleClientId: replacementClientId,
          authorizationCode: 'recent-apple-authorization-code',
          trustedDeviceId: currentDevice.trustedDeviceId,
        }),
      ).rejects.toThrow(
        'Apple authorization revocation is temporarily unavailable',
      );
      await t.finishAllScheduledFunctions(() => vi.advanceTimersByTime(60_000));

      // The exchange, the failed revocation and its recovery each use the replacement client.
      const appleForms = fetchMock.mock.calls
        .slice(earlierFetches)
        .map(([, init]) => init?.body)
        .filter((body) => body instanceof URLSearchParams)
        .map((form) => {
          const [, clientSecretClaims] = String(
            form.get('client_secret'),
          ).split('.');
          return {
            clientId: form.get('client_id'),
            clientSecretSubject: JSON.parse(
              Buffer.from(String(clientSecretClaims), 'base64url').toString(),
            ).sub,
          };
        });
      expect(appleForms).toStrictEqual(
        Array.from({ length: 3 }, () => ({
          clientId: replacementClientId,
          clientSecretSubject: replacementClientId,
        })),
      );
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
      vi.stubEnv('APPLE_BUNDLE_ID', previousBundleId);
      vi.stubEnv('APPLE_PRODUCT_CLIENT_IDS', previousClientIds);
    }
  });

  it.each([
    ['another identity', 'apple-user-002', 'dev.unwired.mail'],
    [
      'another configured client',
      appleIdentity.subject,
      'dev.unwired.mail.replacement',
    ],
  ])(
    'rejects an Apple authorization code for %s',
    async (_case, subject, audience) => {
      expect.assertions(2);
      const previousClientIds = env.APPLE_PRODUCT_CLIENT_IDS;
      vi.stubEnv('APPLE_PRODUCT_CLIENT_IDS', 'dev.unwired.mail.replacement');
      try {
        const t = convexTest(schema, modules);
        const asUser = t.withIdentity(appleIdentity);
        const currentDevice = await connectTrusted(t, asUser, {
          deviceIdentifier: 'device-001',
          platform: 'ios',
        });
        vi.mocked(fetch).mockImplementationOnce(async () =>
          appleTokenResponse(subject, audience),
        );

        await expect(
          asUser.action(api.productAccountDeletion.deleteProductAccount, {
            authorizationCode: 'other-users-authorization-code',
            trustedDeviceId: currentDevice.trustedDeviceId,
          }),
        ).rejects.toThrow(
          'Recent authentication must match the Product Account',
        );
        await expect(
          t.run(async (ctx) => ctx.db.query('productAccounts').collect()),
        ).resolves.toHaveLength(1);
      } finally {
        vi.stubEnv('APPLE_PRODUCT_CLIENT_IDS', previousClientIds);
      }
    },
  );

  it('rejects a malformed or invalidly signed Apple identity token', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const currentDevice = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const token = appleIdToken(appleIdentity.subject);
    const [header, claims] = token.split('.');
    const invalidSignature = Buffer.alloc(256).toString('base64url');
    const fetchMock = vi.mocked(fetch);
    const deleteWithAppleTokenResponse = async (body: unknown) => {
      fetchMock.mockImplementationOnce(async () => Response.json(body));
      return asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'malformed-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      });
    };

    await expect(
      deleteWithAppleTokenResponse({
        access_token: 'apple-access-token',
        id_token: `${header}.${claims}.${invalidSignature}`,
        token_type: 'Bearer',
      }),
    ).rejects.toThrow('Apple authorization exchange failed');
    await expect(
      deleteWithAppleTokenResponse({
        id_token: `${header}.${Buffer.from('null').toString('base64url')}.${invalidSignature}`,
        refresh_token: 'apple-refresh-token',
      }),
    ).rejects.toThrow('Apple authorization exchange failed');
    await expect(
      deleteWithAppleTokenResponse({ refresh_token: 'apple-refresh-token' }),
    ).rejects.toThrow('Apple authorization exchange failed');
    // Apple publishes no usable RSA key for the token's key identifier.
    fetchMock.mockImplementationOnce(async () => appleTokenResponse());
    fetchMock.mockImplementationOnce(async () =>
      Response.json({ keys: [{ ...appleIdentitySigningKey, kty: 'EC' }] }),
    );
    await expect(
      asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'unverifiable-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Apple authorization exchange failed');
    await expect(
      t.run(async (ctx) => ctx.db.query('productAccounts').collect()),
    ).resolves.toHaveLength(1);
  });
});
