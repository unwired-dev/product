/// <reference types="vite/client" />

import type {
  EncryptedProductSyncPayloadListResponse,
  EncryptedProductSyncPayloadPage,
} from '@private-email/contracts/productSync';

import { convexTest } from 'convex-test';

import type { Id } from '../convex/_generated/dataModel.js';

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

async function connectAppleDevice() {
  const t = convexTest(schema, modules);
  const asUser = t.withIdentity(appleIdentity);
  const connect = await asUser.mutation(api.productAccount.connect, {
    deviceIdentifier: 'device-001',
    platform: 'ios',
  });

  return { asUser, connect, t };
}

async function putPayload(
  asUser: Awaited<ReturnType<typeof connectAppleDevice>>['asUser'],
  trustedDeviceId: Id<'trustedDevices'>,
  payloadIdentifier: string,
) {
  return asUser.mutation(api.productSync.putEncryptedPayload, {
    encryptedPayload,
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
      page: [stored],
    });
  });

  it('rejects legacy Product Sync reads without a trusted device argument', async () => {
    expect.assertions(3);

    const { asUser, connect } = await connectAppleDevice();
    await putPayload(asUser, connect.trustedDeviceId, 'payload-001');

    await expect(
      asUser.query(api.productSync.getEncryptedPayload, {
        payloadIdentifier: 'payload-001',
      }),
    ).rejects.toThrow('Trusted device required');
    await expect(
      asUser.query(api.productSync.getEncryptedPayloads, {
        payloadIdentifiers: ['payload-001'],
      }),
    ).rejects.toThrow('Trusted device required');
    await expect(
      asUser.query(api.productSync.listEncryptedPayloads, {
        paginationOpts: firstPage,
      }),
    ).rejects.toThrow('Trusted device required');
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

  it('replaces an encrypted payload by opaque payload identifier', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();

    await putPayload(asUser, connect.trustedDeviceId, 'payload-001');
    const updated = await asUser.mutation(api.productSync.putEncryptedPayload, {
      encryptedPayload: {
        ...encryptedPayload,
        ciphertextBase64: 'bmV3LWNpcGhlcnRleHQ',
      },
      payloadIdentifier: 'payload-001',
      trustedDeviceId: connect.trustedDeviceId,
    });
    const listed = await asUser.query(
      api.productSync.listEncryptedPayloadsForTrustedDevice,
      {
        paginationOpts: firstPage,
        trustedDeviceId: connect.trustedDeviceId,
      },
    );
    const listedPage = requirePayloadPage(listed);

    expect(listedPage.page).toHaveLength(1);
    expect(listedPage.page[0]).toStrictEqual(updated);
  });

  it('keeps the first encrypted payload when a caller writes only if absent', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();

    const first = await asUser.mutation(
      api.productSync.putEncryptedPayloadIfAbsent,
      {
        encryptedPayload,
        payloadIdentifier: 'message-category-001',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );
    const second = await asUser.mutation(
      api.productSync.putEncryptedPayloadIfAbsent,
      {
        encryptedPayload: {
          ...encryptedPayload,
          ciphertextBase64: 'bmV3LWNpcGhlcnRleHQ',
        },
        payloadIdentifier: 'message-category-001',
        trustedDeviceId: connect.trustedDeviceId,
      },
    );

    expect(second).toStrictEqual(first);
    expect(second.encryptedPayload.ciphertextBase64).toBe(
      encryptedPayload.ciphertextBase64,
    );
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
      api.productSync.putEncryptedPayload,
      {
        encryptedPayload: {
          ...encryptedPayload,
          ciphertextBase64: 'Y29uY3VycmVudA',
        },
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

  it('reserves Recovery Key material for the recent-auth mutation', async () => {
    expect.assertions(3);

    const { asUser, connect } = await connectAppleDevice();
    const args = {
      encryptedPayload,
      payloadIdentifier: 'product-account-recovery-v1',
      trustedDeviceId: connect.trustedDeviceId,
    };

    await expect(
      asUser.mutation(api.productSync.putEncryptedPayload, args),
    ).rejects.toThrow('Recovery material requires recent authentication');
    await expect(
      asUser.mutation(api.productSync.putEncryptedPayloadIfAbsent, args),
    ).rejects.toThrow('Recovery material requires recent authentication');
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
      trustedDeviceId: connect.trustedDeviceId,
    });
    const missingToken = await asUser.fetch('/product-sync/recovery-material', {
      body,
      headers: { 'content-type': 'application/json' },
      method: 'POST',
    });
    const staleToken = await asUser.fetch('/product-sync/recovery-material', {
      body,
      headers: {
        authorization: `Bearer ${appleIdentityToken(Math.floor(Date.now() / 1000) - 301)}`,
        'content-type': 'application/json',
      },
      method: 'POST',
    });

    expect(missingToken.status).toBe(401);
    expect(staleToken.status).toBe(401);
  });

  it('accepts small Apple authentication clock skew', async () => {
    expect.assertions(1);

    const { asUser, connect } = await connectAppleDevice();
    const response = await asUser.fetch('/product-sync/recovery-material', {
      body: JSON.stringify({
        encryptedPayload,
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

  it('publishes Recovery Key material with a freshly issued Apple bearer token', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();
    const response = await asUser.fetch('/product-sync/recovery-material', {
      body: JSON.stringify({
        encryptedPayload,
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
    expect(pageTwoResponse.page).toHaveLength(5);
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

  it('gets an encrypted payload by opaque payload identifier', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();

    const stored = await asUser.mutation(api.productSync.putEncryptedPayload, {
      encryptedPayload,
      payloadIdentifier: 'payload-001',
      trustedDeviceId: connect.trustedDeviceId,
    });
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
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherConnect = await asOtherUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-002',
        platform: 'ios',
      },
    );

    await asUser.mutation(api.productSync.putEncryptedPayload, {
      encryptedPayload,
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
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherConnect = await asOtherUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-002',
        platform: 'ios',
      },
    );

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
    const connect = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const otherConnect = await asOtherUser.mutation(
      api.productAccount.connect,
      { deviceIdentifier: 'device-002', platform: 'ios' },
    );
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
