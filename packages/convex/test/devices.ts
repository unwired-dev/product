import type { TestConvex } from 'convex-test';
import type { FunctionArgs, FunctionReturnType } from 'convex/server';

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
      deviceIdentifier: pendingDevice.deviceIdentifier,
      ...(pendingDevice.displayName === undefined
        ? {}
        : { displayName: pendingDevice.displayName }),
      lastSeenAt: now,
      platform: pendingDevice.platform,
      productAccountId: account._id,
      productSyncKeyEpoch:
        account.productSyncPendingKeyEpoch ?? account.productSyncKeyEpoch ?? 1,
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
