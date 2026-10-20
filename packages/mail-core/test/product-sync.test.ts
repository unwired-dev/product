import {
  mailboxRecord,
  storeDescriptor,
  storedDescriptor,
} from '../src/testing/registration-vault.ts';
import {
  account,
  decodeRecord,
  productSubject,
  setup,
} from './product-sync-fixture.ts';

describe('product sync', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one synchronization path end to end. */

  // Replaces ProductSyncTests.newAccountInitializesProductSyncOnceAndRelaunchKeepsItsKeys.
  it('initializes a new account once, keeps its keys across relaunch and stores only opaque records', async () => {
    expect.hasAssertions();
    const {
      flow,
      relaunch,
      vault,
      sync,
      device,
      google,
      ring,
      record,
      records,
    } = setup();
    const registered = await flow.signIn('google');
    expect(registered).toMatchObject({
      privateSync: 'recovery-key',
      recoveryKey: `SYNTHETIC-RECOVERY-${ring().id}`,
    });
    expect(sync.initializations).toBe(1);
    expect(device.productSync.vault?.ring).toStrictEqual(ring());
    // Keys are stored before the backend acknowledges them, and only then published.
    expect(sync.steps).toStrictEqual([
      'createKeyRing',
      'recordInitialization:true',
      'removeQueuedPushRoutes',
    ]);

    google.subject = 'synthetic-mailbox-subject';
    const connected = await flow.addMailbox('gmail', false);
    expect(connected).toMatchObject({
      kind: 'connected',
      privateSyncMailboxes: 'alex@example.invalid',
    });
    // Signing in again rechecks the mailbox without new consent or new keys.
    google.subject = productSubject;
    await expect(flow.signIn('google')).resolves.toStrictEqual(connected);
    google.subject = 'synthetic-mailbox-subject';
    expect([...records().keys()]).toStrictEqual([
      record('synthetic-mailbox-subject'),
    ]);
    // Convex holds only opaque identifiers and ciphertext; no address, subject or Recovery Key.
    expect(JSON.stringify([...records().values()])).not.toMatch(
      /alex@example\.invalid|synthetic-mailbox-subject|SYNTHETIC-RECOVERY/u,
    );

    await expect(flow.confirmRecoveryKey('0000')).rejects.toMatchObject({
      code: 'recovery-key-mismatch',
    });
    const confirmed = await flow.confirmRecoveryKey(ring().id.slice(-4));
    expect(confirmed).toMatchObject({ privateSync: 'ready' });
    expect(confirmed).not.toHaveProperty('recoveryKey');
    // The confirmed key no longer crosses from native storage at all.
    await expect(vault.registration()).resolves.not.toHaveProperty([
      'productSync',
      'vault',
      'recoveryKey',
    ]);

    // A record sealed for another Product Account is never presented as this account's mailbox.
    storeDescriptor(sync, {
      account,
      record: 'mailbox.foreign',
      descriptor: undefined,
    });
    await expect(relaunch().restore()).resolves.toStrictEqual(confirmed);
    expect(sync.initializations).toBe(1);
    expect(device.productSync.vault?.ring).toStrictEqual(ring());
  });

  it.each([
    ['gmail@example.invalid', 'graph@example.invalid'],
    ['alex@example.invalid', 'alex@example.invalid'],
  ])(
    'publishes and removes provider-scoped mailboxes of the same subject (%s, %s)',
    async (gmailAddress, graphAddress) => {
      expect.hasAssertions();
      const { flow, vault, google, microsoft, sync, ring, relaunch } = setup();
      await flow.signIn('google');
      google.subject = 'shared-mailbox-subject';
      microsoft.subject = 'shared-mailbox-subject';
      google.address = gmailAddress;
      microsoft.address = graphAddress;
      await flow.addMailbox('gmail', false);
      await flow.addMailbox('microsoft-graph', false);
      const stored = (provider: string) =>
        storedDescriptor(
          sync,
          account,
          mailboxRecord(sync, ring().id, `${provider}:shared-mailbox-subject`),
        );
      expect([stored('gmail'), stored('microsoft-graph')]).toStrictEqual([
        expect.objectContaining({
          provider: 'gmail',
          address: gmailAddress,
        }),
        expect.objectContaining({
          provider: 'microsoft-graph',
          address: graphAddress,
        }),
      ]);
      const [gmail, graph] = decodeRecord(await vault.registration()).mailboxes;
      expect(gmail?.id).not.toBe(graph?.id);
      // Another device's Graph removal purges only Graph, and explicit consent recreates it.
      storeDescriptor(sync, {
        account,
        record: mailboxRecord(
          sync,
          ring().id,
          'microsoft-graph:shared-mailbox-subject',
        ),
        descriptor: {
          provider: 'microsoft-graph',
          address: graphAddress,
          removed: true,
        },
      });
      await relaunch().restore();
      expect(decodeRecord(await vault.registration()).mailboxes).toStrictEqual([
        expect.objectContaining({ id: gmail?.id, provider: 'gmail' }),
      ]);
      await flow.addMailbox('microsoft-graph', false);
      expect(stored('microsoft-graph')?.removed).toBeUndefined();
      // Removing the Microsoft connection locally marks only its own descriptor removed.
      expect(graph?.provider).toBe('microsoft-graph');
      await flow.removeMailbox(String(graph?.id));
      expect([
        stored('gmail')?.removed,
        stored('microsoft-graph'),
      ]).toStrictEqual([
        undefined,
        expect.objectContaining({ provider: 'microsoft-graph', removed: true }),
      ]);
    },
  );

  // Replaces ProductSyncTests.mailboxDescriptorsThisDeviceCannotOpenAreNeverReplaced.
  it('never shows or replaces a descriptor this device cannot open', async () => {
    expect.hasAssertions();
    const { flow, put, record, records } = setup();
    await flow.signIn('google');
    await flow.addMailbox('gmail', false);
    const stored = () => records().get(record());
    // A newer client's schema, an epoch or ring this device lacks, or a payload failing
    // authentication all read the same here: never shown, never replaced.
    put(undefined);
    const unreadable = stored();
    const signedIn = await flow.signIn('google');
    expect(signedIn).toMatchObject({ kind: 'connected' });
    expect(signedIn).not.toHaveProperty('privateSyncMailboxes');
    expect(stored()).toStrictEqual(unreadable);

    // A record that opens and differs is replaced and read back.
    put({ address: 'stale@example.invalid' });
    const stale = stored();
    await expect(flow.signIn('google')).resolves.toMatchObject({
      privateSyncMailboxes: 'alex@example.invalid',
    });
    expect(stored()).not.toStrictEqual(stale);
  });

  // Replaces ProductSyncTests.missingLocalKeysNeverReplaceAnExistingAccountsKeyMaterial and covers
  // a kill between storing keys and their acknowledgement.
  it('resumes an interrupted initialization with the same keys and never replaces the account key material', async () => {
    expect.hasAssertions();
    const { flow, relaunch, otherDevice, sync, device, keysOf } = setup();
    // Initialization cannot reach Convex: the keys stay saved and setup stays pending.
    sync.offline = true;
    await expect(flow.signIn('google')).resolves.toMatchObject({
      privateSync: 'setup-pending',
    });
    const saved = device.productSync.vault;
    expect(saved?.published).toBe(false);
    expect(keysOf().recovery).toBeUndefined();
    sync.offline = false;
    // The backend applies the next attempt, but its reply is lost before it is recorded here.
    sync.loseInitializationReply = true;
    await expect(relaunch().restore()).resolves.toMatchObject({
      privateSync: 'setup-pending',
    });
    expect(device.productSync.vault?.published).toBe(false);
    // The next attempt sends the same keys again; nothing new is created.
    await expect(relaunch().restore()).resolves.toMatchObject({
      privateSync: 'recovery-key',
      recoveryKey: saved?.recoveryKey,
    });
    expect(device.productSync.vault?.ring).toStrictEqual(saved?.ring);
    expect(sync.initializations).toBe(1);
    expect(sync.rings).toBe(1);

    // Another installation waits as a Pending Device and never creates keys of its own.
    const other = otherDevice();
    await expect(other.flow.signIn('google')).resolves.toMatchObject({
      kind: 'device-pending',
      privateSync: 'enrollment-pending',
    });
    expect(other.device.productSync.vault).toBeUndefined();
    expect(sync.rings).toBe(1);
  });

  it('discards unpublished keys when the account already holds other key material', async () => {
    expect.hasAssertions();
    const { flow, relaunch, sync, device, keysOf, records } = setup();
    sync.offline = true;
    await flow.signIn('google');
    expect(device.productSync.vault?.published).toBe(false);
    // Meanwhile the account received key material this device did not publish.
    Object.assign(keysOf(), {
      recovery: 'recovery-elsewhere',
      ring: { id: 'ring-elsewhere', epochs: [1], current: 1 },
    });
    sync.offline = false;
    const resumed = await relaunch().restore();
    expect(resumed).toMatchObject({ privateSync: 'enrollment-needed' });
    expect(resumed).not.toHaveProperty('recoveryKey');
    expect(device.productSync.vault).toBeUndefined();
    expect(keysOf().recovery).toBe('recovery-elsewhere');
    expect(sync.initializations).toBe(0);
    // Gmail stays authorizable, but no record is written without the account's keys.
    await expect(relaunch().addMailbox('gmail', false)).resolves.toMatchObject({
      kind: 'connected',
      privateSync: 'enrollment-needed',
    });
    expect(records().size).toBe(0);
  });

  // Replaces ProductSyncTests.unknownProductSyncStateWaitsForVerificationWithoutCreatingKeys.
  it('waits for verification without creating keys while the account state is unknown', async () => {
    expect.hasAssertions();
    const { flow, relaunch, sync } = setup();
    // A receipt saved before Product Sync neither creates keys nor demands enrollment.
    sync.legacyReceipts = true;
    await expect(flow.signIn('apple')).resolves.toMatchObject({
      privateSync: 'setup-pending',
    });
    await expect(relaunch().restore()).resolves.toMatchObject({
      privateSync: 'setup-pending',
    });
    expect(sync.rings).toBe(0);
    // Signing in again reports the account's actual state, which initializes it.
    sync.legacyReceipts = false;
    await expect(relaunch().signIn('apple')).resolves.toMatchObject({
      privateSync: 'recovery-key',
    });
    expect(sync.initializations).toBe(1);
  });

  // Replaces ProductSyncTests.unreadableProductSyncKeysLeaveRegistrationAndGmailUsable.
  it('keeps registration and Gmail usable while Product Sync keys are unreadable', async () => {
    expect.hasAssertions();
    const { flow, relaunch, sync, device, google } = setup();
    await flow.signIn('google');
    const keys = device.productSync.vault;
    device.productSync.unreadable = true;
    google.subject = 'synthetic-mailbox-subject';
    const connected = await flow.addMailbox('gmail', false);
    expect(connected).toMatchObject({
      kind: 'connected',
      privateSync: 'unavailable',
    });
    await expect(relaunch().restore()).resolves.toStrictEqual(connected);
    google.subject = productSubject;
    await expect(relaunch().signIn('google')).resolves.toStrictEqual(connected);
    expect(device.record?.mailboxSetupReason).toBeUndefined();
    // The unreadable keys are kept, never replaced.
    expect(device.productSync.vault).toBe(keys);
    expect(sync.initializations).toBe(1);
  });

  // Replaces ProductSyncTests.appleRelaunchAsksToSignInAgainBeforeSavingANewMailbox.
  it('saves a mailbox chosen after an Apple relaunch once Apple sign-in renews the session', async () => {
    expect.hasAssertions();
    const { flow, relaunch, google, records } = setup();
    const appleAccount = 'account-synthetic-apple-subject';
    await flow.signIn('apple');
    google.subject = 'synthetic-mailbox-subject';
    await expect(flow.addMailbox('gmail', false)).resolves.not.toHaveProperty(
      'privateSyncPending',
    );
    // An Apple relaunch cannot reach Convex but still shows the list it last decrypted.
    await expect(relaunch().restore()).resolves.toMatchObject({
      privateSyncMailboxes: 'alex@example.invalid',
    });
    // Without a session, a newly chosen mailbox waits for sign-in.
    google.subject = 'synthetic-other-mailbox';
    google.addresses = { 'synthetic-other-mailbox': 'other@example.invalid' };
    await expect(relaunch().addMailbox('gmail', true)).resolves.toMatchObject({
      kind: 'connected',
      privateSyncPending: 'mailbox',
    });
    expect(records(appleAccount).size).toBe(1);
    // Signing in again saves the descriptor and reads both back.
    const signedIn = await relaunch().signIn('apple');
    expect(signedIn).not.toHaveProperty('privateSyncPending');
    expect(signedIn).toMatchObject({
      privateSyncMailboxes: 'alex@example.invalid\nother@example.invalid',
    });
    expect(records(appleAccount).size).toBe(2);
  });

  it('reads every 100-record page of descriptors', async () => {
    expect.hasAssertions();
    const { flow, backend, sync, put } = setup();
    await flow.signIn('google');
    const addresses = Array.from(
      { length: 250 },
      (_, index) => `mailbox-${String(index).padStart(3, '0')}@example.invalid`,
    );
    for (const [index, address] of addresses.entries()) {
      put({ address, epoch: 'elsewhere' }, `synthetic-subject-${index}`);
    }
    backend.calls.length = 0;
    sync.listedPages = 0;
    await expect(flow.signIn('google')).resolves.toMatchObject({
      privateSyncMailboxes: addresses.join('\n'),
    });
    const cursors = backend.calls
      .filter(
        ({ path }) =>
          path === 'productSync:listEncryptedPayloadsForTrustedDevice',
      )
      .filter(({ args }) => args.payloadIdentifierPrefix === 'mailbox.')
      .map(({ args }) => args.paginationOpts);
    expect(cursors).toStrictEqual([
      { cursor: null, numItems: 100 },
      { cursor: '100', numItems: 100 },
      { cursor: '200', numItems: 100 },
    ]);
    // Plus one empty page each of Profile definitions, connection ownership and notification
    // policies.
    expect(sync.listedPages).toBe(6);
  });

  // Replaces ProductSyncTests.writesSealedAtAnOvertakenEpochAreSealedAgainAfterAdoptingIt.
  it('seals a write again at the newest epoch after a removal overtakes it', async () => {
    expect.hasAssertions();
    const { flow, google, beforeWrite, rotate, records, record } = setup();
    await flow.signIn('google');
    // Another device's removal commits epoch 2 just before this device's descriptor write lands.
    beforeWrite(() => rotate(2), { subject: 'synthetic-mailbox-subject' });
    google.subject = 'synthetic-mailbox-subject';
    await expect(flow.addMailbox('gmail', false)).resolves.toMatchObject({
      privateSyncMailboxes: 'alex@example.invalid',
    });
    expect(
      records().get(record('synthetic-mailbox-subject'))?.encryptedPayload
        .keyVersion,
    ).toBe(2);
  });

  // Replaces the first half of MailboxConnectionTests.removalsReachProductSyncAndEveryTrustedDevice.
  // fallow-ignore-next-line complexity -- One journey proves each removal and recreation rule in order.
  it('marks removals in Product Sync and purges connections another device removed', async () => {
    expect.hasAssertions();
    const {
      flow,
      relaunch,
      sync,
      put,
      descriptor,
      connections,
      connection,
      mailboxId,
    } = setup();
    await flow.signIn('google');
    await expect(flow.addMailbox('gmail', false)).resolves.toMatchObject({
      privateSyncMailboxes: 'alex@example.invalid',
    });
    const published = descriptor();
    expect(published?.removed).toBeUndefined();
    expect(published?.epoch).toBeDefined();
    expect(connection().published).toBe(true);
    const id = await mailboxId();

    // Removal marks the descriptor removed; credentials and mail never reach Product Sync.
    const removed = await flow.removeMailbox(id);
    expect(removed).toMatchObject({ kind: 'mailbox-needed' });
    expect(removed).not.toHaveProperty('mailboxes');
    expect(removed).not.toHaveProperty('privateSyncMailboxes');
    expect(descriptor()).toStrictEqual({
      provider: 'gmail',
      address: 'alex@example.invalid',
      epoch: published?.epoch,
      removed: true,
    });

    // Adding the mailbox again starts a new epoch.
    await expect(flow.addMailbox('gmail', false)).resolves.toMatchObject({
      privateSyncMailboxes: 'alex@example.invalid',
    });
    const renewed = descriptor();
    expect(renewed?.removed).toBeUndefined();
    expect(renewed?.epoch).not.toBe(published?.epoch);

    // Another device removes it: this device purges the connection on its next synchronization.
    put({ epoch: renewed?.epoch, removed: true });
    await expect(relaunch().restore()).resolves.not.toHaveProperty('mailboxes');
    expect(connections()).toHaveLength(0);
    expect(sync.steps).toContain(`purgeMailbox:${id}`);

    // An authorization from before a removal and another device's addition is purged too.
    await flow.addMailbox('gmail', false);
    put({ epoch: 'added-on-another-device' });
    await expect(relaunch().restore()).resolves.not.toHaveProperty('mailboxes');
    // Authorizing a mailbox another device already published adopts that device's epoch.
    await expect(flow.addMailbox('gmail', false)).resolves.toMatchObject({
      kind: 'connected',
    });
    expect(connection()).toMatchObject({
      epoch: 'added-on-another-device',
      published: true,
    });
    expect(descriptor()?.epoch).toBe('added-on-another-device');

    // Removing while offline and adding back cannot inherit the pre-removal epoch.
    sync.offline = true;
    await flow.removeMailbox(id);
    await flow.addMailbox('gmail', false);
    sync.offline = false;
    await relaunch().restore();
    const recreated = descriptor();
    expect(recreated?.epoch).not.toBe('added-on-another-device');
    expect(recreated?.removed).toBeUndefined();
    expect(connection().epoch).toBe(recreated?.epoch);
    await expect(relaunch().restore()).resolves.toMatchObject({
      mailboxes: expect.stringContaining(`"epoch":"${recreated?.epoch}"`),
    });
  });

  // Replaces the second half of MailboxConnectionTests.removalsReachProductSyncAndEveryTrustedDevice.
  it('keeps a removal until its tombstone is stored and never lets restore resurrect it', async () => {
    expect.hasAssertions();
    const {
      flow,
      relaunch,
      sync,
      put,
      descriptor,
      connections,
      connection,
      mailboxId,
      device,
      records,
    } = setup();
    await flow.signIn('google');
    await flow.addMailbox('gmail', false);
    const id = await mailboxId();
    const added = descriptor();

    // An unreadable descriptor is read-only and cannot acknowledge a removal.
    put(undefined);
    await expect(flow.removeMailbox(id)).resolves.toMatchObject({
      privateSyncPending: 'mailbox',
    });
    expect(device.record?.removals).toHaveLength(1);
    expect(descriptor()).toBeUndefined();
    // When it becomes readable, the retained removal publishes the matching tombstone.
    put({ epoch: added?.epoch });
    await expect(flow.refreshPrivateSync()).resolves.not.toHaveProperty(
      'privateSyncPending',
    );
    expect(descriptor()?.removed).toBe(true);

    // An absent descriptor also needs a tombstone; absence never acknowledges publication.
    await flow.addMailbox('gmail', false);
    records().clear();
    await flow.removeMailbox(id);
    expect(descriptor()?.removed).toBe(true);

    // An offline authorization cannot resurrect a removal during ordinary restore.
    sync.offline = true;
    await flow.addMailbox('gmail', false);
    expect(connections()).toHaveLength(1);
    sync.offline = false;
    await expect(relaunch().restore()).resolves.not.toHaveProperty('mailboxes');
    expect(connections()).toHaveLength(0);
    // Fresh explicit consent after learning the tombstone can recreate it.
    await expect(flow.addMailbox('gmail', false)).resolves.toMatchObject({
      kind: 'connected',
    });
    expect(descriptor()?.removed).toBeUndefined();
    await flow.removeMailbox(id);
    sync.offline = true;
    await flow.addMailbox('gmail', false);
    put({ epoch: 'another-device-recreated' });
    sync.offline = false;
    // A later live incarnation also cannot inherit the earlier unpublished authorization.
    await expect(relaunch().restore()).resolves.not.toHaveProperty('mailboxes');
    await expect(flow.addMailbox('gmail', false)).resolves.toMatchObject({
      kind: 'connected',
    });
    expect(connection().epoch).toBe('another-device-recreated');
  });

  // Replaces the descriptor journeys of
  // MailboxConnectionTests.concurrentAdditionsConvergeAndLegacyBodiesCountTowardTheLimit.
  it('converges concurrent additions on the compare-and-set winner', async () => {
    expect.hasAssertions();
    const {
      flow,
      relaunch,
      sync,
      put,
      record,
      records,
      connections,
      connection,
      mailboxId,
      device,
      beforeWrite,
      failNextList,
    } = setup();
    await flow.signIn('google');
    // Another device publishes the same mailbox between this device's read and its write.
    beforeWrite(() => put({ epoch: 'added-on-another-device' }));
    await expect(flow.addMailbox('gmail', false)).resolves.toMatchObject({
      kind: 'connected',
    });
    // The stored record is the winner's, and this device adopts its epoch.
    expect(records().get(record())).toBeDefined();
    expect(connection()).toMatchObject({
      epoch: 'added-on-another-device',
      published: true,
    });
    // A relaunch does not read the winning epoch as a removal and recreation.
    await expect(relaunch().restore()).resolves.toMatchObject({
      kind: 'connected',
    });
    expect(connections().map(({ epoch }) => epoch)).toStrictEqual([
      'added-on-another-device',
    ]);
    const id = await mailboxId();

    // Losing the later list cannot discard the CAS winner this device already confirmed.
    await flow.removeMailbox(id);
    beforeWrite(() => {
      put({ epoch: 'concurrent-recreation' });
      failNextList();
    });
    await flow.addMailbox('gmail', false);
    expect(connection()).toMatchObject({
      epoch: 'concurrent-recreation',
      published: true,
    });
    await expect(relaunch().restore()).resolves.toMatchObject({
      kind: 'connected',
    });

    // The durable remove/re-add intent stays eligible after relaunch, only for its tombstone.
    sync.offline = true;
    await flow.removeMailbox(id);
    await flow.addMailbox('gmail', false);
    sync.offline = false;
    beforeWrite(() => put({ epoch: 'concurrent-retained-recreation' }), {
      times: 2,
    });
    await expect(relaunch().restore()).resolves.toMatchObject({
      kind: 'connected',
    });
    expect(connection().epoch).toBe('concurrent-retained-recreation');
    expect(device.record?.removals).toBeUndefined();

    // An offline grant encountering absence cannot inherit a later incarnation published before
    // its compare-and-set.
    await flow.removeMailbox(id);
    records().delete(record());
    sync.offline = true;
    await flow.addMailbox('gmail', false);
    sync.offline = false;
    beforeWrite(() => {
      put({ epoch: 'offline-grant-was-removed', removed: true });
      put({ epoch: 'later-incarnation' });
    });
    await expect(relaunch().restore()).resolves.not.toHaveProperty('mailboxes');
    expect(connections()).toHaveLength(0);

    // A tombstone winning a fresh addition's compare-and-set is removal, not consent.
    records().delete(record());
    beforeWrite(() => put({ epoch: 'removal-winner', removed: true }));
    await expect(flow.addMailbox('gmail', false)).resolves.not.toHaveProperty(
      'mailboxes',
    );
    expect(connections()).toHaveLength(0);

    // A successful addition removed and recreated before read-back keeps no grant.
    beforeWrite(() => {
      sync.beforeList = () => {
        sync.beforeList = undefined;
        put({ epoch: connection().epoch, removed: true });
        put({ epoch: 'recreated-after-success' });
      };
    });
    await expect(flow.addMailbox('gmail', false)).resolves.not.toHaveProperty(
      'mailboxes',
    );
    expect(connections()).toHaveLength(0);

    // An address update's losing compare-and-set cannot move a published grant to a new epoch.
    await flow.addMailbox('gmail', false);
    connection().address = 'renamed@example.invalid';
    beforeWrite(() => {
      put({ epoch: 'recreated-during-address-update' });
      failNextList();
    });
    await expect(flow.refreshPrivateSync()).resolves.not.toHaveProperty(
      'mailboxes',
    );
    expect(connections()).toHaveLength(0);
  });

  // Replaces MailboxConnectionTests.offlineAuthorizationAdoptsAnUnchangedDescriptor.
  it('adopts only an unchanged descriptor after an offline authorization', async () => {
    expect.hasAssertions();
    const { flow, relaunch, sync, put, connections, google, failWrites } =
      setup();
    google.addresses = {
      'synthetic-other-mailbox': 'other@example.invalid',
      'synthetic-third-mailbox': 'third@example.invalid',
      'synthetic-unobserved-mailbox': 'unobserved@example.invalid',
      'synthetic-failing-mailbox': 'failing@example.invalid',
    };
    await flow.signIn('google');
    await flow.addMailbox('gmail', false);
    // Another device's descriptors, read once by this device.
    put(
      { address: 'other@example.invalid', epoch: 'published-elsewhere' },
      'synthetic-other-mailbox',
    );
    put(
      { address: 'third@example.invalid', epoch: 'first-incarnation' },
      'synthetic-third-mailbox',
    );
    await relaunch().restore();
    // Each is authorized here offline; meanwhile the third is removed and added again elsewhere.
    sync.offline = true;
    for (const subject of [
      'synthetic-other-mailbox',
      'synthetic-third-mailbox',
      'synthetic-unobserved-mailbox',
      'synthetic-failing-mailbox',
    ]) {
      google.subject = subject;
      await flow.addMailbox('gmail', true);
    }
    google.subject = productSubject;
    expect(connections()).toHaveLength(5);
    sync.offline = false;
    put(
      { address: 'third@example.invalid', epoch: 'second-incarnation' },
      'synthetic-third-mailbox',
    );
    // Absence in the earlier snapshot is no evidence that no unseen add/remove/re-add happened.
    put(
      { address: 'unobserved@example.invalid', epoch: 'later-incarnation' },
      'synthetic-unobserved-mailbox',
    );
    // A later connection's failed publication cannot undo a removal already learned.
    failWrites('synthetic-failing-mailbox');
    await relaunch().restore();
    const subjects = () => connections().map(({ subject }) => subject);
    expect(subjects()).not.toContain('synthetic-third-mailbox');
    expect(subjects()).not.toContain('synthetic-unobserved-mailbox');
    sync.beforePut = undefined;
    await expect(relaunch().restore()).resolves.toMatchObject({
      kind: 'connected',
    });
    expect(
      connections().find(
        ({ subject }) => subject === 'synthetic-other-mailbox',
      ),
    ).toMatchObject({ epoch: 'published-elsewhere', published: true });
    expect(subjects()).not.toContain('synthetic-third-mailbox');
    expect(subjects()).not.toContain('synthetic-unobserved-mailbox');
  });

  // Replaces the descriptor journeys of
  // MailboxConnectionTests.legacyConnectionsConvergeOnOneEpochAndStayFenced.
  it('converges connections from before epochs on the legacy epoch and fences later incarnations', async () => {
    expect.hasAssertions();
    const {
      flow,
      relaunch,
      sync,
      put,
      descriptor,
      connections,
      connection,
      device,
      mailboxId,
      beforeWrite,
      makeLegacy,
      forgetConnections,
    } = setup();
    await flow.signIn('google');
    await flow.addMailbox('gmail', false);
    makeLegacy();
    put({});
    // A concurrent legacy upgrade wins the compare-and-set; both devices choose one incarnation.
    beforeWrite(() => put({ epoch: 'legacy' }));
    await expect(relaunch().restore()).resolves.toMatchObject({
      kind: 'connected',
    });
    expect(connection().epoch).toBe('legacy');
    expect(descriptor()?.epoch).toBe('legacy');
    // Another device from before epochs reads the upgraded descriptor as its own incarnation.
    makeLegacy();
    await expect(relaunch().restore()).resolves.toMatchObject({
      kind: 'connected',
    });
    expect(connection().epoch).toBe('legacy');
    // A device authorizing the pre-epoch mailbox for the first time upgrades it to legacy too.
    forgetConnections();
    put({});
    await expect(relaunch().addMailbox('gmail', false)).resolves.toMatchObject({
      kind: 'connected',
    });
    expect(descriptor()?.epoch).toBe('legacy');
    makeLegacy();
    await expect(relaunch().restore()).resolves.toMatchObject({
      kind: 'connected',
    });
    // A mailbox removed and added again elsewhere is not carried over from before epochs.
    makeLegacy();
    put({ epoch: 'added-again-elsewhere' });
    await expect(relaunch().restore()).resolves.not.toHaveProperty('mailboxes');
    expect(connections()).toHaveLength(0);

    // A queued removal of the pre-epoch incarnation cannot remove a newer remote incarnation.
    await flow.addMailbox('gmail', false);
    const id = await mailboxId();
    makeLegacy();
    put({});
    sync.offline = true;
    await flow.removeMailbox(id);
    put({ epoch: 'newer-than-legacy-removal' });
    sync.offline = false;
    await relaunch().restore();
    expect(descriptor()).toMatchObject({ epoch: 'newer-than-legacy-removal' });
    expect(descriptor()?.removed).toBeUndefined();
    expect(device.record?.removals).toBeUndefined();
    await expect(relaunch().restore()).resolves.toMatchObject({
      privateSyncMailboxes: 'alex@example.invalid',
    });

    // A retained explicit offline recreation still matches its removal after a legacy upgrade.
    await flow.addMailbox('gmail', false);
    makeLegacy();
    put({});
    sync.offline = true;
    await flow.removeMailbox(id);
    await flow.addMailbox('gmail', false);
    const recreatedEpoch = connection().epoch;
    put({ epoch: 'legacy' });
    sync.offline = false;
    await expect(relaunch().restore()).resolves.toMatchObject({
      kind: 'connected',
    });
    expect(connection().epoch).toBe(recreatedEpoch);
    expect(descriptor()?.epoch).toBe(recreatedEpoch);
    expect(device.record?.removals).toBeUndefined();
    // A legacy tombstone purges ordinary restore; explicit consent recreates it at a fresh epoch.
    makeLegacy();
    put({ epoch: 'legacy', removed: true });
    await expect(relaunch().restore()).resolves.not.toHaveProperty('mailboxes');
    await expect(flow.addMailbox('gmail', false)).resolves.toMatchObject({
      kind: 'connected',
    });
    expect(descriptor()?.epoch).not.toBe('legacy');
  });

  // Replaces the enrollment decision of ProductSyncTests.aDeviceThatLostItsKeysEnrollsAgainAsANewDevice
  // and aLostDeviceKeyNeverDiscardsAnUnconfirmedRecoveryKey, whose native halves stay there.
  it('enrolls again as a new device after losing its key, but never discards an unconfirmed Recovery Key', async () => {
    expect.hasAssertions();
    const { flow, relaunch, sync, device, google, put, confirmHeldKey } =
      setup();
    await flow.signIn('google');
    google.subject = 'synthetic-mailbox-subject';
    await flow.addMailbox('gmail', false);
    google.subject = productSubject;
    const installation = device.record?.deviceIdentifier;
    // The only copy of an unconfirmed Recovery Key stays, whatever else is lost.
    device.productSync.deviceKey = false;
    await expect(relaunch().signIn('google')).resolves.toMatchObject({
      privateSync: 'recovery-key',
    });
    expect(device.record?.deviceIdentifier).toBe(installation);
    expect(sync.steps).not.toContain('reenroll');
    // A confirmed key ring without its device key enrolls again under a new installation.
    confirmHeldKey();
    await expect(relaunch().signIn('google')).resolves.toMatchObject({
      kind: 'device-pending',
      privateSync: 'enrollment-pending',
    });
    expect(sync.steps).toContain('reenroll');
    expect(device.record?.deviceIdentifier).not.toBe(installation);
    expect(device.productSync.vault).toBeUndefined();
    // Another Trusted Device approves it; it adopts the account's keys and reads the account's
    // mailboxes back without creating any.
    put({ address: 'shared@example.invalid' }, 'synthetic-shared-mailbox');
    sync.approves = true;
    await expect(relaunch().signIn('google')).resolves.toMatchObject({
      privateSync: 'ready',
      privateSyncMailboxes: 'alex@example.invalid\nshared@example.invalid',
    });
    expect(sync.rings).toBe(1);
  });
});
