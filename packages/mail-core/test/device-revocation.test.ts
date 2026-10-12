import type { NativeRegistration } from '../src/registration.ts';
import type { Device, Setup } from './device-trust-fixture.ts';

import { removeTrustedDevice } from '../src/testing/registration-vault.ts';
import {
  account,
  required,
  textOf,
  field,
  lastGroup,
  outcome,
  productOf,
  idOf,
  heldEpoch,
  revocationOf,
  setup,
} from './device-trust-fixture.ts';

// Ways the remover settles an unanswered activation.
const settleBy = {
  cancelling: (flow: NativeRegistration) => flow.cancelRevocation(),
  confirming: (flow: NativeRegistration, key: string) =>
    flow.confirmRevocation(lastGroup(key)),
};

describe('device revocation', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one enrollment, recovery or removal path end to end. */
  // Replaces ProductSyncTests.removingADeviceSealsANewEpochToEachRemainingDeviceAfterItsRecoveryKeyIsConfirmed;
  // the cryptographic halves are native, in enrollmentRecoveryAndRemovalKeepEveryKeyOnTheDevice.
  it('removes a device only after its replacement Recovery Key is confirmed and seals the new epoch to each remaining device', async () => {
    expect.hasAssertions();
    const {
      flow,
      sync,
      google,
      keys,
      ring,
      trustedDevice,
      currentRecoveryKey,
      install,
      createKeys,
      recovered,
      device,
    } = setup();
    const shown = await createKeys(true);
    const survivor = await recovered(shown);
    const removed = await recovered(shown);
    const removerId = idOf(device);
    const oldRing = structuredClone(ring());
    // Each admitted device bound its own encryption key.
    expect(
      [...keys().devices.values()].every(({ key }) => key !== undefined),
    ).toBe(true);

    // Just before its removal, the lost device approves a new installation, which stores the keys
    // but cannot confirm its admission yet.
    const newcomer = install();
    const firstCode = field(
      await newcomer.flow.signIn('google'),
      'enrollmentCode',
    );
    const request = field(
      await removed.flow.refreshPrivateSync(),
      'enrollmentRequest',
    );
    await removed.flow.approveEnrollment(request, firstCode);
    sync.failCompletion = true;
    await expect(newcomer.flow.refreshPrivateSync()).resolves.toMatchObject({
      kind: 'device-pending',
    });
    sync.failCompletion = false;
    expect(newcomer.device.productSync).toMatchObject({
      vault: { ring: oldRing },
    });

    // Preparing a removal asks for a fresh sign-in and shows a replacement Recovery Key; the
    // account is unchanged until the person confirms it.
    const listed = field(await flow.refreshPrivateSync(), 'trustedDevices');
    expect(listed).toContain(survivor.id);
    expect(listed).toContain(removed.id);
    expect(listed).not.toContain(removerId);
    const prompts = google.hints.length;
    const prepared = await flow.revokeTrustedDevice(removed.id);
    expect(google.hints).toHaveLength(prompts + 1);
    expect(prepared).toMatchObject({ revocationDevice: removed.id });
    expect(prepared).not.toHaveProperty('revocationNotice');
    const discarded = field(prepared, 'revocationRecoveryKey');
    expect(discarded).not.toBe(shown);
    // Cancelling discards it without reaching the account.
    const cancelled = await flow.cancelRevocation();
    expect(cancelled).not.toHaveProperty('revocationDevice');
    expect(cancelled).not.toHaveProperty('revocationRecoveryKey');
    expect(revocationOf(device)).toBeUndefined();
    expect(sync.activations).toBe(0);
    // A new proposal has a new key; an entry that does not match it activates nothing.
    const replacement = field(
      await flow.revokeTrustedDevice(removed.id),
      'revocationRecoveryKey',
    );
    expect(replacement).not.toBe(discarded);
    await expect(flow.confirmRevocation('0000')).rejects.toMatchObject({
      code: 'recovery-key-mismatch',
    });
    expect(sync.activations).toBe(0);
    expect(revocationOf(device)).toMatchObject({ submitted: false });

    // Confirmed, the removal activates at once, before any other device adopts it.
    const result = await flow.confirmRevocation(lastGroup(replacement));
    expect(result).toMatchObject({
      revocationNotice: 'removed',
      privateSync: 'ready',
    });
    expect(result).not.toHaveProperty('revocationDevice');
    expect(result).not.toHaveProperty('recoveryKey');
    expect(field(result, 'trustedDevices')).not.toContain(removed.id);
    expect(ring()).toMatchObject({ current: 2, epochs: [1, 2] });
    expect(device.productSync).toMatchObject({ vault: { ring: ring() } });
    // Every remaining device received its own envelope; the removed device received none.
    expect([...keys().devices.keys()]).toStrictEqual([removerId, survivor.id]);
    expect(trustedDevice(removerId)).toMatchObject({
      envelope: { keyEpoch: 2 },
    });
    expect(trustedDevice(survivor.id)).toMatchObject({
      envelope: { keyEpoch: 2 },
    });
    // The replacement Recovery Key is current immediately.
    expect(currentRecoveryKey()).toBe(replacement);

    // The approval ended with its approver and the epoch it sealed: the device discards the keys
    // it stored and asks again.
    const renewed = await newcomer.flow.refreshPrivateSync();
    expect(renewed).toMatchObject({
      kind: 'device-pending',
      enrollmentNotice: 'renewed',
    });
    const code = field(renewed, 'enrollmentCode');
    expect(code).not.toBe(firstCode);
    expect(newcomer.device.productSync.vault).toBeUndefined();

    // Still open, the removed device tries a removal of its own: it purges before any sign-in
    // prompt, so cancelling that prompt cannot keep its keys.
    const before = google.hints.length;
    google.outcome = 'cancelled';
    await expect(
      removed.flow.revokeTrustedDevice(survivor.id),
    ).resolves.toStrictEqual({ kind: 'signed-out', notice: 'revoked' });
    expect(google.hints).toHaveLength(before);
    google.outcome = undefined;
    expect(removed.device.record).toBeUndefined();
    expect(removed.device.productSync.vault).toBeUndefined();
    // Signing in again only waits as a Pending Device, and the previous Recovery Key admits nobody.
    await expect(removed.flow.signIn('google')).resolves.toMatchObject({
      kind: 'device-pending',
    });
    await expect(
      removed.flow.recoverWithRecoveryKey(shown),
    ).resolves.toMatchObject({ recoveryNotice: 'rejected' });
    expect(removed.device.productSync.vault).toBeUndefined();

    // The survivor adopts the new epoch from its own envelope and acknowledges it.
    await expect(survivor.flow.refreshPrivateSync()).resolves.toMatchObject({
      privateSync: 'ready',
    });
    expect(survivor.device.productSync).toMatchObject({
      vault: { ring: ring() },
    });
    expect(trustedDevice(survivor.id).epoch).toBe(2);
    // It seals the new epoch to the waiting device, which is admitted at that epoch.
    await survivor.flow.approveEnrollment(request, code);
    await expect(newcomer.flow.refreshPrivateSync()).resolves.toMatchObject({
      privateSync: 'ready',
    });
    expect(newcomer.device.productSync).toMatchObject({
      vault: { ring: ring() },
    });
  });

  // Replaces ProductSyncTests.anOfflineDeviceSkipsSuccessiveRemovalsAndAdoptsTheNewestRingDirectly.
  it('lets a device that stayed offline adopt the newest of successive removals directly', async () => {
    expect.hasAssertions();
    const { flow, ring, trustedDevice, createKeys, recovered, remove } =
      setup();
    const shown = await createKeys(true);
    const absent = await recovered(shown);
    const first = await recovered(shown);
    const second = await recovered(shown);
    expect(trustedDevice(absent.id).epoch).toBe(1);
    // Two removals complete while that device never connects; its acknowledgement holds neither.
    await expect(remove(flow, first.id)).resolves.toMatchObject({
      revocationNotice: 'removed',
    });
    await expect(remove(flow, second.id)).resolves.toMatchObject({
      revocationNotice: 'removed',
    });
    expect(ring().current).toBe(3);
    expect(trustedDevice(absent.id)).toMatchObject({
      epoch: 1,
      envelope: { keyEpoch: 3 },
    });
    // Reconnecting, it adopts epoch 3 directly, without a Recovery Key, and reads older data.
    await expect(absent.flow.refreshPrivateSync()).resolves.toMatchObject({
      privateSync: 'ready',
      privateSyncMailboxes: 'alex@example.invalid',
    });
    expect(absent.device.productSync).toMatchObject({
      vault: { ring: ring() },
    });
    expect(ring().epochs).toStrictEqual([1, 2, 3]);
    expect(trustedDevice(absent.id).epoch).toBe(3);
  });

  // Replaces the adoption half of ProductSyncTests.draftWritesAtAnOvertakenEpochAdoptBeforeRetrying.
  it('adopts the newest key epoch when a Draft write is refused for an earlier one', async () => {
    expect.hasAssertions();
    const {
      flow,
      relaunch,
      sync,
      ring,
      trustedDevice,
      device,
      createKeys,
      recovered,
    } = setup();
    const writer = await recovered(await createKeys());
    removeTrustedDevice(sync, account);
    expect(ring().current).toBe(2);
    await expect(
      required(writer.flow.adoptKeyRotation, 'adoption')(),
    ).resolves.toMatchObject({ privateSync: 'ready' });
    expect(writer.device.productSync).toMatchObject({
      vault: { ring: ring() },
    });
    expect(trustedDevice(writer.id).epoch).toBe(2);
    // Without this process's Product Sign-In nothing is adopted.
    await required(relaunch().adoptKeyRotation, 'adoption')();
    expect(heldEpoch(device)).toBe(1);
    await flow.refreshPrivateSync();
    expect(heldEpoch(device)).toBe(2);
  });

  // Replaces ProductSyncTests.aLostActivationReplyIsSettledWithoutRemovingTwice.
  it.each([
    {
      by: 'synchronizing',
      settle: (flow: NativeRegistration) => flow.refreshPrivateSync(),
      notice: undefined,
    },
    { by: 'confirming', settle: settleBy.confirming, notice: 'removed' },
  ])(
    'settles a lost activation reply without removing twice, by $by',
    async ({ settle, notice }) => {
      expect.hasAssertions();
      const {
        flow,
        sync,
        device,
        ring,
        currentRecoveryKey,
        createKeys,
        recovered,
      } = setup();
      const shown = await createKeys();
      const target = await recovered(shown);
      await recovered(shown);
      // A device the account does not list prepares nothing and claims no removal.
      await expect(
        flow.revokeTrustedDevice('device-unknown'),
      ).resolves.not.toHaveProperty('revocationNotice');
      expect(revocationOf(device)).toBeUndefined();

      // The activation applies, but its reply is lost: the proposal and its key stay shown.
      const key = field(
        await flow.revokeTrustedDevice(target.id),
        'revocationRecoveryKey',
      );
      sync.loseActivationReply = true;
      await expect(
        flow.confirmRevocation(lastGroup(key)),
      ).resolves.toMatchObject({
        revocationNotice: 'unconfirmed',
        revocationRecoveryKey: key,
      });
      expect(sync.revoked.has(target.id)).toBe(true);
      expect(revocationOf(device)).toMatchObject({ submitted: true });

      const settled = await settle(flow, key);
      expect(textOf(settled, 'revocationNotice')).toBe(notice);
      expect(settled).not.toHaveProperty('revocationRecoveryKey');
      expect(revocationOf(device)).toBeUndefined();
      // Nothing was removed or rotated twice, and the confirmed key is the account's current one.
      expect(sync.activations).toBe(1);
      expect(ring().current).toBe(2);
      expect(device.productSync).toMatchObject({ vault: { ring: ring() } });
      expect(currentRecoveryKey()).toBe(key);
      // Removing a device that is already gone prepares nothing new.
      const repeated = await flow.revokeTrustedDevice(target.id);
      expect(repeated).not.toHaveProperty('revocationNotice');
      expect(repeated).not.toHaveProperty('revocationRecoveryKey');
      expect(sync.activations).toBe(1);
    },
  );

  // Replaces ProductSyncTests.anUnansweredActivationKeepsItsIdentityAcrossCancellationAndRestart.
  it.each([
    {
      losesDeviceKey: false,
      preparing: (first: string) => ({ revocationDevice: first }),
    },
    {
      losesDeviceKey: true,
      preparing: () => ({ refused: 'unavailable' }),
    },
  ])(
    'keeps an unanswered activation across cancellation and restart (device key lost: $losesDeviceKey)',
    async ({ losesDeviceKey, preparing }) => {
      expect.hasAssertions();
      const { flow, relaunch, sync, google, device, createKeys, recovered } =
        setup();
      const shown = await createKeys();
      const first = await recovered(shown);
      const second = await recovered(shown);
      const key = field(
        await flow.revokeTrustedDevice(first.id),
        'revocationRecoveryKey',
      );
      const proposal = structuredClone(revocationOf(device));
      sync.failActivationBeforeCommit = true;
      await expect(
        flow.confirmRevocation(lastGroup(key)),
      ).resolves.toMatchObject({ revocationNotice: 'unconfirmed' });
      device.productSync.deviceKey = !losesDeviceKey;
      // The receipt does not exist yet; that cannot prove the original request was rejected.
      await expect(flow.cancelRevocation()).resolves.toMatchObject({
        revocationNotice: 'unconfirmed',
      });
      expect(revocationOf(device)).toMatchObject({
        request: required(proposal, 'proposal').request,
        submitted: true,
      });
      // There is no Product Sign-In after relaunch, but cancellation still preserves it.
      const restarted = relaunch();
      await expect(restarted.cancelRevocation()).resolves.toMatchObject({
        revocationRecoveryKey: key,
      });
      await expect(
        outcome(restarted.revokeTrustedDevice(second.id)),
      ).resolves.toMatchObject(preparing(first.id));
      expect(revocationOf(device)).toMatchObject({
        request: required(proposal, 'proposal').request,
      });
      // A sign-in that is no longer recent is renewed; cancelling that prompt changes nothing.
      sync.failActivationBeforeCommit = false;
      sync.staleOnce = true;
      google.outcome = 'cancelled';
      await expect(
        restarted.confirmRevocation(lastGroup(key)),
      ).rejects.toMatchObject({ code: 'cancelled' });
      expect(revocationOf(device)).toMatchObject({ submitted: true });
      await expect(restarted.cancelRevocation()).resolves.toMatchObject({
        revocationNotice: 'unconfirmed',
      });
      google.outcome = undefined;
      await expect(
        restarted.confirmRevocation(lastGroup(key)),
      ).resolves.toMatchObject({ revocationNotice: 'removed' });
      expect(sync.activations).toBe(1);
      expect(sync.revoked.has(first.id)).toBe(true);
      expect(sync.revoked.has(second.id)).toBe(false);
      // Without its key the device enrolls again, and the confirmed key unlocks it.
      expect(productOf(device).pending === true).toBe(losesDeviceKey);
      await expect(
        restarted.recoverWithRecoveryKey(key),
      ).resolves.toMatchObject({ privateSync: 'ready' });
      expect(heldEpoch(device)).toBe(2);
      expect(revocationOf(device)).toBeUndefined();
    },
  );

  // Replaces ProductSyncTests.aLostReplyFollowedByAnotherRotationNeverClaimsItsKeyIsCurrent.
  it.each([
    { by: 'cancelling', settle: settleBy.cancelling },
    { by: 'confirming', settle: settleBy.confirming },
  ])(
    'never calls a key current that a later removal replaced after a lost reply, settled by $by',
    async ({ settle }) => {
      expect.hasAssertions();
      const {
        flow,
        sync,
        device,
        currentRecoveryKey,
        createKeys,
        recovered,
        remove,
      } = setup();
      const shown = await createKeys();
      const first = await recovered(shown);
      const other = await recovered(shown);
      const second = await recovered(shown);
      const key = field(
        await flow.revokeTrustedDevice(first.id),
        'revocationRecoveryKey',
      );
      sync.loseActivationReply = true;
      await expect(
        flow.confirmRevocation(lastGroup(key)),
      ).resolves.toMatchObject({ revocationNotice: 'unconfirmed' });
      await remove(other.flow, second.id);
      const settled = await settle(flow, key);
      expect(settled).toMatchObject({ revocationNotice: 'superseded' });
      expect(settled).not.toHaveProperty('revocationRecoveryKey');
      expect(revocationOf(device)).toBeUndefined();
      expect(heldEpoch(device)).toBe(3);
      expect(sync.activations).toBe(2);
      expect(currentRecoveryKey()).not.toBe(key);
    },
  );

  // Replaces ProductSyncTests.aCommittedActivationKeepsItsReceiptUntilDurableAdoption.
  it('keeps a committed activation until this device durably adopts its ring', async () => {
    expect.hasAssertions();
    const { flow, relaunch, sync, device, ring, createKeys, recovered } =
      setup();
    const target = await recovered(await createKeys());
    const key = field(
      await flow.revokeTrustedDevice(target.id),
      'revocationRecoveryKey',
    );
    sync.offlineAfterActivation = true;
    await expect(flow.confirmRevocation(lastGroup(key))).rejects.toMatchObject({
      code: 'unavailable',
    });
    expect(ring().current).toBe(2);
    expect(heldEpoch(device)).toBe(1);
    expect(revocationOf(device)).toMatchObject({ submitted: true });
    sync.offline = false;
    sync.offlineAfterActivation = false;
    await relaunch().restore();
    expect(heldEpoch(device)).toBe(2);
    expect(revocationOf(device)).toBeUndefined();
    expect(sync.activations).toBe(1);
  });

  // Replaces ProductSyncTests.aFailedOutcomeReadAfterActivationKeepsTheProposalToSettle.
  it.each([
    { by: 'cancelling', settle: settleBy.cancelling },
    { by: 'confirming', settle: settleBy.confirming },
  ])(
    'keeps a proposal to settle when reading its outcome fails, settled by $by',
    async ({ settle }) => {
      expect.hasAssertions();
      const { flow, sync, device, createKeys, recovered } = setup();
      const target = await recovered(await createKeys());
      // The activation applies, then the second outcome read after it loses its connection.
      const key = field(
        await flow.revokeTrustedDevice(target.id),
        'revocationRecoveryKey',
      );
      sync.outcomeReads = 0;
      sync.failingOutcomeRead = 2;
      await expect(
        flow.confirmRevocation(lastGroup(key)),
      ).rejects.toMatchObject({ code: 'unavailable' });
      expect(sync.activations).toBe(1);
      // The proposal is still there to settle, so the screen it shows still works, also when the
      // settling attempt loses its connection the same way.
      expect(revocationOf(device)).toMatchObject({ submitted: true });
      sync.failingOutcomeRead = sync.outcomeReads + 2;
      await expect(settle(flow, key)).rejects.toMatchObject({
        code: 'unavailable',
      });
      expect(revocationOf(device)).toMatchObject({ submitted: true });
      sync.failingOutcomeRead = undefined;
      const settled = await settle(flow, key);
      expect(settled).toMatchObject({ revocationNotice: 'removed' });
      expect(settled).not.toHaveProperty('revocationRecoveryKey');
      expect(sync.activations).toBe(1);
      expect(heldEpoch(device)).toBe(2);
    },
  );

  // Replaces ProductSyncTests.aFailedAdoptionAcknowledgementDoesNotStrandRevocation.
  it.each([
    { by: 'cancelling', settle: settleBy.cancelling },
    { by: 'confirming', settle: settleBy.confirming },
  ])(
    'settles a removal although acknowledging its adoption fails, settled by $by',
    async ({ settle }) => {
      expect.hasAssertions();
      const { flow, sync, device, createKeys, recovered } = setup();
      const target = await recovered(await createKeys());
      const key = field(
        await flow.revokeTrustedDevice(target.id),
        'revocationRecoveryKey',
      );
      sync.loseActivationReply = true;
      await expect(
        flow.confirmRevocation(lastGroup(key)),
      ).resolves.toMatchObject({ revocationNotice: 'unconfirmed' });
      // Adoption is durable even when its acknowledgement cannot reach the backend.
      sync.failAcknowledgement = true;
      const settled = await settle(flow, key);
      expect(settled).toMatchObject({ revocationNotice: 'removed' });
      expect(settled).not.toHaveProperty('revocationRecoveryKey');
      expect(revocationOf(device)).toBeUndefined();
      expect(heldEpoch(device)).toBe(2);
      expect(sync.activations).toBe(1);
      // A host that missed the settled status can retry either control without a proposal.
      for (const result of [
        await flow.confirmRevocation(lastGroup(key)),
        await flow.cancelRevocation(),
      ]) {
        expect(result).not.toHaveProperty('revocationNotice');
        expect(result).not.toHaveProperty('revocationRecoveryKey');
      }
      expect(heldEpoch(device)).toBe(2);
      expect(sync.activations).toBe(1);
    },
  );

  // Replaces ProductSyncTests.aRotationDuringRevocationSettlementNeverCallsTheProposedKeyCurrent.
  it.each(
    (['cancelling', 'confirming'] as const).flatMap((by) => [
      {
        by,
        lands: 'afterOutcomeRead' as const,
        missingKey: false,
        status: { privateSync: 'ready' },
        epoch: 3,
      },
      {
        by,
        lands: 'afterAcknowledgement' as const,
        missingKey: false,
        status: { privateSync: 'ready' },
        epoch: 3,
      },
      {
        by,
        lands: 'afterOutcomeRead' as const,
        missingKey: true,
        status: { kind: 'device-pending' },
        epoch: undefined,
      },
    ]),
  )(
    'never calls a proposed key current when a rotation lands during settlement ($by, $lands, key lost: $missingKey)',
    async ({ by, lands, missingKey, status, epoch }) => {
      expect.hasAssertions();
      const { flow, sync, device, currentRecoveryKey, createKeys, recovered } =
        setup();
      const shown = await createKeys();
      const first = await recovered(shown);
      const second = await recovered(shown);
      await recovered(shown);
      const key = field(
        await flow.revokeTrustedDevice(first.id),
        'revocationRecoveryKey',
      );
      sync.loseActivationReply = true;
      await flow.confirmRevocation(lastGroup(key));
      // The first receipt says this key is current, but a second removal overtakes adoption.
      device.productSync.deviceKey = !missingKey;
      sync[lands] = () => {
        removeTrustedDevice(sync, account, second.id);
      };
      const settled = await settleBy[by](flow, key);
      expect(settled).toMatchObject({
        revocationNotice: 'superseded',
        ...status,
      });
      expect(settled).not.toHaveProperty('revocationRecoveryKey');
      expect(revocationOf(device)).toBeUndefined();
      expect(heldEpoch(device)).toBe(epoch);
      expect(sync.activations).toBe(1);
      expect(currentRecoveryKey()).not.toBe(key);
      for (const result of [
        await flow.confirmRevocation(lastGroup(key)),
        await flow.cancelRevocation(),
      ]) {
        expect(result).not.toHaveProperty('revocationNotice');
        expect(result).not.toHaveProperty('revocationRecoveryKey');
      }
      expect(sync.activations).toBe(1);
    },
  );

  // Replaces ProductSyncTests.aFailedProposalRenewalKeepsTheRejectedProposalCancellable.
  it.each([
    {
      by: 'cancelling',
      finish: async (flow: NativeRegistration) => {
        await expect(flow.cancelRevocation()).resolves.not.toHaveProperty(
          'revocationRecoveryKey',
        );
      },
      removed: false,
      activations: 1,
    },
    {
      by: 'confirming the renewed proposal',
      finish: async (flow: NativeRegistration, key: string) => {
        const renewed = await flow.confirmRevocation(lastGroup(key));
        expect(renewed).toMatchObject({ revocationNotice: 'renewed' });
        const replacement = field(renewed, 'revocationRecoveryKey');
        expect(replacement).not.toBe(key);
        await expect(
          flow.confirmRevocation(lastGroup(replacement)),
        ).resolves.toMatchObject({ revocationNotice: 'removed' });
      },
      removed: true,
      activations: 2,
    },
  ])(
    'keeps a refused proposal cancellable when preparing its replacement fails, then $by',
    async ({ finish, removed, activations }) => {
      expect.hasAssertions();
      const { flow, sync, device, createKeys, recovered, remove } = setup();
      const shown = await createKeys();
      const first = await recovered(shown);
      const second = await recovered(shown);
      const other = await recovered(shown);
      const key = field(
        await flow.revokeTrustedDevice(first.id),
        'revocationRecoveryKey',
      );
      await remove(other.flow, second.id);
      // The stale proposal is refused, then renewal loses its recovery-record read.
      sync.failRecoveryRead = true;
      await expect(
        flow.confirmRevocation(lastGroup(key)),
      ).rejects.toMatchObject({ code: 'unavailable' });
      expect(revocationOf(device)).toMatchObject({ submitted: false });
      expect(heldEpoch(device)).toBe(2);
      expect(sync.revoked.has(first.id)).toBe(false);
      sync.failRecoveryRead = false;
      await finish(flow, key);
      expect(revocationOf(device)).toBeUndefined();
      expect(sync.revoked.has(first.id)).toBe(removed);
      expect(sync.activations).toBe(activations);
    },
  );

  // Replaces ProductSyncTests.anOvertakenProposalIsPreparedAgainWithANewKeyBeforeItApplies and
  // the retired "renews an aged sign-in once before confirming a prepared removal again".
  it('prepares an overtaken proposal again with a new key, and never applies one another removal superseded', async () => {
    expect.hasAssertions();
    const {
      flow,
      sync,
      google,
      ring,
      currentRecoveryKey,
      createKeys,
      recovered,
      remove,
    } = setup();
    const shown = await createKeys();
    const first = await recovered(shown);
    const second = await recovered(shown);
    const other = await recovered(shown);
    const fourth = await recovered(shown);

    // While this device's proposal waits, another device removes a third one.
    const firstKey = field(
      await flow.revokeTrustedDevice(first.id),
      'revocationRecoveryKey',
    );
    await remove(other.flow, second.id);
    expect(ring().current).toBe(2);
    // Its confirmation finds the account changed: nothing applies, and a new key is shown.
    const renewed = await flow.confirmRevocation(lastGroup(firstKey));
    expect(renewed).toMatchObject({
      revocationNotice: 'renewed',
      revocationDevice: first.id,
    });
    const secondKey = field(renewed, 'revocationRecoveryKey');
    expect(secondKey).not.toBe(firstKey);
    expect(sync.revoked.has(first.id)).toBe(false);
    expect(ring().current).toBe(2);
    // Confirming the discarded key does not count for the new proposal.
    await expect(
      flow.confirmRevocation(lastGroup(firstKey)),
    ).rejects.toMatchObject({ code: 'recovery-key-mismatch' });
    // The sign-in has aged by now; activation renews it once and applies the new proposal.
    sync.staleOnce = true;
    const prompts = google.hints.length;
    await expect(
      flow.confirmRevocation(lastGroup(secondKey)),
    ).resolves.toMatchObject({ revocationNotice: 'removed' });
    expect(google.hints).toHaveLength(prompts + 1);
    expect(ring().current).toBe(3);

    // A device another one removes first supersedes a waiting proposal, which never applies.
    const waiting = field(
      await flow.revokeTrustedDevice(fourth.id),
      'revocationRecoveryKey',
    );
    await remove(other.flow, fourth.id);
    const superseded = await flow.confirmRevocation(lastGroup(waiting));
    expect(superseded).toMatchObject({ revocationNotice: 'superseded' });
    expect(superseded).not.toHaveProperty('revocationRecoveryKey');
    expect(String(textOf(superseded, 'trustedDevices'))).not.toContain(
      fourth.id,
    );
    expect(currentRecoveryKey()).not.toBe(waiting);
  });

  // Replaces ProductSyncTests.aTargetThatEnrolledAgainIsNeverReportedRemoved.
  it('never reports a target removed that enrolled again under a new identifier', async () => {
    expect.hasAssertions();
    const { flow, sync, keys, trustedDevice, device, createKeys, recovered } =
      setup();
    const target = await recovered(await createKeys());
    expect(field(await flow.refreshPrivateSync(), 'trustedDevices')).toContain(
      target.id,
    );
    // Before it is selected, the installation signs out and is admitted again under a new row.
    const row = trustedDevice(target.id);
    keys().devices.delete(target.id);
    keys().devices.set('device-enrolled-again', {
      ...row,
      installation: 'synthetic-enrolled-again',
    });
    // The stale selection prepares nothing and claims no removal; the refreshed list shows the
    // device that is still trusted.
    const result = await flow.revokeTrustedDevice(target.id);
    expect(result).not.toHaveProperty('revocationNotice');
    expect(result).not.toHaveProperty('revocationRecoveryKey');
    expect(field(result, 'trustedDevices')).toContain('device-enrolled-again');
    expect(revocationOf(device)).toBeUndefined();
    expect(sync.activations).toBe(0);
  });

  // Replaces ProductSyncTests.aRejectedActivationAfterDeviceKeyLossNeverReportsItsTargetRemoved.
  it('never reports a target removed when an unanswered activation is refused after the device key is lost', async () => {
    expect.hasAssertions();
    const { flow, sync, keys, device, createKeys, recovered } = setup();
    const shown = await createKeys();
    const target = await recovered(shown);
    const proposed = field(
      await flow.revokeTrustedDevice(target.id),
      'revocationRecoveryKey',
    );
    sync.failActivationBeforeCommit = true;
    await flow.confirmRevocation(lastGroup(proposed));
    // A new recipient makes the unanswered proposal stale; losing the private key prevents renewal.
    await recovered(shown);
    device.productSync.deviceKey = false;
    const rejected = await flow.confirmRevocation(lastGroup(proposed));
    expect(rejected).toMatchObject({ kind: 'device-pending' });
    expect(rejected).not.toHaveProperty('revocationNotice');
    expect(rejected).not.toHaveProperty('revocationRecoveryKey');
    expect(keys().devices.has(target.id)).toBe(true);
    expect(sync.activations).toBe(0);
  });

  // Replaces ProductSyncTests.aLostDeviceKeyNeverDiscardsAnUnconfirmedRecoveryKey; the enrollment
  // decision is also in product-sync.test.ts.
  it('neither approves, declines nor enrolls again while a lost device key guards an unconfirmed Recovery Key', async () => {
    expect.hasAssertions();
    const { flow, device, install } = setup();
    const shown = field(await flow.signIn('google'), 'recoveryKey');
    const creatorId = idOf(device);
    const candidate = install();
    const code = field(await candidate.flow.signIn('google'), 'enrollmentCode');
    const request = field(await flow.refreshPrivateSync(), 'enrollmentRequest');

    // The device key goes missing before the account's only Recovery Key is confirmed: the keys
    // stay, and the Recovery Key is still shown for confirmation.
    device.productSync.deviceKey = false;
    const kept = await flow.refreshPrivateSync();
    expect(kept).toMatchObject({
      privateSync: 'recovery-key',
      recoveryKey: shown,
    });
    expect(kept).not.toHaveProperty('enrollmentRequest');
    expect(kept).not.toHaveProperty('trustedDevices');
    expect(idOf(device)).toBe(creatorId);
    await expect(flow.approveEnrollment(request, code)).rejects.toMatchObject({
      code: 'unavailable',
    });
    await expect(flow.declineEnrollment(request)).rejects.toMatchObject({
      code: 'unavailable',
    });
    await expect(candidate.flow.refreshPrivateSync()).resolves.toMatchObject({
      enrollmentCode: code,
    });

    // Once it is confirmed, the device enrolls again as a new installation.
    await flow.confirmRecoveryKey(lastGroup(shown));
    await expect(flow.refreshPrivateSync()).resolves.toMatchObject({
      kind: 'device-pending',
    });
    expect(idOf(device)).not.toBe(creatorId);
    await expect(flow.recoverWithRecoveryKey(shown)).resolves.toMatchObject({
      privateSync: 'ready',
    });
  });

  // Replaces ProductSyncTests.aLostDeviceKeySettlesOnlyItsSubmittedRemovalBeforeFreshEnrollment.
  it.each(
    [
      {
        by: 'synchronizing',
        settle: (flow: NativeRegistration) => flow.refreshPrivateSync(),
        notices: [undefined, undefined],
      },
      {
        by: 'cancelling',
        settle: settleBy.cancelling,
        notices: ['removed', 'superseded'],
      },
      {
        by: 'confirming',
        settle: settleBy.confirming,
        notices: ['removed', 'superseded'],
      },
    ].flatMap(({ by, settle, notices: [kept, superseded] }) => [
      {
        by,
        settle,
        superseded: false,
        // Nothing else removes a device.
        replace: async () => undefined,
        notice: kept,
        proposedRecovery: undefined,
        activations: 1,
        epoch: 2,
      },
      {
        by,
        settle,
        superseded: true,
        // Another device's removal replaces the proposed Recovery Key.
        replace: async ({
          remove,
          other,
          second,
        }: Readonly<{
          remove: Setup['remove'];
          other: NativeRegistration;
          second: string;
        }>) => {
          await remove(other, second);
        },
        notice: superseded,
        proposedRecovery: 'rejected',
        activations: 2,
        epoch: 3,
      },
    ]),
  )(
    'settles only its submitted removal before enrolling again without its device key ($by, superseded: $superseded)',
    async ({
      settle,
      replace,
      notice,
      proposedRecovery,
      activations,
      epoch,
    }) => {
      expect.hasAssertions();
      const {
        flow,
        sync,
        keys,
        device,
        currentRecoveryKey,
        createKeys,
        recovered,
        remove,
      } = setup();
      const shown = await createKeys();
      const target = await recovered(shown);
      const other = await recovered(shown);
      const second = await recovered(shown);
      const original = idOf(device);
      const proposed = field(
        await flow.revokeTrustedDevice(target.id),
        'revocationRecoveryKey',
      );
      sync.loseActivationReply = true;
      await flow.confirmRevocation(lastGroup(proposed));
      await replace({ remove, other: other.flow, second: second.id });
      const currentKey = required(currentRecoveryKey(), 'Recovery Key');
      device.productSync.deviceKey = false;
      const settled = await settle(flow, proposed);
      expect(settled).toMatchObject({ kind: 'device-pending' });
      expect(settled).not.toHaveProperty('revocationRecoveryKey');
      expect(textOf(settled, 'revocationNotice')).toBe(notice);
      expect(idOf(device)).not.toBe(original);
      expect(keys().devices.has(original)).toBe(true);
      expect(sync.activations).toBe(activations);
      // Only the current Recovery Key unlocks the new installation.
      expect(
        textOf(await flow.recoverWithRecoveryKey(proposed), 'recoveryNotice'),
      ).toBe(proposedRecovery);
      await expect(
        flow.recoverWithRecoveryKey(currentKey),
      ).resolves.toMatchObject({ privateSync: 'ready' });
      expect(heldEpoch(device)).toBe(epoch);
    },
  );

  // Replaces the enrollment halves of ProductSyncTests.aDeviceThatLostItsKeysEnrollsAgainAsANewDevice.
  it.each([
    { keeps: 'its ring', forget: () => undefined },
    {
      keeps: 'nothing',
      forget: (lost: Device) => {
        lost.productSync.vault = undefined;
      },
    },
  ])(
    'admits a device that lost its key again only under a new identifier, keeping $keeps',
    async ({ forget }) => {
      expect.hasAssertions();
      const { flow, keys, trustedDevice, createKeys, recovered, remove } =
        setup();
      const lost = await recovered(await createKeys());
      const oldKey = trustedDevice(lost.id).key;
      // Losing its private key requires fresh admission, even if the old ring is still present.
      forget(lost.device);
      lost.device.productSync.deviceKey = false;
      const rejoined = lost.relaunch();
      const code = field(await rejoined.signIn('google'), 'enrollmentCode');
      const request = field(
        await flow.refreshPrivateSync(),
        'enrollmentRequest',
      );
      await flow.approveEnrollment(request, code);
      await expect(rejoined.refreshPrivateSync()).resolves.toMatchObject({
        privateSync: 'ready',
      });
      const newId = idOf(lost.device);
      expect(newId).not.toBe(lost.id);
      expect(trustedDevice(newId).key).toBe(
        lost.device.productSync.deviceKeyName,
      );
      expect(trustedDevice(newId).key).not.toBe(oldKey);
      // The abandoned registration stays listed until it is removed explicitly.
      expect(
        field(await flow.refreshPrivateSync(), 'trustedDevices'),
      ).toContain(lost.id);
      await expect(remove(flow, lost.id)).resolves.toMatchObject({
        revocationNotice: 'removed',
      });
      await expect(rejoined.refreshPrivateSync()).resolves.toMatchObject({
        privateSync: 'ready',
      });
      expect(heldEpoch(lost.device)).toBe(2);
      expect(keys().devices.has(lost.id)).toBe(false);
    },
  );
});
