/// <reference types="vite/client" />

import { generateKeyPairSync, sign } from 'node:crypto';

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

function requireFormBody(body: BodyInit | null | undefined): URLSearchParams {
  if (!(body instanceof URLSearchParams)) {
    throw new Error('Expected form body');
  }
  return body;
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
      asUser.mutation(api.productSync.putEncryptedPayload, {
        encryptedPayload,
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
    expect.assertions(2);
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

      await expect(
        asUser.action(api.productAccountDeletion.deleteProductAccount, {
          authorizationCode: 'recent-apple-authorization-code',
          trustedDeviceId: currentDevice.trustedDeviceId,
        }),
      ).resolves.toStrictEqual({ deleted: false });
      await t.finishAllScheduledFunctions(vi.runAllTimers);
      await expect(
        t.run(async (ctx) => ctx.db.query('productAccounts').collect()),
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
    await asUser.mutation(api.productSync.putEncryptedPayload, {
      encryptedPayload,
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

  it('revokes with the Apple access token when no refresh token is returned', async () => {
    expect.assertions(4);

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
    fetchMock.mockImplementationOnce(async (input, init) => {
      expect(input).toBe('https://appleid.apple.com/auth/revoke');
      const body = requireFormBody(init?.body);
      expect(body.get('token')).toBe('apple-access-token');
      expect(body.get('token_type_hint')).toBe('access_token');
      return new Response(null, { status: 200 });
    });

    await expect(
      asUser.action(api.productAccountDeletion.deleteProductAccount, {
        authorizationCode: 'recent-apple-authorization-code',
        trustedDeviceId: currentDevice.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ deleted: true });
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

  it('resumes deletion without revoking an access token twice after durable success', async () => {
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
      await t.finishAllScheduledFunctions(vi.runAllTimers);

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

  it('resumes data deletion after its trusted device was already removed', async () => {
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
    ).resolves.toStrictEqual({ deleted: true });
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
