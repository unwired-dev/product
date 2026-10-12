import type { NativeRegistrationVault } from '@private-email/mail-core/registration-flow';

import * as Schema from 'effect/Schema';

import {
  defaultProfile,
  mailboxesOf,
  profilesOf,
  RegistrationSnapshotSchema,
} from '../src/registration.ts';
import {
  storeProfile,
  storedProfiles,
} from '../src/testing/registration-vault.ts';
import { account, setup } from './product-sync-fixture.ts';
import { createRegistrationFlow } from './registration-flow-fixture.ts';

type BackendCall = Parameters<NativeRegistrationVault['call']>[0];

// A connected account with Product Sync and one Gmail connection.
const connected = async () => {
  const context = setup();
  await context.flow.signIn('google');
  await context.flow.addMailbox('gmail', false);
  return context;
};
const decode = Schema.decodeUnknownSync(RegistrationSnapshotSchema);
const listed = (snapshot: unknown) => profilesOf(decode(snapshot));
const profileNamed = (snapshot: unknown, name: string) => {
  const found = listed(snapshot).find((profile) => profile.name === name);
  if (found === undefined) {
    throw new Error(`No Profile named ${name}`);
  }
  return found;
};
// This device as a publication whose outcome it never recorded left it: the Profile still pending.
const forgetPublication = (
  device: ReturnType<typeof setup>['device'],
  id: string,
) => {
  const saved = device.record;
  if (saved?.profiles === undefined) {
    throw new Error('No Profile state');
  }
  saved.profiles = { ...saved.profiles, profiles: [{ id, pending: 'Work' }] };
};
// The only connection ownership stored for the account.
const ownershipOf = (sync: ReturnType<typeof setup>['sync']) => {
  const ownership = storedProfiles(sync, account).find(
    ({ kind }) => kind === 'mailbox',
  );
  if (ownership?.kind !== 'mailbox') {
    throw new Error('No ownership');
  }
  return ownership;
};
const owners = (snapshot: unknown) =>
  mailboxesOf(decode(snapshot)).map(({ profile }) => profile);

// A native request whose caller loses the reply before Convex receives the first publication.
const delayPublication = (vault: NativeRegistrationVault) => {
  let delayed: BackendCall | undefined = undefined;
  const flow = createRegistrationFlow({
    ...vault,
    call: (request) => {
      if (
        request.path === 'productSync:putEncryptedPayloadIfUnchanged' &&
        String(request.args.payloadIdentifier).startsWith('profile.')
      ) {
        delayed = request;
        return Promise.reject(new Error('Synthetic unanswered publication'));
      }
      return vault.call(request);
    },
  });
  const publish = () => {
    if (delayed === undefined) {
      throw new Error('No delayed Profile publication');
    }
    return vault.call(delayed);
  };
  return { flow, publish };
};

// A device that knows the definitions but has never opened the now-unreadable ownership record.
const unreadableOwnership = ({ device, sync }: ReturnType<typeof setup>) => {
  const saved = device.record;
  if (saved?.profiles === undefined) {
    throw new Error('No Profile state');
  }
  saved.profiles = { ...saved.profiles, owners: [] };
  for (const [ciphertext, { record }] of sync.sealedProfiles) {
    if (record.kind === 'mailbox') {
      sync.sealedProfiles.delete(ciphertext);
    }
  }
};

