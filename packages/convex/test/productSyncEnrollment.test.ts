/// <reference types="vite/client" />

import { convexTest } from 'convex-test';

import type { Id } from '../convex/_generated/dataModel.js';

import { api, internal } from '../convex/_generated/api.js';
import { trustedDeviceCredentialDigest } from '../convex/productAccountAuth.js';
import schema from '../convex/schema.js';
import {
  pendingConnection,
  recoveryProof,
  recoveryVerifier,
  trustedConnection,
} from './devices.js';

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
const encryptedRecord = { ...recoveryEnvelope, schemaVersion: 1 };

// The value and digest a removal's replacement Recovery Key would derive.
const replacementRecoveryProof = 'c'.repeat(64);
const replacementRecoveryVerifier =
  '52b6419d27bd7f547cee3b92f8c17a908b8a49601ecbec161e5030de1dfe9e0a';

const enrollmentPublicKey = `${'A'.repeat(43)}=`;
const renewedPublicKey = `${'C'.repeat(43)}=`;
const sealedKeyRing = {
  ciphertextBase64: 'c2VhbGVkIGtleSByaW5n',
  encapsulatedKeyBase64: `${'B'.repeat(43)}=`,
};
const enrollmentLifetime = 15 * 60 * 1000;
const unavailable = { data: { code: 'ENROLLMENT_REQUEST_UNAVAILABLE' } };
const pendingUnavailable = { data: { code: 'PENDING_DEVICE_UNAVAILABLE' } };

type Backend = ReturnType<typeof convexTest>;
type Client = ReturnType<Backend['withIdentity']>;

async function connect(
  asUser: Client,
  deviceIdentifier: string,
  platform = 'ios',
) {
  return asUser.mutation(api.productAccount.connect, {
    deviceIdentifier,
    platform,
    supportsDeviceCredentials: true,
  });
}

async function trustedDevice(asUser: Client, deviceIdentifier: string) {
  const connection = trustedConnection(await connect(asUser, deviceIdentifier));
  return {
    deviceIdentifier,
    productAccountId: connection.productAccountId,
    proof: {
      trustedDeviceCredential: connection.trustedDeviceCredential,
      trustedDeviceId: connection.trustedDeviceId as Id<'trustedDevices'>,
    },
  };
}

type Trusted = Awaited<ReturnType<typeof trustedDevice>>;

async function pendingDevice(
  asUser: Client,
  deviceIdentifier: string,
  platform = 'macos',
) {
  const connection = pendingConnection(
    await connect(asUser, deviceIdentifier, platform),
  );
  return {
    connection,
    deviceIdentifier,
    proof: {
      pendingDeviceCredential: connection.pendingDeviceCredential,
      pendingDeviceId: connection.pendingDeviceId as Id<'pendingDevices'>,
    },
  };
}

type Pending = Awaited<ReturnType<typeof pendingDevice>>;

// An initialized Product Account with the device that created its keys and a device that waits.
async function enrollmentAccount(identity = googleIdentity) {
  const t = convexTest(schema, modules);
  const asUser = t.withIdentity(identity);
  const holder = await trustedDevice(asUser, 'installation-001');
  await asUser.mutation(api.productSync.initialize, {
    ...holder.proof,
    encryptedPayload: recoveryEnvelope,
    recoveryVerifier,
  });
  const newcomer = await pendingDevice(asUser, 'installation-002');
  return { asUser, holder, newcomer, t };
}

async function request(
  asUser: Client,
  device: Pending,
  publicKey = enrollmentPublicKey,
) {
  return asUser.mutation(api.productSyncEnrollment.request, {
    ...device.proof,
    enrollmentPublicKey: publicKey,
  });
}

async function approve(
  asUser: Client,
  approver: Trusted,
  sealed: Readonly<{
    device: Pending;
    enrollmentPublicKey?: string;
    keyVersion?: number;
  }>,
) {
  return asUser.mutation(api.productSyncEnrollment.approve, {
    ...approver.proof,
    ...sealedKeyRing,
    enrollmentPublicKey: sealed.enrollmentPublicKey ?? enrollmentPublicKey,
    keyVersion: sealed.keyVersion ?? 1,
    pendingDeviceId: sealed.device.proof.pendingDeviceId,
  });
}

async function status(asUser: Client, device: Pending) {
  return asUser.mutation(api.productSyncEnrollment.status, device.proof);
}

