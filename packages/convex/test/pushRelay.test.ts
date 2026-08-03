/// <reference types="vite/client" />

import { createHash, createHmac, generateKeyPairSync, sign } from 'node:crypto';

import type { TestConvexForDataModel } from 'convex-test';

import { convexTest } from 'convex-test';

import type { DataModel, Id } from '../convex/_generated/dataModel.js';

import { api, internal } from '../convex/_generated/api.js';
import {
  decodeGmailPushEnvelope,
  gmailWakeupPayload,
} from '../convex/gmailPushPayload.js';
import { opaqueGmailConnectionId } from '../convex/gmailRouting.js';
import schema from '../convex/schema.js';

type ObservedApnsRequest = Readonly<{
  authority: string;
  headers: Record<string, unknown>;
  payload: string;
}>;

const apnsMock = vi.hoisted(() => ({
  closedRequests: 0,
  connections: [] as string[],
  requests: [] as ObservedApnsRequest[],
  responseBody: '',
  sessions: [] as Array<{
    listenerCount: (eventName: string | symbol) => number;
  }>,
  status: 200,
  statusByToken: {} as Record<string, number>,
  stallResponseBody: false,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- A partial HTTP/2 transport fake intentionally cannot satisfy the full Node module type.
vi.mock('node:http2', async () => {
  const { EventEmitter } = await import('node:events');

  return {
    connect: (authority: URL | string) => {
      apnsMock.connections.push(String(authority));
      // oxlint-disable-next-line unicorn/prefer-event-target -- the production client is an EventEmitter.
      const session = Object.assign(new EventEmitter(), {
        close() {
          return undefined;
        },
        request: (headers: Record<string, unknown>) => {
          // oxlint-disable-next-line unicorn/prefer-event-target -- node:events.once requires EventEmitter semantics.
          const request = Object.assign(new EventEmitter(), {
            end(payload: string) {
              apnsMock.requests.push({
                authority: String(authority),
                headers,
                payload,
              });
              queueMicrotask(() => {
                const token = String(headers[':path']).split('/').at(-1) ?? '';
                request.emit('response', {
                  ':status': apnsMock.statusByToken[token] ?? apnsMock.status,
                });
                setTimeout(() => {
                  if (apnsMock.stallResponseBody) {
                    return;
                  }
                  if (apnsMock.responseBody.length > 0) {
                    request.emit('data', apnsMock.responseBody);
                  }
                  request.emit('end');
                }, 0);
              });
            },
            close() {
              apnsMock.closedRequests += 1;
              return undefined;
            },
            setEncoding(_encoding: string) {
              return undefined;
            },
          });
          return request;
        },
      });
      apnsMock.sessions.push(session);
      return session;
    },
  };
});

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
  kid: 'google-test-key',
  use: 'sig',
};

function createGoogleIdentityToken(
  emailAddress: string,
  providerAccountIdentifier: string,
): string {
  const header = Buffer.from(
    JSON.stringify({ alg: 'RS256', kid: 'google-test-key', typ: 'JWT' }),
  ).toString('base64url');
  const claims = Buffer.from(
    JSON.stringify({
      aud: 'gmail-client-id',
      email: emailAddress,
      email_verified: true,
      exp: 4_102_444_800,
      iss: 'https://accounts.google.com',
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

const badDeviceIdentityToken = createGoogleIdentityToken(
  'bad-device@example.com',
  'bad-device-gmail',
);
const busyIdentityToken = createGoogleIdentityToken(
  'busy@example.com',
  'gmail-user-001',
);
const matchingIdentityToken = createGoogleIdentityToken(
  'matching@example.com',
  'gmail-user-001',
);
const matchingVictimEmailIdentityToken = createGoogleIdentityToken(
  'victim@example.com',
  'gmail-attacker',
);
const matchingVictimSubjectIdentityToken = createGoogleIdentityToken(
  'attacker@example.com',
  'client-asserted-id',
);

vi.stubEnv('GMAIL_OAUTH_CLIENT_ID', 'gmail-client-id');
vi.stubEnv('GMAIL_ROUTING_KEY', 'gmail-routing-test-key');
vi.stubEnv('GMAIL_IDENTITY_BINDING_KEY', 'gmail-identity-binding-test-key');
const googleSigningKeyFetch = vi.fn<() => Promise<Response>>(async () =>
  Response.json(
    { keys: [googleIdentitySigningKey] },
    { headers: { 'cache-control': 'public, max-age=3600' } },
  ),
);
vi.stubGlobal('fetch', googleSigningKeyFetch);

function opaqueConnectionId(providerAccountIdentifier: string): string {
  return `opaque:${providerAccountIdentifier}`;
}

function versionedRoutingDigest(
  emailAddress: string,
  key: string,
  version: number,
): string {
  return `${String(version)}:${createHmac('sha256', key)
    .update(`${String(version)}\0${emailAddress}`)
    .digest('base64url')}`;
}

function routingDigest(emailAddress: string): string {
  return versionedRoutingDigest(emailAddress, 'gmail-routing-test-key', 1);
}

function opaqueConnectionIdFromIdentityToken(identityToken: string): string {
  try {
    const claimsSegment = identityToken.split('.').at(1);
    if (claimsSegment === undefined) {
      return 'opaque:untrusted';
    }
    const claims: unknown = JSON.parse(
      Buffer.from(claimsSegment, 'base64url').toString('utf8'),
    );
    if (
      typeof claims === 'object' &&
      claims !== null &&
      'sub' in claims &&
      typeof claims.sub === 'string'
    ) {
      return opaqueConnectionId(claims.sub);
    }
  } catch {
    // Invalid proof inputs still need an opaque route argument for auth-first tests.
  }
  return 'opaque:untrusted';
}

async function registerGmailConnection(
  client: TestConvexForDataModel<DataModel>,
  args: Readonly<{
    emailAddress: string;
    providerAccountIdentifier: string;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
) {
  return client.action(api.pushRelay.registerGmailConnection, {
    gmailIdentityToken: createGoogleIdentityToken(
      args.emailAddress,
      args.providerAccountIdentifier,
    ),
    opaqueConnectionId: opaqueConnectionId(args.providerAccountIdentifier),
    trustedDeviceId: args.trustedDeviceId,
  });
}

describe('gmail push relay', () => {
  it('counts legacy rows toward the per-device Gmail connection cap', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await t.run(async (ctx) => {
      for (let index = 0; index < 2; index += 1) {
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: index,
          emailAddress: `legacy-${String(index)}@example.com`,
          lastVerifiedAt: index,
          productAccountId: device.productAccountId,
          provider: 'gmail',
          providerAccountIdentifier: `legacy-${String(index)}`,
          trustedDeviceId: device.trustedDeviceId,
          updatedAt: index,
        });
      }
      for (let index = 0; index < 18; index += 1) {
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: index + 2,
          gmailRoutingDigest: routingDigest(
            `current-${String(index)}@example.com`,
          ),
          gmailRoutingKeyVersion: 1,
          lastVerifiedAt: index + 2,
          opaqueConnectionId: `opaque:current-${String(index)}`,
          productAccountId: device.productAccountId,
          provider: 'gmail',
          trustedDeviceId: device.trustedDeviceId,
          updatedAt: index + 2,
        });
      }
    });

    await expect(
      registerGmailConnection(asUser, {
        emailAddress: 'new@example.com',
        providerAccountIdentifier: 'gmail-user-new',
        trustedDeviceId: device.trustedDeviceId,
      }),
    ).rejects.toThrow('Gmail connection limit reached');
  });

  it('authenticates the trusted device before fetching Google signing keys', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const connection = await t
      .withIdentity(appleIdentity)
      .mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
    googleSigningKeyFetch.mockClear();

    await expect(
      t.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: 'untrusted-input',
        opaqueConnectionId:
          opaqueConnectionIdFromIdentityToken('untrusted-input'),
        historyId: '100',
        trustedDeviceId: connection.trustedDeviceId,
      }),
    ).rejects.toThrow('Authentication required');
    expect(googleSigningKeyFetch).not.toHaveBeenCalled();
  });

  it('derives the opaque connection id for legacy watch verification calls', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-legacy-watch-verification',
      platform: 'ios',
    });
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        emailAddress: 'legacy@example.com',
        lastVerifiedAt: now,
        productAccountId: device.productAccountId,
        provider: 'gmail',
        providerAccountIdentifier: 'gmail-user-legacy',
        trustedDeviceId: device.trustedDeviceId,
        updatedAt: now,
      });
    });

    await expect(
      asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: createGoogleIdentityToken(
          'legacy@example.com',
          'gmail-user-legacy',
        ),
        historyId: '100',
        trustedDeviceId: device.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: false }));
    await expect(
      t.run((ctx) =>
        ctx.db
          .query('mailProviderConnections')
          .withIndex('by_productId_provider_deviceId_providerAccountId', (q) =>
            q
              .eq('productAccountId', device.productAccountId)
              .eq('provider', 'gmail')
              .eq('trustedDeviceId', device.trustedDeviceId)
              .eq('providerAccountIdentifier', 'gmail-user-legacy'),
          )
          .unique(),
      ),
    ).resolves.toStrictEqual(
      expect.objectContaining({
        emailAddress: 'legacy@example.com',
        providerAccountIdentifier: 'gmail-user-legacy',
      }),
    );
  });

  it('stops a mailbox watch only after its last active device route', async () => {
    expect.assertions(3);

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
    for (const trustedDeviceId of [
      firstDevice.trustedDeviceId,
      secondDevice.trustedDeviceId,
    ]) {
      await registerGmailConnection(asUser, {
        emailAddress: 'matching@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId,
      });
    }
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'second-apns-token',
      trustedDeviceId: secondDevice.trustedDeviceId,
    });
    await t.run(async (ctx) => {
      const connection = await ctx.db
        .query('mailProviderConnections')
        .withIndex('by_productId_provider_deviceId_connectionId', (q) =>
          q
            .eq('productAccountId', secondDevice.productAccountId)
            .eq('provider', 'gmail')
            .eq('trustedDeviceId', secondDevice.trustedDeviceId)
            .eq('opaqueConnectionId', opaqueConnectionId('gmail-user-001')),
        )
        .unique();
      expect(connection).not.toBeNull();
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(connection!._id, {
        pushOwnershipVerifiedAt: Date.now(),
        pushVerifiedAt: Date.now(),
      });
    });

    await expect(
      asUser.query(api.pushRelay.shouldStopGmailWatch, {
        opaqueConnectionId: opaqueConnectionId('gmail-user-001'),
        trustedDeviceId: firstDevice.trustedDeviceId,
      }),
      // oxlint-disable-next-line vitest/prefer-to-be-falsy -- The strict boolean matcher is required by vitest/prefer-strict-boolean-matchers.
    ).resolves.toBe(false);
    await asUser.mutation(api.pushRelay.unregisterDevice, {
      trustedDeviceId: secondDevice.trustedDeviceId,
    });
    await expect(
      asUser.query(api.pushRelay.shouldStopGmailWatch, {
        opaqueConnectionId: opaqueConnectionId('gmail-user-001'),
        trustedDeviceId: firstDevice.trustedDeviceId,
      }),
    ).resolves.toBe(true);
  });

  it('stops a legacy mailbox watch after its last active device route', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-legacy-watch-stop',
      platform: 'ios',
    });
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        emailAddress: 'legacy-watch@example.com',
        lastVerifiedAt: now,
        productAccountId: device.productAccountId,
        provider: 'gmail',
        providerAccountIdentifier: 'legacy-watch-user',
        trustedDeviceId: device.trustedDeviceId,
        updatedAt: now,
      });
    });

    await expect(
      asUser.query(api.pushRelay.shouldStopGmailWatch, {
        providerAccountIdentifier: 'legacy-watch-user',
        trustedDeviceId: device.trustedDeviceId,
      }),
    ).resolves.toBe(true);
  });

  it('keeps a legacy mailbox watch while another legacy device route is active', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const firstDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-first-legacy-watch',
      platform: 'ios',
    });
    const secondDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-second-legacy-watch',
      platform: 'macos',
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'second-legacy-apns-token',
      trustedDeviceId: secondDevice.trustedDeviceId,
    });
    await t.run(async (ctx) => {
      const now = Date.now();
      for (const [trustedDeviceId, providerAccountIdentifier] of [
        [firstDevice.trustedDeviceId, 'first-legacy-watch-user'],
        [secondDevice.trustedDeviceId, 'second-legacy-watch-user'],
      ] as const) {
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: now,
          emailAddress: 'shared-legacy-watch@example.com',
          lastVerifiedAt: now,
          productAccountId: firstDevice.productAccountId,
          provider: 'gmail',
          providerAccountIdentifier,
          pushOwnershipVerifiedAt: now,
          pushVerifiedAt: now,
          trustedDeviceId,
          updatedAt: now,
        });
      }
    });

    await expect(
      asUser.query(api.pushRelay.shouldStopGmailWatch, {
        opaqueConnectionId: await opaqueGmailConnectionId(
          firstDevice.productAccountId,
          'first-legacy-watch-user',
        ),
        trustedDeviceId: firstDevice.trustedDeviceId,
      }),
      // oxlint-disable-next-line vitest/prefer-to-be-falsy -- The strict boolean matcher is required by vitest/prefer-strict-boolean-matchers.
    ).resolves.toBe(false);
  });

  it('keeps a mailbox watch while active routes use both rotation keys', async () => {
    expect.assertions(2);

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
    for (const [trustedDeviceId, apnsToken] of [
      [firstDevice.trustedDeviceId, 'first-apns-token'],
      [secondDevice.trustedDeviceId, 'second-apns-token'],
    ] as const) {
      await registerGmailConnection(asUser, {
        emailAddress: 'matching@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId,
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken,
        trustedDeviceId,
      });
      await t.run(async (ctx) => {
        const connection = await ctx.db
          .query('mailProviderConnections')
          .withIndex('by_productId_provider_deviceId_connectionId', (q) =>
            q
              .eq('productAccountId', firstDevice.productAccountId)
              .eq('provider', 'gmail')
              .eq('trustedDeviceId', trustedDeviceId)
              .eq('opaqueConnectionId', opaqueConnectionId('gmail-user-001')),
          )
          .unique();
        const now = Date.now();
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        await ctx.db.patch(connection!._id, {
          pushOwnershipVerifiedAt: now,
          pushVerifiedAt: now,
          pushVerifiedHistoryId: '100',
        });
      });
    }

    vi.stubEnv('GMAIL_ROUTING_KEY', 'rotated-routing-test-key');
    vi.stubEnv('GMAIL_ROUTING_KEY_VERSION', '2');
    vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY', 'gmail-routing-test-key');
    vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY_VERSION', '1');
    try {
      await asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingIdentityToken,
        historyId: '100',
        opaqueConnectionId: opaqueConnectionId('gmail-user-001'),
        trustedDeviceId: secondDevice.trustedDeviceId,
      });
      await expect(
        asUser.query(api.pushRelay.shouldStopGmailWatch, {
          opaqueConnectionId: opaqueConnectionId('gmail-user-001'),
          trustedDeviceId: firstDevice.trustedDeviceId,
        }),
        // oxlint-disable-next-line vitest/prefer-to-be-falsy -- The strict boolean matcher is required by vitest/prefer-strict-boolean-matchers.
      ).resolves.toBe(false);
      await expect(
        asUser.query(api.pushRelay.shouldStopGmailWatch, {
          opaqueConnectionId: opaqueConnectionId('gmail-user-001'),
          trustedDeviceId: secondDevice.trustedDeviceId,
        }),
        // oxlint-disable-next-line vitest/prefer-to-be-falsy -- The strict boolean matcher is required by vitest/prefer-strict-boolean-matchers.
      ).resolves.toBe(false);
    } finally {
      vi.stubEnv('GMAIL_ROUTING_KEY', 'gmail-routing-test-key');
      vi.stubEnv('GMAIL_ROUTING_KEY_VERSION', '');
      vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY', '');
      vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY_VERSION', '');
    }
  });

  it('keeps a mailbox watch when another account has an active verified route', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connection = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await registerGmailConnection(asUser, {
      emailAddress: 'shared@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: connection.trustedDeviceId,
    });
    await t.run(async (ctx) => {
      const productAccountId = await ctx.db.insert('productAccounts', {
        createdAt: Date.now(),
        lastSeenAt: Date.now(),
        tokenIdentifier: 'other-account',
      });
      const trustedDeviceId = await ctx.db.insert('trustedDevices', {
        apnsEnvironment: 'production',
        apnsToken: 'other-token',
        deviceIdentifier: 'other-device',
        lastSeenAt: Date.now(),
        platform: 'ios',
        productAccountId,
        registeredAt: Date.now(),
      });
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: Date.now(),
        emailAddress: 'shared@example.com',
        gmailRoutingDigest: routingDigest('shared@example.com'),
        gmailRoutingKeyVersion: 1,
        lastVerifiedAt: Date.now(),
        productAccountId,
        provider: 'gmail',
        providerAccountIdentifier: 'other-gmail-user',
        opaqueConnectionId: opaqueConnectionId('other-gmail-user'),
        pushOwnershipVerifiedAt: Date.now(),
        pushVerifiedAt: Date.now(),
        trustedDeviceId,
        updatedAt: Date.now(),
      });
    });

    await expect(
      asUser.query(api.pushRelay.shouldStopGmailWatch, {
        opaqueConnectionId: opaqueConnectionId('gmail-user-001'),
        trustedDeviceId: connection.trustedDeviceId,
      }),
      // oxlint-disable-next-line vitest/prefer-to-be-falsy -- The strict boolean matcher is required by vitest/prefer-strict-boolean-matchers.
    ).resolves.toBe(false);
  });

  it('stops a mailbox watch when the only other route is unverified', async () => {
    expect.assertions(1);

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
    for (const trustedDeviceId of [
      firstDevice.trustedDeviceId,
      secondDevice.trustedDeviceId,
    ]) {
      await registerGmailConnection(asUser, {
        emailAddress: 'matching@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId,
      });
    }
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'second-apns-token',
      trustedDeviceId: secondDevice.trustedDeviceId,
    });
    await expect(
      asUser.query(api.pushRelay.shouldStopGmailWatch, {
        opaqueConnectionId: opaqueConnectionId('gmail-user-001'),
        trustedDeviceId: firstDevice.trustedDeviceId,
      }),
    ).resolves.toBe(true);
  });

  it('stops a mailbox watch when the only other proof was invalidated', async () => {
    expect.assertions(2);

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
    for (const trustedDeviceId of [
      firstDevice.trustedDeviceId,
      secondDevice.trustedDeviceId,
    ]) {
      await registerGmailConnection(asUser, {
        emailAddress: 'matching@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId,
      });
    }
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'second-apns-token',
      trustedDeviceId: secondDevice.trustedDeviceId,
    });
    await t.run(async (ctx) => {
      const proofUpdatedAt = Date.now();
      const connection = await ctx.db
        .query('mailProviderConnections')
        .withIndex('by_productId_provider_deviceId_connectionId', (q) =>
          q
            .eq('productAccountId', secondDevice.productAccountId)
            .eq('provider', 'gmail')
            .eq('trustedDeviceId', secondDevice.trustedDeviceId)
            .eq('opaqueConnectionId', opaqueConnectionId('gmail-user-001')),
        )
        .unique();
      expect(connection).not.toBeNull();
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(connection!._id, {
        pushOwnershipVerifiedAt: proofUpdatedAt,
        pushVerifiedAt: proofUpdatedAt,
      });
      await ctx.db.patch(secondDevice.trustedDeviceId, {
        gmailPushProofsInvalidatedAt: proofUpdatedAt,
      });
    });

    await expect(
      asUser.query(api.pushRelay.shouldStopGmailWatch, {
        opaqueConnectionId: opaqueConnectionId('gmail-user-001'),
        trustedDeviceId: firstDevice.trustedDeviceId,
      }),
    ).resolves.toBe(true);
  });

  it('checks account routes before applying the connection cap', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      const otherProductAccountId = await ctx.db.insert('productAccounts', {
        createdAt: Date.now(),
        lastSeenAt: Date.now(),
        tokenIdentifier: 'other-account',
      });
      for (let index = 0; index < 100; index += 1) {
        const trustedDeviceId = await ctx.db.insert('trustedDevices', {
          deviceIdentifier: `other-device-${index}`,
          lastSeenAt: Date.now(),
          platform: 'ios',
          productAccountId: otherProductAccountId,
          registeredAt: Date.now(),
        });
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: Date.now(),
          emailAddress: 'shared@example.com',
          gmailRoutingDigest: routingDigest('shared@example.com'),
          gmailRoutingKeyVersion: 1,
          lastVerifiedAt: Date.now(),
          productAccountId: otherProductAccountId,
          provider: 'gmail',
          providerAccountIdentifier: `other-gmail-${index}`,
          opaqueConnectionId: opaqueConnectionId(`other-gmail-${index}`),
          trustedDeviceId,
          updatedAt: Date.now(),
        });
      }
    });
    const asUser = t.withIdentity(appleIdentity);
    const firstDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const secondDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    for (const trustedDeviceId of [
      firstDevice.trustedDeviceId,
      secondDevice.trustedDeviceId,
    ]) {
      await registerGmailConnection(asUser, {
        emailAddress: 'shared@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId,
      });
    }
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'second-apns-token',
      trustedDeviceId: secondDevice.trustedDeviceId,
    });

    await t.run(async (ctx) => {
      const connection = await ctx.db
        .query('mailProviderConnections')
        .withIndex('by_productId_provider_deviceId_connectionId', (q) =>
          q
            .eq('productAccountId', secondDevice.productAccountId)
            .eq('provider', 'gmail')
            .eq('trustedDeviceId', secondDevice.trustedDeviceId)
            .eq('opaqueConnectionId', opaqueConnectionId('gmail-user-001')),
        )
        .unique();
      expect(connection).not.toBeNull();
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(connection!._id, {
        pushOwnershipVerifiedAt: Date.now(),
        pushVerifiedAt: Date.now(),
      });
    });

    await expect(
      asUser.query(api.pushRelay.shouldStopGmailWatch, {
        opaqueConnectionId: opaqueConnectionId('gmail-user-001'),
        trustedDeviceId: firstDevice.trustedDeviceId,
      }),
      // oxlint-disable-next-line vitest/prefer-to-be-falsy -- The strict boolean matcher is required by vitest/prefer-strict-boolean-matchers.
    ).resolves.toBe(false);
  });

  it('registers APNs routing data for an owned trusted device', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connection = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    const result = await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'sandbox',
      apnsToken: 'apns-device-token',
      trustedDeviceId: connection.trustedDeviceId,
    });

    expect(result).toStrictEqual({ registered: true });
    await expect(
      asUser.mutation(api.pushRelay.unregisterDevice, {
        trustedDeviceId: connection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ registered: false });
    const otherUser = t.withIdentity({
      ...appleIdentity,
      subject: 'apple-user-002',
      tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
    });
    await otherUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'ios',
    });
    await expect(
      otherUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'sandbox',
        apnsToken: 'other-apns-device-token',
        trustedDeviceId: connection.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
  });

  it('clears a reused APNs token from the previous device route', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const firstUser = t.withIdentity(appleIdentity);
    const firstConnection = await firstUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    const secondUser = t.withIdentity({
      ...appleIdentity,
      subject: 'apple-user-002',
      tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
    });
    const secondConnection = await secondUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-002',
        platform: 'ios',
      },
    );

    await firstUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'sandbox',
      apnsToken: 'shared-apns-token',
      trustedDeviceId: firstConnection.trustedDeviceId,
    });
    await secondUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'shared-apns-token',
      trustedDeviceId: secondConnection.trustedDeviceId,
    });

    await expect(
      t.run((ctx) => ctx.db.get(firstConnection.trustedDeviceId)),
    ).resolves.toStrictEqual(
      expect.not.objectContaining({
        apnsEnvironment: expect.anything(),
        apnsToken: expect.anything(),
      }),
    );
    await expect(
      t.run((ctx) => ctx.db.get(secondConnection.trustedDeviceId)),
    ).resolves.toStrictEqual(
      expect.objectContaining({
        apnsEnvironment: 'production',
        apnsToken: 'shared-apns-token',
      }),
    );
  });

  it('reconciles stale APNs routes without clearing a refreshed route', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const staleDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-stale',
      platform: 'ios',
    });
    const legacyStaleDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-legacy-stale',
        platform: 'ios',
      },
    );
    const refreshedDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-refreshed',
      platform: 'ios',
    });
    await registerGmailConnection(asUser, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-legacy-stale',
      trustedDeviceId: legacyStaleDevice.trustedDeviceId,
    });
    await registerGmailConnection(asUser, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-stale',
      trustedDeviceId: staleDevice.trustedDeviceId,
    });
    await registerGmailConnection(asUser, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-refreshed',
      trustedDeviceId: refreshedDevice.trustedDeviceId,
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'sandbox',
      apnsToken: 'stale-apns-token',
      trustedDeviceId: staleDevice.trustedDeviceId,
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'sandbox',
      apnsToken: 'legacy-stale-apns-token',
      trustedDeviceId: legacyStaleDevice.trustedDeviceId,
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'refreshed-apns-token',
      trustedDeviceId: refreshedDevice.trustedDeviceId,
    });

    const staleBefore = Date.now() - 1000;
    await t.run(async (ctx) => {
      const staleHeartbeat = await ctx.db
        .query('devicePushRouteHeartbeats')
        .withIndex('by_trustedDeviceId', (q) =>
          q.eq('trustedDeviceId', staleDevice.trustedDeviceId),
        )
        .unique();
      const legacyStaleHeartbeat = await ctx.db
        .query('devicePushRouteHeartbeats')
        .withIndex('by_trustedDeviceId', (q) =>
          q.eq('trustedDeviceId', legacyStaleDevice.trustedDeviceId),
        )
        .unique();
      const refreshedHeartbeat = await ctx.db
        .query('devicePushRouteHeartbeats')
        .withIndex('by_trustedDeviceId', (q) =>
          q.eq('trustedDeviceId', refreshedDevice.trustedDeviceId),
        )
        .unique();
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(staleHeartbeat!._id, { refreshedAt: staleBefore - 1 });
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.delete(legacyStaleHeartbeat!._id);
      await ctx.db.patch(legacyStaleDevice.trustedDeviceId, {
        lastSeenAt: staleBefore - 1,
      });
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(refreshedHeartbeat!._id, {
        refreshedAt: staleBefore + 1,
      });
      const connections = await ctx.db
        .query('mailProviderConnections')
        .withIndex('by_gmailRoutingDigest_and_pushVerifiedAt', (q) =>
          q.eq('gmailRoutingDigest', routingDigest('matching@example.com')),
        )
        .take(3);
      await Promise.all(
        connections.map((connection) =>
          // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
          ctx.db.patch(connection._id, {
            pushOwnershipVerifiedAt: staleBefore,
            pushVerifiedAt: staleBefore,
          }),
        ),
      );
    });

    await expect(
      t.mutation(internal.pushRelay.reconcileStaleDevicePushRoutes, {
        staleBefore,
      }),
    ).resolves.toStrictEqual({ clearedRouteCount: 2 });
    await expect(
      t.query(internal.pushRelay.resolveGmailRecipients, {
        routingDigest: routingDigest('matching@example.com'),
      }),
    ).resolves.toStrictEqual([
      {
        apnsEnvironment: 'production',
        apnsToken: 'refreshed-apns-token',
        pushCleanupGeneration: expect.any(Number),
        routeId: expect.any(String),
        trustedDeviceId: refreshedDevice.trustedDeviceId,
      },
    ]);
  });

  it('keeps a re-registered route after a delayed stale-token clear', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'sandbox',
      apnsToken: 'reused-apns-token',
      trustedDeviceId: device.trustedDeviceId,
    });
    const originalRoute = await t.run((ctx) =>
      ctx.db.get(device.trustedDeviceId),
    );
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'reused-apns-token',
      trustedDeviceId: device.trustedDeviceId,
    });
    await t.mutation(internal.pushRelay.clearStaleDevice, {
      apnsToken: 'reused-apns-token',
      pushCleanupGeneration: originalRoute!.pushCleanupGeneration!,
      trustedDeviceId: device.trustedDeviceId,
    });

    const refreshedRoute = await t.run((ctx) =>
      ctx.db.get(device.trustedDeviceId),
    );
    expect(refreshedRoute).toStrictEqual(
      expect.objectContaining({
        apnsEnvironment: 'production',
        apnsToken: 'reused-apns-token',
      }),
    );
  });

  it('drops a queued wakeup after its Gmail connection is removed', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-queued-removal',
      platform: 'ios',
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'queued-removal-token',
      trustedDeviceId: device.trustedDeviceId,
    });
    const opaqueConnection = opaqueConnectionId('queued-removal-gmail');
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        gmailRoutingDigest: routingDigest('queued-removal@example.com'),
        gmailRoutingKeyVersion: 1,
        lastVerifiedAt: now,
        opaqueConnectionId: opaqueConnection,
        productAccountId: device.productAccountId,
        provider: 'gmail',
        pushOwnershipVerifiedAt: now,
        pushVerifiedAt: now,
        trustedDeviceId: device.trustedDeviceId,
        updatedAt: now,
      });
    });
    const queued = await t.query(internal.pushRelay.resolveGmailRecipients, {
      routingDigest: routingDigest('queued-removal@example.com'),
    });
    expect(queued).toHaveLength(1);

    await asUser.mutation(api.pushRelay.removeGmailConnection, {
      opaqueConnectionId: opaqueConnection,
      trustedDeviceId: device.trustedDeviceId,
    });

    await expect(
      t.query(internal.pushRelay.revalidateGmailRecipients, {
        recipients: queued,
      }),
    ).resolves.toStrictEqual([]);
  });

  it('routes verified legacy Gmail rows during backend rollout', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-legacy-route-fallback',
      platform: 'ios',
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'legacy-route-token',
      trustedDeviceId: device.trustedDeviceId,
    });
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        emailAddress: 'legacy-route@example.com',
        lastVerifiedAt: now,
        productAccountId: device.productAccountId,
        provider: 'gmail',
        providerAccountIdentifier: 'legacy-route-user',
        pushOwnershipVerifiedAt: now,
        pushVerifiedAt: now,
        trustedDeviceId: device.trustedDeviceId,
        updatedAt: now,
      });
    });

    await expect(
      t.query(internal.pushRelay.resolveGmailRecipients, {
        emailAddress: 'legacy-route@example.com',
        routingDigest: routingDigest('legacy-route@example.com'),
      }),
    ).resolves.toStrictEqual([
      {
        apnsEnvironment: 'production',
        apnsToken: 'legacy-route-token',
        pushCleanupGeneration: expect.any(Number),
        routeId: expect.any(String),
        trustedDeviceId: device.trustedDeviceId,
      },
    ]);
  });

  it('removes a matching legacy Gmail connection by its opaque identifier', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-legacy-removal',
      platform: 'ios',
    });
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        emailAddress: 'legacy@example.com',
        lastVerifiedAt: now,
        productAccountId: device.productAccountId,
        provider: 'gmail',
        providerAccountIdentifier: 'legacy-gmail-user',
        trustedDeviceId: device.trustedDeviceId,
        updatedAt: now,
      });
    });

    await expect(
      asUser.mutation(api.pushRelay.removeGmailConnection, {
        opaqueConnectionId: await opaqueGmailConnectionId(
          device.productAccountId,
          'legacy-gmail-user',
        ),
        trustedDeviceId: device.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({
      hasRemainingGmailConnections: false,
      removed: true,
    });
    await expect(
      t.run((ctx) =>
        ctx.db
          .query('mailProviderConnections')
          .withIndex(
            'by_productAccountId_and_provider_and_trustedDeviceId',
            (q) =>
              q
                .eq('productAccountId', device.productAccountId)
                .eq('provider', 'gmail')
                .eq('trustedDeviceId', device.trustedDeviceId),
          )
          .collect(),
      ),
    ).resolves.toStrictEqual([]);
  });

  it('retains an identity binding while a matching legacy route remains', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const firstDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-current-binding',
      platform: 'ios',
    });
    const secondDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-legacy-binding',
      platform: 'macos',
    });
    const opaqueConnection = await opaqueGmailConnectionId(
      firstDevice.productAccountId,
      'shared-legacy-user',
    );
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        gmailRoutingDigest: routingDigest('shared-legacy@example.com'),
        gmailRoutingKeyVersion: 1,
        lastVerifiedAt: now,
        opaqueConnectionId: opaqueConnection,
        productAccountId: firstDevice.productAccountId,
        provider: 'gmail',
        trustedDeviceId: firstDevice.trustedDeviceId,
        updatedAt: now,
      });
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        emailAddress: 'shared-legacy@example.com',
        lastVerifiedAt: now,
        productAccountId: secondDevice.productAccountId,
        provider: 'gmail',
        providerAccountIdentifier: 'shared-legacy-user',
        trustedDeviceId: secondDevice.trustedDeviceId,
        updatedAt: now,
      });
      await ctx.db.insert('gmailOpaqueIdentityBindings', {
        identityBindingDigest: 'identity:shared-legacy-user',
        opaqueConnectionId: opaqueConnection,
        productAccountId: firstDevice.productAccountId,
        updatedAt: now,
      });
    });

    await asUser.mutation(api.pushRelay.removeGmailConnection, {
      opaqueConnectionId: opaqueConnection,
      trustedDeviceId: firstDevice.trustedDeviceId,
    });

    await expect(
      t.run((ctx) =>
        ctx.db
          .query('gmailOpaqueIdentityBindings')
          .withIndex('by_productAccountId_and_opaqueConnectionId', (q) =>
            q
              .eq('productAccountId', firstDevice.productAccountId)
              .eq('opaqueConnectionId', opaqueConnection),
          )
          .unique(),
      ),
    ).resolves.not.toBeNull();
  });

  it('retains an identity binding when legacy cleanup reaches its inspection limit', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-bounded-legacy-binding',
      platform: 'ios',
    });
    const opaqueConnection = await opaqueGmailConnectionId(
      device.productAccountId,
      'removed-user',
    );
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        gmailRoutingDigest: routingDigest('removed@example.com'),
        gmailRoutingKeyVersion: 1,
        lastVerifiedAt: now,
        opaqueConnectionId: opaqueConnection,
        productAccountId: device.productAccountId,
        provider: 'gmail',
        trustedDeviceId: device.trustedDeviceId,
        updatedAt: now,
      });
      for (let index = 0; index <= 100; index += 1) {
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: now,
          emailAddress: `legacy-${String(index)}@example.com`,
          lastVerifiedAt: now,
          productAccountId: device.productAccountId,
          provider: 'gmail',
          providerAccountIdentifier: `legacy-user-${String(index)}`,
          trustedDeviceId: device.trustedDeviceId,
          updatedAt: now,
        });
      }
      await ctx.db.insert('gmailOpaqueIdentityBindings', {
        identityBindingDigest: 'identity:removed-user',
        opaqueConnectionId: opaqueConnection,
        productAccountId: device.productAccountId,
        updatedAt: now,
      });
    });

    await expect(
      asUser.mutation(api.pushRelay.removeGmailConnection, {
        opaqueConnectionId: opaqueConnection,
        trustedDeviceId: device.trustedDeviceId,
      }),
    ).resolves.toMatchObject({ removed: true });
    await expect(
      t.run((ctx) =>
        ctx.db
          .query('gmailOpaqueIdentityBindings')
          .withIndex('by_productAccountId_and_opaqueConnectionId', (q) =>
            q
              .eq('productAccountId', device.productAccountId)
              .eq('opaqueConnectionId', opaqueConnection),
          )
          .unique(),
      ),
    ).resolves.not.toBeNull();
  });

  it('keeps the cleanup generation for a same-route registration heartbeat', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'heartbeat-apns-token',
      trustedDeviceId: device.trustedDeviceId,
    });
    const originalRoute = await t.run((ctx) =>
      ctx.db.get(device.trustedDeviceId),
    );
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'heartbeat-apns-token',
      trustedDeviceId: device.trustedDeviceId,
    });
    await t.mutation(internal.pushRelay.clearStaleDevice, {
      apnsToken: 'heartbeat-apns-token',
      pushCleanupGeneration: originalRoute!.pushCleanupGeneration!,
      trustedDeviceId: device.trustedDeviceId,
    });

    await expect(
      t.run((ctx) => ctx.db.get(device.trustedDeviceId)),
    ).resolves.toStrictEqual(
      expect.not.objectContaining({ apnsToken: expect.anything() }),
    );
  });

  it('clears a legacy route after a stale-token delivery failure', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const deviceId = await t.run(async (ctx) => {
      const productAccountId = await ctx.db.insert('productAccounts', {
        createdAt: Date.now(),
        lastSeenAt: Date.now(),
        tokenIdentifier: 'legacy-device-account',
      });
      return ctx.db.insert('trustedDevices', {
        apnsEnvironment: 'production',
        apnsToken: 'legacy-apns-token',
        deviceIdentifier: 'legacy-device',
        lastSeenAt: Date.now(),
        platform: 'ios',
        productAccountId,
        registeredAt: Date.now(),
      });
    });

    await t.mutation(internal.pushRelay.clearStaleDevice, {
      apnsToken: 'legacy-apns-token',
      pushCleanupGeneration: 0,
      trustedDeviceId: deviceId,
    });

    await expect(t.run((ctx) => ctx.db.get(deviceId))).resolves.toStrictEqual(
      expect.not.objectContaining({ apnsToken: expect.anything() }),
    );
  });

  it('requires fresh Gmail push proof after device unregistration', async () => {
    expect.assertions(2);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const connection = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      await registerGmailConnection(asUser, {
        emailAddress: 'matching@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId: connection.trustedDeviceId,
      });
      await asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingIdentityToken,
        ),
        historyId: '100',
        trustedDeviceId: connection.trustedDeviceId,
      });
      await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
        routingDigest: routingDigest('matching@example.com'),
        historyId: '100',
      });
      await t.run(async (ctx) => {
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: Date.now(),
          emailAddress: 'matching@example.com',
          gmailRoutingDigest: routingDigest('matching@example.com'),
          gmailRoutingKeyVersion: 1,
          lastVerifiedAt: Date.now(),
          productAccountId: connection.productAccountId,
          provider: 'gmail',
          providerAccountIdentifier: 'duplicate-gmail-user-001',
          opaqueConnectionId: opaqueConnectionId('duplicate-gmail-user-001'),
          pushVerificationHistoryId: '100',
          pushVerificationOwnershipVerifiedAt: Date.now(),
          pushVerificationRequestedAt: Date.now(),
          pushVerifiedHistoryId: '100',
          pushOwnershipVerifiedAt: Date.now(),
          pushVerifiedAt: Date.now(),
          trustedDeviceId: connection.trustedDeviceId,
          updatedAt: Date.now(),
        });
        for (let index = 0; index < 9; index += 1) {
          await ctx.db.insert('mailProviderConnections', {
            connectedAt: Date.now(),
            emailAddress: 'matching@example.com',
            gmailRoutingDigest: routingDigest('matching@example.com'),
            gmailRoutingKeyVersion: 1,
            lastVerifiedAt: Date.now(),
            productAccountId: connection.productAccountId,
            provider: 'gmail',
            providerAccountIdentifier: `duplicate-gmail-user-${index}`,
            opaqueConnectionId: opaqueConnectionId(
              `duplicate-gmail-user-${index}`,
            ),
            pushVerifiedHistoryId: '100',
            pushOwnershipVerifiedAt: Date.now(),
            pushVerifiedAt: Date.now(),
            trustedDeviceId: connection.trustedDeviceId,
            updatedAt: Date.now(),
          });
        }
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'first-apns-token',
        trustedDeviceId: connection.trustedDeviceId,
      });

      await expect(
        asUser.mutation(api.pushRelay.unregisterDevice, {
          trustedDeviceId: connection.trustedDeviceId,
        }),
      ).resolves.toStrictEqual({ registered: false });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'second-apns-token',
        trustedDeviceId: connection.trustedDeviceId,
      });
      await expect(
        t.query(internal.pushRelay.resolveGmailRecipients, {
          routingDigest: routingDigest('matching@example.com'),
        }),
      ).resolves.toStrictEqual([]);
      await t.finishAllScheduledFunctions(vi.runAllTimers);
    } finally {
      vi.useRealTimers();
    }
  });

  it('accepts a proof refreshed in the cleanup millisecond', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date('2026-01-01T00:00:00.000Z'));
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const connection = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      await registerGmailConnection(asUser, {
        emailAddress: 'matching@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId: connection.trustedDeviceId,
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'first-apns-token',
        trustedDeviceId: connection.trustedDeviceId,
      });
      await asUser.mutation(api.pushRelay.unregisterDevice, {
        trustedDeviceId: connection.trustedDeviceId,
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'second-apns-token',
        trustedDeviceId: connection.trustedDeviceId,
      });
      await asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingIdentityToken,
        ),
        historyId: '100',
        trustedDeviceId: connection.trustedDeviceId,
      });

      await expect(
        t.mutation(internal.pushRelay.enqueueGmailWakeups, {
          routingDigest: routingDigest('matching@example.com'),
          historyId: '100',
        }),
      ).resolves.toStrictEqual({ recipientCount: 1 });
    } finally {
      vi.useRealTimers();
    }
  });

  it('clears every Gmail push proof in bounded continuations', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const device = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      const verifiedAt = Date.now();
      await t.run(async (ctx) => {
        for (let index = 0; index < 11; index += 1) {
          await ctx.db.insert('mailProviderConnections', {
            connectedAt: verifiedAt,
            emailAddress: `matching-${index}@example.com`,
            gmailRoutingDigest: routingDigest(`matching-${index}@example.com`),
            gmailRoutingKeyVersion: 1,
            lastVerifiedAt: verifiedAt,
            productAccountId: device.productAccountId,
            provider: 'gmail',
            providerAccountIdentifier: `gmail-user-${index}`,
            opaqueConnectionId: opaqueConnectionId(`gmail-user-${index}`),
            pushVerifiedHistoryId: '100',
            pushOwnershipVerifiedAt: verifiedAt,
            pushVerifiedAt: verifiedAt,
            trustedDeviceId: device.trustedDeviceId,
            updatedAt: verifiedAt,
          });
        }
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'first-apns-token',
        trustedDeviceId: device.trustedDeviceId,
      });

      await asUser.mutation(api.pushRelay.unregisterDevice, {
        trustedDeviceId: device.trustedDeviceId,
      });
      await t.finishAllScheduledFunctions(vi.runAllTimers);

      const proofsWereCleared = await t.run(async (ctx) => {
        const connections = await ctx.db
          .query('mailProviderConnections')
          .withIndex(
            'by_productAccountId_and_provider_and_trustedDeviceId',
            (q) =>
              q
                .eq('productAccountId', device.productAccountId)
                .eq('provider', 'gmail')
                .eq('trustedDeviceId', device.trustedDeviceId),
          )
          .take(11);
        return connections.map((connection) => ({
          pushVerifiedAt: connection.pushVerifiedAt,
          pushVerifiedHistoryId: connection.pushVerifiedHistoryId,
        }));
      });
      expect(proofsWereCleared).toStrictEqual(
        Array.from({ length: 11 }, () => ({})),
      );
    } finally {
      vi.useRealTimers();
    }
  });

  it('preserves refreshed proofs while clearing stale paginated proofs', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const device = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      const originalVerifiedAt = Date.now();
      await t.run(async (ctx) => {
        for (let index = 0; index < 12; index += 1) {
          await ctx.db.insert('mailProviderConnections', {
            connectedAt: originalVerifiedAt,
            emailAddress: `matching-${index}@example.com`,
            gmailRoutingDigest: routingDigest(`matching-${index}@example.com`),
            gmailRoutingKeyVersion: 1,
            lastVerifiedAt: originalVerifiedAt,
            productAccountId: device.productAccountId,
            provider: 'gmail',
            providerAccountIdentifier: `gmail-user-${index}`,
            opaqueConnectionId: opaqueConnectionId(`gmail-user-${index}`),
            pushVerifiedHistoryId: '100',
            pushOwnershipVerifiedAt: originalVerifiedAt,
            pushVerifiedAt: originalVerifiedAt,
            trustedDeviceId: device.trustedDeviceId,
            updatedAt: originalVerifiedAt,
          });
        }
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'first-apns-token',
        trustedDeviceId: device.trustedDeviceId,
      });
      await asUser.mutation(api.pushRelay.unregisterDevice, {
        trustedDeviceId: device.trustedDeviceId,
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'second-apns-token',
        trustedDeviceId: device.trustedDeviceId,
      });
      const refreshedVerifiedAt = originalVerifiedAt + 1;
      await t.run(async (ctx) => {
        const connections = await ctx.db
          .query('mailProviderConnections')
          .withIndex(
            'by_productAccountId_and_provider_and_trustedDeviceId',
            (q) =>
              q
                .eq('productAccountId', device.productAccountId)
                .eq('provider', 'gmail')
                .eq('trustedDeviceId', device.trustedDeviceId),
          )
          .take(12);
        await Promise.all(
          connections.slice(-1).map((connection) =>
            // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
            ctx.db.patch(connection._id, {
              pushVerificationHistoryId: '101',
              pushVerificationOwnershipVerifiedAt: refreshedVerifiedAt,
              pushVerificationRequestedAt: refreshedVerifiedAt,
            }),
          ),
        );
      });

      await t.finishAllScheduledFunctions(vi.runAllTimers);

      const proofCleanupState = await t.run(async (ctx) => {
        const connections = await ctx.db
          .query('mailProviderConnections')
          .withIndex(
            'by_productAccountId_and_provider_and_trustedDeviceId',
            (q) =>
              q
                .eq('productAccountId', device.productAccountId)
                .eq('provider', 'gmail')
                .eq('trustedDeviceId', device.trustedDeviceId),
          )
          .take(12);
        return connections.map((connection) => ({
          pushVerificationHistoryId: connection.pushVerificationHistoryId,
          pushVerificationRequestedAt: connection.pushVerificationRequestedAt,
          pushVerifiedHistoryId: connection.pushVerifiedHistoryId,
          pushVerifiedAt: connection.pushVerifiedAt,
        }));
      });
      expect(proofCleanupState).toStrictEqual([
        ...Array.from({ length: 11 }, () => ({})),
        {
          pushVerificationHistoryId: '101',
          pushVerificationRequestedAt: refreshedVerifiedAt,
        },
      ]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('drains reused APNs token cleanup after the owner signs out', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'current-device',
        platform: 'ios',
      });
      await t.run(async (ctx) => {
        for (let index = 0; index < 101; index += 1) {
          await ctx.db.insert('trustedDevices', {
            apnsEnvironment: 'sandbox',
            apnsToken: 'shared-apns-token',
            deviceIdentifier: `old-device-${index}`,
            lastSeenAt: Date.now(),
            platform: 'ios',
            productAccountId: currentDevice.productAccountId,
            registeredAt: Date.now(),
          });
        }
      });

      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'shared-apns-token',
        trustedDeviceId: currentDevice.trustedDeviceId,
      });
      await asUser.mutation(api.pushRelay.unregisterDevice, {
        trustedDeviceId: currentDevice.trustedDeviceId,
      });
      await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'old-device-0',
        platform: 'ios',
      });
      await t.finishAllScheduledFunctions(vi.runAllTimers);

      const routes = await t.run((ctx) =>
        ctx.db
          .query('trustedDevices')
          .withIndex('by_apnsToken', (q) =>
            q.eq('apnsToken', 'shared-apns-token'),
          )
          .take(102),
      );
      expect(routes).toStrictEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('drains reused APNs token cleanup after the owner rotates tokens', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'current-device',
        platform: 'ios',
      });
      await t.run(async (ctx) => {
        for (let index = 0; index < 101; index += 1) {
          await ctx.db.insert('trustedDevices', {
            apnsEnvironment: 'sandbox',
            apnsToken: 'shared-apns-token',
            deviceIdentifier: `old-device-${index}`,
            lastSeenAt: Date.now(),
            platform: 'ios',
            productAccountId: currentDevice.productAccountId,
            registeredAt: Date.now(),
          });
        }
      });

      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'shared-apns-token',
        trustedDeviceId: currentDevice.trustedDeviceId,
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'rotated-apns-token',
        trustedDeviceId: currentDevice.trustedDeviceId,
      });
      await t.finishAllScheduledFunctions(vi.runAllTimers);

      await expect(
        t.run((ctx) =>
          ctx.db
            .query('trustedDevices')
            .withIndex('by_apnsToken', (q) =>
              q.eq('apnsToken', 'shared-apns-token'),
            )
            .take(101),
        ),
      ).resolves.toStrictEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('stops reused-token cleanup when another device takes ownership', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const firstDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'first-device',
        platform: 'ios',
      });
      const secondDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'second-device',
        platform: 'ios',
      });
      await t.run(async (ctx) => {
        for (let index = 0; index < 10; index += 1) {
          await ctx.db.insert('trustedDevices', {
            apnsEnvironment: 'sandbox',
            apnsToken: 'shared-apns-token',
            deviceIdentifier: `old-device-${index}`,
            lastSeenAt: Date.now(),
            platform: 'ios',
            productAccountId: firstDevice.productAccountId,
            registeredAt: Date.now(),
          });
        }
      });

      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'shared-apns-token',
        trustedDeviceId: firstDevice.trustedDeviceId,
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'shared-apns-token',
        trustedDeviceId: secondDevice.trustedDeviceId,
      });
      await t.finishAllScheduledFunctions(vi.runAllTimers);

      const routes = await t.run((ctx) =>
        ctx.db
          .query('trustedDevices')
          .withIndex('by_apnsToken', (q) =>
            q.eq('apnsToken', 'shared-apns-token'),
          )
          .take(12),
      );
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      expect(routes.map((route) => route._id)).toStrictEqual([
        secondDevice.trustedDeviceId,
      ]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('continues route reconciliation and backfills a fresh legacy route', async () => {
    expect.assertions(2);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const connectRoute = async (index: number) => {
        const device = await asUser.mutation(api.productAccount.connect, {
          deviceIdentifier: `device-${index}`,
          platform: 'ios',
        });
        await asUser.mutation(api.pushRelay.registerDevice, {
          apnsEnvironment: 'sandbox',
          apnsToken: `route-token-${String(index).padStart(2, '0')}`,
          trustedDeviceId: device.trustedDeviceId,
        });
        return device;
      };
      for (let index = 0; index < 9; index += 1) {
        await connectRoute(index);
      }
      const freshLegacyDevice = await connectRoute(9);
      const staleSecondPageDevice = await connectRoute(10);
      const staleBefore = Date.now() - 1000;
      const freshLegacyLastSeenAt = await t.run(async (ctx) => {
        const freshLegacyHeartbeat = await ctx.db
          .query('devicePushRouteHeartbeats')
          .withIndex('by_trustedDeviceId', (q) =>
            q.eq('trustedDeviceId', freshLegacyDevice.trustedDeviceId),
          )
          .unique();
        const staleHeartbeat = await ctx.db
          .query('devicePushRouteHeartbeats')
          .withIndex('by_trustedDeviceId', (q) =>
            q.eq('trustedDeviceId', staleSecondPageDevice.trustedDeviceId),
          )
          .unique();
        const freshLegacyRoute = await ctx.db.get(
          freshLegacyDevice.trustedDeviceId,
        );
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        await ctx.db.delete(freshLegacyHeartbeat!._id);
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        await ctx.db.patch(staleHeartbeat!._id, {
          refreshedAt: staleBefore - 1,
        });
        return freshLegacyRoute!.lastSeenAt;
      });

      await t.mutation(internal.pushRelay.reconcileStaleDevicePushRoutes, {
        staleBefore,
      });
      await t.finishAllScheduledFunctions(vi.runAllTimers);

      const state = await t.run(async (ctx) => ({
        freshLegacyHeartbeat: await ctx.db
          .query('devicePushRouteHeartbeats')
          .withIndex('by_trustedDeviceId', (q) =>
            q.eq('trustedDeviceId', freshLegacyDevice.trustedDeviceId),
          )
          .unique(),
        staleRoute: await ctx.db.get(staleSecondPageDevice.trustedDeviceId),
      }));
      expect(state.freshLegacyHeartbeat).toStrictEqual(
        expect.objectContaining({ refreshedAt: freshLegacyLastSeenAt }),
      );
      expect(state.staleRoute).not.toHaveProperty('apnsToken');
    } finally {
      vi.useRealTimers();
    }
  });

  it('upgrades an already verified route during routing-key rotation', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await registerGmailConnection(asUser, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: device.trustedDeviceId,
    });
    await t.run(async (ctx) => {
      const connection = await ctx.db
        .query('mailProviderConnections')
        .withIndex('by_productId_provider_deviceId_connectionId', (q) =>
          q
            .eq('productAccountId', device.productAccountId)
            .eq('provider', 'gmail')
            .eq('trustedDeviceId', device.trustedDeviceId)
            .eq('opaqueConnectionId', opaqueConnectionId('gmail-user-001')),
        )
        .unique();
      const now = Date.now();
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(connection!._id, {
        pushOwnershipVerifiedAt: now,
        pushVerifiedAt: now,
        pushVerifiedHistoryId: 'verified-history',
      });
    });

    vi.stubEnv('GMAIL_ROUTING_KEY', 'rotated-routing-test-key');
    vi.stubEnv('GMAIL_ROUTING_KEY_VERSION', '2');
    vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY', 'gmail-routing-test-key');
    vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY_VERSION', '1');
    try {
      await expect(
        asUser.action(api.pushRelay.verifyGmailWatch, {
          gmailIdentityToken: matchingIdentityToken,
          historyId: 'verified-history',
          opaqueConnectionId: opaqueConnectionId('gmail-user-001'),
          trustedDeviceId: device.trustedDeviceId,
        }),
      ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
      const route = await t.run((ctx) =>
        ctx.db
          .query('mailProviderConnections')
          .withIndex('by_productId_provider_deviceId_connectionId', (q) =>
            q
              .eq('productAccountId', device.productAccountId)
              .eq('provider', 'gmail')
              .eq('trustedDeviceId', device.trustedDeviceId)
              .eq('opaqueConnectionId', opaqueConnectionId('gmail-user-001')),
          )
          .unique(),
      );
      expect(route?.gmailRoutingDigest).toBe(
        versionedRoutingDigest(
          'matching@example.com',
          'rotated-routing-test-key',
          2,
        ),
      );
      vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY', '');
      vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY_VERSION', '');
      const secondDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-002',
        platform: 'ios',
      });
      await expect(
        registerGmailConnection(asUser, {
          emailAddress: 'matching@example.com',
          providerAccountIdentifier: 'gmail-user-001',
          trustedDeviceId: secondDevice.trustedDeviceId,
        }),
      ).resolves.toStrictEqual(
        expect.objectContaining({
          opaqueConnectionId: opaqueConnectionId('gmail-user-001'),
        }),
      );
    } finally {
      vi.stubEnv('GMAIL_ROUTING_KEY', 'gmail-routing-test-key');
      vi.stubEnv('GMAIL_ROUTING_KEY_VERSION', '');
      vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY', '');
      vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY_VERSION', '');
    }
  });

  it('keeps a dormant identity binding valid after routing-key rotation', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const firstDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await registerGmailConnection(asUser, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: firstDevice.trustedDeviceId,
    });

    vi.stubEnv('GMAIL_ROUTING_KEY', 'rotated-routing-test-key');
    vi.stubEnv('GMAIL_ROUTING_KEY_VERSION', '2');
    try {
      const secondDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-002',
        platform: 'ios',
      });
      await expect(
        registerGmailConnection(asUser, {
          emailAddress: 'matching@example.com',
          providerAccountIdentifier: 'gmail-user-001',
          trustedDeviceId: secondDevice.trustedDeviceId,
        }),
      ).resolves.toStrictEqual(
        expect.objectContaining({
          opaqueConnectionId: opaqueConnectionId('gmail-user-001'),
        }),
      );
    } finally {
      vi.stubEnv('GMAIL_ROUTING_KEY', 'gmail-routing-test-key');
      vi.stubEnv('GMAIL_ROUTING_KEY_VERSION', '');
    }
  });

  it('associates minimal Gmail metadata only with matching connected devices', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const firstUser = t.withIdentity(appleIdentity);
    const secondUser = t.withIdentity({
      ...appleIdentity,
      subject: 'apple-user-002',
      tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
    });
    const firstConnection = await firstUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    const secondConnection = await secondUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-002',
        platform: 'macos',
      },
    );

    await registerGmailConnection(firstUser, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: firstConnection.trustedDeviceId,
    });
    await registerGmailConnection(secondUser, {
      emailAddress: 'other@example.com',
      providerAccountIdentifier: 'gmail-user-002',
      trustedDeviceId: secondConnection.trustedDeviceId,
    });
    await secondUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'other-apns-token',
      trustedDeviceId: secondConnection.trustedDeviceId,
    });

    const recipients = await t.query(
      internal.pushRelay.resolveGmailRecipients,
      {
        routingDigest: routingDigest('matching@example.com'),
      },
    );

    expect(recipients).toStrictEqual([]);
    await expect(
      firstUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingIdentityToken,
        ),
        historyId: 'history-123',
        trustedDeviceId: firstConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: false }));
    await expect(
      t.mutation(internal.pushRelay.enqueueGmailWakeups, {
        routingDigest: routingDigest('matching@example.com'),
        historyId: 'history-123',
      }),
    ).resolves.toStrictEqual({ recipientCount: 0 });
    await firstUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'matching-apns-token',
      trustedDeviceId: firstConnection.trustedDeviceId,
    });

    const verifiedRecipients = await t.query(
      internal.pushRelay.resolveGmailRecipients,
      {
        routingDigest: routingDigest('matching@example.com'),
      },
    );

    expect(verifiedRecipients).toStrictEqual([
      {
        apnsEnvironment: 'production',
        apnsToken: 'matching-apns-token',
        pushCleanupGeneration: expect.any(Number),
        routeId: expect.any(String),
        trustedDeviceId: firstConnection.trustedDeviceId,
      },
    ]);
    expect(JSON.stringify(verifiedRecipients)).not.toMatch(
      /accessToken|refreshToken|messageBody|category|classification/iu,
    );
  });

  it('enqueues a legacy Gmail route once during routing-key rotation', async () => {
    expect.assertions(1);
    vi.useFakeTimers();

    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      const productAccountId = await ctx.db.insert('productAccounts', {
        createdAt: now,
        lastSeenAt: now,
        tokenIdentifier: 'legacy-rotation-account',
      });
      const trustedDeviceId = await ctx.db.insert('trustedDevices', {
        apnsEnvironment: 'production',
        apnsToken: 'legacy-rotation-token',
        deviceIdentifier: 'legacy-rotation-device',
        lastSeenAt: now,
        platform: 'ios',
        productAccountId,
        registeredAt: now,
      });
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        emailAddress: 'legacy-rotation@example.com',
        lastVerifiedAt: now,
        productAccountId,
        provider: 'gmail',
        providerAccountIdentifier: 'legacy-rotation-user',
        pushOwnershipVerifiedAt: now,
        pushVerifiedAt: now,
        trustedDeviceId,
        updatedAt: now,
      });
    });

    vi.stubEnv('GMAIL_ROUTING_KEY', 'rotated-routing-test-key');
    vi.stubEnv('GMAIL_ROUTING_KEY_VERSION', '2');
    vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY', 'gmail-routing-test-key');
    vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY_VERSION', '1');
    try {
      await expect(
        t.action(internal.pushRelay.enqueueGmailWakeupsFromMetadata, {
          emailAddress: 'legacy-rotation@example.com',
          historyId: 'history-rotation',
        }),
      ).resolves.toStrictEqual({ recipientCount: 1 });
    } finally {
      vi.stubEnv('GMAIL_ROUTING_KEY', 'gmail-routing-test-key');
      vi.stubEnv('GMAIL_ROUTING_KEY_VERSION', '');
      vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY', '');
      vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY_VERSION', '');
      vi.clearAllTimers();
      vi.useRealTimers();
    }
  });

  it('keeps multiple Gmail verification signals until the matching device verifies', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const productConnection = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    await registerGmailConnection(asUser, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: productConnection.trustedDeviceId,
    });
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      routingDigest: routingDigest('matching@example.com'),
      historyId: 'history-first',
    });
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      routingDigest: routingDigest('matching@example.com'),
      historyId: 'history-second',
    });

    await expect(
      asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingIdentityToken,
        ),
        historyId: 'history-first',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
    await expect(
      asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingIdentityToken,
        ),
        historyId: 'history-first',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
  });

  it('keeps a newer Gmail proof timestamp when a delayed signal verifies', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const productConnection = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    await registerGmailConnection(asUser, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: productConnection.trustedDeviceId,
    });
    const newerProofAt = Date.now() + 1000;
    await t.run(async (ctx) => {
      const connection = await ctx.db
        .query('mailProviderConnections')
        .withIndex(
          'by_productAccountId_and_provider_and_trustedDeviceId',
          (q) =>
            q
              .eq('productAccountId', productConnection.productAccountId)
              .eq('provider', 'gmail')
              .eq('trustedDeviceId', productConnection.trustedDeviceId),
        )
        .unique();
      expect(connection).not.toBeNull();
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(connection!._id, {
        pushVerificationHistoryId: '100',
        pushVerificationOwnershipVerifiedAt: Date.now(),
        pushVerificationRequestedAt: Date.now(),
        pushOwnershipVerifiedAt: newerProofAt,
        pushVerifiedAt: newerProofAt,
      });
    });

    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      routingDigest: routingDigest('matching@example.com'),
      historyId: '100',
    });

    await expect(
      t.run(async (ctx) => {
        const connection = await ctx.db
          .query('mailProviderConnections')
          .withIndex(
            'by_productAccountId_and_provider_and_trustedDeviceId',
            (q) =>
              q
                .eq('productAccountId', productConnection.productAccountId)
                .eq('provider', 'gmail')
                .eq('trustedDeviceId', productConnection.trustedDeviceId),
          )
          .unique();
        return connection?.pushVerifiedAt;
      }),
    ).resolves.toBe(newerProofAt);
  });

  it('requires a Gmail signal received after proof invalidation', async () => {
    expect.assertions(2);
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date('2026-01-01T00:00:00.000Z'));
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const productConnection = await asUser.mutation(
        api.productAccount.connect,
        {
          deviceIdentifier: 'device-001',
          platform: 'ios',
        },
      );
      await registerGmailConnection(asUser, {
        emailAddress: 'matching@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId: productConnection.trustedDeviceId,
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'matching-apns-token',
        trustedDeviceId: productConnection.trustedDeviceId,
      });
      await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
        routingDigest: routingDigest('matching@example.com'),
        historyId: '100',
      });
      await asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingIdentityToken,
        ),
        historyId: '100',
        trustedDeviceId: productConnection.trustedDeviceId,
      });
      vi.advanceTimersByTime(1);
      await t.run(async (ctx) => {
        await ctx.db.patch(productConnection.trustedDeviceId, {
          gmailPushProofsInvalidatedAt: Date.now(),
        });
      });

      await expect(
        asUser.action(api.pushRelay.verifyGmailWatch, {
          gmailIdentityToken: matchingIdentityToken,
          opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
            matchingIdentityToken,
          ),
          historyId: '100',
          trustedDeviceId: productConnection.trustedDeviceId,
        }),
      ).resolves.toStrictEqual(expect.objectContaining({ verified: false }));
      await expect(
        t.mutation(internal.pushRelay.enqueueGmailWakeups, {
          routingDigest: routingDigest('matching@example.com'),
          historyId: '100',
        }),
      ).resolves.toStrictEqual({ recipientCount: 1 });
    } finally {
      vi.useRealTimers();
    }
  });

  it('does not refresh a pending Gmail proof requested before invalidation', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date('2026-01-01T00:00:00.000Z'));
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const productConnection = await asUser.mutation(
        api.productAccount.connect,
        {
          deviceIdentifier: 'device-001',
          platform: 'ios',
        },
      );
      await registerGmailConnection(asUser, {
        emailAddress: 'matching@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId: productConnection.trustedDeviceId,
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'matching-apns-token',
        trustedDeviceId: productConnection.trustedDeviceId,
      });
      await asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingIdentityToken,
        ),
        historyId: '100',
        trustedDeviceId: productConnection.trustedDeviceId,
      });
      vi.advanceTimersByTime(1);
      await t.run(async (ctx) => {
        const connection = await ctx.db
          .query('mailProviderConnections')
          .withIndex(
            'by_productAccountId_and_provider_and_trustedDeviceId',
            (q) =>
              q
                .eq('productAccountId', productConnection.productAccountId)
                .eq('provider', 'gmail')
                .eq('trustedDeviceId', productConnection.trustedDeviceId),
          )
          .unique();
        await ctx.db.patch(productConnection.trustedDeviceId, {
          gmailPushProofsInvalidatedAt: Date.now(),
        });
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        await ctx.db.patch(connection!._id, {
          pushVerificationHistoryId: '100',
          pushVerificationOwnershipVerifiedAt: Date.now() - 1,
          pushVerificationRequestedAt: Date.now() - 1,
          pushOwnershipVerifiedAt: undefined,
          pushVerifiedAt: undefined,
        });
      });

      await expect(
        t.mutation(internal.pushRelay.enqueueGmailWakeups, {
          routingDigest: routingDigest('matching@example.com'),
          historyId: '100',
        }),
      ).resolves.toStrictEqual({ recipientCount: 0 });
    } finally {
      vi.useRealTimers();
    }
  });

  it('keeps a Gmail verification signal available for another device', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const firstUser = t.withIdentity(appleIdentity);
    const secondUser = t.withIdentity({
      ...appleIdentity,
      subject: 'apple-user-002',
      tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
    });
    const firstConnection = await firstUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    const secondConnection = await secondUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-002',
        platform: 'ios',
      },
    );
    await registerGmailConnection(firstUser, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: firstConnection.trustedDeviceId,
    });
    await registerGmailConnection(secondUser, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: secondConnection.trustedDeviceId,
    });
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      routingDigest: routingDigest('matching@example.com'),
      historyId: 'history-shared',
    });

    await expect(
      firstUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingIdentityToken,
        ),
        historyId: 'history-shared',
        trustedDeviceId: firstConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
    await expect(
      secondUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingIdentityToken,
        ),
        historyId: 'history-shared',
        trustedDeviceId: secondConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
  });

  it('searches the newest Gmail verification signals first', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const productConnection = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    await registerGmailConnection(asUser, {
      emailAddress: 'busy@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: productConnection.trustedDeviceId,
    });
    await t.run(async (ctx) => {
      for (let index = 0; index < 100; index += 1) {
        await ctx.db.insert('gmailPushVerificationSignals', {
          emailAddress: 'busy@example.com',
          historyId: String(index),
          receivedAt: Date.now(),
        });
      }
    });
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      routingDigest: routingDigest('busy@example.com'),
      historyId: '200',
    });

    await expect(
      asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: busyIdentityToken,
        opaqueConnectionId:
          opaqueConnectionIdFromIdentityToken(busyIdentityToken),
        historyId: '150',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
  });

  it('expires verification signals without another Gmail push', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const signalId = await t.run((ctx) =>
      ctx.db.insert('gmailPushVerificationSignals', {
        emailAddress: 'quiet@example.com',
        historyId: '100',
        receivedAt: 100,
      }),
    );
    await t.run((ctx) => ctx.db.patch(signalId, { receivedAt: 200 }));

    await t.mutation(internal.pushRelay.expireGmailVerificationSignal, {
      receivedAt: 100,
      signalId,
    });
    await expect(t.run((ctx) => ctx.db.get(signalId))).resolves.not.toBeNull();

    await t.mutation(internal.pushRelay.expireGmailVerificationSignal, {
      receivedAt: 200,
      signalId,
    });
    await expect(t.run((ctx) => ctx.db.get(signalId))).resolves.toBeNull();
  });

  it('applies the Gmail recipient cap after filtering inactive routes', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const verifiedDeviceId = await t.run(async (ctx) => {
      const productAccountId = await ctx.db.insert('productAccounts', {
        createdAt: Date.now(),
        lastSeenAt: Date.now(),
        tokenIdentifier: 'verified-account',
      });
      for (let index = 0; index < 100; index += 1) {
        const trustedDeviceId = await ctx.db.insert('trustedDevices', {
          deviceIdentifier: `inactive-device-${index}`,
          lastSeenAt: Date.now(),
          platform: 'ios',
          productAccountId,
          registeredAt: Date.now(),
        });
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: Date.now(),
          emailAddress: 'crowded@example.com',
          gmailRoutingDigest: routingDigest('crowded@example.com'),
          gmailRoutingKeyVersion: 1,
          lastVerifiedAt: Date.now(),
          productAccountId,
          provider: 'gmail',
          providerAccountIdentifier: `inactive-${index}`,
          opaqueConnectionId: opaqueConnectionId(`inactive-${index}`),
          pushOwnershipVerifiedAt: Date.now(),
          pushVerifiedAt: Date.now(),
          trustedDeviceId,
          updatedAt: Date.now(),
        });
      }
      const trustedDeviceId = await ctx.db.insert('trustedDevices', {
        apnsEnvironment: 'production',
        apnsToken: 'verified-token',
        deviceIdentifier: 'verified-device',
        lastSeenAt: Date.now(),
        platform: 'ios',
        productAccountId,
        registeredAt: Date.now(),
      });
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: Date.now(),
        emailAddress: 'crowded@example.com',
        gmailRoutingDigest: routingDigest('crowded@example.com'),
        gmailRoutingKeyVersion: 1,
        lastVerifiedAt: Date.now(),
        productAccountId,
        provider: 'gmail',
        providerAccountIdentifier: 'verified',
        opaqueConnectionId: opaqueConnectionId('verified'),
        pushOwnershipVerifiedAt: Date.now(),
        pushVerifiedAt: Date.now(),
        trustedDeviceId,
        updatedAt: Date.now(),
      });
      return trustedDeviceId;
    });

    await expect(
      t.query(internal.pushRelay.resolveGmailRecipients, {
        routingDigest: routingDigest('crowded@example.com'),
      }),
    ).resolves.toStrictEqual([
      {
        apnsEnvironment: 'production',
        apnsToken: 'verified-token',
        pushCleanupGeneration: expect.any(Number),
        routeId: expect.any(String),
        trustedDeviceId: verifiedDeviceId,
      },
    ]);
  });

  it('filters pending Gmail watch proofs before applying the cap', async () => {
    expect.assertions(1);
    vi.useFakeTimers();

    try {
      const now = Date.now();
      const t = convexTest(schema, modules);
      const pendingDeviceId = await t.run(async (ctx) => {
        const productAccountId = await ctx.db.insert('productAccounts', {
          createdAt: now,
          lastSeenAt: now,
          tokenIdentifier: 'pending-account',
        });
        for (let index = 0; index < 100; index += 1) {
          const trustedDeviceId = await ctx.db.insert('trustedDevices', {
            deviceIdentifier: `non-pending-device-${index}`,
            lastSeenAt: now,
            platform: 'ios',
            productAccountId,
            registeredAt: now,
          });
          await ctx.db.insert('mailProviderConnections', {
            connectedAt: now,
            emailAddress: 'crowded-pending@example.com',
            gmailRoutingDigest: routingDigest('crowded-pending@example.com'),
            gmailRoutingKeyVersion: 1,
            lastVerifiedAt: now,
            productAccountId,
            provider: 'gmail',
            providerAccountIdentifier: `non-pending-${index}`,
            opaqueConnectionId: opaqueConnectionId(`non-pending-${index}`),
            trustedDeviceId,
            updatedAt: now,
          });
        }
        const trustedDeviceId = await ctx.db.insert('trustedDevices', {
          deviceIdentifier: 'pending-device',
          lastSeenAt: now,
          platform: 'ios',
          productAccountId,
          registeredAt: now,
        });
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: now,
          emailAddress: 'crowded-pending@example.com',
          gmailRoutingDigest: routingDigest('crowded-pending@example.com'),
          gmailRoutingKeyVersion: 1,
          lastVerifiedAt: now,
          productAccountId,
          provider: 'gmail',
          providerAccountIdentifier: 'pending',
          opaqueConnectionId: opaqueConnectionId('pending'),
          pushVerificationHistoryId: '100',
          pushVerificationOwnershipVerifiedAt: now,
          pushVerificationRequestedAt: now,
          trustedDeviceId,
          updatedAt: now,
        });
        return trustedDeviceId;
      });

      await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
        routingDigest: routingDigest('crowded-pending@example.com'),
        historyId: '101',
      });
      await t.run(async (ctx) => {
        await ctx.db.patch(pendingDeviceId, {
          apnsEnvironment: 'production',
          apnsToken: 'pending-token',
        });
      });
      await expect(
        t.query(internal.pushRelay.resolveGmailRecipients, {
          routingDigest: routingDigest('crowded-pending@example.com'),
        }),
      ).resolves.toStrictEqual([
        {
          apnsEnvironment: 'production',
          apnsToken: 'pending-token',
          pushCleanupGeneration: expect.any(Number),
          routeId: expect.any(String),
          trustedDeviceId: pendingDeviceId,
        },
      ]);
      await t.finishAllScheduledFunctions(vi.runAllTimers);
    } finally {
      vi.useRealTimers();
    }
  });

  it('checks the newest pending Gmail watch proofs before applying the cap', async () => {
    expect.assertions(1);
    vi.useFakeTimers();

    try {
      const now = Date.now();
      const t = convexTest(schema, modules);
      const pendingDeviceId = await t.run(async (ctx) => {
        const productAccountId = await ctx.db.insert('productAccounts', {
          createdAt: now,
          lastSeenAt: now,
          tokenIdentifier: 'newest-pending-account',
        });
        for (let index = 0; index < 100; index += 1) {
          const trustedDeviceId = await ctx.db.insert('trustedDevices', {
            deviceIdentifier: `older-pending-device-${index}`,
            lastSeenAt: now,
            platform: 'ios',
            productAccountId,
            registeredAt: now,
          });
          await ctx.db.insert('mailProviderConnections', {
            connectedAt: now,
            emailAddress: 'many-pending@example.com',
            gmailRoutingDigest: routingDigest('many-pending@example.com'),
            gmailRoutingKeyVersion: 1,
            lastVerifiedAt: now,
            productAccountId,
            provider: 'gmail',
            providerAccountIdentifier: `older-pending-${index}`,
            opaqueConnectionId: opaqueConnectionId(`older-pending-${index}`),
            pushVerificationHistoryId: `${300 + index}`,
            pushVerificationOwnershipVerifiedAt: now - 100 + index,
            pushVerificationRequestedAt: now - 100 + index,
            trustedDeviceId,
            updatedAt: now,
          });
        }
        const trustedDeviceId = await ctx.db.insert('trustedDevices', {
          deviceIdentifier: 'newest-pending-device',
          lastSeenAt: now,
          platform: 'ios',
          productAccountId,
          registeredAt: now,
        });
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: now,
          emailAddress: 'many-pending@example.com',
          gmailRoutingDigest: routingDigest('many-pending@example.com'),
          gmailRoutingKeyVersion: 1,
          lastVerifiedAt: now,
          productAccountId,
          provider: 'gmail',
          providerAccountIdentifier: 'newest-pending',
          opaqueConnectionId: opaqueConnectionId('newest-pending'),
          pushVerificationHistoryId: '200',
          pushVerificationOwnershipVerifiedAt: now,
          pushVerificationRequestedAt: now,
          trustedDeviceId,
          updatedAt: now,
        });
        return trustedDeviceId;
      });

      await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
        routingDigest: routingDigest('many-pending@example.com'),
        historyId: '200',
      });
      await t.run(async (ctx) => {
        await ctx.db.patch(pendingDeviceId, {
          apnsEnvironment: 'production',
          apnsToken: 'newest-pending-token',
        });
      });

      await expect(
        t.query(internal.pushRelay.resolveGmailRecipients, {
          routingDigest: routingDigest('many-pending@example.com'),
        }),
      ).resolves.toStrictEqual([
        {
          apnsEnvironment: 'production',
          apnsToken: 'newest-pending-token',
          pushCleanupGeneration: expect.any(Number),
          routeId: expect.any(String),
          trustedDeviceId: pendingDeviceId,
        },
      ]);
      await t.finishAllScheduledFunctions(vi.runAllTimers);
    } finally {
      vi.useRealTimers();
    }
  });

  it('verifies every pending Gmail watch proof in bounded continuations', async () => {
    expect.assertions(1);
    vi.useFakeTimers();

    try {
      const now = Date.now();
      const t = convexTest(schema, modules);
      const connectionIds = await t.run(async (ctx) => {
        const productAccountId = await ctx.db.insert('productAccounts', {
          createdAt: now,
          lastSeenAt: now,
          tokenIdentifier: 'batched-pending-account',
        });
        return Promise.all(
          Array.from({ length: 11 }, async (_, index) => {
            const trustedDeviceId = await ctx.db.insert('trustedDevices', {
              deviceIdentifier: `batched-pending-device-${index}`,
              lastSeenAt: now,
              platform: 'ios',
              productAccountId,
              registeredAt: now,
            });
            return ctx.db.insert('mailProviderConnections', {
              connectedAt: now,
              emailAddress: 'batched-pending@example.com',
              gmailRoutingDigest: routingDigest('batched-pending@example.com'),
              gmailRoutingKeyVersion: 1,
              lastVerifiedAt: now,
              productAccountId,
              provider: 'gmail',
              providerAccountIdentifier: `batched-pending-${index}`,
              opaqueConnectionId: opaqueConnectionId(
                `batched-pending-${index}`,
              ),
              pushVerificationHistoryId: '100',
              pushVerificationOwnershipVerifiedAt: now,
              pushVerificationRequestedAt: now,
              trustedDeviceId,
              updatedAt: now,
            });
          }),
        );
      });

      await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
        routingDigest: routingDigest('batched-pending@example.com'),
        historyId: '101',
      });
      await t.finishAllScheduledFunctions(vi.runAllTimers);

      await expect(
        t.run(async (ctx) =>
          Promise.all(
            connectionIds.map(async (connectionId) => {
              const connection = await ctx.db.get(connectionId);
              return connection!.pushVerifiedHistoryId;
            }),
          ),
        ),
      ).resolves.toStrictEqual(Array.from({ length: 11 }, () => '100'));
    } finally {
      vi.useRealTimers();
    }
  });

  it('schedules a wakeup for a route verified by a continuation', async () => {
    expect.assertions(1);
    vi.useFakeTimers();

    try {
      const now = Date.now();
      const t = convexTest(schema, modules);
      await t.run(async (ctx) => {
        const productAccountId = await ctx.db.insert('productAccounts', {
          createdAt: now,
          lastSeenAt: now,
          tokenIdentifier: 'continued-pending-account',
        });
        const trustedDeviceId = await ctx.db.insert('trustedDevices', {
          apnsEnvironment: 'production',
          apnsToken: 'continued-pending-token',
          deviceIdentifier: 'continued-pending-device',
          lastSeenAt: now,
          platform: 'ios',
          productAccountId,
          registeredAt: now,
        });
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: now,
          emailAddress: 'continued-pending@example.com',
          gmailRoutingDigest: routingDigest('continued-pending@example.com'),
          gmailRoutingKeyVersion: 1,
          lastVerifiedAt: now,
          opaqueConnectionId: opaqueConnectionId('continued-pending'),
          productAccountId,
          provider: 'gmail',
          providerAccountIdentifier: 'continued-pending',
          pushVerificationHistoryId: '100',
          pushVerificationOwnershipVerifiedAt: now,
          pushVerificationRequestedAt: now,
          trustedDeviceId,
          updatedAt: now,
        });
      });

      await expect(
        t.mutation(
          internal.pushRelay.continuePendingGmailConnectionVerification,
          {
            cursor: null,
            historyId: '101',
            now,
            routingDigest: routingDigest('continued-pending@example.com'),
          },
        ),
      ).resolves.toStrictEqual({ recipientCount: 1 });
    } finally {
      vi.useRealTimers();
    }
  });

  it('rejects a spoofed low Gmail history id when the exact email differs', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const productConnection = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'attacker-device',
        platform: 'ios',
      },
    );
    await registerGmailConnection(asUser, {
      emailAddress: 'victim@example.com',
      providerAccountIdentifier: 'client-asserted-id',
      trustedDeviceId: productConnection.trustedDeviceId,
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'attacker-device-token',
      trustedDeviceId: productConnection.trustedDeviceId,
    });

    await expect(
      asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingVictimSubjectIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingVictimSubjectIdentityToken,
        ),
        historyId: '1',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).rejects.toThrow('Gmail mailbox ownership proof rejected');
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      routingDigest: routingDigest('victim@example.com'),
      historyId: '100',
    });

    await expect(
      t.query(internal.pushRelay.resolveGmailRecipients, {
        routingDigest: routingDigest('victim@example.com'),
      }),
    ).resolves.toStrictEqual([]);
  });

  it('verifies a Gmail watch from a later notification history id', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const productConnection = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    await registerGmailConnection(asUser, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: productConnection.trustedDeviceId,
    });

    await expect(
      asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingIdentityToken,
        ),
        historyId: '100',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: false }));
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      routingDigest: routingDigest('matching@example.com'),
      historyId: '101',
    });
    await expect(
      asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingIdentityToken,
        ),
        historyId: '100',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
  });

  it('does not regress the verified Gmail history watermark', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const productConnection = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    await registerGmailConnection(asUser, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: productConnection.trustedDeviceId,
    });
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      routingDigest: routingDigest('matching@example.com'),
      historyId: '200',
    });
    await expect(
      asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingIdentityToken,
        ),
        historyId: '150',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      routingDigest: routingDigest('matching@example.com'),
      historyId: '120',
    });
    await expect(
      asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingIdentityToken,
        ),
        historyId: '100',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
    await expect(
      asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingIdentityToken,
        ),
        historyId: '150',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
  });

  it('rejects mailbox ownership when the stable Google subject differs', async () => {
    expect.assertions(3);

    const nowSpy = vi.spyOn(Date, 'now').mockReturnValue(1_784_000_000_000);
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const productConnection = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    await registerGmailConnection(asUser, {
      emailAddress: 'victim@example.com',
      providerAccountIdentifier: 'client-asserted-id',
      trustedDeviceId: productConnection.trustedDeviceId,
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'attacker-device-token',
      trustedDeviceId: productConnection.trustedDeviceId,
    });
    await expect(
      asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: matchingVictimEmailIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          matchingVictimEmailIdentityToken,
        ),
        historyId: 'victim-history-id',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).rejects.toThrow('Gmail mailbox ownership proof rejected');
    nowSpy.mockReturnValue(1_784_000_600_001);

    await expect(
      t.mutation(internal.pushRelay.enqueueGmailWakeups, {
        routingDigest: routingDigest('victim@example.com'),
        historyId: 'victim-history-id',
      }),
    ).resolves.toStrictEqual({ recipientCount: 0 });
    await expect(
      t.query(internal.pushRelay.resolveGmailRecipients, {
        routingDigest: routingDigest('victim@example.com'),
      }),
    ).resolves.toStrictEqual([]);
    nowSpy.mockRestore();
  });

  it('creates a content-free background wakeup payload', () => {
    expect.assertions(2);

    const payload = gmailWakeupPayload('history-123', 'route-001');

    expect(payload).toStrictEqual({
      aps: { 'content-available': 1 },
      historyId: 'history-123',
      provider: 'gmail',
      routeId: 'route-001',
    });
    expect(JSON.stringify(payload)).not.toMatch(
      /email|subject|snippet|body|category|classification|accessToken|refreshToken/iu,
    );
  });

  it('decodes only Gmail Minimal Push Metadata from Pub/Sub', () => {
    expect.assertions(1);

    const encodedData = btoa(
      JSON.stringify({
        emailAddress: 'matching@example.com',
        historyId: 'history-123',
        ignoredProviderField: 'not-routed',
      }),
    )
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replaceAll('=', '');

    expect(
      decodeGmailPushEnvelope({
        message: {
          data: encodedData,
          messageId: 'pubsub-message-001',
          publishTime: '2026-07-14T09:00:00Z',
        },
        subscription: 'projects/example/subscriptions/gmail-push',
      }),
    ).toStrictEqual({
      emailAddress: 'matching@example.com',
      historyId: 'history-123',
    });
  });

  it('preserves UTF-8 Gmail addresses from Pub/Sub', () => {
    expect.assertions(1);

    const metadata = JSON.stringify({
      emailAddress: 'josé@example.com',
      historyId: 'history-utf8',
    });
    const encodedData = Buffer.from(metadata, 'utf8').toString('base64url');

    expect(
      decodeGmailPushEnvelope({ message: { data: encodedData } }),
    ).toStrictEqual({
      emailAddress: 'josé@example.com',
      historyId: 'history-utf8',
    });
  });

  it('authenticates and validates the Gmail Pub/Sub HTTP ingress', async () => {
    expect.assertions(4);

    vi.stubEnv('GMAIL_PUSH_VERIFICATION_TOKEN', 'push-secret');
    try {
      const t = convexTest(schema, modules);
      const metadata = btoa(
        JSON.stringify({
          emailAddress: 'matching@example.com',
          historyId: 'history-123',
        }),
      );

      const missingToken = await t.fetch('/gmail/push', { method: 'POST' });
      expect(missingToken.status).toBe(401);

      const wrongToken = await t.fetch('/gmail/push?token=wrong', {
        method: 'POST',
      });
      expect(wrongToken.status).toBe(401);

      const malformed = await t.fetch('/gmail/push?token=push-secret', {
        body: JSON.stringify({ message: { data: 'not-base64-json' } }),
        method: 'POST',
      });
      expect(malformed.status).toBe(400);

      const accepted = await t.fetch('/gmail/push?token=push-secret', {
        body: JSON.stringify({ message: { data: metadata } }),
        method: 'POST',
      });
      expect(accepted.status).toBe(204);
    } finally {
      vi.unstubAllEnvs();
    }
  });

  it('sends content-free background requests to the selected APNs environment', async () => {
    expect.assertions(5);

    apnsMock.closedRequests = 0;
    apnsMock.connections.length = 0;
    apnsMock.requests.length = 0;
    apnsMock.responseBody = '';
    apnsMock.sessions.length = 0;
    apnsMock.status = 200;
    apnsMock.statusByToken = {};
    apnsMock.stallResponseBody = false;
    vi.stubEnv('APNS_KEY_ID', 'key-id');
    vi.stubEnv('APNS_TEAM_ID', 'team-id');
    vi.stubEnv('GMAIL_OAUTH_CLIENT_ID', 'gmail-client-id');
    vi.stubEnv('GMAIL_IDENTITY_BINDING_KEY', 'gmail-identity-binding-test-key');
    vi.stubEnv('GMAIL_ROUTING_KEY', 'gmail-routing-test-key');
    const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
    vi.stubEnv(
      'APNS_PRIVATE_KEY',
      privateKey.export({ format: 'pem', type: 'pkcs8' }),
    );
    vi.stubEnv('APNS_TOPIC', 'dev.unwired.mail');
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const goodDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'good-device',
        platform: 'ios',
      });
      const badDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'bad-device',
        platform: 'ios',
      });
      await registerGmailConnection(asUser, {
        emailAddress: 'bad-device@example.com',
        providerAccountIdentifier: 'bad-device-gmail',
        trustedDeviceId: badDevice.trustedDeviceId,
      });
      await asUser.action(api.pushRelay.verifyGmailWatch, {
        gmailIdentityToken: badDeviceIdentityToken,
        opaqueConnectionId: opaqueConnectionIdFromIdentityToken(
          badDeviceIdentityToken,
        ),
        historyId: '100',
        trustedDeviceId: badDevice.trustedDeviceId,
      });
      await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
        routingDigest: routingDigest('bad-device@example.com'),
        historyId: '100',
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'bad-device-token',
        trustedDeviceId: badDevice.trustedDeviceId,
      });
      await t.action(internal.apns.deliverGmailWakeups, {
        historyId: 'history-123',
        recipients: [
          {
            apnsEnvironment: 'sandbox',
            apnsToken: 'device-token',
            routeId: 'good-route',
            trustedDeviceId: goodDevice.trustedDeviceId,
          },
        ],
      });

      expect(apnsMock.requests).toHaveLength(1);
      const request = apnsMock.requests[0]!;
      expect({
        authority: request.authority,
        path: request.headers[':path'],
        priority: request.headers['apns-priority'],
        pushType: request.headers['apns-push-type'],
        topic: request.headers['apns-topic'],
      }).toStrictEqual({
        authority: 'https://api.sandbox.push.apple.com',
        path: '/3/device/device-token',
        priority: '5',
        pushType: 'background',
        topic: 'dev.unwired.mail',
      });
      expect(JSON.parse(request.payload)).toStrictEqual({
        aps: { 'content-available': 1 },
        historyId: 'history-123',
        provider: 'gmail',
        routeId: 'good-route',
      });

      apnsMock.responseBody = '{"reason":"BadDeviceToken"}';
      apnsMock.statusByToken = { 'bad-device-token': 410 };
      await expect(
        t.action(internal.apns.deliverGmailWakeups, {
          historyId: 'history-124',
          recipients: [
            {
              apnsEnvironment: 'production',
              apnsToken: 'bad-device-token',
              pushCleanupGeneration: 1,
              routeId: 'bad-route',
              trustedDeviceId: badDevice.trustedDeviceId,
            },
            {
              apnsEnvironment: 'production',
              apnsToken: 'good-device-token',
              pushCleanupGeneration: 0,
              routeId: 'good-route',
              trustedDeviceId: goodDevice.trustedDeviceId,
            },
          ],
        }),
      ).resolves.toBeNull();
      const prunedDevice = await t.run(async (ctx) =>
        ctx.db.get(badDevice.trustedDeviceId),
      );
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'replacement-device-token',
        trustedDeviceId: badDevice.trustedDeviceId,
      });
      const remainingRecipients = await t.query(
        internal.pushRelay.resolveGmailRecipients,
        { routingDigest: routingDigest('bad-device@example.com') },
      );
      expect({
        badAuthority: apnsMock.requests[1]?.authority,
        connections: apnsMock.connections,
        goodPath: apnsMock.requests[2]?.headers[':path'],
        prunedToken: prunedDevice?.apnsToken,
        remainingRecipients,
        sessionErrorListeners: apnsMock.sessions.map((session) =>
          session.listenerCount('error'),
        ),
      }).toStrictEqual({
        badAuthority: 'https://api.push.apple.com',
        connections: [
          'https://api.sandbox.push.apple.com',
          'https://api.push.apple.com',
        ],
        goodPath: '/3/device/good-device-token',
        prunedToken: undefined,
        remainingRecipients: [],
        sessionErrorListeners: [1, 1],
      });
    } finally {
      vi.unstubAllEnvs();
    }
  });

  it('times out stalled APNs response bodies', async () => {
    expect.assertions(3);

    vi.useFakeTimers();
    apnsMock.closedRequests = 0;
    apnsMock.connections.length = 0;
    apnsMock.requests.length = 0;
    apnsMock.responseBody = '';
    apnsMock.sessions.length = 0;
    apnsMock.status = 200;
    apnsMock.statusByToken = {};
    apnsMock.stallResponseBody = true;
    vi.stubEnv('APNS_KEY_ID', 'key-id');
    vi.stubEnv('APNS_TEAM_ID', 'team-id');
    const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
    vi.stubEnv(
      'APNS_PRIVATE_KEY',
      privateKey.export({ format: 'pem', type: 'pkcs8' }),
    );
    vi.stubEnv('APNS_TOPIC', 'dev.unwired.mail');
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const device = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'stalled-device',
        platform: 'ios',
      });
      const delivery = t.action(internal.apns.deliverGmailWakeups, {
        historyId: 'history-125',
        recipients: [
          {
            apnsEnvironment: 'production',
            apnsToken: 'stalled-device-token',
            pushCleanupGeneration: 0,
            routeId: 'stalled-route',
            trustedDeviceId: device.trustedDeviceId,
          },
        ],
      });

      await vi.advanceTimersByTimeAsync(0);
      expect(apnsMock.requests).toHaveLength(1);
      await vi.advanceTimersByTimeAsync(10_000);
      await expect(delivery).resolves.toBeNull();
      expect(apnsMock.closedRequests).toBe(1);
    } finally {
      vi.useRealTimers();
      vi.unstubAllEnvs();
      apnsMock.stallResponseBody = false;
    }
  });

  it('isolates and coalesces Microsoft Graph routes without forwarding provider data', async () => {
    expect.assertions(7);

    vi.useFakeTimers();
    apnsMock.connections.length = 0;
    apnsMock.requests.length = 0;
    apnsMock.responseBody = '';
    apnsMock.sessions.length = 0;
    apnsMock.status = 200;
    apnsMock.statusByToken = {};
    vi.stubEnv('APNS_KEY_ID', 'key-id');
    vi.stubEnv('APNS_TEAM_ID', 'team-id');
    const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
    vi.stubEnv(
      'APNS_PRIVATE_KEY',
      privateKey.export({ format: 'pem', type: 'pkcs8' }),
    );
    vi.stubEnv('APNS_TOPIC', 'dev.unwired.mail');
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const device = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'graph-device',
        platform: 'ios',
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'sandbox',
        apnsToken: 'graph-device-token',
        trustedDeviceId: device.trustedDeviceId,
      });
      const clientState = 'graph-client-state';
      const clientStateDigest = createHash('sha256')
        .update(clientState)
        .digest('hex');
      const route = await asUser.mutation(
        api.pushRelay.prepareMicrosoftGraphRoute,
        {
          clientStateDigest,
          opaqueConnectionId: 'opaque-graph-connection',
          trustedDeviceId: device.trustedDeviceId,
        },
      );
      await asUser.mutation(api.pushRelay.confirmMicrosoftGraphRoute, {
        clientStateDigest,
        expiresAt: Date.now() + 10 * 60_000,
        routeId: route.routeId,
        subscriptionId: 'graph-subscription',
        trustedDeviceId: device.trustedDeviceId,
      });

      const validation = await t.fetch(
        '/microsoft-graph/push?validationToken=validation-value',
        { method: 'POST' },
      );
      await expect(validation.text()).resolves.toBe('validation-value');
      const notification = {
        clientState,
        resource: 'users/private/messages/provider-message-id',
        resourceData: {
          body: 'provider message content must not cross the boundary',
        },
        subscriptionId: 'graph-subscription',
      };
      const pushURL = `/microsoft-graph/push?routeId=${route.routeId}`;
      for (let index = 0; index < 2; index += 1) {
        const response = await t.fetch(pushURL, {
          body: JSON.stringify({ value: [notification] }),
          headers: { 'content-type': 'application/json' },
          method: 'POST',
        });
        expect(response.status).toBe(202);
      }
      const isolatedResponse = await t.fetch(pushURL, {
        body: JSON.stringify({
          value: [
            {
              ...notification,
              clientState: 'another-route-client-state',
            },
          ],
        }),
        headers: { 'content-type': 'application/json' },
        method: 'POST',
      });
      const oversizedResponse = await t.fetch(pushURL, {
        body: JSON.stringify({
          value: Array.from({ length: 101 }, () => notification),
        }),
        headers: { 'content-type': 'application/json' },
        method: 'POST',
      });
      const pendingWakeups = await t.run((ctx) =>
        ctx.db.query('microsoftGraphWakeupStates').collect(),
      );
      expect({
        pendingWakeupCount: pendingWakeups.length,
        pendingWakeupRouteId: pendingWakeups[0]?.routeId,
        statuses: [isolatedResponse.status, oversizedResponse.status],
      }).toStrictEqual({
        pendingWakeupCount: 1,
        pendingWakeupRouteId: route.routeId,
        statuses: [202, 202],
      });

      apnsMock.status = 500;
      const failedDelivery = t.action(
        internal.apns.deliverMicrosoftGraphWakeup,
        {
          routeId: route.routeId,
          scheduledAt: pendingWakeups[0]!.scheduledAt,
        },
      );
      await vi.advanceTimersByTimeAsync(0);
      await failedDelivery;
      const retainedWakeups = await t.run((ctx) =>
        ctx.db.query('microsoftGraphWakeupStates').collect(),
      );
      expect({
        attemptCount: retainedWakeups[0]!.attemptCount,
        requestCount: apnsMock.requests.length,
        retainedWakeupCount: retainedWakeups.length,
        retryWasRescheduled:
          retainedWakeups[0]!.scheduledAt > pendingWakeups[0]!.scheduledAt,
      }).toStrictEqual({
        attemptCount: 1,
        requestCount: 1,
        retainedWakeupCount: 1,
        retryWasRescheduled: true,
      });

      const previousScheduledAt = retainedWakeups[0]!.scheduledAt;
      await t.run(async (ctx) => {
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        await ctx.db.patch(retainedWakeups[0]!._id, { attemptCount: 4 });
      });
      await vi.advanceTimersByTimeAsync(1);
      const newerNotification = await t.fetch(pushURL, {
        body: JSON.stringify({ value: [notification] }),
        headers: { 'content-type': 'application/json' },
        method: 'POST',
      });
      const refreshedWakeup = await t.run((ctx) =>
        ctx.db.query('microsoftGraphWakeupStates').unique(),
      );
      expect({
        attemptCount: refreshedWakeup?.attemptCount,
        scheduledAtChanged:
          refreshedWakeup?.scheduledAt !== previousScheduledAt,
        status: newerNotification.status,
      }).toStrictEqual({
        attemptCount: 0,
        scheduledAtChanged: false,
        status: 202,
      });

      apnsMock.status = 200;
      await t.finishAllScheduledFunctions(vi.runAllTimers);

      const remainingAfterSuccessfulRetry = await t.run((ctx) =>
        ctx.db.query('microsoftGraphWakeupStates').collect(),
      );
      await asUser.mutation(api.pushRelay.confirmMicrosoftGraphRoute, {
        clientStateDigest,
        expiresAt: Date.now() + 10 * 60_000,
        routeId: route.routeId,
        subscriptionId: 'graph-subscription',
        trustedDeviceId: device.trustedDeviceId,
      });
      await t.fetch(pushURL, {
        body: JSON.stringify({ value: [notification] }),
        headers: { 'content-type': 'application/json' },
        method: 'POST',
      });
      const permanentWakeup = await t.run(async (ctx) =>
        ctx.db.query('microsoftGraphWakeupStates').unique(),
      );
      apnsMock.status = 400;
      const permanentDelivery = t.action(
        internal.apns.deliverMicrosoftGraphWakeup,
        {
          routeId: route.routeId,
          scheduledAt: permanentWakeup!.scheduledAt,
        },
      );
      await vi.advanceTimersByTimeAsync(0);
      await permanentDelivery;
      await t.finishAllScheduledFunctions(vi.runAllTimers);
      const remainingAfterPermanentFailure = await t.run((ctx) =>
        ctx.db.query('microsoftGraphWakeupStates').collect(),
      );
      expect({
        payload: JSON.parse(apnsMock.requests[0]!.payload),
        payloadContainsProviderData: apnsMock.requests[0]!.payload.includes(
          'provider-message-id',
        ),
        remainingAfterPermanentFailure,
        remainingAfterSuccessfulRetry,
        requestCount: apnsMock.requests.length,
      }).toStrictEqual({
        payload: {
          aps: { 'content-available': 1 },
          provider: 'microsoft-graph',
          routeId: route.routeId,
        },
        payloadContainsProviderData: false,
        remainingAfterPermanentFailure: [],
        remainingAfterSuccessfulRetry: [],
        requestCount: 3,
      });
    } finally {
      vi.useRealTimers();
      vi.unstubAllEnvs();
    }
  });

  it('retains a Microsoft Graph notification received before route confirmation', async () => {
    expect.assertions(4);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'graph-preconfirmation-device',
      platform: 'ios',
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'sandbox',
      apnsToken: 'graph-preconfirmation-token',
      trustedDeviceId: device.trustedDeviceId,
    });
    const clientStateDigest = createHash('sha256')
      .update('graph-preconfirmation-state')
      .digest('hex');
    const route = await asUser.mutation(
      api.pushRelay.prepareMicrosoftGraphRoute,
      {
        clientStateDigest,
        opaqueConnectionId: 'opaque-graph-preconfirmation',
        trustedDeviceId: device.trustedDeviceId,
      },
    );

    await expect(
      t.mutation(internal.pushRelay.enqueueMicrosoftGraphWakeup, {
        clientStateDigest,
        routeId: route.routeId,
        subscriptionId: 'graph-preconfirmation-subscription',
      }),
    ).resolves.toStrictEqual({ accepted: true });
    const staged = await t.run((ctx) =>
      ctx.db.query('microsoftGraphWakeupStates').unique(),
    );
    expect(staged).toMatchObject({
      clientStateDigest,
      routeId: route.routeId,
      subscriptionId: 'graph-preconfirmation-subscription',
    });

    await asUser.mutation(api.pushRelay.confirmMicrosoftGraphRoute, {
      clientStateDigest,
      expiresAt: Date.now() + 60_000,
      routeId: route.routeId,
      subscriptionId: 'graph-preconfirmation-subscription',
      trustedDeviceId: device.trustedDeviceId,
    });
    const confirmed = await t.run((ctx) =>
      ctx.db.query('microsoftGraphWakeupStates').unique(),
    );
    expect(confirmed?.routeId).toBe(route.routeId);
    await expect(
      t.mutation(internal.pushRelay.claimMicrosoftGraphWakeup, {
        routeId: route.routeId,
        scheduledAt: confirmed!.scheduledAt,
      }),
    ).resolves.toMatchObject({
      apnsToken: 'graph-preconfirmation-token',
      routeId: route.routeId,
    });
  });

  it('rejects Microsoft Graph wakeups after account deletion is fenced', async () => {
    expect.assertions(4);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'graph-deleting-device',
      platform: 'ios',
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'sandbox',
      apnsToken: 'graph-deleting-token',
      trustedDeviceId: device.trustedDeviceId,
    });
    const clientStateDigest = createHash('sha256')
      .update('graph-deleting-state')
      .digest('hex');
    const route = await asUser.mutation(
      api.pushRelay.prepareMicrosoftGraphRoute,
      {
        clientStateDigest,
        opaqueConnectionId: 'opaque-graph-deleting',
        trustedDeviceId: device.trustedDeviceId,
      },
    );
    await asUser.mutation(api.pushRelay.confirmMicrosoftGraphRoute, {
      clientStateDigest,
      expiresAt: Date.now() + 60_000,
      routeId: route.routeId,
      subscriptionId: 'graph-deleting-subscription',
      trustedDeviceId: device.trustedDeviceId,
    });
    const pending = await t.mutation(
      internal.pushRelay.enqueueMicrosoftGraphWakeup,
      {
        clientStateDigest,
        routeId: route.routeId,
        subscriptionId: 'graph-deleting-subscription',
      },
    );
    expect(pending).toStrictEqual({ accepted: true });
    const wakeup = await t.run((ctx) =>
      ctx.db.query('microsoftGraphWakeupStates').unique(),
    );
    await t.run(async (ctx) => {
      await ctx.db.insert('productAccountDeletionRequests', {
        phase: 'revocation-pending',
        productAccountId: device.productAccountId,
        requestedAt: Date.now() - 1,
        requestedByTrustedDeviceId: device.trustedDeviceId,
        tokenIdentifier: appleIdentity.tokenIdentifier,
        updatedAt: Date.now() - 1,
      });
      await ctx.db.insert('productAccountDeletionRequests', {
        phase: 'deleting-data',
        productAccountId: device.productAccountId,
        requestedAt: Date.now(),
        requestedByTrustedDeviceId: device.trustedDeviceId,
        tokenIdentifier: appleIdentity.tokenIdentifier,
        updatedAt: Date.now(),
      });
    });

    await expect(
      t.mutation(internal.pushRelay.enqueueMicrosoftGraphWakeup, {
        clientStateDigest,
        routeId: route.routeId,
        subscriptionId: 'graph-deleting-subscription',
      }),
    ).resolves.toStrictEqual({ accepted: false });
    await expect(
      t.mutation(internal.pushRelay.claimMicrosoftGraphWakeup, {
        routeId: route.routeId,
        scheduledAt: wakeup!.scheduledAt,
      }),
    ).resolves.toBeNull();
    await expect(
      t.run((ctx) => ctx.db.query('microsoftGraphWakeupStates').collect()),
    ).resolves.toHaveLength(0);
  });

  it('caps Microsoft Graph routes per trusted device', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'graph-route-cap-device',
      platform: 'ios',
    });
    await t.run(async (ctx) => {
      await Promise.all(
        Array.from({ length: 20 }, async (_, index) => {
          await ctx.db.insert('mailProviderConnections', {
            connectedAt: index,
            lastVerifiedAt: index,
            opaqueConnectionId: `opaque-graph-${String(index)}`,
            productAccountId: device.productAccountId,
            provider: 'microsoft-graph',
            trustedDeviceId: device.trustedDeviceId,
            updatedAt: index,
          });
        }),
      );
    });

    await expect(
      asUser.mutation(api.pushRelay.prepareMicrosoftGraphRoute, {
        clientStateDigest: 'new-client-state-digest',
        opaqueConnectionId: 'opaque-graph-over-limit',
        trustedDeviceId: device.trustedDeviceId,
      }),
    ).rejects.toThrow('Microsoft Graph connection limit reached');
    await expect(
      asUser.mutation(api.pushRelay.prepareMicrosoftGraphRoute, {
        clientStateDigest: 'replacement-client-state-digest',
        opaqueConnectionId: 'opaque-graph-0',
        trustedDeviceId: device.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ routeId: expect.any(String) });
  });

  it('rejects unauthenticated and cross-account Graph route mutations', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const firstUser = t.withIdentity(appleIdentity);
    const firstDevice = await firstUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'graph-first-device',
      platform: 'ios',
    });
    const otherUser = t.withIdentity({
      ...appleIdentity,
      subject: 'apple-user-002',
      tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
    });
    await otherUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'graph-other-device',
      platform: 'ios',
    });
    const routeArgs = {
      clientStateDigest: 'graph-route-digest',
      opaqueConnectionId: 'opaque-graph-auth',
      trustedDeviceId: firstDevice.trustedDeviceId,
    };
    const route = await firstUser.mutation(
      api.pushRelay.prepareMicrosoftGraphRoute,
      routeArgs,
    );
    const confirmationArgs = {
      clientStateDigest: routeArgs.clientStateDigest,
      expiresAt: Date.now() + 60_000,
      routeId: route.routeId,
      subscriptionId: 'graph-auth-subscription',
      trustedDeviceId: firstDevice.trustedDeviceId,
    };
    const removalArgs = {
      opaqueConnectionId: routeArgs.opaqueConnectionId,
      trustedDeviceId: firstDevice.trustedDeviceId,
    };

    const results = await Promise.allSettled([
      t.mutation(api.pushRelay.prepareMicrosoftGraphRoute, routeArgs),
      t.mutation(api.pushRelay.confirmMicrosoftGraphRoute, confirmationArgs),
      t.mutation(api.pushRelay.removeMicrosoftGraphRoute, removalArgs),
      otherUser.mutation(api.pushRelay.prepareMicrosoftGraphRoute, routeArgs),
      otherUser.mutation(
        api.pushRelay.confirmMicrosoftGraphRoute,
        confirmationArgs,
      ),
      otherUser.mutation(api.pushRelay.removeMicrosoftGraphRoute, removalArgs),
    ]);

    expect(
      results.map((result) => String(Reflect.get(result, 'reason'))),
    ).toStrictEqual([
      expect.stringContaining('Authentication required'),
      expect.stringContaining('Authentication required'),
      expect.stringContaining('Authentication required'),
      expect.stringContaining('Trusted device required'),
      expect.stringContaining('Trusted device required'),
      expect.stringContaining('Trusted device required'),
    ]);
  });

  it('rejects a stale Microsoft Graph subscription confirmation', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'graph-confirmation-device',
      platform: 'ios',
    });
    const firstDigest = createHash('sha256')
      .update('first-state')
      .digest('hex');
    const secondDigest = createHash('sha256')
      .update('second-state')
      .digest('hex');
    const firstRoute = await asUser.mutation(
      api.pushRelay.prepareMicrosoftGraphRoute,
      {
        clientStateDigest: firstDigest,
        opaqueConnectionId: 'opaque-graph-confirmation',
        trustedDeviceId: device.trustedDeviceId,
      },
    );
    const secondRoute = await asUser.mutation(
      api.pushRelay.prepareMicrosoftGraphRoute,
      {
        clientStateDigest: secondDigest,
        opaqueConnectionId: 'opaque-graph-confirmation',
        trustedDeviceId: device.trustedDeviceId,
      },
    );

    expect(secondRoute.routeId).toBe(firstRoute.routeId);
    await expect(
      asUser.mutation(api.pushRelay.confirmMicrosoftGraphRoute, {
        clientStateDigest: firstDigest,
        expiresAt: Date.now() + 60_000,
        routeId: firstRoute.routeId,
        subscriptionId: 'stale-subscription',
        trustedDeviceId: device.trustedDeviceId,
      }),
    ).rejects.toThrow('Microsoft Graph route rejected');
    await expect(
      asUser.mutation(api.pushRelay.confirmMicrosoftGraphRoute, {
        clientStateDigest: secondDigest,
        expiresAt: Date.now() + 60_000,
        routeId: secondRoute.routeId,
        subscriptionId: 'current-subscription',
        trustedDeviceId: device.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ routeId: secondRoute.routeId });
  });

  it('keeps a confirmed Microsoft Graph route active while preparing its replacement', async () => {
    expect.hasAssertions();
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'graph-replacement-device',
      platform: 'ios',
    });
    const firstDigest = createHash('sha256')
      .update('active-state')
      .digest('hex');
    const replacementDigest = createHash('sha256')
      .update('replacement-state')
      .digest('hex');
    const route = await asUser.mutation(
      api.pushRelay.prepareMicrosoftGraphRoute,
      {
        clientStateDigest: firstDigest,
        opaqueConnectionId: 'opaque-graph-replacement',
        trustedDeviceId: device.trustedDeviceId,
      },
    );
    await asUser.mutation(api.pushRelay.confirmMicrosoftGraphRoute, {
      clientStateDigest: firstDigest,
      expiresAt: Date.now() + 120_000,
      routeId: route.routeId,
      subscriptionId: 'active-subscription',
      trustedDeviceId: device.trustedDeviceId,
    });

    await asUser.mutation(api.pushRelay.prepareMicrosoftGraphRoute, {
      clientStateDigest: replacementDigest,
      opaqueConnectionId: 'opaque-graph-replacement',
      trustedDeviceId: device.trustedDeviceId,
    });
    const prepared = await t.run((ctx) => ctx.db.get(route.routeId));
    expect(prepared).toMatchObject({
      microsoftClientStateDigest: firstDigest,
      microsoftPendingClientStateDigest: replacementDigest,
      microsoftSubscriptionId: 'active-subscription',
    });
    const activePush = await t.fetch(
      `/microsoft-graph/push?routeId=${route.routeId}`,
      {
        body: JSON.stringify({
          value: [
            {
              clientState: 'active-state',
              subscriptionId: 'active-subscription',
            },
          ],
        }),
        headers: { 'content-type': 'application/json' },
        method: 'POST',
      },
    );
    expect(activePush.status).toBe(202);
    const pendingWakeup = await t.run((ctx) =>
      ctx.db.query('microsoftGraphWakeupStates').unique(),
    );
    expect(pendingWakeup?.routeId).toBe(route.routeId);

    await asUser.mutation(api.pushRelay.confirmMicrosoftGraphRoute, {
      clientStateDigest: firstDigest,
      expiresAt: Date.now() + 120_000,
      routeId: route.routeId,
      subscriptionId: 'active-subscription',
      trustedDeviceId: device.trustedDeviceId,
    });
    const renewed = await t.run((ctx) => ctx.db.get(route.routeId));
    expect(renewed).toMatchObject({
      microsoftClientStateDigest: firstDigest,
      microsoftPendingClientStateDigest: replacementDigest,
      microsoftSubscriptionId: 'active-subscription',
    });

    await asUser.mutation(api.pushRelay.confirmMicrosoftGraphRoute, {
      clientStateDigest: replacementDigest,
      expiresAt: Date.now() + 120_000,
      routeId: route.routeId,
      subscriptionId: 'replacement-subscription',
      trustedDeviceId: device.trustedDeviceId,
    });
    const confirmed = await t.run((ctx) => ctx.db.get(route.routeId));
    const retainedWakeup = await t.run((ctx) =>
      ctx.db.query('microsoftGraphWakeupStates').unique(),
    );
    expect({
      clientStateDigest: confirmed?.microsoftClientStateDigest,
      pendingClientStateDigest: confirmed?.microsoftPendingClientStateDigest,
      retainedWakeup: {
        clientStateDigest: retainedWakeup?.clientStateDigest,
        routeId: retainedWakeup?.routeId,
        subscriptionId: retainedWakeup?.subscriptionId,
      },
      subscriptionId: confirmed?.microsoftSubscriptionId,
    }).toStrictEqual({
      clientStateDigest: replacementDigest,
      pendingClientStateDigest: undefined,
      retainedWakeup: {
        clientStateDigest: replacementDigest,
        routeId: route.routeId,
        subscriptionId: 'replacement-subscription',
      },
      subscriptionId: 'replacement-subscription',
    });
  });

  it('rolls back only the matching failed Microsoft Graph preparation', async () => {
    expect.hasAssertions();
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const device = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'graph-rollback-device',
      platform: 'ios',
    });
    const firstDigest = createHash('sha256').update('first').digest('hex');
    const replacementDigest = createHash('sha256')
      .update('replacement')
      .digest('hex');
    const route = await asUser.mutation(
      api.pushRelay.prepareMicrosoftGraphRoute,
      {
        clientStateDigest: firstDigest,
        opaqueConnectionId: 'opaque-graph-rollback',
        trustedDeviceId: device.trustedDeviceId,
      },
    );
    await asUser.mutation(api.pushRelay.confirmMicrosoftGraphRoute, {
      clientStateDigest: firstDigest,
      expiresAt: Date.now() + 120_000,
      routeId: route.routeId,
      subscriptionId: 'active-subscription',
      trustedDeviceId: device.trustedDeviceId,
    });
    await asUser.mutation(api.pushRelay.prepareMicrosoftGraphRoute, {
      clientStateDigest: replacementDigest,
      opaqueConnectionId: 'opaque-graph-rollback',
      trustedDeviceId: device.trustedDeviceId,
    });

    await expect(
      asUser.mutation(api.pushRelay.rollbackMicrosoftGraphRoute, {
        clientStateDigest: replacementDigest,
        routeId: route.routeId,
        trustedDeviceId: device.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ rolledBack: true });
    const retained = await t.run((ctx) => ctx.db.get(route.routeId));
    expect(retained).toMatchObject({
      microsoftClientStateDigest: firstDigest,
      microsoftSubscriptionId: 'active-subscription',
    });
    expect(retained?.microsoftPendingClientStateDigest).toBeUndefined();

    const unconfirmed = await asUser.mutation(
      api.pushRelay.prepareMicrosoftGraphRoute,
      {
        clientStateDigest: replacementDigest,
        opaqueConnectionId: 'opaque-graph-unconfirmed',
        trustedDeviceId: device.trustedDeviceId,
      },
    );
    await expect(
      asUser.mutation(api.pushRelay.rollbackMicrosoftGraphRoute, {
        clientStateDigest: replacementDigest,
        routeId: unconfirmed.routeId,
        trustedDeviceId: device.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ rolledBack: true });
    await expect(
      t.run((ctx) => ctx.db.get(unconfirmed.routeId)),
    ).resolves.toBeNull();
  });
});
