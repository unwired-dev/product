/// <reference types="vite/client" />

import { convexTest } from 'convex-test';

import type { Id } from '../convex/_generated/dataModel.js';
import type { MutationCtx } from '../convex/_generated/server.js';

import { api } from '../convex/_generated/api.js';
import schema from '../convex/schema.js';

const modules = import.meta.glob('../convex/**/*.ts');

const googleIdentity = {
  issuer: 'https://accounts.google.com',
  subject: 'google-user-001',
  tokenIdentifier: 'https://accounts.google.com|google-user-001',
};

const otherAppleIdentity = {
  issuer: 'https://appleid.apple.com',
  subject: 'apple-user-002',
  tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
};

const recoveryEnvelope = {
  algorithm: 'AES-GCM-256' as const,
  ciphertextBase64: 'cmVjb3Zlcnk',
  keyVersion: 1,
  nonceBase64: 'bm9uY2U',
  schemaVersion: 3,
  tagBase64: 'dGFn',
};

const enrollmentPublicKey = `${'A'.repeat(43)}=`;
const sealedKeyRing = {
  ciphertextBase64: 'c2VhbGVkIGtleSByaW5n',
  encapsulatedKeyBase64: `${'B'.repeat(43)}=`,
  keyVersion: 1,
};
const enrollmentLifetime = 15 * 60 * 1000;
const unavailable = { data: { code: 'ENROLLMENT_REQUEST_UNAVAILABLE' } };

type Client = ReturnType<ReturnType<typeof convexTest>['withIdentity']>;

async function connectDevice(
  asUser: Client,
  deviceIdentifier: string,
  platform = 'ios',
) {
  const connection = await asUser.mutation(api.productAccount.connect, {
    deviceIdentifier,
    platform,
    supportsDeviceCredentials: true,
  });
  return {
    deviceIdentifier,
    productAccountId: connection.productAccountId,
    proof: {
      trustedDeviceCredential: connection.trustedDeviceCredential,
      trustedDeviceId: connection.trustedDeviceId as Id<'trustedDevices'>,
    },
  };
}

type Device = Awaited<ReturnType<typeof connectDevice>>;

// An initialized Product Account with a key-holding device and a second device without keys.
async function enrollmentAccount(identity = googleIdentity) {
  const t = convexTest(schema, modules);
  const asUser = t.withIdentity(identity);
  const holder = await connectDevice(asUser, 'installation-001');
  await asUser.mutation(api.productSync.initialize, {
    ...holder.proof,
    encryptedPayload: recoveryEnvelope,
  });
  const newcomer = await connectDevice(asUser, 'installation-002', 'macos');
  return { asUser, holder, newcomer, t };
}

async function requestEnrollment(asUser: Client, device: Device) {
  return asUser.mutation(api.productSyncEnrollment.request, {
    ...device.proof,
    enrollmentPublicKey,
  });
}

async function approve(
  asUser: Client,
  approver: Device,
  request: Readonly<{
    requestId: string;
    requester: Device;
    sealed?: Partial<typeof sealedKeyRing>;
  }>,
) {
  return asUser.mutation(api.productSyncEnrollment.approve, {
    ...approver.proof,
    ...sealedKeyRing,
    ...request.sealed,
    requestId: request.requestId,
    requesterTrustedDeviceId: request.requester.proof.trustedDeviceId,
  });
}

async function status(asUser: Client, device: Device, requestId: string) {
  return asUser.mutation(api.productSyncEnrollment.status, {
    ...device.proof,
    requestId,
  });
}

async function listPending(asUser: Client, device: Device) {
  return asUser.mutation(api.productSyncEnrollment.listPending, device.proof);
}

async function changeTrustBoundary(
  ctx: MutationCtx,
  holder: Device,
  change: string,
) {
  if (change === 'removed') {
    await ctx.db.delete('trustedDevices', holder.proof.trustedDeviceId);
  } else if (change === 'revoked') {
    await ctx.db.insert('revokedTrustedDevices', {
      deviceIdentifier: holder.deviceIdentifier,
      productAccountId: holder.productAccountId,
      productSyncKeyEpoch: 2,
      revokedAt: Date.now(),
      trustedDeviceId: holder.proof.trustedDeviceId,
    });
  } else {
    await ctx.db.patch(
      'productAccounts',
      holder.productAccountId,
      change === 'pending-rotation'
        ? { productSyncPendingKeyEpoch: 2 }
        : { productSyncKeyEpoch: 2 },
    );
  }
}