async function complete(asUser: Client, device: Pending, keyVersion = 1) {
  return asUser.mutation(api.productSyncEnrollment.complete, {
    ...device.proof,
    keyVersion,
  });
}

async function recover(asUser: Client, device: Pending, proof = recoveryProof) {
  return asUser.mutation(api.productSyncEnrollment.recover, {
    ...device.proof,
    recoveryProof: proof,
  });
}

async function listTrusted(asUser: Client, device: Trusted) {
  return asUser.query(api.productAccount.listTrustedDevices, device.proof);
}

// Confirms an authorized Pending Device, which then proves itself as the Trusted Device it became
// with the credential it had while pending.
async function admit(
  asUser: Client,
  device: Pending,
  keyVersion = 1,
): Promise<Trusted> {
  const completion = await complete(asUser, device, keyVersion);
  if (!completion.admitted) {
    throw new Error('Pending Device was not admitted');
  }
  return {
    deviceIdentifier: device.deviceIdentifier,
    productAccountId: device.connection.productAccountId,
    proof: {
      trustedDeviceCredential: device.proof.pendingDeviceCredential,
      trustedDeviceId: completion.trustedDeviceId,
    },
  };
}

// Removes a device and starts a key rotation, as the recently authenticated HTTP route does.
async function revoke(asUser: Client, remover: Trusted, target: Trusted) {
  const recovery = await asUser.query(
    api.productSync.getEncryptedPayloadForTrustedDevice,
    { ...remover.proof, payloadIdentifier: 'product-account-recovery-v1' },
  );
  const account = await asUser.query(
    api.productAccount.getProductSyncKeyRotation,
    remover.proof,
  );
  const committedEpoch = recovery?.encryptedPayload.keyVersion ?? 1;
  const nextEpoch = (account?.keyEpoch ?? committedEpoch) + 1;
  return asUser.mutation(internal.productAccount.revokeTrustedDevice, {
    ...remover.proof,
    encryptedTransition: { ...encryptedRecord, keyVersion: committedEpoch },
    expectedRecoveryUpdatedAt: recovery?.updatedAt ?? 0,
    recoveryVerifier: replacementRecoveryVerifier,
    recoveryWrappedAccountKey: { ...recoveryEnvelope, keyVersion: nextEpoch },
    trustedDeviceToRevokeId: target.proof.trustedDeviceId,
  });
}

// Convex omits iat from the identity, so freshness comes only from the bearer token.
async function deleteRecentlyAuthenticated(
  asUser: Client,
  body: Readonly<Record<string, unknown>>,
  issuedAt = Math.floor(Date.now() / 1000),
): Promise<Response> {
  const encode = (value: Readonly<Record<string, unknown>>) =>
    Buffer.from(JSON.stringify(value), 'utf8').toString('base64url');
  const token = `${encode({ alg: 'RS256' })}.${encode({
    iat: issuedAt,
    iss: googleIdentity.issuer,
    sub: googleIdentity.subject,
  })}.signature`;
  return asUser.fetch('/product-account/delete', {
    body: JSON.stringify(body),
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
    },
    method: 'POST',
  });
}

