/// <reference types="vite/client" />

import type {
  EncryptedProductSyncPayloadListResponse,
  EncryptedProductSyncPayloadPage,
} from '@private-email/contracts/productSync';

import { convexTest } from 'convex-test';

import type { Id } from '../convex/_generated/dataModel.js';

import { api } from '../convex/_generated/api.js';
import schema from '../convex/schema.js';
import { connectTrusted, recoveryVerifier } from './devices.js';

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

const recoveryEnvelope = {
  ...encryptedPayload,
  ciphertextBase64: 'cmVjb3Zlcnk',
  schemaVersion: 3,
};

const firstPage = {
  cursor: null,
  numItems: 100,
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

async function initializeProductSync(
  asUser: ReturnType<ReturnType<typeof convexTest>['withIdentity']>,
  proof: Readonly<{
    trustedDeviceCredential?: string;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
) {
  return asUser.mutation(api.productSync.initialize, {
    recoveryVerifier,
    encryptedPayload: recoveryEnvelope,
    trustedDeviceCredential: proof.trustedDeviceCredential,
    trustedDeviceId: proof.trustedDeviceId,
  });
}

async function connectAppleDevice({ initialized = true } = {}) {
  const t = convexTest(schema, modules);
  const asUser = t.withIdentity(appleIdentity);
  const connect = await connectTrusted(t, asUser, {
    deviceIdentifier: 'device-001',
    platform: 'ios',
  });
  if (initialized) {
    await initializeProductSync(asUser, connect);
  }

  return { asUser, connect, t };
}

async function putPayload(
  asUser: Awaited<ReturnType<typeof connectAppleDevice>>['asUser'],
  trustedDeviceId: Id<'trustedDevices'>,
  payloadIdentifier: string,
) {
  return asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
    encryptedPayload,
    expectedUpdatedAt: undefined,
    payloadIdentifier,
    trustedDeviceId,
  });
}

function requirePayloadPage(
  response: EncryptedProductSyncPayloadListResponse,
): EncryptedProductSyncPayloadPage {
  if (Array.isArray(response)) {
    throw new TypeError('Expected paginated encrypted payload response');
  }

  return response;
}