describe('mail profiles', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one synchronization path end to end. */

  it('publishes a Profile named offline once, under an opaque identifier, and keeps it across relaunch', async () => {
    expect.hasAssertions();
    const { flow, relaunch, sync, records, device } = await connected();
    sync.offline = true;
    const drafted = await flow.createProfile('Work');
    expect(listed(drafted)).toStrictEqual([
      { id: expect.any(String), name: 'Work', pending: true },
    ]);
    const { id } = profileNamed(drafted, 'Work');
    expect(storedProfiles(sync, account)).toStrictEqual([]);

    // The drafted Profile keeps its identity across relaunch until Product Sync is reachable.
    sync.offline = false;
    const published = await relaunch().refreshPrivateSync();
    expect(listed(published)).toStrictEqual([{ id, name: 'Work' }]);
    expect(storedProfiles(sync, account)).toStrictEqual([
      { kind: 'profile', id, version: 1, name: 'Work' },
    ]);
    // Convex holds only opaque identifiers and ciphertext.
    expect(JSON.stringify([...records().values()])).not.toMatch(
      new RegExp(`Work|${id}`, 'u'),
    );

    // A publication whose outcome this device never recorded settles without writing again.
    const stored = [...records().values()].map(({ updatedAt }) => updatedAt);
    forgetPublication(device, id);
    await expect(relaunch().refreshPrivateSync()).resolves.toStrictEqual(
      published,
    );
    expect(
      [...records().values()].map(({ updatedAt }) => updatedAt),
    ).toStrictEqual(stored);
    // Every connection still belongs to the Default Profile.
    expect(owners(published)).toStrictEqual([defaultProfile]);
  });

  it('applies only its own pending name over another device’s edits, and a removal elsewhere wins', async () => {
    expect.hasAssertions();
    const { flow, sync } = await connected();
    const { id } = profileNamed(await flow.createProfile('Work'), 'Work');

    // Another device's rename lands while this device renames offline; this device's later name
    // is applied to the newer record rather than replacing it blindly.
    storeProfile(sync, account, {
      kind: 'profile',
      id,
      version: 2,
      name: 'Office',
    });
    sync.offline = true;
    await flow.renameProfile(id, 'Job');
    sync.offline = false;
    // A third write lands between this device's read and its compare-and-set: it loses, keeps its
    // name pending and publishes it over the winner on the next pass.
    sync.beforePut = () => {
      sync.beforePut = undefined;
      storeProfile(sync, account, {
        kind: 'profile',
        id,
        version: 3,
        name: 'Desk',
      });
    };
    expect(listed(await flow.refreshPrivateSync())).toStrictEqual([
      { id, name: 'Job', pending: true },
    ]);
    expect(listed(await flow.refreshPrivateSync())).toStrictEqual([
      { id, name: 'Job' },
    ]);
    expect(storedProfiles(sync, account)).toStrictEqual([
      { kind: 'profile', id, version: 4, name: 'Job' },
    ]);

    // Another device removes the Profile while this device renames it offline: the removal stays.
    storeProfile(sync, account, { kind: 'profile', id, version: 5 });
    sync.offline = true;
    await flow.renameProfile(id, 'Later');
    sync.offline = false;
    await expect(flow.refreshPrivateSync()).resolves.not.toHaveProperty(
      'profiles',
    );
    expect(storedProfiles(sync, account)).toStrictEqual([
      { kind: 'profile', id, version: 5 },
    ]);
  });

  it('moves a connection in one compare-and-set write and keeps it only for that incarnation', async () => {
    expect.hasAssertions();
    const { flow, relaunch, sync, mailboxId, descriptor } = await connected();
    const id = await mailboxId();
    const work = profileNamed(await flow.createProfile('Work'), 'Work').id;
    const before = descriptor();

    const moved = await flow.moveMailbox(id, work);
    expect(owners(moved)).toStrictEqual([work]);
    await expect(relaunch().restore()).resolves.toStrictEqual(moved);
    // One ownership record; the connection's descriptor, which older clients read, is unchanged.
    expect(
      storedProfiles(sync, account).filter(({ kind }) => kind === 'mailbox'),
    ).toStrictEqual([
      {
        kind: 'mailbox',
        record: expect.any(String),
        epoch: expect.any(String),
        version: 1,
        profile: work,
      },
    ]);
    expect(descriptor()).toStrictEqual(before);

    // A Profile still named only on this device cannot receive a connection.
    sync.offline = true;
    const home = profileNamed(await flow.createProfile('Home'), 'Home').id;
    sync.offline = false;
    await expect(flow.moveMailbox(id, home)).rejects.toMatchObject({
      code: 'unavailable',
    });
    // Moving needs Product Sync.
    sync.offline = true;
    await expect(flow.moveMailbox(id, defaultProfile)).rejects.toBeDefined();
    sync.offline = false;

    // Another device moves it first: this move changes nothing and reports the conflict.
    // Publishing Home first lets the other device move the connection there.
    await flow.refreshPrivateSync();
    const ownership = ownershipOf(sync);
    sync.beforePut = () => {
      sync.beforePut = undefined;
      storeProfile(sync, account, { ...ownership, version: 2, profile: home });
    };
    await expect(flow.moveMailbox(id, defaultProfile)).rejects.toMatchObject({
      code: 'profile-changed',
    });
    expect(owners(await flow.restore())).toStrictEqual([home]);

    // Removed and added again, the connection starts over in the Default Profile.
    await flow.removeMailbox(id);
    await expect(flow.addMailbox('gmail', false)).resolves.toMatchObject({
      kind: 'connected',
    });
    expect(owners(await flow.restore())).toStrictEqual([defaultProfile]);
  });

  it('removes only a Profile that owns no live connection', async () => {
    expect.hasAssertions();
    const { flow, sync, mailboxId } = await connected();
    const id = await mailboxId();
    const work = profileNamed(await flow.createProfile('Work'), 'Work').id;
    await flow.moveMailbox(id, work);

    await expect(flow.removeProfile(work)).rejects.toMatchObject({
      code: 'profile-in-use',
    });
    await expect(flow.removeProfile(defaultProfile)).rejects.toMatchObject({
      code: 'unavailable',
    });
    await flow.moveMailbox(id, defaultProfile);
    await expect(flow.removeProfile(work)).resolves.not.toHaveProperty(
      'profiles',
    );
    expect(storedProfiles(sync, account)).toContainEqual({
      kind: 'profile',
      id: work,
      version: 2,
    });

    // Another device removes the Profile that owns this connection: it belongs to the Default
    // Profile again.
    const home = profileNamed(await flow.createProfile('Home'), 'Home').id;
    await flow.moveMailbox(id, home);
    storeProfile(sync, account, { kind: 'profile', id: home, version: 2 });
    expect(owners(await flow.refreshPrivateSync())).toStrictEqual([
      defaultProfile,
    ]);
  });

  it('keeps a removed offline Profile removed when its unanswered first publication arrives later', async () => {
    expect.hasAssertions();
    const { flow, vault } = await connected();
    const { flow: interrupted, publish } = delayPublication(vault);
    const { id } = profileNamed(
      await interrupted.createProfile('Work'),
      'Work',
    );
    await expect(flow.removeProfile(id)).resolves.not.toHaveProperty(
      'profiles',
    );
    await publish();
    await expect(flow.refreshPrivateSync()).resolves.not.toHaveProperty(
      'profiles',
    );
  });

  it('keeps an offline Profile identity through authorized re-enrollment after losing the device key', async () => {
    expect.hasAssertions();
    const { flow, relaunch, sync, device, confirmHeldKey } = await connected();
    confirmHeldKey();
    sync.offline = true;
    const { id } = profileNamed(await flow.createProfile('Work'), 'Work');
    sync.offline = false;
    device.productSync.deviceKey = false;
    await expect(relaunch().signIn('google')).resolves.toMatchObject({
      kind: 'device-pending',
    });
    sync.approves = true;
    expect(listed(await relaunch().signIn('google'))).toStrictEqual([
      { id, name: 'Work' },
    ]);
  });

  it('refuses removal when it cannot determine whether an owned connection is live', async () => {
    expect.hasAssertions();
    const context = await connected();
    const { flow, mailboxId, put, descriptor } = context;
    const work = profileNamed(await flow.createProfile('Work'), 'Work').id;
    await flow.moveMailbox(await mailboxId(), work);
    const before = descriptor();
    put(undefined);
    await expect(flow.removeProfile(work)).rejects.toMatchObject({
      code: 'unavailable',
    });
    expect(listed(await flow.restore())).toStrictEqual([
      { id: work, name: 'Work' },
    ]);
    put(before);
    unreadableOwnership(context);
    await expect(flow.removeProfile(work)).rejects.toMatchObject({
      code: 'unavailable',
    });
  });

  it('does not revive a removed Profile or regress connection ownership from replayed authenticated records', async () => {
    expect.hasAssertions();
    const { flow, sync, mailboxId, records } = await connected();
    const work = profileNamed(await flow.createProfile('Work'), 'Work').id;
    const home = profileNamed(await flow.createProfile('Home'), 'Home').id;
    const id = await mailboxId();
    await flow.moveMailbox(id, work);
    const first = ownershipOf(sync);
    await flow.moveMailbox(id, home);
    await flow.removeProfile(work);

    // Missing ciphertext must not erase a confirmed owner or its authenticated version floor.
    [...records().keys()]
      .filter((record) => record.startsWith('mailbox-profile.'))
      .forEach((record) => records().delete(record));
    expect(owners(await flow.refreshPrivateSync())).toStrictEqual([home]);

    // Row revisions do not authenticate the record's write count.
    storeProfile(sync, account, {
      kind: 'profile',
      id: work,
      version: 1,
      name: 'Work',
    });
    storeProfile(sync, account, first);
    const refreshed = await flow.refreshPrivateSync();
    expect(listed(refreshed)).toStrictEqual([{ id: home, name: 'Home' }]);
    expect(owners(refreshed)).toStrictEqual([home]);
    await expect(flow.moveMailbox(id, defaultProfile)).rejects.toMatchObject({
      code: 'unavailable',
    });
  });

  it('keeps confirmed remote removals when an unrelated pending publication fails', async () => {
    expect.hasAssertions();
    const { flow, relaunch, sync } = await connected();
    const work = profileNamed(await flow.createProfile('Work'), 'Work').id;
    sync.offline = true;
    const home = profileNamed(await flow.createProfile('Home'), 'Home').id;
    sync.offline = false;
    storeProfile(sync, account, { kind: 'profile', id: work, version: 2 });
    sync.beforePut = () => {
      throw new Error('Synthetic publication failure');
    };
    await flow.refreshPrivateSync();
    sync.beforePut = undefined;

    // Relaunch must retain the removal and reject an older authenticated definition.
    storeProfile(sync, account, {
      kind: 'profile',
      id: work,
      version: 1,
      name: 'Work',
    });
    // A valid newer record in the same listing still becomes durable when replay refuses the pass.
    storeProfile(sync, account, {
      kind: 'profile',
      id: home,
      version: 1,
      name: 'Home',
    });
    expect(listed(await relaunch().refreshPrivateSync())).toStrictEqual([
      { id: home, name: 'Home' },
    ]);
  });

  it('keeps confirmed CAS winners when a later pending publication fails', async () => {
    expect.hasAssertions();
    const { flow, relaunch, sync } = await connected();
    const work = profileNamed(await flow.createProfile('Work'), 'Work').id;
    sync.offline = true;
    await flow.renameProfile(work, 'Office');
    const home = profileNamed(await flow.createProfile('Home'), 'Home').id;
    sync.offline = false;
    sync.beforePut = () => {
      sync.beforePut = () => {
        throw new Error('Synthetic publication failure');
      };
    };
    expect(listed(await flow.refreshPrivateSync())).toStrictEqual([
      { id: work, name: 'Office' },
      { id: home, name: 'Home', pending: true },
    ]);
    sync.beforePut = undefined;
    storeProfile(sync, account, {
      kind: 'profile',
      id: work,
      version: 1,
      name: 'Work',
    });
    expect(listed(await relaunch().refreshPrivateSync())).toStrictEqual([
      { id: work, name: 'Office' },
      { id: home, name: 'Home', pending: true },
    ]);
  });
});