/* oxlint-disable vitest/max-expects -- Each journey proves one admission state machine across devices. */
describe('pending device admission', () => {
  it('admits a second device only after a Trusted Device approves it and it confirms the stored keys', async () => {
    expect.hasAssertions();

    const { asUser, holder, newcomer } = await enrollmentAccount();
    expect(newcomer.connection).toMatchObject({
      accountCreated: false,
      productSyncMaterialInitialized: true,
    });
    // Signing in admitted nobody: the account still has one Trusted Device.
    await expect(listTrusted(asUser, holder)).resolves.toHaveLength(1);

    const { expiresAt } = await request(asUser, newcomer);
    await expect(
      asUser.mutation(api.productSyncEnrollment.listPending, holder.proof),
    ).resolves.toStrictEqual([
      {
        createdAt: expiresAt - enrollmentLifetime,
        displayName: 'Mac',
        enrollmentPublicKey,
        expiresAt,
        pendingDeviceId: newcomer.proof.pendingDeviceId,
        platform: 'macos',
      },
    ]);
    await expect(status(asUser, newcomer)).resolves.toStrictEqual({
      expiresAt,
      state: 'pending',
    });
    // Nothing is authorized before an approval.
    await expect(complete(asUser, newcomer)).resolves.toStrictEqual({
      admitted: false,
    });

    await expect(
      approve(asUser, holder, { device: newcomer }),
    ).resolves.toStrictEqual({
      approved: true,
    });
    await expect(
      asUser.mutation(api.productSyncEnrollment.listPending, holder.proof),
    ).resolves.toStrictEqual([]);
    await expect(status(asUser, newcomer)).resolves.toMatchObject({
      approval: { ...sealedKeyRing, keyVersion: 1 },
      state: 'approved',
    });

    const device = await admit(asUser, newcomer);
    // The admitted device keeps its credential and reads Product Sync like any Trusted Device.
    await expect(listTrusted(asUser, device)).resolves.toHaveLength(2);
    await expect(
      asUser.query(api.productSync.getEncryptedPayloadForTrustedDevice, {
        ...device.proof,
        payloadIdentifier: 'product-account-recovery-v1',
      }),
    ).resolves.toMatchObject({ encryptedPayload: recoveryEnvelope });
    // Its next sign-in reconnects the same Trusted Device.
    await expect(
      asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: newcomer.deviceIdentifier,
        pendingDeviceCredential: newcomer.proof.pendingDeviceCredential,
        platform: 'macos',
        supportsDeviceCredentials: true,
      }),
    ).resolves.toMatchObject({
      trustedDeviceCredential: newcomer.proof.pendingDeviceCredential,
      trustedDeviceId: device.proof.trustedDeviceId,
    });
    // The Pending Device record is gone; its proof opens nothing any more.
    await expect(status(asUser, newcomer)).rejects.toMatchObject(
      pendingUnavailable,
    );
  });

  it('refuses protected backend operations to a Pending Device, including one presenting a real Trusted Device id', async () => {
    expect.hasAssertions();

    const { asUser, holder, newcomer } = await enrollmentAccount();
    await request(asUser, newcomer);
    // Reject both an invalid table id and a real device id paired with the pending credential.
    const pendingId: string = newcomer.proof.pendingDeviceId;
    // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The pending table id deliberately violates the Trusted Device argument validator.
    const pendingAsTrustedId = pendingId as Id<'trustedDevices'>;
    for (const trustedDeviceId of [
      pendingAsTrustedId,
      holder.proof.trustedDeviceId,
    ]) {
      const asTrusted = {
        trustedDeviceCredential: newcomer.proof.pendingDeviceCredential,
        trustedDeviceId,
      };
      const refusals = [
        () => asUser.query(api.productAccount.listTrustedDevices, asTrusted),
        () =>
          asUser.query(api.productAccount.getProductSyncKeyRotation, asTrusted),
        () =>
          asUser.query(api.productSync.getEncryptedPayloadForTrustedDevice, {
            ...asTrusted,
            payloadIdentifier: 'product-account-recovery-v1',
          }),
        () =>
          asUser.query(api.productSync.listEncryptedPayloadsForTrustedDevice, {
            ...asTrusted,
          }),
        () =>
          asUser.mutation(api.productSync.putEncryptedPayloadIfUnchanged, {
            ...asTrusted,
            encryptedPayload: encryptedRecord,
            payloadIdentifier: 'mailbox.pending',
          }),
        () =>
          asUser.mutation(
            api.productAccount.acknowledgeProductSyncKeyRotation,
            {
              ...asTrusted,
              keyEpoch: 1,
            },
          ),
        () => asUser.mutation(api.productSyncEnrollment.listPending, asTrusted),
        () =>
          asUser.mutation(api.productSyncEnrollment.approve, {
            ...asTrusted,
            ...sealedKeyRing,
            enrollmentPublicKey,
            keyVersion: 1,
            pendingDeviceId: newcomer.proof.pendingDeviceId,
          }),
        () =>
          asUser.mutation(api.pushRelay.registerDevice, {
            ...asTrusted,
            apnsEnvironment: 'production',
            apnsToken: 'pending-apns-token',
          }),
        () =>
          asUser.mutation(api.productAccount.renameTrustedDevice, {
            ...asTrusted,
            displayName: 'Mine',
            trustedDeviceToRenameId: holder.proof.trustedDeviceId,
          }),
        () =>
          asUser.mutation(internal.productAccount.revokeTrustedDevice, {
            ...asTrusted,
            encryptedTransition: encryptedRecord,
            expectedRecoveryUpdatedAt: 0,
            recoveryVerifier,
            recoveryWrappedAccountKey: { ...recoveryEnvelope, keyVersion: 2 },
            trustedDeviceToRevokeId: holder.proof.trustedDeviceId,
          }),
        () =>
          asUser.mutation(
            internal.productSync.replaceRecoveryMaterialIfUnchanged,
            {
              ...asTrusted,
              encryptedPayload: recoveryEnvelope,
              recoveryVerifier,
            },
          ),
        () =>
          asUser.mutation(internal.signInLinks.request, {
            ...asTrusted,
            provider: 'apple',
          }),
      ];
      for (const refusal of refusals) {
        await expect(refusal()).rejects.toThrow(
          /Trusted device required|Expected ID for table "trustedDevices"|TRUSTED_DEVICE_RECONNECT_REQUIRED/u,
        );
      }
    }
    // It never sees another device's request, a transition or the trusted list.
    await expect(listTrusted(asUser, holder)).resolves.toHaveLength(1);
  });

  it('lets an approver behind a pending epoch approve only after it adopts the newest epoch', async () => {
    expect.hasAssertions();

    const { asUser, holder, t } = await enrollmentAccount();
    // Admit a second Trusted Device by Recovery Key, then remove a third to start a rotation.
    const secondPending = await pendingDevice(asUser, 'installation-003');
    await recover(asUser, secondPending);
    const approver = await admit(asUser, secondPending);
    const removedPending = await pendingDevice(asUser, 'installation-004');
    await recover(asUser, removedPending);
    const removed = await admit(asUser, removedPending);
    await expect(revoke(asUser, holder, removed)).resolves.toMatchObject({
      keyEpoch: 2,
      state: 'pending',
    });

    const newcomer = await pendingDevice(asUser, 'installation-005');
    await request(asUser, newcomer);
    // Only the newest epoch may be sealed, and only by an approver that holds it.
    await expect(
      approve(asUser, approver, { device: newcomer }),
    ).rejects.toThrow('Product Sync key rotation required');
    await expect(
      approve(asUser, approver, { device: newcomer, keyVersion: 2 }),
    ).rejects.toThrow('Product Sync key rotation required');
    await asUser.mutation(
      api.productAccount.acknowledgeProductSyncKeyRotation,
      {
        ...approver.proof,
        keyEpoch: 2,
      },
    );
    await expect(
      approve(asUser, approver, { device: newcomer, keyVersion: 2 }),
    ).resolves.toStrictEqual({ approved: true });

    // A delayed confirmation for a previously stored ring cannot acknowledge the newer approval.
    await expect(complete(asUser, newcomer, 1)).resolves.toStrictEqual({
      admitted: false,
    });
    const completion = await complete(asUser, newcomer, 2);
    expect(completion.admitted).toBe(true);
    // The admitted device is acknowledged at the epoch it received, so it never fetches a
    // transition; only the holder still has to adopt it.
    const stored = await t.run(async (ctx) =>
      ctx.db.query('trustedDevices').collect(),
    );
    expect(
      stored.find(
        ({ deviceIdentifier }) => deviceIdentifier === 'installation-005',
      )?.productSyncKeyEpoch,
    ).toBe(2);
    await expect(
      asUser.query(api.productAccount.getProductSyncKeyRotation, holder.proof),
    ).resolves.toMatchObject({ keyEpoch: 2, pendingDeviceCount: 1 });
  });

  it('keeps the device pending when its approval cannot be opened, its approver leaves, or its epoch is superseded', async () => {
    expect.hasAssertions();

    const { asUser, holder, newcomer } = await enrollmentAccount();
    const other = await pendingDevice(asUser, 'installation-003', 'ios');
    await recover(asUser, other);
    const approver = await admit(asUser, other);

    // A ring the device cannot open (another code was entered): it asks again with a new key,
    // and the earlier approval can never be collected.
    await request(asUser, newcomer);
    await approve(asUser, approver, { device: newcomer });
    const renewed = await request(asUser, newcomer, renewedPublicKey);
    await expect(status(asUser, newcomer)).resolves.toStrictEqual({
      expiresAt: renewed.expiresAt,
      state: 'pending',
    });
    await expect(complete(asUser, newcomer)).resolves.toStrictEqual({
      admitted: false,
    });
    // An approval sealed to the replaced key is refused.
    await expect(
      approve(asUser, approver, { device: newcomer }),
    ).rejects.toMatchObject(unavailable);

    // The approver is removed before the device confirms: the approval is void.
    await approve(asUser, approver, {
      device: newcomer,
      enrollmentPublicKey: renewedPublicKey,
    });
    await revoke(asUser, holder, approver);
    await expect(status(asUser, newcomer)).resolves.toStrictEqual({
      state: 'cancelled',
    });
    await expect(complete(asUser, newcomer)).resolves.toStrictEqual({
      admitted: false,
    });

    // An approval at an epoch that a later removal superseded is void too.
    await asUser.mutation(
      api.productAccount.acknowledgeProductSyncKeyRotation,
      {
        ...holder.proof,
        keyEpoch: 2,
      },
    );
    await request(asUser, newcomer);
    await approve(asUser, holder, { device: newcomer, keyVersion: 2 });
    const third = await pendingDevice(asUser, 'installation-004', 'ios');
    await recover(asUser, third, replacementRecoveryProof);
    await revoke(asUser, holder, await admit(asUser, third, 2));
    await expect(complete(asUser, newcomer)).resolves.toStrictEqual({
      admitted: false,
    });
    // Still pending and not acknowledged: it never counts toward the rotation.
    await expect(
      asUser.query(api.productAccount.getProductSyncKeyRotation, holder.proof),
    ).resolves.toMatchObject({ keyEpoch: 3, pendingDeviceCount: 1 });
    await expect(request(asUser, newcomer)).resolves.toMatchObject({
      expiresAt: expect.any(Number),
    });
  });

  it('declines a request so the device asks again with a new key', async () => {
    expect.hasAssertions();

    const { asUser, holder, newcomer } = await enrollmentAccount();
    await request(asUser, newcomer);
    await expect(
      asUser.mutation(api.productSyncEnrollment.decline, {
        ...holder.proof,
        pendingDeviceId: newcomer.proof.pendingDeviceId,
      }),
    ).resolves.toStrictEqual({ declined: true });
    await expect(status(asUser, newcomer)).resolves.toStrictEqual({
      state: 'cancelled',
    });
    await expect(
      approve(asUser, holder, { device: newcomer }),
    ).rejects.toMatchObject(unavailable);
    await request(asUser, newcomer, renewedPublicKey);
    await expect(
      approve(asUser, holder, {
        device: newcomer,
        enrollmentPublicKey: renewedPublicKey,
      }),
    ).resolves.toStrictEqual({ approved: true });
  });

  it('admits a device that proves the Recovery Key and returns nothing for a wrong one', async () => {
    expect.hasAssertions();

    const { asUser, holder, newcomer } = await enrollmentAccount();
    const { expiresAt } = await request(asUser, newcomer);
    // A wrong proof returns nothing and leaves the device pending with its current code.
    await expect(
      recover(asUser, newcomer, replacementRecoveryProof),
    ).resolves.toBeNull();
    await expect(recover(asUser, newcomer, 'not-a-proof')).resolves.toBeNull();
    await expect(status(asUser, newcomer)).resolves.toStrictEqual({
      expiresAt,
      state: 'pending',
    });
    await expect(complete(asUser, newcomer)).resolves.toStrictEqual({
      admitted: false,
    });

    await expect(recover(asUser, newcomer)).resolves.toStrictEqual(
      recoveryEnvelope,
    );
    // A device that fails before confirming proves the Recovery Key again; the proof is idempotent.
    await expect(recover(asUser, newcomer)).resolves.toStrictEqual(
      recoveryEnvelope,
    );
    await admit(asUser, newcomer);
    await expect(listTrusted(asUser, holder)).resolves.toHaveLength(2);
  });

  it('during a pending rotation admits only with the replacement Recovery Key, at the newest epoch', async () => {
    expect.hasAssertions();

    const { asUser, holder, newcomer, t } = await enrollmentAccount();
    await recover(asUser, newcomer);
    const removed = await admit(asUser, newcomer);
    await revoke(asUser, holder, removed);

    // The removed device mints a new identifier: it is an ordinary Pending Device.
    const returning = await pendingDevice(asUser, 'installation-minted');
    await expect(
      connect(asUser, newcomer.deviceIdentifier),
    ).rejects.toMatchObject({ data: { code: 'TRUSTED_DEVICE_REVOKED' } });
    // The previous Recovery Key, which the removed device may know, admits nobody new.
    await expect(recover(asUser, returning)).resolves.toBeNull();
    // The holder still adopts with the transition; the previous key stays its recovery until then.
    await expect(
      asUser.query(api.productSync.getEncryptedPayloadForTrustedDevice, {
        ...holder.proof,
        payloadIdentifier: 'product-account-recovery-v1',
      }),
    ).resolves.toMatchObject({ encryptedPayload: recoveryEnvelope });

    // The replacement Recovery Key yields the newest epoch's envelope.
    await expect(
      recover(asUser, returning, replacementRecoveryProof),
    ).resolves.toStrictEqual({ ...recoveryEnvelope, keyVersion: 2 });
    const readmitted = await complete(asUser, returning, 2);
    expect(readmitted.admitted).toBe(true);
    const devices = await t.run(async (ctx) =>
      ctx.db.query('trustedDevices').collect(),
    );
    expect(
      devices.map(({ deviceIdentifier, productSyncKeyEpoch }) => [
        deviceIdentifier,
        productSyncKeyEpoch,
      ]),
    ).toStrictEqual([
      ['installation-001', 1],
      ['installation-minted', 2],
    ]);

    // Completing the rotation makes the replacement key the only one that admits.
    await asUser.mutation(
      api.productAccount.acknowledgeProductSyncKeyRotation,
      {
        ...holder.proof,
        keyEpoch: 2,
      },
    );
    const later = await pendingDevice(asUser, 'installation-later');
    await expect(recover(asUser, later)).resolves.toBeNull();
    await expect(
      recover(asUser, later, replacementRecoveryProof),
    ).resolves.toStrictEqual({ ...recoveryEnvelope, keyVersion: 2 });
  });

  it('never admits an installation removed through its retained id while it waited again after signing out', async () => {
    expect.hasAssertions();

    const { asUser, holder, newcomer, t } = await enrollmentAccount();
    await recover(asUser, newcomer);
    const signedOut = await admit(asUser, newcomer);
    await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
      ...signedOut.proof,
      deviceIdentifier: signedOut.deviceIdentifier,
    });
    // The same installation signs in again and waits.
    const waiting = await pendingDevice(asUser, newcomer.deviceIdentifier);

    // Removing it through its retained Trusted Device id refuses the waiting record too, so the
    // replacement Recovery Key cannot admit it.
    await revoke(asUser, holder, signedOut);
    await expect(
      recover(asUser, waiting, replacementRecoveryProof),
    ).rejects.toMatchObject(pendingUnavailable);
    await expect(complete(asUser, waiting, 2)).rejects.toMatchObject(
      pendingUnavailable,
    );
    await expect(
      connect(asUser, newcomer.deviceIdentifier),
    ).rejects.toMatchObject({ data: { code: 'TRUSTED_DEVICE_REVOKED' } });

    // Even a record that outlived the removal is refused at admission and dropped.
    const outlivedId = await t.run(async (ctx) =>
      ctx.db.insert('pendingDevices', {
        createdAt: Date.now(),
        credentialDigest: await trustedDeviceCredentialDigest(
          waiting.proof.pendingDeviceCredential,
        ),
        deviceIdentifier: newcomer.deviceIdentifier,
        expiresAt: Date.now() + enrollmentLifetime,
        platform: 'macos',
        productAccountId: holder.productAccountId,
        recoveryKeyVersion: 2,
      }),
    );
    const outlived = {
      ...waiting,
      proof: { ...waiting.proof, pendingDeviceId: outlivedId },
    };
    await expect(complete(asUser, outlived, 2)).resolves.toStrictEqual({
      admitted: false,
    });
    await expect(
      t.run(async (ctx) => ctx.db.query('pendingDevices').collect()),
    ).resolves.toStrictEqual([]);
    await expect(listTrusted(asUser, holder)).resolves.toHaveLength(1);
  });

  it('completes a pending rotation without waiting for a Pending Device', async () => {
    expect.hasAssertions();

    const { asUser, holder, newcomer } = await enrollmentAccount();
    await recover(asUser, newcomer);
    const admittedDevice = await admit(asUser, newcomer);
    // After admission it behaves like any Trusted Device, including its later removal.
    await expect(revoke(asUser, holder, admittedDevice)).resolves.toStrictEqual(
      { keyEpoch: 2, pendingDeviceCount: 1, state: 'pending' },
    );
    await expect(listTrusted(asUser, admittedDevice)).rejects.toMatchObject({
      data: { code: 'TRUSTED_DEVICE_REVOKED' },
    });

    const waiting = await pendingDevice(asUser, 'installation-waiting');
    await request(asUser, waiting);
    await expect(
      asUser.mutation(api.productAccount.acknowledgeProductSyncKeyRotation, {
        ...holder.proof,
        keyEpoch: 2,
      }),
    ).resolves.toStrictEqual({
      keyEpoch: 2,
      pendingDeviceCount: 0,
      state: 'complete',
    });
    await expect(
      asUser.query(api.productAccount.getProductSyncKeyRotation, holder.proof),
    ).resolves.toBeNull();
  });

  it('limits Pending Devices per identifier and account, ends them with their code, and enforces the Trusted Device limit at admission', async () => {
    expect.hasAssertions();

    vi.useFakeTimers();
    try {
      const { asUser, holder, newcomer, t } = await enrollmentAccount();
      // Signing in again resumes the same record for the same identifier.
      await expect(
        asUser.mutation(api.productAccount.connect, {
          deviceIdentifier: newcomer.deviceIdentifier,
          pendingDeviceCredential: newcomer.proof.pendingDeviceCredential,
          platform: 'macos',
          supportsDeviceCredentials: true,
        }),
      ).resolves.toStrictEqual(newcomer.connection);
      await pendingDevice(asUser, 'installation-003');
      await pendingDevice(asUser, 'installation-004');
      await expect(connect(asUser, 'installation-005')).rejects.toMatchObject({
        data: { code: 'PENDING_DEVICE_LIMIT_REACHED' },
      });

      const { expiresAt } = await request(asUser, newcomer);
      vi.setSystemTime(expiresAt);
      // The expired record admits nothing and no longer counts toward the limit.
      await expect(status(asUser, newcomer)).resolves.toStrictEqual({
        expiresAt,
        state: 'expired',
      });
      await expect(recover(asUser, newcomer)).rejects.toMatchObject(
        pendingUnavailable,
      );
      await expect(
        approve(asUser, holder, { device: newcomer }),
      ).rejects.toMatchObject(unavailable);
      const fresh = await pendingDevice(asUser, 'installation-005');
      // The same device signs in again for a new record and a new code.
      const resumed = pendingConnection(
        await asUser.mutation(api.productAccount.connect, {
          deviceIdentifier: newcomer.deviceIdentifier,
          pendingDeviceCredential: newcomer.proof.pendingDeviceCredential,
          platform: 'macos',
          supportsDeviceCredentials: true,
        }),
      );
      expect(resumed.pendingDeviceId).not.toBe(newcomer.proof.pendingDeviceId);

      // The Trusted Device limit applies when an authorized device confirms.
      await t.run(async (ctx) => {
        for (let index = 1; index < 100; index += 1) {
          await ctx.db.insert('trustedDevices', {
            deviceIdentifier: `seeded-${index}`,
            lastSeenAt: Date.now(),
            platform: 'ios',
            productAccountId: holder.productAccountId,
            productSyncKeyEpoch: 1,
            registeredAt: Date.now(),
          });
        }
      });
      await recover(asUser, fresh);
      await expect(complete(asUser, fresh)).rejects.toThrow(
        'Trusted Device limit exceeded',
      );
    } finally {
      vi.useRealTimers();
    }
  });

  it('lets a Pending Device sign out, and delete the Product Account only after a recent sign-in', async () => {
    expect.hasAssertions();

    const { asUser, holder, newcomer, t } = await enrollmentAccount();
    const leaving = await pendingDevice(asUser, 'installation-leaving');
    await expect(
      asUser.mutation(api.productAccount.unregisterPendingDevice, {
        ...leaving.proof,
        deviceIdentifier: leaving.deviceIdentifier,
      }),
    ).resolves.toStrictEqual({ registered: false });
    // A retry after a lost reply is a no-op.
    await expect(
      asUser.mutation(api.productAccount.unregisterPendingDevice, {
        ...leaving.proof,
        deviceIdentifier: leaving.deviceIdentifier,
      }),
    ).resolves.toStrictEqual({ registered: false });
    await expect(status(asUser, leaving)).rejects.toMatchObject(
      pendingUnavailable,
    );

    // Admission can commit before sign-out without the device hearing its Trusted Device id.
    const unanswered = await pendingDevice(asUser, leaving.deviceIdentifier);
    await recover(asUser, unanswered);
    await complete(asUser, unanswered);
    await expect(listTrusted(asUser, holder)).resolves.toHaveLength(2);
    // A forged same-installation proof cannot unregister the admitted device.
    await expect(
      asUser.mutation(api.productAccount.unregisterPendingDevice, {
        ...unanswered.proof,
        deviceIdentifier: unanswered.deviceIdentifier,
        pendingDeviceCredential: 'd'.repeat(64),
      }),
    ).rejects.toMatchObject({
      data: { code: 'TRUSTED_DEVICE_RECONNECT_REQUIRED' },
    });
    await asUser.mutation(api.productAccount.unregisterPendingDevice, {
      ...unanswered.proof,
      deviceIdentifier: unanswered.deviceIdentifier,
    });
    await expect(listTrusted(asUser, holder)).resolves.toHaveLength(1);

    const deletion = {
      pendingDeviceCredential: newcomer.proof.pendingDeviceCredential,
      pendingDeviceId: newcomer.proof.pendingDeviceId,
    };
    const stale = await deleteRecentlyAuthenticated(
      asUser,
      deletion,
      Math.floor(Date.now() / 1000) - 301,
    );
    expect(stale.status).toBe(401);
    const forged = await deleteRecentlyAuthenticated(asUser, {
      ...deletion,
      pendingDeviceCredential: 'd'.repeat(64),
    });
    expect(forged.status).toBe(403);
    await expect(listTrusted(asUser, holder)).resolves.toHaveLength(1);

    const deleted = await deleteRecentlyAuthenticated(asUser, deletion);
    expect(deleted.status).toBe(200);
    await t.finishAllScheduledFunctions(() => undefined);
    await expect(
      t.run(async (ctx) => ({
        accounts: await ctx.db.query('productAccounts').collect(),
        pendingDevices: await ctx.db.query('pendingDevices').collect(),
        trustedDevices: await ctx.db.query('trustedDevices').collect(),
      })),
    ).resolves.toStrictEqual({
      accounts: [],
      pendingDevices: [],
      trustedDevices: [],
    });
  });

  it('keeps Pending Devices invisible and unusable to another Product Account', async () => {
    expect.hasAssertions();

    const { holder, newcomer, t } = await enrollmentAccount();
    const asOther = t.withIdentity(otherAppleIdentity);
    const stranger = await trustedDevice(asOther, 'installation-other');
    await asOther.mutation(api.productSync.initialize, {
      ...stranger.proof,
      encryptedPayload: recoveryEnvelope,
      recoveryVerifier,
    });
    await request(t.withIdentity(googleIdentity), newcomer);
    await expect(
      asOther.mutation(api.productSyncEnrollment.listPending, stranger.proof),
    ).resolves.toStrictEqual([]);
    await expect(
      approve(asOther, stranger, { device: newcomer }),
    ).rejects.toMatchObject(unavailable);
    // Another account's sign-in cannot use this account's Pending Device proof.
    await expect(status(asOther, newcomer)).rejects.toMatchObject(
      pendingUnavailable,
    );
    await expect(recover(asOther, newcomer)).rejects.toMatchObject(
      pendingUnavailable,
    );
    expect(holder.productAccountId).not.toBe(stranger.productAccountId);
  });

  it('lets the next device create the keys of an account that has none and no Trusted Device', async () => {
    expect.hasAssertions();

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(googleIdentity);
    const first = await trustedDevice(asUser, 'installation-001');
    // Another device waits while the first still holds the account without keys.
    await expect(connect(asUser, 'installation-002')).resolves.toMatchObject({
      pendingDeviceId: expect.any(String),
    });
    await asUser.mutation(api.productAccount.unregisterTrustedDevice, {
      ...first.proof,
      deviceIdentifier: first.deviceIdentifier,
    });
    // With no keys and no Trusted Device, the next device creates the keys.
    await expect(connect(asUser, 'installation-003')).resolves.toMatchObject({
      trustedDeviceId: expect.any(String),
    });
  });
});
/* oxlint-enable vitest/max-expects */