describe('productSync encrypted payloads', () => {
  it('stores and returns opaque encrypted payloads for the signed-in Product Account', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();

    const stored = await putPayload(
      asUser,
      connect.trustedDeviceId,
      'payload-001',
    );
    const listed = await asUser.query(
      api.productSync.listEncryptedPayloadsForTrustedDevice,
      {
        paginationOpts: firstPage,
        trustedDeviceId: connect.trustedDeviceId,
      },
    );

    expect(stored).toMatchObject({
      encryptedPayload,
      payloadIdentifier: 'payload-001',
    });
    expect(listed).toMatchObject({
      isDone: true,
      page: [
        stored,
        {
          encryptedPayload: recoveryEnvelope,
          payloadIdentifier: 'product-account-recovery-v1',
        },
      ],
    });
  });

  it('rejects trusted-device reads from unauthenticated callers', async () => {
    expect.assertions(3);

    const { connect, t } = await connectAppleDevice();

    await expect(
      t.query(api.productSync.getEncryptedPayloadForTrustedDevice, {
        payloadIdentifier: 'payload-001',
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).rejects.toThrow('Authentication required');
    await expect(
      t.query(api.productSync.getEncryptedPayloadsForTrustedDevice, {
        payloadIdentifiers: ['payload-001'],
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).rejects.toThrow('Authentication required');
    await expect(
      t.query(api.productSync.listEncryptedPayloadsForTrustedDevice, {
        paginationOpts: firstPage,
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).rejects.toThrow('Authentication required');
  });

  it('rejects malformed trusted-device read arguments', async () => {
    expect.assertions(3);

    const { asUser } = await connectAppleDevice();
    // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- Malformed runtime input is intentional validation coverage.
    const malformedTrustedDeviceId = 1 as never;

    await expect(
      asUser.query(api.productSync.getEncryptedPayloadForTrustedDevice, {
        payloadIdentifier: 'payload-001',
        trustedDeviceId: malformedTrustedDeviceId,
      }),
    ).rejects.toThrow('Validator error');
    await expect(
      asUser.query(api.productSync.getEncryptedPayloadsForTrustedDevice, {
        payloadIdentifiers: ['payload-001'],
        trustedDeviceId: malformedTrustedDeviceId,
      }),
    ).rejects.toThrow('Validator error');
    await expect(
      asUser.query(api.productSync.listEncryptedPayloadsForTrustedDevice, {
        paginationOpts: firstPage,
        trustedDeviceId: malformedTrustedDeviceId,
      }),
    ).rejects.toThrow('Validator error');
  });

  it('bounds exact trusted-device reads to one atomic batch', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();
    const identifiers = Array.from(
      { length: 101 },
      (_, index) => `payload-${String(index)}`,
    );

    await expect(
      asUser.query(api.productSync.getEncryptedPayloadsForTrustedDevice, {
        payloadIdentifiers: identifiers.slice(0, 100),
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).resolves.toStrictEqual([]);
    await expect(
      asUser.query(api.productSync.getEncryptedPayloadsForTrustedDevice, {
        payloadIdentifiers: identifiers,
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).rejects.toThrow('Encrypted Product Sync read has too many identifiers');
  });

  it('updates an encrypted payload only when its version is unchanged', async () => {
    expect.assertions(3);

    const { asUser, connect } = await connectAppleDevice();
    const first = await putPayload(
      asUser,
      connect.trustedDeviceId,
      'message-category-learning-signals',
    );
    const concurrent = await asUser.mutation(
      api.productSync.putEncryptedPayloadIfUnchanged,
      {
        encryptedPayload: {
          ...encryptedPayload,
          ciphertextBase64: 'Y29uY3VycmVudA',
        },
        expectedUpdatedAt: first.updatedAt,
        payloadIdentifier: 'message-category-learning-signals',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );
    const staleAttempt = await asUser.mutation(
      api.productSync.putEncryptedPayloadIfUnchanged,
      {
        encryptedPayload: {
          ...encryptedPayload,
          ciphertextBase64: 'c3RhbGU',
        },
        expectedUpdatedAt: first.updatedAt,
        payloadIdentifier: 'message-category-learning-signals',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );
    const updated = await asUser.mutation(
      api.productSync.putEncryptedPayloadIfUnchanged,
      {
        encryptedPayload: {
          ...encryptedPayload,
          ciphertextBase64: 'bWVyZ2Vk',
        },
        expectedUpdatedAt: concurrent.updatedAt,
        payloadIdentifier: 'message-category-learning-signals',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );

    expect(concurrent.updatedAt).toBeGreaterThan(first.updatedAt);
    expect(staleAttempt).toStrictEqual(concurrent);
    expect(updated.encryptedPayload.ciphertextBase64).toBe('bWVyZ2Vk');
  });

  it('commits multi-record writes and deletes only when every revision matches', async () => {
    expect.assertions(5);

    const { asUser, connect } = await connectAppleDevice();
    const first = await putPayload(
      asUser,
      connect.trustedDeviceId,
      'mail-profiles-primary',
    );
    const second = await putPayload(
      asUser,
      connect.trustedDeviceId,
      'profile-config-source',
    );
    const stale = await asUser.mutation(
      api.productSync.putEncryptedPayloadsAtomically,
      {
        checks: [],
        deletes: [
          {
            expectedUpdatedAt: second.updatedAt,
            payloadIdentifier: second.payloadIdentifier,
          },
        ],
        trustedDeviceId: connect.trustedDeviceId,
        writes: [
          {
            encryptedPayload: {
              ...encryptedPayload,
              ciphertextBase64: 'cHJvZmlsZS11cGRhdGU',
            },
            expectedUpdatedAt: first.updatedAt - 1,
            payloadIdentifier: first.payloadIdentifier,
          },
        ],
      },
    );
    const afterStale = await asUser.query(
      api.productSync.getEncryptedPayloadsForTrustedDevice,
      {
        payloadIdentifiers: [first.payloadIdentifier, second.payloadIdentifier],
        trustedDeviceId: connect.trustedDeviceId,
      },
    );
    const committed = await asUser.mutation(
      api.productSync.putEncryptedPayloadsAtomically,
      {
        checks: [],
        deletes: [
          {
            expectedUpdatedAt: second.updatedAt,
            payloadIdentifier: second.payloadIdentifier,
          },
        ],
        trustedDeviceId: connect.trustedDeviceId,
        writes: [
          {
            encryptedPayload: {
              ...encryptedPayload,
              ciphertextBase64: 'cHJvZmlsZS11cGRhdGU',
            },
            expectedUpdatedAt: first.updatedAt,
            payloadIdentifier: first.payloadIdentifier,
          },
        ],
      },
    );
    const afterCommit = await asUser.query(
      api.productSync.getEncryptedPayloadsForTrustedDevice,
      {
        payloadIdentifiers: [first.payloadIdentifier, second.payloadIdentifier],
        trustedDeviceId: connect.trustedDeviceId,
      },
    );

    expect(stale).toMatchObject({ committed: false });
    expect(
      new Map(
        afterStale.map(({ payloadIdentifier, updatedAt }) => [
          payloadIdentifier,
          updatedAt,
        ]),
      ),
    ).toStrictEqual(
      new Map([
        [first.payloadIdentifier, first.updatedAt],
        [second.payloadIdentifier, second.updatedAt],
      ]),
    );
    expect(committed).toMatchObject({ committed: true });
    expect(afterCommit).toHaveLength(1);
    expect(afterCommit[0]?.encryptedPayload.ciphertextBase64).toBe(
      'cHJvZmlsZS11cGRhdGU',
    );
  });

  it.each([
    [
      'empty transactions',
      { checks: [], deletes: [], writes: [] },
      'invalid record count',
    ],
    [
      'oversized transactions',
      {
        checks: Array.from({ length: 101 }, (_, index) => ({
          expectedUpdatedAt: index,
          payloadIdentifier: `record:${index}`,
        })),
        deletes: [],
        writes: [],
      },
      'invalid record count',
    ],
    [
      'duplicate identifiers',
      {
        checks: [{ expectedUpdatedAt: 1, payloadIdentifier: 'duplicate' }],
        deletes: [{ expectedUpdatedAt: 1, payloadIdentifier: 'duplicate' }],
        writes: [],
      },
      'duplicate records',
    ],
    [
      'reserved Recovery material',
      {
        checks: [
          {
            expectedUpdatedAt: 1,
            payloadIdentifier: 'product-account-recovery-v1',
          },
        ],
        deletes: [],
        writes: [],
      },
      'Recovery material requires recent authentication',
    ],
  ])('rejects %s in an atomic mutation', async (_name, mutation, message) => {
    expect.assertions(1);
    const { asUser, connect } = await connectAppleDevice();

    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadsAtomically, {
        ...mutation,
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).rejects.toThrow(message);
  });

  it('rejects an atomic write encrypted for the wrong key epoch', async () => {
    expect.assertions(1);
    const { asUser, connect } = await connectAppleDevice();

    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadsAtomically, {
        checks: [],
        deletes: [],
        trustedDeviceId: connect.trustedDeviceId,
        writes: [
          {
            encryptedPayload: { ...encryptedPayload, keyVersion: 2 },
            expectedUpdatedAt: undefined,
            payloadIdentifier: 'record:wrong-key-epoch',
          },
        ],
      }),
    ).rejects.toThrow('Product Sync key rotation required');
  });

  it('rejects reuse of a consumed atomic revision', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();
    const first = await putPayload(
      asUser,
      connect.trustedDeviceId,
      'mail-profiles-primary',
    );
    const transaction = (ciphertextBase64: string) =>
      asUser.mutation(api.productSync.putEncryptedPayloadsAtomically, {
        checks: [],
        deletes: [],
        trustedDeviceId: connect.trustedDeviceId,
        writes: [
          {
            encryptedPayload: { ...encryptedPayload, ciphertextBase64 },
            expectedUpdatedAt: first.updatedAt,
            payloadIdentifier: first.payloadIdentifier,
          },
        ],
      });
    const results = await Promise.all([
      transaction('Y29uY3VycmVudC0x'),
      transaction('Y29uY3VycmVudC0y'),
    ]);
    const stored = await asUser.query(
      api.productSync.getEncryptedPayloadForTrustedDevice,
      {
        payloadIdentifier: first.payloadIdentifier,
        trustedDeviceId: connect.trustedDeviceId,
      },
    );

    expect(
      results
        .map(({ committed }) => committed)
        .toSorted((left, right) => Number(left) - Number(right)),
    ).toStrictEqual([false, true]);
    expect(['Y29uY3VycmVudC0x', 'Y29uY3VycmVudC0y']).toContain(
      stored?.encryptedPayload.ciphertextBase64,
    );
  });

  it('reserves Recovery Key material for the recent-auth mutation', async () => {
    expect.assertions(1);

    const { asUser, connect } = await connectAppleDevice();
    const args = {
      encryptedPayload,
      payloadIdentifier: 'product-account-recovery-v1',
      trustedDeviceId: connect.trustedDeviceId,
    };

    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
        ...args,
        expectedUpdatedAt: undefined,
      }),
    ).rejects.toThrow('Recovery material requires recent authentication');
  });

  it('rejects Recovery Key material without recent authentication', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();
    const body = JSON.stringify({
      encryptedPayload,
      recoveryVerifier,
      trustedDeviceId: connect.trustedDeviceId,
    });
    const missingToken = await asUser.fetch('/product-sync/recovery-material', {
      body,
      headers: { 'content-type': 'application/json' },
      method: 'POST',
    });
    const [header, recentClaims, signature] = appleIdentityToken(
      Math.floor(Date.now() / 1000),
    ).split('.');
    const encodeClaims = (claims: unknown) =>
      Buffer.from(JSON.stringify(claims), 'utf8').toString('base64url');
    const rejectedTokens = [
      appleIdentityToken(Math.floor(Date.now() / 1000) - 301),
      `${header}.${Buffer.from('not-json').toString('base64url')}.${signature}`,
      `${header}.${encodeClaims([recentClaims])}.${signature}`,
      `${header}.${encodeClaims({
        iat: String(Math.floor(Date.now() / 1000)),
        iss: appleIdentity.issuer,
        sub: appleIdentity.subject,
      })}.${signature}`,
    ];
    const rejectedStatuses = await Promise.all(
      rejectedTokens.map(async (token) => {
        const response = await asUser.fetch('/product-sync/recovery-material', {
          body,
          headers: {
            authorization: `Bearer ${token}`,
            'content-type': 'application/json',
          },
          method: 'POST',
        });
        return response.status;
      }),
    );

    expect(missingToken.status).toBe(401);
    // Stale, non-JSON, non-object and non-numeric issued-at claims all fail closed.
    expect(rejectedStatuses).toStrictEqual([401, 401, 401, 401]);
  });

  it('accepts small Apple authentication clock skew', async () => {
    expect.assertions(1);

    const { asUser, connect } = await connectAppleDevice();
    const response = await asUser.fetch('/product-sync/recovery-material', {
      body: JSON.stringify({
        encryptedPayload,
        recoveryVerifier,
        trustedDeviceId: connect.trustedDeviceId,
      }),
      headers: {
        authorization: `Bearer ${appleIdentityToken(Math.floor(Date.now() / 1000) + 5)}`,
        'content-type': 'application/json',
      },
      method: 'POST',
    });

    expect(response.status).toBe(200);
  });

  it.each([
    ['missing encrypted payload', { trustedDeviceId: 'device' }],
    [
      'invalid algorithm',
      {
        encryptedPayload: { ...encryptedPayload, algorithm: 'AES-128' },
        trustedDeviceId: 'device',
      },
    ],
    [
      'invalid ciphertext',
      {
        encryptedPayload: { ...encryptedPayload, ciphertextBase64: 1 },
        trustedDeviceId: 'device',
      },
    ],
    [
      'invalid key version',
      {
        encryptedPayload: { ...encryptedPayload, keyVersion: '1' },
        trustedDeviceId: 'device',
      },
    ],
    [
      'invalid nonce',
      {
        encryptedPayload: { ...encryptedPayload, nonceBase64: 1 },
        trustedDeviceId: 'device',
      },
    ],
    [
      'invalid schema version',
      {
        encryptedPayload: { ...encryptedPayload, schemaVersion: '1' },
        trustedDeviceId: 'device',
      },
    ],
    [
      'invalid tag',
      {
        encryptedPayload: { ...encryptedPayload, tagBase64: 1 },
        trustedDeviceId: 'device',
      },
    ],
    ['invalid trusted device', { encryptedPayload, trustedDeviceId: 1 }],
    [
      'invalid expected update time',
      { encryptedPayload, expectedUpdatedAt: 'now', trustedDeviceId: 'device' },
    ],
  ])('rejects malformed Recovery Key material: %s', async (_name, body) => {
    expect.assertions(1);

    const { asUser } = await connectAppleDevice();
    const response = await asUser.fetch('/product-sync/recovery-material', {
      body: JSON.stringify(body),
      headers: {
        authorization: `Bearer ${appleIdentityToken(Math.floor(Date.now() / 1000))}`,
        'content-type': 'application/json',
      },
      method: 'POST',
    });

    expect(response.status).toBe(400);
  });

  it('returns a client error for an unknown trusted device', async () => {
    expect.assertions(1);

    const { asUser } = await connectAppleDevice();
    const response = await asUser.fetch('/product-sync/recovery-material', {
      body: JSON.stringify({
        encryptedPayload,
        recoveryVerifier,
        trustedDeviceId: 'not-a-convex-id',
      }),
      headers: {
        authorization: `Bearer ${appleIdentityToken(Math.floor(Date.now() / 1000))}`,
        'content-type': 'application/json',
      },
      method: 'POST',
    });

    expect(response.status).toBe(403);
  });

  it('returns a stable error when Recovery Key replacement observes revocation', async () => {
    expect.assertions(2);

    const { asUser, connect, t } = await connectAppleDevice();
    await t.run(async (ctx) => {
      await ctx.db.insert('revokedTrustedDevices', {
        deviceIdentifier: 'device-001',
        productAccountId: connect.productAccountId,
        productSyncKeyEpoch: 1,
        revokedAt: Date.now(),
        trustedDeviceId: connect.trustedDeviceId,
      });
      await ctx.db.delete('trustedDevices', connect.trustedDeviceId);
    });

    const response = await asUser.fetch('/product-sync/recovery-material', {
      body: JSON.stringify({
        encryptedPayload,
        recoveryVerifier,
        trustedDeviceId: connect.trustedDeviceId,
      }),
      headers: {
        authorization: `Bearer ${appleIdentityToken(Math.floor(Date.now() / 1000))}`,
        'content-type': 'application/json',
      },
      method: 'POST',
    });

    expect(response.status).toBe(403);
    await expect(response.json()).resolves.toStrictEqual({
      code: 'TRUSTED_DEVICE_REVOKED',
    });
  });

  it('requires the device credential for Recovery Key replacement after activation', async () => {
    expect.assertions(4);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connect = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
      supportsDeviceCredentials: true,
    });
    const request = (trustedDeviceCredential?: string) =>
      asUser.fetch('/product-sync/recovery-material', {
        body: JSON.stringify({
          encryptedPayload,
          recoveryVerifier,
          trustedDeviceCredential,
          trustedDeviceId: connect.trustedDeviceId,
        }),
        headers: {
          authorization: `Bearer ${appleIdentityToken(Math.floor(Date.now() / 1000))}`,
          'content-type': 'application/json',
        },
        method: 'POST',
      });

    const missingProof = await request();
    expect(missingProof.status).toBe(403);
    await expect(missingProof.json()).resolves.toStrictEqual({
      code: 'TRUSTED_DEVICE_RECONNECT_REQUIRED',
    });

    const authenticated = await request(connect.trustedDeviceCredential);
    expect(authenticated.status).toBe(200);
    await expect(authenticated.json()).resolves.toMatchObject({
      encryptedPayload,
      payloadIdentifier: 'product-account-recovery-v1',
    });
  });

  it('publishes Recovery Key material and the initialized marker together through the legacy route', async () => {
    expect.assertions(3);

    const { asUser, connect, t } = await connectAppleDevice({
      initialized: false,
    });
    const response = await asUser.fetch('/product-sync/recovery-material', {
      body: JSON.stringify({
        encryptedPayload,
        recoveryVerifier,
        trustedDeviceId: connect.trustedDeviceId,
      }),
      headers: {
        authorization: `Bearer ${appleIdentityToken(Math.floor(Date.now() / 1000))}`,
        'content-type': 'application/json',
      },
      method: 'POST',
    });

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      encryptedPayload,
      payloadIdentifier: 'product-account-recovery-v1',
    });
    const account = await t.run(async (ctx) =>
      ctx.db.get('productAccounts', connect.productAccountId),
    );
    expect(account?.productSyncMaterialInitializedAt).toBeTypeOf('number');
  });

  it('paginates encrypted payload listing past the first page', async () => {
    expect.assertions(4);

    const { asUser, connect } = await connectAppleDevice();

    for (let index = 0; index < 105; index += 1) {
      await putPayload(
        asUser,
        connect.trustedDeviceId,
        `payload-${String(index).padStart(3, '0')}`,
      );
    }

    const pageOne = await asUser.query(
      api.productSync.listEncryptedPayloadsForTrustedDevice,
      {
        paginationOpts: firstPage,
        trustedDeviceId: connect.trustedDeviceId,
      },
    );
    const pageOneResponse = requirePayloadPage(pageOne);
    const pageTwo = await asUser.query(
      api.productSync.listEncryptedPayloadsForTrustedDevice,
      {
        paginationOpts: {
          cursor: pageOneResponse.continueCursor,
          numItems: 100,
        },
        trustedDeviceId: connect.trustedDeviceId,
      },
    );
    const pageTwoResponse = requirePayloadPage(pageTwo);

    expect(pageOneResponse).toMatchObject({ isDone: false });
    expect(pageOneResponse.page).toHaveLength(100);
    expect(pageTwoResponse.isDone).toBe(true);
    // The remaining 5 records plus the recovery envelope.
    expect(pageTwoResponse.page).toHaveLength(6);
  });

  it('paginates only encrypted payloads matching an identifier prefix', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();

    await putPayload(
      asUser,
      connect.trustedDeviceId,
      'message-category-learning-signal:001',
    );
    await putPayload(
      asUser,
      connect.trustedDeviceId,
      'message-category-learning-signal:002',
    );
    await putPayload(asUser, connect.trustedDeviceId, 'message-category:001');

    const listed = await asUser.query(
      api.productSync.listEncryptedPayloadsForTrustedDevice,
      {
        paginationOpts: firstPage,
        payloadIdentifierPrefix: 'message-category-learning-signal:',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );
    const page = requirePayloadPage(listed);

    expect(page.isDone).toBe(true);
    expect(page.page.map((payload) => payload.payloadIdentifier)).toStrictEqual(
      [
        'message-category-learning-signal:001',
        'message-category-learning-signal:002',
      ],
    );
  });

  it('caps encrypted payload listing pages at the server page size', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();

    for (let index = 0; index < 105; index += 1) {
      await putPayload(
        asUser,
        connect.trustedDeviceId,
        `payload-${String(index).padStart(3, '0')}`,
      );
    }

    const page = await asUser.query(
      api.productSync.listEncryptedPayloadsForTrustedDevice,
      {
        paginationOpts: {
          cursor: null,
          numItems: 1000,
        },
        trustedDeviceId: connect.trustedDeviceId,
      },
    );
    const pageResponse = requirePayloadPage(page);

    expect(pageResponse).toMatchObject({ isDone: false });
    expect(pageResponse.page).toHaveLength(100);
  });

  it('keeps the unpaginated encrypted payload listing response', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();

    for (let index = 0; index < 105; index += 1) {
      await putPayload(
        asUser,
        connect.trustedDeviceId,
        `payload-${String(index).padStart(3, '0')}`,
      );
    }

    const listed = await asUser.query(
      api.productSync.listEncryptedPayloadsForTrustedDevice,
      {
        trustedDeviceId: connect.trustedDeviceId,
      },
    );

    expect(Array.isArray(listed)).toBe(true);
    expect(listed).toHaveLength(100);
  });

  it('returns the recovery envelope to a new device of its Product Account only', async () => {
    expect.assertions(3);

    const { asUser, t } = await connectAppleDevice();
    // Another installation of the account holds no keys yet; the Recovery Key opens the envelope there.
    const added = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    const asOther = t.withIdentity(otherAppleIdentity);
    const outsider = await connectTrusted(t, asOther, {
      deviceIdentifier: 'device-003',
      platform: 'ios',
    });
    const read = (
      caller: typeof asUser,
      trustedDeviceId: Id<'trustedDevices'>,
    ) =>
      caller.query(api.productSync.getEncryptedPayloadForTrustedDevice, {
        payloadIdentifier: 'product-account-recovery-v1',
        trustedDeviceId,
      });

    await expect(read(asUser, added.trustedDeviceId)).resolves.toMatchObject({
      encryptedPayload: recoveryEnvelope,
    });
    await expect(read(asOther, outsider.trustedDeviceId)).resolves.toBeNull();
    await expect(read(asOther, added.trustedDeviceId)).rejects.toThrow(
      'Trusted device required',
    );
  });

  it('gets an encrypted payload by opaque payload identifier', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();

    const stored = await putPayload(
      asUser,
      connect.trustedDeviceId,
      'payload-001',
    );
    const found = await asUser.query(
      api.productSync.getEncryptedPayloadForTrustedDevice,
      {
        payloadIdentifier: 'payload-001',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );
    const missing = await asUser.query(
      api.productSync.getEncryptedPayloadForTrustedDevice,
      {
        payloadIdentifier: 'missing-payload',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );

    expect(found).toStrictEqual(stored);
    expect(missing).toBeNull();
  });

  it('gets only requested encrypted payloads', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();

    const stored = await putPayload(
      asUser,
      connect.trustedDeviceId,
      'payload-001',
    );
    await putPayload(asUser, connect.trustedDeviceId, 'payload-002');
    const found = await asUser.query(
      api.productSync.getEncryptedPayloadsForTrustedDevice,
      {
        payloadIdentifiers: ['payload-001', 'missing-payload'],
        trustedDeviceId: connect.trustedDeviceId,
      },
    );

    expect(found).toStrictEqual([stored]);
    expect(found).toHaveLength(1);
  });

  it('does not expose targeted encrypted payloads across Product Accounts', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const asOtherUser = t.withIdentity(otherAppleIdentity);
    const connect = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherConnect = await connectTrusted(t, asOtherUser, {
      deviceIdentifier: 'device-002',
      platform: 'ios',
    });
    await initializeProductSync(asUser, connect);

    await asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
      encryptedPayload,
      expectedUpdatedAt: undefined,
      payloadIdentifier: 'payload-001',
      trustedDeviceId: connect.trustedDeviceId,
    });

    await expect(
      asOtherUser.query(api.productSync.getEncryptedPayloadForTrustedDevice, {
        payloadIdentifier: 'payload-001',
        trustedDeviceId: otherConnect.trustedDeviceId,
      }),
    ).resolves.toBeNull();
    await expect(
      asOtherUser.query(api.productSync.getEncryptedPayloadsForTrustedDevice, {
        payloadIdentifiers: ['payload-001'],
        trustedDeviceId: otherConnect.trustedDeviceId,
      }),
    ).resolves.toStrictEqual([]);
  });

  it('does not expose encrypted payloads across Product Accounts', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const asOtherUser = t.withIdentity(otherAppleIdentity);
    const connect = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherConnect = await connectTrusted(t, asOtherUser, {
      deviceIdentifier: 'device-002',
      platform: 'ios',
    });
    await initializeProductSync(asUser, connect);

    await putPayload(asUser, connect.trustedDeviceId, 'payload-001');

    await expect(
      asOtherUser.query(api.productSync.listEncryptedPayloadsForTrustedDevice, {
        paginationOpts: firstPage,
        trustedDeviceId: otherConnect.trustedDeviceId,
      }),
    ).resolves.toMatchObject({
      isDone: true,
      page: [],
    });
  });

  it('rejects encrypted payload reads from a device after its access is removed', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();
    await putPayload(asUser, connect.trustedDeviceId, 'payload-001');
    await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
      deviceIdentifier: 'device-001',
      trustedDeviceId: connect.trustedDeviceId,
    });

    await expect(
      asUser.query(api.productSync.getEncryptedPayloadForTrustedDevice, {
        payloadIdentifier: 'payload-001',
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
    await expect(
      asUser.query(api.productSync.listEncryptedPayloadsForTrustedDevice, {
        paginationOpts: firstPage,
        trustedDeviceId: connect.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
  });

  it('rejects encrypted payload reads using another Product Account device', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const asOtherUser = t.withIdentity(otherAppleIdentity);
    const connect = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherConnect = await connectTrusted(t, asOtherUser, {
      deviceIdentifier: 'device-002',
      platform: 'ios',
    });
    await initializeProductSync(asUser, connect);
    await putPayload(asUser, connect.trustedDeviceId, 'payload-001');

    await expect(
      asUser.query(api.productSync.getEncryptedPayloadForTrustedDevice, {
        payloadIdentifier: 'payload-001',
        trustedDeviceId: otherConnect.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
    await expect(
      asUser.query(api.productSync.listEncryptedPayloadsForTrustedDevice, {
        paginationOpts: firstPage,
        trustedDeviceId: otherConnect.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
  });

  it('rejects writes from a trusted device outside the signed-in Product Account', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const asOtherUser = t.withIdentity(otherAppleIdentity);
    const otherConnect = await connectTrusted(t, asOtherUser, {
      deviceIdentifier: 'device-002',
      platform: 'ios',
    });
    await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
        encryptedPayload,
        expectedUpdatedAt: undefined,
        payloadIdentifier: 'payload-001',
        trustedDeviceId: otherConnect.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
  });

  it('rejects Product Sync access before the Product Account exists', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const trustedDeviceId = await t.run(async (ctx) => {
      const now = Date.now();
      const productAccountId = await ctx.db.insert('productAccounts', {
        createdAt: now,
        lastSeenAt: now,
        tokenIdentifier: otherAppleIdentity.tokenIdentifier,
      });
      return ctx.db.insert('trustedDevices', {
        deviceIdentifier: 'device-001',
        lastSeenAt: now,
        platform: 'ios',
        productAccountId,
        registeredAt: now,
      });
    });

    await expect(
      t
        .withIdentity(appleIdentity)
        .query(api.productSync.listEncryptedPayloadsForTrustedDevice, {
          paginationOpts: firstPage,
          trustedDeviceId,
        }),
    ).rejects.toThrow('Product Account required');
  });
});

describe('productSync initialization', () => {
  const googleIdentity = {
    issuer: 'https://accounts.google.com',
    subject: 'google-user-001',
    tokenIdentifier: 'https://accounts.google.com|google-user-001',
  };

  async function connectDevice(
    t: ReturnType<typeof convexTest>,
    asUser: ReturnType<ReturnType<typeof convexTest>['withIdentity']>,
    deviceIdentifier: string,
  ) {
    const connection = await connectTrusted(t, asUser, {
      deviceIdentifier,
      platform: 'ios',
      supportsDeviceCredentials: true,
    });
    return {
      connection,
      proof: {
        trustedDeviceCredential: connection.trustedDeviceCredential,
        trustedDeviceId: connection.trustedDeviceId as Id<'trustedDevices'>,
      },
    };
  }

  it('creates key material once for a new Product Account and lets only the winning device retry', async () => {
    expect.assertions(4);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(googleIdentity);
    const first = await connectDevice(t, asUser, 'installation-001');
    const second = await connectDevice(t, asUser, 'installation-002');
    expect(first.connection).toMatchObject({
      productSyncMaterialInitialized: false,
    });

    await expect(
      asUser.mutation(api.productSync.initialize, {
        recoveryVerifier,
        ...first.proof,
        encryptedPayload: recoveryEnvelope,
      }),
    ).resolves.toStrictEqual({ initialized: true });
    // A lost response retries with the same envelope; another device's material is refused.
    await expect(
      asUser.mutation(api.productSync.initialize, {
        recoveryVerifier,
        ...first.proof,
        encryptedPayload: recoveryEnvelope,
      }),
    ).resolves.toStrictEqual({ initialized: true });
    await expect(
      asUser.mutation(api.productSync.initialize, {
        recoveryVerifier,
        ...second.proof,
        encryptedPayload: { ...recoveryEnvelope, ciphertextBase64: 'b3RoZXI' },
      }),
    ).resolves.toStrictEqual({ initialized: false });
  });

  it('shares the winning recovery envelope with later devices but keeps it out of record writes', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(googleIdentity);
    const first = await connectDevice(t, asUser, 'installation-001');
    await asUser.mutation(api.productSync.initialize, {
      recoveryVerifier,
      ...first.proof,
      encryptedPayload: recoveryEnvelope,
    });
    const second = await connectDevice(t, asUser, 'installation-002');
    expect(second.connection).toMatchObject({
      productSyncMaterialInitialized: true,
    });
    await expect(
      asUser.query(api.productSync.getEncryptedPayloadForTrustedDevice, {
        ...second.proof,
        payloadIdentifier: 'product-account-recovery-v1',
      }),
    ).resolves.toMatchObject({ encryptedPayload: recoveryEnvelope });
    // The recovery envelope stays reserved from ordinary record writes.
    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
        ...second.proof,
        encryptedPayload: recoveryEnvelope,
        payloadIdentifier: 'product-account-recovery-v1',
      }),
    ).rejects.toThrow('Recovery material requires recent authentication');
  });

  it('rejects the initialized marker until a recovery envelope is published', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(googleIdentity);
    const device = await connectDevice(t, asUser, 'installation-001');

    await expect(
      asUser.mutation(api.productAccount.markProductSyncMaterialInitialized, {
        ...device.proof,
      }),
    ).rejects.toThrow('Recovery material required');
    // The refused marker leaves the account free to publish its first envelope.
    await expect(
      asUser.mutation(api.productSync.initialize, {
        recoveryVerifier,
        ...device.proof,
        encryptedPayload: recoveryEnvelope,
      }),
    ).resolves.toStrictEqual({ initialized: true });
  });

  it('rejects record writes until a recovery envelope is published', async () => {
    expect.assertions(4);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(googleIdentity);
    const device = await connectDevice(t, asUser, 'installation-001');

    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
        ...device.proof,
        encryptedPayload,
        payloadIdentifier: 'mailbox.prototype',
      }),
    ).rejects.toThrow('Product Sync is not initialized');
    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadsAtomically, {
        ...device.proof,
        checks: [],
        deletes: [],
        writes: [{ encryptedPayload, payloadIdentifier: 'mailbox.prototype' }],
      }),
    ).rejects.toThrow('Product Sync is not initialized');
    // The refused writes leave the account free to publish its first envelope.
    await expect(
      asUser.mutation(api.productSync.initialize, {
        recoveryVerifier,
        ...device.proof,
        encryptedPayload: recoveryEnvelope,
      }),
    ).resolves.toStrictEqual({ initialized: true });
    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
        ...device.proof,
        encryptedPayload,
        payloadIdentifier: 'mailbox.prototype',
      }),
    ).resolves.toMatchObject({ payloadIdentifier: 'mailbox.prototype' });
  });

  it.each([
    ['an initialized marker', { productSyncMaterialInitializedAt: 1 }, []],
    ['records under earlier keys', {}, ['mailbox.prototype']],
  ])(
    'never silently replaces key material for an account left with %s but no recovery envelope',
    async (_name, accountPatch, recordIdentifiers) => {
      expect.assertions(3);

      const { asUser, connect, t } = await connectAppleDevice({
        initialized: false,
      });
      const proof = { trustedDeviceId: connect.trustedDeviceId };
      // Seeds the stuck state that earlier backends allowed.
      await t.run(async (ctx) => {
        await ctx.db.patch(
          'productAccounts',
          connect.productAccountId,
          accountPatch,
        );
        for (const payloadIdentifier of recordIdentifiers) {
          await ctx.db.insert('encryptedProductSyncPayloads', {
            encryptedPayload,
            payloadIdentifier,
            productAccountId: connect.productAccountId,
            trustedDeviceId: connect.trustedDeviceId,
            updatedAt: 1,
            writtenAt: 1,
          });
        }
      });

      await expect(
        asUser.mutation(api.productSync.initialize, {
          recoveryVerifier,
          ...proof,
          encryptedPayload: recoveryEnvelope,
        }),
      ).resolves.toStrictEqual({ initialized: false });
      const legacyPublication = await asUser.fetch(
        '/product-sync/recovery-material',
        {
          body: JSON.stringify({
            ...proof,
            encryptedPayload: recoveryEnvelope,
            recoveryVerifier,
          }),
          headers: {
            authorization: `Bearer ${appleIdentityToken(Math.floor(Date.now() / 1000))}`,
            'content-type': 'application/json',
          },
          method: 'POST',
        },
      );
      expect(legacyPublication.status).toBe(409);
      await expect(
        asUser.query(api.productSync.getEncryptedPayloadForTrustedDevice, {
          ...proof,
          payloadIdentifier: 'product-account-recovery-v1',
        }),
      ).resolves.toBeNull();
    },
  );

  it('initializes only the Product Account of the presenting Trusted Device', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const owner = await connectDevice(
      t,
      t.withIdentity(googleIdentity),
      'installation-001',
    );
    const asOther = t.withIdentity(otherAppleIdentity);
    await connectDevice(t, asOther, 'installation-002');

    await expect(
      asOther.mutation(api.productSync.initialize, {
        recoveryVerifier,
        ...owner.proof,
        encryptedPayload: recoveryEnvelope,
      }),
    ).rejects.toThrow('Trusted device required');
    await expect(
      t.withIdentity(googleIdentity).mutation(api.productSync.initialize, {
        recoveryVerifier,
        trustedDeviceId: owner.proof.trustedDeviceId,
        encryptedPayload: recoveryEnvelope,
      }),
    ).rejects.toThrow('Reconnect this Trusted Device to continue.');
  });
});
