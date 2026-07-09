/// <reference types="vite/client" />

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

describe('productSync encrypted payloads', () => {
  it('stores and returns opaque encrypted payloads for the signed-in Product Account', async () => {
    expect.assertions(2);

    const { asUser, connect } = await connectAppleDevice();

    const stored = await putPayload(
      asUser,
      connect.trustedDeviceId,
      'payload-001',
    );
    const listed = await asUser.query(api.productSync.listEncryptedPayloads, {
      paginationOpts: firstPage,
    });

    expect(stored).toMatchObject({
      encryptedPayload,
      payloadIdentifier: 'payload-001',
    });
    expect(listed).toMatchObject({
      isDone: true,
      page: [stored],
    });
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
    const listed = await asUser.query(api.productSync.listEncryptedPayloads, {
      paginationOpts: firstPage,
    });

    expect(listed.page).toHaveLength(1);
    expect(listed.page[0]).toStrictEqual(updated);
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

    const pageOne = await asUser.query(api.productSync.listEncryptedPayloads, {
      paginationOpts: firstPage,
    });
    const pageTwo = await asUser.query(api.productSync.listEncryptedPayloads, {
      paginationOpts: {
        cursor: pageOne.continueCursor,
        numItems: 100,
      },
    });

    expect(pageOne).toMatchObject({ isDone: false });
    expect(pageOne.page).toHaveLength(100);
    expect(pageTwo.isDone).toBe(true);
    expect(pageTwo.page).toHaveLength(5);
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

    const page = await asUser.query(api.productSync.listEncryptedPayloads, {
      paginationOpts: {
        cursor: null,
        numItems: 1000,
      },
    });

    expect(page).toMatchObject({ isDone: false });
    expect(page.page).toHaveLength(100);
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
    await asOtherUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'ios',
    });

    await putPayload(asUser, connect.trustedDeviceId, 'payload-001');

    await expect(
      asOtherUser.query(api.productSync.listEncryptedPayloads, {
        paginationOpts: firstPage,
      }),
    ).resolves.toMatchObject({
      isDone: true,
      page: [],
    });
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

    await expect(
      t
        .withIdentity(appleIdentity)
        .query(api.productSync.listEncryptedPayloads, {
          paginationOpts: firstPage,
        }),
    ).rejects.toThrow('Product Account required');
  });
});
