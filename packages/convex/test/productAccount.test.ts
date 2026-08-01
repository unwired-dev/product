/// <reference types="vite/client" />

import { generateKeyPairSync, sign } from 'node:crypto';

import { convexTest } from 'convex-test';

import { api } from '../convex/_generated/api.js';
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
vi.stubEnv('GMAIL_ROUTING_KEY', 'gmail-routing-test-key');
vi.stubEnv('GMAIL_IDENTITY_BINDING_KEY', 'gmail-identity-binding-test-key');
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

  it('deletes Microsoft Graph routes and wakeup state owned by an unregistered device', async () => {
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
      for (const trustedDeviceId of [
        currentDevice.trustedDeviceId,
        otherDevice.trustedDeviceId,
      ]) {
        const routeId = await ctx.db.insert('mailProviderConnections', {
          connectedAt: now,
          lastVerifiedAt: now,
          productAccountId: currentDevice.productAccountId,
          provider: 'microsoft-graph',
          trustedDeviceId,
          updatedAt: now,
        });
        await ctx.db.insert('microsoftGraphWakeupStates', {
          routeId,
          scheduledAt: now,
        });
      }
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
});
