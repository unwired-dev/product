import { createHash } from 'node:crypto';

import type { TestConvex } from 'convex-test';
import type { FunctionArgs, FunctionReturnType } from 'convex/server';

import type { Id } from '../convex/_generated/dataModel.js';
import type schema from '../convex/schema.js';

import { api } from '../convex/_generated/api.js';
import { trustedDeviceCredentialDigest } from '../convex/productAccountAuth.js';

type Backend = TestConvex<typeof schema>;
type Client = ReturnType<Backend['withIdentity']>;
type Connection = FunctionReturnType<typeof api.productAccount.connect>;
export type TrustedConnection = Extract<
  Connection,
  { trustedDeviceId: unknown }
>;
export type PendingConnection = Extract<
  Connection,
  { pendingDeviceId: unknown }
>;

export function trustedConnection(connection: Connection): TrustedConnection {
  if (!('trustedDeviceId' in connection)) {
    throw new Error('Expected a Trusted Device');
  }
  return connection;
}

export function pendingConnection(connection: Connection): PendingConnection {
  if (!('pendingDeviceId' in connection)) {
    throw new Error('Expected a Pending Device');
  }
  return connection;
}

// A stand-in for an installation's long-lived X25519 public key, as standard base64.
export function deviceEncryptionPublicKey(installation: string): string {
  return createHash('sha256').update(installation).digest('base64');
}

// Connects a device that the account has already admitted. A device after the account's first
// would wait as a Pending Device; for tests whose subject is not admission, its approval is stood
// in for by storing the Trusted Device that a confirmed approval at the newest epoch creates.
export async function connectTrusted(
  t: Backend,
  asUser: Client,
  args: FunctionArgs<typeof api.productAccount.connect>,
): Promise<TrustedConnection> {
  const connection = await asUser.mutation(api.productAccount.connect, args);
  if ('trustedDeviceId' in connection) {
    return connection;
  }
  await t.run(async (ctx) => {
    const pendingDevice = await ctx.db.get(
      'pendingDevices',
      connection.pendingDeviceId,
    );
    const account = await ctx.db.get(
      'productAccounts',
      connection.productAccountId,
    );
    if (pendingDevice === null || account === null) {
      throw new Error('Pending Device required');
    }
    const now = Date.now();
    await ctx.db.insert('trustedDevices', {
      // A device that predates device credentials proves itself with Product Sign-In alone.
      ...(args.supportsDeviceCredentials === true
        ? {
            credentialDigest: await trustedDeviceCredentialDigest(
              connection.pendingDeviceCredential,
            ),
          }
        : {}),
      deviceEncryptionPublicKey: deviceEncryptionPublicKey(
        pendingDevice.deviceIdentifier,
      ),
      deviceIdentifier: pendingDevice.deviceIdentifier,
      ...(pendingDevice.displayName === undefined
        ? {}
        : { displayName: pendingDevice.displayName }),
      lastSeenAt: now,
      platform: pendingDevice.platform,
      productAccountId: account._id,
      productSyncKeyEpoch: account.productSyncKeyEpoch ?? 1,
      registeredAt: now,
    });
    await ctx.db.delete('pendingDevices', pendingDevice._id);
  });
  return {
    ...trustedConnection(
      await asUser.mutation(api.productAccount.connect, {
        ...args,
        ...(args.supportsDeviceCredentials === true
          ? { trustedDeviceCredential: connection.pendingDeviceCredential }
          : {}),
      }),
    ),
    deviceRegistered: true,
  };
}

// A stand-in for the value a Recovery Key derives to admit a Pending Device, and its digest.
export const recoveryProof = 'b'.repeat(64);
export const recoveryVerifier =
  'a0fab1377f49a759b57f63318262ebe89fabfc990e8e93ceac2984561482b9d4';

// The value and digest a removal's replacement Recovery Key would derive.
export const replacementRecoveryProof = 'c'.repeat(64);
export const replacementRecoveryVerifier =
  '52b6419d27bd7f547cee3b92f8c17a908b8a49601ecbec161e5030de1dfe9e0a';

type DeviceProof = Readonly<{
  trustedDeviceCredential?: string;
  trustedDeviceId: Id<'trustedDevices'>;
}>;

// The activation a Trusted Device submits after preparing a removal against the account as it is
// now: its epoch, Recovery Key revision and every remaining Trusted Device's bound key, each sealed
// a stand-in ring. Tests alter it to simulate stale or malformed proposals.
export async function preparedRemoval(
  t: Backend,
  initiator: DeviceProof,
  trustedDeviceToRevokeId: Id<'trustedDevices'>,
) {
  return t.run(async (ctx) => {
    const device = await ctx.db.get(
      'trustedDevices',
      initiator.trustedDeviceId,
    );
    if (device === null) {
      throw new Error('Trusted Device required');
    }
    const { productAccountId } = device;
    const [account, recovery, liveTarget, retainedTarget, devices] =
      await Promise.all([
        ctx.db.get('productAccounts', productAccountId),
        ctx.db
          .query('encryptedProductSyncPayloads')
          .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
            q
              .eq('productAccountId', productAccountId)
              .eq('payloadIdentifier', 'product-account-recovery-v1'),
          )
          .unique(),
        ctx.db.get('trustedDevices', trustedDeviceToRevokeId),
        ctx.db
          .query('trustedDeviceRevocationTargets')
          .withIndex('by_productAccountId_and_trustedDeviceId', (q) =>
            q
              .eq('productAccountId', productAccountId)
              .eq('trustedDeviceId', trustedDeviceToRevokeId),
          )
          .unique(),
        ctx.db
          .query('trustedDevices')
          .withIndex('by_productAccountId_and_deviceIdentifier', (q) =>
            q.eq('productAccountId', productAccountId),
          )
          .collect(),
      ]);
    const removedInstallation = (liveTarget ?? retainedTarget)
      ?.deviceIdentifier;
    const keyEpoch = (account?.productSyncKeyEpoch ?? 1) + 1;
    const proposalId = [...crypto.getRandomValues(new Uint8Array(16))]
      .map((byte) => byte.toString(16).padStart(2, '0'))
      .join('');
    return {
      ...(initiator.trustedDeviceCredential === undefined
        ? {}
        : { trustedDeviceCredential: initiator.trustedDeviceCredential }),
      expectedKeyEpoch: keyEpoch - 1,
      expectedRecoveryUpdatedAt: recovery?.updatedAt ?? 0,
      keyEnvelopes: devices.flatMap((survivor) =>
        survivor._id === trustedDeviceToRevokeId ||
        survivor.deviceIdentifier === removedInstallation ||
        survivor.deviceEncryptionPublicKey === undefined
          ? []
          : [
              {
                ciphertextBase64: btoa(`ring ${keyEpoch} for ${survivor._id}`),
                deviceEncryptionPublicKey: survivor.deviceEncryptionPublicKey,
                encapsulatedKeyBase64: `${'E'.repeat(43)}=`,
                trustedDeviceId: survivor._id,
              },
            ],
      ),
      proposalId,
      recoveryVerifier: replacementRecoveryVerifier,
      recoveryWrappedAccountKey: {
        algorithm: 'AES-GCM-256' as const,
        ciphertextBase64: btoa(`recovery ${proposalId}`),
        keyVersion: keyEpoch,
        nonceBase64: 'bm9uY2U',
        schemaVersion: 3,
        tagBase64: 'dGFn',
      },
      trustedDeviceId: initiator.trustedDeviceId,
      trustedDeviceToRevokeId,
    };
  });
}
