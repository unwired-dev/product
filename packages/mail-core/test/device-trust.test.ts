import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import {
  productSubject,
  mailboxSubject,
  field,
  productOf,
  idOf,
  heldEpoch,
  setup,
} from './device-trust-fixture.ts';

const decodeDevices = Schema.decodeUnknownOption(
  Schema.fromJsonString(
    Schema.Array(Schema.Record(Schema.String, Schema.Unknown)),
  ),
);
describe('device trust', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one enrollment, recovery or removal path end to end. */
  // Replaces ProductSyncTests.trustedDeviceApprovalUnlocksANewDeviceWithoutReplacingAccountKeys.
  it('approves a new device only with the code it shows and never replaces the account keys', async () => {
    expect.hasAssertions();
    const { flow, sync, google, backend, keys, ring, install } = setup();
    // The first device creates the account keys and saves its mailbox to Product Sync.
    await flow.signIn('google');
    google.subject = mailboxSubject;
    await flow.addMailbox('gmail', false);
    google.subject = productSubject;
    const { recovery } = keys();
    const accountRing = structuredClone(ring());

    // The same Product Sign-In on another installation only waits as a Pending Device: it holds no
    // keys and cannot authorize Gmail.
    const enrolling = install();
    const requested = await enrolling.flow.signIn('google');
    expect(requested).toMatchObject({
      kind: 'device-pending',
      privateSync: 'enrollment-pending',
    });
    expect(requested).not.toHaveProperty('privateSyncMailboxes');
    const firstCode = field(requested, 'enrollmentCode');
    expect(enrolling.device.productSync.vault).toBeUndefined();
    const pendingId = idOf(enrolling.device);
    await expect(
      enrolling.flow.addMailbox('gmail', false),
    ).rejects.toMatchObject({
      code: 'unavailable',
    });

    // The trusted device sees the request; a mistyped code is caught before anything is sent.
    await expect(flow.refreshPrivateSync()).resolves.toMatchObject({
      enrollmentRequest: pendingId,
      enrollmentDevice: 'iPad',
    });
    await expect(
      flow.approveEnrollment(pendingId, `${firstCode}X`),
    ).rejects.toMatchObject({ code: 'enrollment-code-invalid' });
    expect(sync.pending.get(pendingId)).not.toHaveProperty('approval');

    // A declined request ends; the new device asks again with a new code.
    await flow.declineEnrollment(pendingId);
    const renewed = await enrolling.flow.refreshPrivateSync();
    expect(renewed).toMatchObject({
      privateSync: 'enrollment-pending',
      enrollmentNotice: 'renewed',
    });
    const secondCode = field(renewed, 'enrollmentCode');
    expect(secondCode).not.toBe(firstCode);

    // An approval sealed with the previous code does not open: the device stays pending, asks with
    // a new code and keeps no keys.
    await expect(flow.refreshPrivateSync()).resolves.toMatchObject({
      enrollmentRequest: pendingId,
    });
    await flow.approveEnrollment(pendingId, firstCode);
    const rejected = await enrolling.flow.refreshPrivateSync();
    expect(rejected).toMatchObject({
      kind: 'device-pending',
      enrollmentNotice: 'rejected',
    });
    expect(enrolling.device.productSync.vault).toBeUndefined();
    const thirdCode = field(rejected, 'enrollmentCode');
    expect([firstCode, secondCode]).not.toContain(thirdCode);

    // An expired request cannot be approved; reconnecting replaces the ended Pending Device.
    await expect(flow.refreshPrivateSync()).resolves.toMatchObject({
      enrollmentRequest: pendingId,
    });
    sync.clock += 900_001;
    await expect(
      flow.approveEnrollment(pendingId, thirdCode),
    ).rejects.toMatchObject({ code: 'enrollment-unavailable' });
    const expired = await enrolling.flow.refreshPrivateSync();
    expect(expired).toMatchObject({ privateSync: 'enrollment-pending' });
    const code = field(expired, 'enrollmentCode');
    expect(code).not.toBe(thirdCode);
    const request = idOf(enrolling.device);
    expect(request).not.toBe(pendingId);
    expect(sync.pending.has(pendingId)).toBe(false);

    // The code shown on the new device, typed loosely, approves exactly its request.
    await expect(flow.refreshPrivateSync()).resolves.toMatchObject({
      enrollmentRequest: request,
    });
    const approved = await flow.approveEnrollment(request, code.toLowerCase());
    expect(approved).not.toHaveProperty('enrollmentRequest');
    expect(approved).toMatchObject({ privateSync: 'recovery-key' });
    // Replaying the approval is refused; the backend never saw a code.
    await expect(flow.approveEnrollment(request, code)).rejects.toMatchObject({
      code: 'enrollment-unavailable',
    });
    expect(JSON.stringify(backend.calls)).not.toMatch(/CODE-\d/u);

    // The new device adopts the account keys, becomes a Trusted Device with the same credential
    // and reads the synchronized mailbox list; Gmail on this device still needs its own consent.
    const unlocked = await enrolling.flow.refreshPrivateSync();
    expect(unlocked).toMatchObject({
      kind: 'mailbox-needed',
      privateSync: 'ready',
      privateSyncMailboxes: 'alex@example.invalid',
    });
    expect(unlocked).not.toHaveProperty('recoveryKey');
    expect(unlocked).not.toHaveProperty('enrollmentCode');
    expect(enrolling.device.productSync).toMatchObject({
      vault: { ring: accountRing },
    });
    expect(enrolling.device.productSync.enrollment).toBeUndefined();
    expect(productOf(enrolling.device)).not.toHaveProperty('pending');
    expect(keys().devices.has(idOf(enrolling.device))).toBe(true);
    expect(sync.pending.has(request)).toBe(false);
    google.subject = mailboxSubject;
    await expect(
      enrolling.flow.addMailbox('gmail', false),
    ).resolves.toMatchObject({
      kind: 'connected',
    });
    google.subject = productSubject;
    // Nothing replaced the account's key material.
    expect(keys().recovery).toBe(recovery);
    expect(sync.initializations).toBe(1);
    expect(sync.rings).toBe(1);
    await expect(enrolling.relaunch().restore()).resolves.toMatchObject({
      privateSync: 'ready',
    });
  });

  // Replaces the device lists of the retired "lists other Trusted Devices and the newest
  // enrollment request …" test.
  it('lists the newest enrollment request and the other Trusted Devices', async () => {
    expect.hasAssertions();
    const { flow, sync, trustedDevice, createKeys, install, recovered } =
      setup();
    const other = await recovered(await createKeys());
    const older = install();
    await older.flow.signIn('google');
    sync.clock += 1;
    const newer = install();
    await newer.flow.signIn('google');
    const listed = await flow.refreshPrivateSync();
    expect(listed).toMatchObject({
      enrollmentRequest: idOf(newer.device),
      enrollmentDevice: 'iPad',
    });
    expect(
      Option.getOrThrow(decodeDevices(field(listed, 'trustedDevices'))),
    ).toStrictEqual([
      {
        id: other.id,
        name: `Device ${other.id}`,
        registeredAt: trustedDevice(other.id).registeredAt,
      },
    ]);
    // No encryption key or credential reaches the status.
    expect(field(listed, 'trustedDevices')).not.toMatch(/device-key/u);
  });

  it('forgets the previous device list after signing out even when the new roster read fails', async () => {
    expect.hasAssertions();
    const { flow, vault, createKeys, recovered } = setup();
    const key = await createKeys();
    const previous = await recovered(key);
    expect(field(await flow.refreshPrivateSync(), 'trustedDevices')).toContain(
      previous.id,
    );
    await flow.signOut();
    await previous.flow.signOut();
    const current = await recovered(key);
    await flow.signIn('google');
    const { call } = vault;
    const failing = vi.spyOn(vault, 'call').mockImplementation((request) => {
      // oxlint-disable-next-line vitest/no-conditional-in-test -- The external boundary refuses only roster reads; every other real flow step still runs.
      if (request.path === 'productAccount:listTrustedDevices') {
        return Promise.reject(
          Object.assign(new Error('Roster unavailable'), {
            code: 'unavailable',
          }),
        );
      }
      return call(request);
    });
    const unlocked = await flow.recoverWithRecoveryKey(key);
    expect(unlocked).toMatchObject({ privateSync: 'ready' });
    expect(unlocked).not.toHaveProperty('trustedDevices');
    expect(unlocked).not.toHaveProperty('enrollmentRequest');
    failing.mockRestore();
    const refreshed = field(await flow.refreshPrivateSync(), 'trustedDevices');
    expect(refreshed).toContain(current.id);
  });

  // Replaces ProductSyncTests.recoveryKeyUnlocksANewDeviceWithoutReplacingAccountKeys; its Apple
  // reauthentication stays in the registration flow tests.
  it('unlocks with the Recovery Key only after storing the keys, and changes nothing before', async () => {
    expect.hasAssertions();
    const { flow, sync, keys, ring, install, createKeys, device } = setup();
    const shown = await createKeys(true);
    const { recovery } = keys();
    const accountRing = structuredClone(ring());

    const recovering = install();
    const requested = await recovering.flow.signIn('google');
    expect(requested).toMatchObject({
      kind: 'device-pending',
      privateSync: 'enrollment-pending',
    });
    // Malformed and unrelated keys unlock nothing and report the current status.
    for (const entry of ['', 'SYNTHETIC-RECOVERY-unrelated']) {
      await expect(
        recovering.flow.recoverWithRecoveryKey(entry),
      ).resolves.toMatchObject({
        kind: 'device-pending',
        enrollmentCode: field(requested, 'enrollmentCode'),
        recoveryNotice: 'rejected',
      });
    }
    expect(recovering.device.productSync.vault).toBeUndefined();
    // When the Pending Device ended while the form was open, the sign-in the attempt renews also
    // replaces it, and the rejection shows the new code rather than the superseded one.
    sync.clock += 900_001;
    const renewed = await recovering.flow.recoverWithRecoveryKey(
      'SYNTHETIC-RECOVERY-unrelated',
    );
    expect(renewed).toMatchObject({ recoveryNotice: 'rejected' });
    const code = field(renewed, 'enrollmentCode');
    expect(code).not.toBe(field(requested, 'enrollmentCode'));
    const request = idOf(recovering.device);

    // An interrupted recovery leaves the device waiting for approval, also after relaunch.
    sync.offline = true;
    await expect(
      recovering.flow.recoverWithRecoveryKey(shown),
    ).rejects.toMatchObject({ code: 'unavailable' });
    sync.offline = false;
    const relaunched = await recovering.relaunch().restore();
    expect(relaunched).toMatchObject({
      privateSync: 'enrollment-pending',
      enrollmentCode: code,
    });
    expect(relaunched).not.toHaveProperty('recoveryNotice');
    expect(recovering.device.productSync.vault).toBeUndefined();
    expect(sync.pending.get(request)).toHaveProperty('publicKey');

    // Killed after storing the keys but before confirming them, it is still pending; the next
    // launch confirms the stored keys and admits it.
    sync.failCompletion = true;
    await expect(
      recovering.relaunch().recoverWithRecoveryKey(shown),
    ).rejects.toMatchObject({ code: 'unavailable' });
    sync.failCompletion = false;
    expect(recovering.device.productSync).toMatchObject({
      vault: { ring: accountRing },
    });
    expect(productOf(recovering.device).pending).toBe(true);
    const unlocked = await recovering.relaunch().restore();
    expect(unlocked).toMatchObject({
      kind: 'mailbox-needed',
      privateSync: 'ready',
      privateSyncMailboxes: 'alex@example.invalid',
    });
    expect(unlocked).not.toHaveProperty('recoveryKey');
    expect(unlocked).not.toHaveProperty('enrollmentCode');
    expect(recovering.device.productSync.vault).not.toHaveProperty(
      'recoveryKey',
    );
    expect(productOf(recovering.device)).not.toHaveProperty('pending');
    // Its Pending Device and request are gone; nothing replaced the account's key material.
    expect(sync.pending.has(request)).toBe(false);
    expect(recovering.device.productSync.enrollment).toBeUndefined();
    expect(keys().recovery).toBe(recovery);
    expect(sync.initializations).toBe(1);

    // A Trusted Device that lost its account keys but kept its encryption key reads the account's
    // recovery envelope directly.
    device.productSync.vault = undefined;
    await expect(flow.restore()).resolves.toMatchObject({
      privateSync: 'enrollment-needed',
    });
    await expect(
      flow.recoverWithRecoveryKey('SYNTHETIC-RECOVERY-unrelated'),
    ).resolves.toMatchObject({ recoveryNotice: 'rejected' });
    await expect(flow.recoverWithRecoveryKey(shown)).resolves.toMatchObject({
      privateSync: 'ready',
      privateSyncMailboxes: 'alex@example.invalid',
    });
    expect(device.productSync).toMatchObject({ vault: { ring: accountRing } });
    expect(keys().recovery).toBe(recovery);
  });

  // Replaces ProductSyncTests.interruptedRecoveryDoesNotAcknowledgeANewerApprovalWithOlderKeys.
  it('admits a device whose interrupted recovery a removal overtook only through a newer approval', async () => {
    expect.hasAssertions();
    const { flow, sync, ring, install, createKeys, recovered, remove } =
      setup();
    const shown = await createKeys();
    const survivor = await recovered(shown);
    const removed = await recovered(shown);
    const newcomer = install();
    const code = field(await newcomer.flow.signIn('google'), 'enrollmentCode');
    sync.failCompletion = true;
    await expect(
      newcomer.flow.recoverWithRecoveryKey(shown),
    ).rejects.toMatchObject({ code: 'unavailable' });
    sync.failCompletion = false;
    expect(heldEpoch(newcomer.device)).toBe(1);
    await remove(flow, removed.id);
    const request = field(
      await survivor.flow.refreshPrivateSync(),
      'enrollmentRequest',
    );
    await survivor.flow.approveEnrollment(request, code);
    // The older keys are refused; the epoch-2 approval opens and is stored before admission.
    await expect(newcomer.flow.refreshPrivateSync()).resolves.toMatchObject({
      privateSync: 'ready',
    });
    expect(productOf(newcomer.device)).not.toHaveProperty('pending');
    expect(newcomer.device.productSync).toMatchObject({
      vault: { ring: ring() },
    });
    expect(heldEpoch(newcomer.device)).toBe(2);
  });
});