/* oxlint-disable vitest/max-expects -- Each journey proves one enrollment state machine across devices. */
describe('productSync enrollment', () => {
  it('hands the sealed key ring to the requesting device once and leaves account key material untouched', async () => {
    expect.hasAssertions();

    const { asUser, holder, newcomer, t } = await enrollmentAccount();
    const keyMaterial = async () => ({
      account: await t.run(async (ctx) => {
        const accounts = await ctx.db.query('productAccounts').collect();
        return accounts.map(
          ({ productSyncMaterialInitializedAt }) =>
            productSyncMaterialInitializedAt,
        );
      }),
      recovery: await asUser.query(
        api.productSync.getEncryptedPayloadForTrustedDevice,
        {
          ...holder.proof,
          payloadIdentifier: 'product-account-recovery-v1',
        },
      ),
    });
    const before = await keyMaterial();

    const { expiresAt, requestId } = await requestEnrollment(asUser, newcomer);
    const request = { requestId, requester: newcomer };
    await expect(listPending(asUser, holder)).resolves.toStrictEqual([
      {
        createdAt: expiresAt - enrollmentLifetime,
        displayName: 'Mac',
        enrollmentPublicKey,
        expiresAt,
        platform: 'macos',
        requestId,
        requesterTrustedDeviceId: newcomer.proof.trustedDeviceId,
      },
    ]);
    // The requester never sees its own request as one to approve.
    await expect(listPending(asUser, newcomer)).resolves.toStrictEqual([]);
    await expect(status(asUser, newcomer, requestId)).resolves.toStrictEqual({
      expiresAt,
      state: 'pending',
    });

    await expect(approve(asUser, holder, request)).resolves.toStrictEqual({
      approved: true,
    });
    await expect(listPending(asUser, holder)).resolves.toStrictEqual([]);
    await expect(status(asUser, newcomer, requestId)).resolves.toMatchObject({
      approval: sealedKeyRing,
      state: 'approved',
    });
    // Only the requesting device can read the approval.
    await expect(status(asUser, holder, requestId)).resolves.toStrictEqual({
      state: 'cancelled',
    });

    const completion = { ...newcomer.proof, requestId };
    await expect(
      asUser.mutation(api.productSyncEnrollment.complete, completion),
    ).resolves.toStrictEqual({ completed: true });
    // A retry after a lost response is a no-op and the envelope is gone.
    await expect(
      asUser.mutation(api.productSyncEnrollment.complete, completion),
    ).resolves.toStrictEqual({ completed: false });
    await expect(status(asUser, newcomer, requestId)).resolves.toStrictEqual({
      state: 'cancelled',
    });
    await expect(
      t.run(async (ctx) =>
        ctx.db.query('productSyncEnrollmentRequests').collect(),
      ),
    ).resolves.toStrictEqual([]);
    await expect(keyMaterial()).resolves.toStrictEqual(before);
  });

  it('accepts requests only for initialized accounts with a well-formed one-time key', async () => {
    expect.hasAssertions();

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(googleIdentity);
    const device = await connectDevice(asUser, 'installation-001');

    await expect(requestEnrollment(asUser, device)).rejects.toMatchObject({
      data: { code: 'PRODUCT_SYNC_NOT_INITIALIZED' },
    });
    await asUser.mutation(api.productSync.initialize, {
      ...device.proof,
      encryptedPayload: recoveryEnvelope,
    });
    await expect(
      asUser.mutation(api.productSyncEnrollment.request, {
        ...device.proof,
        enrollmentPublicKey: 'AAAA',
      }),
    ).rejects.toThrow('Enrollment public key is invalid');
    await expect(
      t.run(async (ctx) =>
        ctx.db.query('productSyncEnrollmentRequests').collect(),
      ),
    ).resolves.toStrictEqual([]);
  });

  it('refuses approvals for the wrong device, replayed, declined or superseded requests without changing them', async () => {
    expect.hasAssertions();

    const { asUser, holder, newcomer } = await enrollmentAccount();
    const first = await requestEnrollment(asUser, newcomer);
    const firstRequest = { requestId: first.requestId, requester: newcomer };

    await expect(
      approve(asUser, holder, { ...firstRequest, requester: holder }),
    ).rejects.toMatchObject(unavailable);
    await expect(
      asUser.mutation(api.productSyncEnrollment.approve, {
        ...holder.proof,
        ...sealedKeyRing,
        requestId: first.requestId,
        requesterTrustedDeviceId: 'not-a-trusted-device',
      }),
    ).rejects.toMatchObject(unavailable);
    await expect(
      approve(asUser, holder, { ...firstRequest, requestId: 'not-a-request' }),
    ).rejects.toMatchObject(unavailable);
    // A device without keys cannot approve its own request.
    await expect(approve(asUser, newcomer, firstRequest)).rejects.toMatchObject(
      unavailable,
    );
    await expect(
      approve(asUser, holder, { ...firstRequest, sealed: { keyVersion: 2 } }),
    ).rejects.toThrow('Product Sync key rotation required');
    await expect(
      status(asUser, newcomer, first.requestId),
    ).resolves.toStrictEqual({ expiresAt: first.expiresAt, state: 'pending' });

    await approve(asUser, holder, firstRequest);
    await expect(
      approve(asUser, holder, {
        ...firstRequest,
        sealed: { ciphertextBase64: 'cmVwbGF5ZWQ=' },
      }),
    ).rejects.toMatchObject(unavailable);
    await expect(
      status(asUser, newcomer, first.requestId),
    ).resolves.toMatchObject({ approval: sealedKeyRing, state: 'approved' });

    // A new request supersedes the approved one, so that approval can never be collected.
    const second = await requestEnrollment(asUser, newcomer);
    const secondRequest = { requestId: second.requestId, requester: newcomer };
    await expect(
      status(asUser, newcomer, first.requestId),
    ).resolves.toStrictEqual({ state: 'cancelled' });
    await expect(approve(asUser, holder, firstRequest)).rejects.toMatchObject(
      unavailable,
    );

    await expect(
      asUser.mutation(api.productSyncEnrollment.decline, {
        ...holder.proof,
        requestId: second.requestId,
      }),
    ).resolves.toStrictEqual({ declined: true });
    await expect(approve(asUser, holder, secondRequest)).rejects.toMatchObject(
      unavailable,
    );
    await expect(
      asUser.mutation(api.productSyncEnrollment.decline, {
        ...newcomer.proof,
        requestId: second.requestId,
      }),
    ).rejects.toMatchObject(unavailable);
    await expect(
      status(asUser, newcomer, second.requestId),
    ).resolves.toStrictEqual({ state: 'cancelled' });
  });

  it('expires unapproved and uncollected requests', async () => {
    expect.hasAssertions();
    vi.useFakeTimers();
    try {
      const { asUser, holder, newcomer } = await enrollmentAccount();
      const pending = await requestEnrollment(asUser, newcomer);
      vi.setSystemTime(pending.expiresAt);

      await expect(
        status(asUser, newcomer, pending.requestId),
      ).resolves.toStrictEqual({
        expiresAt: pending.expiresAt,
        state: 'expired',
      });
      await expect(listPending(asUser, holder)).resolves.toStrictEqual([]);
      await expect(
        approve(asUser, holder, {
          requestId: pending.requestId,
          requester: newcomer,
        }),
      ).rejects.toMatchObject(unavailable);
      await expect(
        asUser.mutation(api.productSyncEnrollment.decline, {
          ...holder.proof,
          requestId: pending.requestId,
        }),
      ).rejects.toMatchObject(unavailable);

      // Approval opens a fresh collection window, after which the envelope is withheld.
      const approved = await requestEnrollment(asUser, newcomer);
      const approvedAt = approved.expiresAt - 1;
      const collectionDeadline = approvedAt + enrollmentLifetime;
      vi.setSystemTime(approvedAt);
      await approve(asUser, holder, {
        requestId: approved.requestId,
        requester: newcomer,
      });
      vi.setSystemTime(collectionDeadline - 1);
      await expect(
        status(asUser, newcomer, approved.requestId),
      ).resolves.toStrictEqual({
        approval: sealedKeyRing,
        expiresAt: collectionDeadline,
        state: 'approved',
      });
      vi.setSystemTime(collectionDeadline);
      await expect(
        status(asUser, newcomer, approved.requestId),
      ).resolves.toStrictEqual({
        expiresAt: collectionDeadline,
        state: 'expired',
      });
      await expect(
        asUser.mutation(api.productSyncEnrollment.complete, {
          ...newcomer.proof,
          requestId: approved.requestId,
        }),
      ).resolves.toStrictEqual({ completed: false });
    } finally {
      vi.useRealTimers();
    }
  });

  it('never seals keys for a revoked or removed requester', async () => {
    expect.hasAssertions();

    const { asUser, holder, newcomer, t } = await enrollmentAccount();
    const departing = await connectDevice(asUser, 'installation-003');
    const revoked = await requestEnrollment(asUser, newcomer);
    await t.run(async (ctx) => {
      await ctx.db.insert('revokedTrustedDevices', {
        deviceIdentifier: newcomer.deviceIdentifier,
        productAccountId: newcomer.productAccountId,
        productSyncKeyEpoch: 2,
        revokedAt: Date.now(),
        trustedDeviceId: newcomer.proof.trustedDeviceId,
      });
      await ctx.db.delete('trustedDevices', newcomer.proof.trustedDeviceId);
    });

    await expect(listPending(asUser, holder)).resolves.toStrictEqual([]);
    await expect(
      approve(asUser, holder, {
        requestId: revoked.requestId,
        requester: newcomer,
      }),
    ).rejects.toMatchObject(unavailable);

    // Removing a device through the product deletes its requests with it.
    await requestEnrollment(asUser, departing);
    await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
      ...departing.proof,
      deviceIdentifier: departing.deviceIdentifier,
    });
    await expect(
      t.run(async (ctx) =>
        ctx.db
          .query('productSyncEnrollmentRequests')
          .withIndex('by_trustedDeviceId', (q) =>
            q.eq('trustedDeviceId', departing.proof.trustedDeviceId),
          )
          .collect(),
      ),
    ).resolves.toStrictEqual([]);
  });

  it.each(['removed', 'revoked', 'pending-rotation', 'committed-rotation'])(
    'withholds an uncollected approval after %s changes its trust boundary',
    async (change) => {
      expect.hasAssertions();
      const { asUser, holder, newcomer, t } = await enrollmentAccount();
      const { requestId } = await requestEnrollment(asUser, newcomer);
      await approve(asUser, holder, { requestId, requester: newcomer });

      await t.run(async (ctx) => changeTrustBoundary(ctx, holder, change));

      await expect(status(asUser, newcomer, requestId)).resolves.toStrictEqual({
        state: 'cancelled',
      });
      await expect(
        asUser.mutation(api.productSyncEnrollment.complete, {
          ...newcomer.proof,
          requestId,
        }),
      ).resolves.toStrictEqual({ completed: false });
    },
  );

  it('keeps requests invisible and unusable to another Product Account', async () => {
    expect.hasAssertions();

    const { asUser, newcomer, t } = await enrollmentAccount();
    const { requestId } = await requestEnrollment(asUser, newcomer);
    const asOther = t.withIdentity(otherAppleIdentity);
    const outsider = await connectDevice(asOther, 'installation-101');
    await asOther.mutation(api.productSync.initialize, {
      ...outsider.proof,
      encryptedPayload: recoveryEnvelope,
    });

    await expect(listPending(asOther, outsider)).resolves.toStrictEqual([]);
    await expect(
      approve(asOther, outsider, { requestId, requester: newcomer }),
    ).rejects.toMatchObject(unavailable);
    await expect(
      asOther.mutation(api.productSyncEnrollment.decline, {
        ...outsider.proof,
        requestId,
      }),
    ).rejects.toMatchObject(unavailable);
    await expect(status(asOther, outsider, requestId)).resolves.toStrictEqual({
      state: 'cancelled',
    });
    await expect(
      asOther.mutation(api.productSyncEnrollment.complete, {
        ...outsider.proof,
        requestId,
      }),
    ).resolves.toStrictEqual({ completed: false });
    await expect(status(asUser, newcomer, requestId)).resolves.toMatchObject({
      state: 'pending',
    });
  });
});
