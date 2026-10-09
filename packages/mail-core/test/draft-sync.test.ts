import type { Draft, DraftsState } from '../src/drafts.ts';
import type { RegistrationSnapshot } from '../src/registration.ts';
import type { SyntheticProductSync } from '../src/testing/drafts.ts';

import {
  assetsOf,
  createDrafts,
  draftOf,
  unsendableAssets,
} from '../src/drafts.ts';
import { createRegistration } from '../src/registration.ts';
import { applyText, insertImage } from '../src/semantic-document.ts';
import {
  createSyntheticDrafts,
  createSyntheticProductSync,
} from '../src/testing/drafts.ts';
import { createMockRegistrationSession } from '../src/testing/registration-session.ts';

const alex = { id: 'connection-alex', address: 'alex@example.invalid' };

const connected = (productAccountId: string): RegistrationSnapshot => ({
  kind: 'connected',
  productAccountId,
  signInProvider: 'google',
  mailboxes: JSON.stringify([{ ...alex, state: 'connected' }]),
});

const ready = (state: DraftsState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected ready Drafts, received ${state.kind}`);
  }
  return state;
};

const present = <T>(value: T | undefined, what: string): T => {
  if (value === undefined) {
    throw new Error(`Expected ${what}`);
  }
  return value;
};

// One enrolled device of `productAccountId` with its own encrypted Draft storage. Automatic
// synchronization waits a minute, so each scenario decides when a device synchronizes.
async function device(
  server: SyntheticProductSync,
  productAccountId = 'account-a',
) {
  const snapshot = connected(productAccountId);
  const registration = {
    getSnapshot: () => ({ snapshot, busy: false, failed: false }),
    subscribe: () => () => undefined,
  };
  const storage = createSyntheticDrafts(() => productAccountId, {
    server,
  });
  const open = async () => {
    const store = createDrafts(storage.native, registration, {
      native: present(storage.sync, 'Draft sync'),
      delay: 60_000,
    });
    await store.load();
    return store;
  };
  let drafts = await open();
  return {
    storage,
    get drafts() {
      return drafts;
    },
    // A relaunch reopens the same storage in a new process.
    relaunch: async () => {
      storage.relaunch();
      drafts = await open();
    },
    list: () => ready(drafts.getSnapshot()).drafts,
    draft: (id: string) =>
      present(draftOf(drafts.getSnapshot(), id), `Draft ${id}`),
  };
}

// The complete asset `id` of a Draft, or a failed test.
const complete = (draft: Draft, id: string | undefined) => {
  const asset = assetsOf(draft).find((each) => each.id === id);
  if (asset?.state !== 'complete') {
    throw new Error('Expected a complete asset');
  }
  return asset;
};

const write = (draft: Draft, text: string): Draft => ({
  ...draft,
  body: applyText(draft.body, text).document,
});

describe('synchronizing Drafts through Product Sync', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one synchronization path across devices. */
  it('continues a Draft on another device with its files, and keeps incomplete files incomplete', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a new Draft');
    const created = phone.draft(id);
    phone.storage.addFile('file:///plan.pdf', 'quarterly plan bytes');
    phone.storage.addFile('file:///chart.png', 'chart bytes');
    phone.storage.addFile('file:///slow.mov', 'movie');
    const plan = phone.drafts.prepare({
      name: 'plan.pdf',
      type: 'application/pdf',
    });
    const chart = phone.drafts.prepare({
      name: 'chart.png',
      type: 'image/png',
    });
    const slow = phone.drafts.prepare({
      name: 'slow.mov',
      type: 'video/quicktime',
    });
    await phone.drafts.update(
      {
        ...write(created, 'Numbers attached'),
        to: [{ name: 'Sam', address: 'sam@example.invalid' }],
        subject: 'Plan',
        attachments: [plan, slow],
        body: insertImage(
          write(created, 'Numbers attached').body,
          { start: 0, end: 0 },
          chart,
        ).document,
      },
      created,
    );
    await phone.drafts.importAsset(plan, {
      kind: 'file',
      uri: 'file:///plan.pdf',
    });
    await phone.drafts.importAsset(chart, {
      kind: 'file',
      uri: 'file:///chart.png',
    });
    // The movie is still importing when the phone synchronizes.
    phone.storage.holdImports();
    const importing = phone.drafts.importAsset(slow, {
      kind: 'file',
      uri: 'file:///slow.mov',
    });
    await phone.drafts.sync();

    // Product Sync holds ciphertext only: no subject, recipient, body or file content.
    const sealed = server
      .identifiers('account-a')
      .map((identifier) => server.get('account-a', identifier)?.sealed);
    expect(sealed.join('')).not.toContain('quarterly plan');
    expect(
      server
        .identifiers('account-a')
        .filter((each) => each.startsWith('draft.')),
    ).toStrictEqual([`draft.${id}`]);

    await mac.drafts.sync();
    const continued = mac.draft(id);
    // The same Draft identity and content, sent from the same mailbox; nothing claims delivery.
    expect(continued).toStrictEqual(phone.draft(id));
    expect(continued).toMatchObject({
      connection: alex.id,
      from: alex.address,
      subject: 'Plan',
    });
    const [, slowAsset] = assetsOf(continued);
    // The import running on the phone stays incomplete, and is never sent.
    expect(slowAsset).toMatchObject({ state: 'importing' });
    expect(unsendableAssets(continued)).toStrictEqual([slowAsset]);
    // Complete files download on first use, verified against their digest.
    expect(mac.storage.assets()).toStrictEqual([]);
    await expect(
      mac.drafts.readAsset(complete(continued, chart.id)),
    ).resolves.toStrictEqual({
      kind: 'ready',
      uri: `data:image/png;base64,${btoa('chart bytes')}`,
    });

    // A chunk missing from Product Sync leaves its file incomplete rather than damaged or sent.
    const planned = complete(continued, plan.id);
    server.remove('account-a', `draft-asset.${planned.id}:${planned.digest}.2`);
    await expect(
      mac.drafts.readAsset(planned, { preview: false }),
    ).resolves.toStrictEqual({
      kind: 'incomplete',
    });

    // Once the import finishes, the phone's next synchronization completes it on the Mac.
    phone.storage.releaseImports();
    await importing;
    await phone.drafts.sync();
    await mac.drafts.sync();
    expect(assetsOf(mac.draft(id))[1]).toMatchObject({
      state: 'complete',
      size: 5,
    });
    await expect(
      mac.drafts.readAsset(complete(mac.draft(id), slow.id), {
        preview: false,
      }),
    ).resolves.toStrictEqual({ kind: 'verified' });
  });

  it.each(['revoked', 'deleted'] as const)(
    'forgets the account when a lazy asset download discovers it was %s',
    async (notice) => {
      expect.hasAssertions();
      const server = createSyntheticProductSync();
      const phone = await device(server);
      const id = present(await phone.drafts.create(alex), 'a Draft');
      phone.storage.addFile('file:///notes.txt', 'private notes');
      const asset = phone.drafts.prepare({
        name: 'notes.txt',
        type: 'text/plain',
      });
      await phone.drafts.update(
        { ...phone.draft(id), attachments: [asset] },
        phone.draft(id),
      );
      await phone.drafts.importAsset(asset, {
        kind: 'file',
        uri: 'file:///notes.txt',
      });
      await phone.drafts.sync();

      const session = createMockRegistrationSession('registration-success');
      let snapshot: RegistrationSnapshot = connected('account-a');
      const registration = createRegistration({
        ...session.native,
        restore: () => Promise.resolve(snapshot),
      });
      await registration.restore();
      const storage = createSyntheticDrafts(() => 'account-a', { server });
      const native = present(storage.sync, 'Draft sync');
      let removal: Promise<void> | undefined = undefined;
      const drafts = createDrafts(storage.native, registration, {
        native,
        delay: 60_000,
        removed: () => {
          removal = registration.deviceRemoved();
        },
      });
      await drafts.load();
      await drafts.sync();
      const continued = present(
        draftOf(drafts.getSnapshot(), id),
        'the synchronized Draft',
      );
      // Native preflight purges the registration before rejecting the download.
      vi.spyOn(native, 'downloadDraftAsset').mockImplementationOnce(() => {
        snapshot = { kind: 'signed-out', notice };
        return Promise.reject(
          Object.assign(new Error('Revoked'), { code: 'mailbox-revoked' }),
        );
      });
      await drafts.readAsset(complete(continued, asset.id));
      await removal;
      expect(registration.getSnapshot().snapshot).toStrictEqual({
        kind: 'signed-out',
        notice,
      });
      expect(drafts.getSnapshot()).toStrictEqual({ kind: 'closed' });
    },
  );

  it('automatically publishes a received attachment after its slow import finishes', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a new Draft');
    await phone.drafts.sync();
    phone.storage.addFile('file:///received.pdf', 'received bytes');
    phone.storage.holdImports();
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    try {
      await phone.drafts.attach(id, [
        {
          name: 'received.pdf',
          type: 'application/pdf',
          source: { kind: 'file', uri: 'file:///received.pdf' },
        },
      ]);
      await vi.advanceTimersByTimeAsync(60_000);
      await phone.drafts.sync();
      await mac.drafts.sync();
      expect(assetsOf(mac.draft(id))[0]).toMatchObject({ state: 'importing' });

      phone.storage.releaseImports();
      await vi.advanceTimersByTimeAsync(0);
      expect(assetsOf(phone.draft(id))[0]).toMatchObject({ state: 'complete' });
      // No edit or activation follows the import: its completion schedules publication.
      await vi.advanceTimersByTimeAsync(60_000);
      await mac.drafts.sync();
      expect(assetsOf(mac.draft(id))[0]).toMatchObject({
        state: 'complete',
        size: 14,
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it('preserves edits made on two devices as separate Drafts, and the editor follows its own copy', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a new Draft');
    await phone.drafts.update(write(phone.draft(id), 'Hello'), phone.draft(id));
    await phone.drafts.sync();
    await mac.drafts.sync();

    // Both edit the same Draft while offline.
    server.setReachable(false);
    const before = mac.draft(id);
    await phone.drafts.update(
      write(phone.draft(id), ' from the phone'),
      phone.draft(id),
    );
    const moves: string[] = [];
    await mac.drafts.update(write(before, ' from the Mac'), before, (copy) => {
      moves.push(copy);
    });
    // Unreachable Product Sync changes nothing on either device.
    await phone.drafts.sync();
    await mac.drafts.sync();
    expect(mac.list()).toHaveLength(1);
    server.setReachable(true);

    await phone.drafts.sync();
    await mac.drafts.sync();
    await phone.drafts.sync();
    // The first record keeps the identifier; the Mac's edit is a conflicting copy everywhere.
    const copy = present(
      mac.list().find((draft) => draft.conflict === true),
      'the conflicting copy',
    );
    expect(moves).toStrictEqual([copy.id]);
    expect(mac.draft(id).body).toStrictEqual(phone.draft(id).body);
    expect(phone.draft(copy.id)).toStrictEqual(copy);
    expect(phone.list()).toHaveLength(2);

    // The Mac's editor keeps editing its own copy, which synchronizes without another conflict.
    const edited = write(copy, '!');
    await mac.drafts.update(edited, copy);
    await mac.drafts.sync();
    await phone.drafts.sync();
    expect(phone.list()).toHaveLength(2);
    expect(phone.draft(copy.id).body).toStrictEqual(edited.body);
  });

  it('removes a Draft discarded on another device, but keeps an edit racing that deletion as a copy', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    phone.storage.addFile('file:///notes.txt', 'shared notes');
    const kept = present(await phone.drafts.create(alex), 'a Draft');
    const racing = present(await phone.drafts.create(alex), 'another Draft');
    const notes = phone.drafts.prepare({
      name: 'notes.txt',
      type: 'text/plain',
    });
    await phone.drafts.update(
      { ...write(phone.draft(kept), 'Short'), attachments: [notes] },
      phone.draft(kept),
    );
    await phone.drafts.importAsset(notes, {
      kind: 'file',
      uri: 'file:///notes.txt',
    });
    await phone.drafts.update(
      write(phone.draft(racing), 'Racing'),
      phone.draft(racing),
    );
    await phone.drafts.sync();
    await mac.drafts.sync();
    expect(mac.list()).toHaveLength(2);
    const chunks = () =>
      server
        .identifiers('account-a')
        .filter((each) => each.startsWith('draft-asset.'));
    expect(chunks().length).toBeGreaterThan(1);

    // The phone discards both; the Mac edited one of them meanwhile.
    await phone.drafts.discard(kept);
    await phone.drafts.discard(racing);
    await mac.drafts.update(write(mac.draft(racing), ' on'), mac.draft(racing));
    // The second device downloads the unchanged Draft's file just before its deletion arrives.
    await expect(
      mac.drafts.readAsset(complete(mac.draft(kept), notes.id), {
        preview: false,
      }),
    ).resolves.toStrictEqual({ kind: 'verified' });
    expect(mac.storage.assets()).toStrictEqual([notes.id]);
    await phone.drafts.sync();
    // Cloud bytes remain recoverable for offline copies even when all known records delete.
    expect(chunks().length).toBeGreaterThan(1);
    await mac.drafts.sync();
    await phone.drafts.sync();

    // The discarded identities stay removed; the racing edit survives on both devices.
    for (const each of [phone, mac]) {
      expect(each.list().map((draft) => draft.id)).not.toContain(kept);
      expect(each.list().map((draft) => draft.id)).not.toContain(racing);
      expect(each.list()).toHaveLength(1);
      expect(each.list()[0]).toMatchObject({ conflict: true });
    }
    // The Mac lost the unchanged Draft's bytes along with it.
    expect(mac.storage.assets()).toStrictEqual([]);
  });

  it.each([0, 101])(
    'keeps an offline Discard when another device publishes an edit first, and keeps that edit as a copy (minimum source length: %i)',
    async (minimumLength) => {
      expect.hasAssertions();
      const server = createSyntheticProductSync();
      const phone = await device(server);
      const mac = await device(server);
      let id = present(await phone.drafts.create(alex), 'a Draft');
      for (let round = 0; id.length < minimumLength; round += 1) {
        const stale = phone.draft(id);
        await phone.drafts.update(write(stale, `kept ${round}`), stale);
        const moves: string[] = [];
        await phone.drafts.update(
          write(stale, `copied ${round}`),
          stale,
          (copy) => {
            moves.push(copy);
          },
        );
        const prior = id;
        id = present(moves.at(-1), 'the conflicting copy');
        await phone.drafts.discard(prior);
      }
      expect(id.length).toBeGreaterThanOrEqual(minimumLength);
      await phone.drafts.update(
        write(phone.draft(id), 'Shared'),
        phone.draft(id),
      );
      await phone.drafts.sync();
      await mac.drafts.sync();

      // The phone discards offline; the Mac's edit reaches Product Sync first.
      server.setReachable(false);
      await phone.drafts.discard(id);
      server.setReachable(true);
      const edited = write(mac.draft(id), ' edited');
      const moves: string[] = [];
      let target = id;
      await mac.drafts.update(edited, mac.draft(id), (copy) => {
        moves.push(copy);
        target = copy;
      });
      await mac.drafts.sync();
      await phone.drafts.sync();
      await mac.drafts.sync();

      // The discarded identity stays removed; the Mac's edit survives as a copy on both devices.
      for (const each of [phone, mac]) {
        expect(each.list().map((draft) => draft.id)).not.toContain(id);
        expect(each.list()).toHaveLength(1);
        expect(each.list()[0]).toMatchObject({
          conflict: true,
          body: edited.body,
        });
      }
      expect(phone.list()[0]?.body).toStrictEqual(mac.list()[0]?.body);
      const copy = present(mac.list()[0], 'the conflicting copy');
      expect(moves).toStrictEqual([copy.id]);

      const continued = write(mac.draft(target), '!');
      await mac.drafts.update(continued, mac.draft(target));
      await mac.drafts.sync();
      await phone.drafts.sync();
      await phone.relaunch();
      await mac.relaunch();
      for (const each of [phone, mac]) {
        await each.drafts.sync();
        expect(each.list()).toHaveLength(1);
        expect(each.draft(copy.id).body).toStrictEqual(continued.body);
        expect(each.list().map((draft) => draft.id)).not.toContain(id);
      }

      await mac.drafts.discard(() => target);
      await mac.drafts.sync();
      await phone.drafts.sync();
      expect(mac.list()).toStrictEqual([]);
      expect(phone.list()).toStrictEqual([]);
    },
  );

  it('does not move an editor to another authored version merely because its conflict copy names the discarded Draft', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await mac.drafts.create(alex), 'a Draft');
    const moves: string[] = [];
    await mac.drafts.update(
      write(mac.draft(id), 'Published'),
      mac.draft(id),
      (copy) => {
        moves.push(copy);
      },
    );
    await mac.drafts.sync();
    await phone.drafts.sync();
    const before = phone.draft(id);

    // The phone knowingly discards that version, then keeps a different late edit as a copy.
    await phone.drafts.discard(id);
    await phone.drafts.update(write(before, ' different'), before);
    await phone.drafts.sync();
    await mac.drafts.sync();

    expect(mac.list().map((draft) => draft.id)).not.toContain(id);
    expect(mac.list()).toHaveLength(1);
    expect(mac.list()[0]).toMatchObject({
      conflict: true,
      body: phone.list()[0]?.body,
    });
    expect(moves).toStrictEqual([]);
  });

  it('does not rebind to a copy edited locally before an interrupted Discard finishes publishing', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    await phone.drafts.sync();
    await mac.drafts.sync();
    server.setReachable(false);
    await phone.drafts.discard(id);
    server.setReachable(true);
    const moves: string[] = [];
    await mac.drafts.update(
      write(mac.draft(id), 'Published'),
      mac.draft(id),
      (copy) => {
        moves.push(copy);
      },
    );
    await mac.drafts.sync();

    // The copy lands first, but the phone never receives that reply or writes the tombstone.
    server.loseNextReply();
    await phone.drafts.sync();
    await mac.drafts.sync();
    const copy = present(
      mac.list().find((draft) => draft.conflict === true),
      'the copy',
    );
    const changed = write(copy, ' changed locally');
    await mac.drafts.update(changed, copy);

    await phone.drafts.sync();
    await mac.drafts.sync();
    expect(mac.list()).toHaveLength(1);
    expect(mac.draft(copy.id).body).toStrictEqual(changed.body);
    expect(mac.list().map((draft) => draft.id)).not.toContain(id);
    expect(moves).toStrictEqual([]);
    await phone.drafts.sync();
    expect(phone.draft(copy.id).body).toStrictEqual(changed.body);
  });

  it('synchronizes later edits after a subscriber defect rejects an earlier pass', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    await phone.drafts.sync();

    const unsubscribe = mac.drafts.subscribe(() => {
      throw new Error('Subscriber failed');
    });
    try {
      await expect(mac.drafts.sync()).rejects.toThrow('Subscriber failed');
    } finally {
      unsubscribe();
    }

    const edited = write(phone.draft(id), 'After the failed pass');
    await phone.drafts.update(edited, phone.draft(id));
    await phone.drafts.sync();
    await expect(mac.drafts.sync()).resolves.toBeUndefined();
    expect(mac.draft(id).body).toStrictEqual(edited.body);
    await mac.relaunch();
    expect(mac.draft(id).body).toStrictEqual(edited.body);
  });

  it('keeps conflict copies of conflict copies within the identifier bound, so they still synchronize', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    let id = present(await phone.drafts.create(alex), 'a Draft');
    // Each stale edit of the newest copy preserves itself as a copy of that copy.
    for (let round = 0; round < 25; round += 1) {
      const stale = phone.draft(id);
      await phone.drafts.update(write(stale, `kept ${round}`), stale);
      const moves: string[] = [];
      await phone.drafts.update(
        write(stale, `copied ${round}`),
        stale,
        (copy) => {
          moves.push(copy);
        },
      );
      id = present(moves.at(-1), 'the conflicting copy');
    }
    expect(phone.list().every((draft) => draft.id.length <= 200)).toBe(true);
    await phone.drafts.sync();
    await mac.drafts.sync();
    expect(mac.list()).toHaveLength(phone.list().length);
  });

  it('keeps ambiguous shortened copies recoverable without binding an editor to another removed Draft', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const root = present(await phone.drafts.create(alex), 'a Draft');
    const draft = phone.draft(root);
    const ids = [1, 2].map(
      (suffix) => `${root}${'-conflict-1'.repeat(8)}-conflict-${suffix}`,
    );
    for (const id of ids) {
      expect(id.length).toBeGreaterThan(100);
      expect(id.length).toBeLessThanOrEqual(200);
    }
    // Two already-stored long siblings have the same authored content and shortened base.
    const stored = present(phone.storage.stored(), 'the stored document');
    await phone.storage.native.commitDrafts('account-a', stored.revision, {
      document: JSON.stringify({
        version: 1,
        drafts: ids.map((id) => ({ ...draft, id, conflict: true })),
      }),
      keep: [],
    });
    await phone.relaunch();
    await phone.drafts.sync();
    await mac.drafts.sync();
    const moves: string[] = [];
    for (const id of ids) {
      await phone.drafts.discard(id);
      await mac.drafts.update(
        write(mac.draft(id), 'Identical'),
        mac.draft(id),
        (copy) => {
          moves.push(copy);
        },
      );
    }
    await mac.drafts.sync();
    await phone.drafts.sync();
    await mac.drafts.sync();
    expect(moves).toStrictEqual([]);
    expect(mac.list()).toHaveLength(2);
    for (const id of ids) {
      expect(mac.list().map((copy) => copy.id)).not.toContain(id);
    }
    for (const copy of mac.list()) {
      expect(copy.body).toStrictEqual(write(draft, 'Identical').body);
    }
    expect(mac.list().map(({ body }) => body)).toStrictEqual(
      phone.list().map(({ body }) => body),
    );
    await mac.relaunch();
    expect(mac.list()).toHaveLength(2);
    for (const copy of mac.list()) {
      await mac.drafts.discard(copy.id);
    }
    await mac.drafts.sync();
    await phone.drafts.sync();
    expect(mac.list()).toStrictEqual([]);
    expect(phone.list()).toStrictEqual([]);
  });

  it('resumes after an interrupted write and a relaunch without inventing conflicts', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    await phone.drafts.update(write(phone.draft(id), 'First'), phone.draft(id));
    // The write lands but its reply is lost.
    server.loseNextReply();
    await phone.drafts.sync();
    await phone.relaunch();
    await phone.drafts.sync();
    await mac.drafts.sync();
    expect(mac.list()).toHaveLength(1);
    expect(phone.list()).toHaveLength(1);

    // Edits after relaunching both devices continue the same synchronized Draft.
    await mac.relaunch();
    await mac.drafts.update(write(mac.draft(id), ' and second'), mac.draft(id));
    await mac.drafts.sync();
    await phone.drafts.sync();
    expect(phone.list()).toHaveLength(1);
    expect(phone.draft(id).body).toStrictEqual(mac.draft(id).body);
  });

  it('refuses tampered, moved, replayed and foreign records without changing local Drafts', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const first = present(await phone.drafts.create(alex), 'a Draft');
    const second = present(await phone.drafts.create(alex), 'another Draft');
    await phone.drafts.update(
      write(phone.draft(first), 'One'),
      phone.draft(first),
    );
    await phone.drafts.update(
      write(phone.draft(second), 'Two'),
      phone.draft(second),
    );
    await phone.drafts.sync();
    await mac.drafts.sync();
    const record = (draftId: string) =>
      present(server.get('account-a', `draft.${draftId}`), 'a record').sealed;

    // A newer record is replaced by an older one served again: the Mac keeps what it read.
    const older = record(first);
    await phone.drafts.update(
      write(phone.draft(first), ' updated'),
      phone.draft(first),
    );
    await phone.drafts.sync();
    await mac.drafts.sync();
    const updated = mac.draft(first);
    server.replace('account-a', `draft.${first}`, older);
    // Another Draft's ciphertext moved under this identifier does not open here.
    server.replace('account-a', `draft.${second}`, record(first));
    await mac.drafts.sync();
    expect(mac.draft(first)).toStrictEqual(updated);
    expect(mac.draft(second).body).toStrictEqual(phone.draft(second).body);

    // Another Product Account's device sees none of these records.
    const stranger = await device(server, 'account-b');
    await stranger.drafts.sync();
    expect(stranger.list()).toStrictEqual([]);
  });

  it('retries interrupted asset uploads before publishing complete references', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    await phone.drafts.sync();
    phone.storage.addFile('file:///notes.txt', 'private notes');
    const asset = phone.drafts.prepare({
      name: 'notes.txt',
      type: 'text/plain',
    });
    await phone.drafts.update(
      { ...phone.draft(id), attachments: [asset] },
      phone.draft(id),
    );
    await phone.drafts.importAsset(asset, {
      kind: 'file',
      uri: 'file:///notes.txt',
    });
    // The first chunk lands, but its reply is lost before the remaining chunks upload.
    server.loseNextReply();
    await phone.drafts.sync();
    await mac.drafts.sync();
    expect(assetsOf(mac.draft(id))).toStrictEqual([]);
    await phone.relaunch();
    await phone.drafts.sync();
    await mac.drafts.sync();
    await expect(
      mac.drafts.readAsset(complete(mac.draft(id), asset.id), {
        preview: false,
      }),
    ).resolves.toStrictEqual({ kind: 'verified' });
  });

  it('recovers a deleted Draft conflict with assets never downloaded on the editing device', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    phone.storage.addFile('file:///notes.txt', 'recoverable notes');
    const asset = phone.drafts.prepare({
      name: 'notes.txt',
      type: 'text/plain',
    });
    await phone.drafts.update(
      { ...phone.draft(id), attachments: [asset] },
      phone.draft(id),
    );
    await phone.drafts.importAsset(asset, {
      kind: 'file',
      uri: 'file:///notes.txt',
    });
    await phone.drafts.sync();
    await mac.drafts.sync();
    expect(mac.storage.assets()).toStrictEqual([]);
    server.setReachable(false);
    await mac.drafts.update(
      { ...mac.draft(id), subject: 'Offline edit' },
      mac.draft(id),
    );
    await phone.drafts.discard(id);
    server.setReachable(true);
    await phone.drafts.sync();
    expect(phone.storage.assets()).toStrictEqual([]);
    await mac.drafts.sync();
    await phone.drafts.sync();
    expect(phone.list()).toHaveLength(1);
    const copy = present(phone.list()[0], 'the conflict copy');
    expect(copy).toMatchObject({ conflict: true, subject: 'Offline edit' });
    await expect(
      phone.drafts.readAsset(complete(copy, asset.id), { preview: false }),
    ).resolves.toStrictEqual({ kind: 'verified' });
  });

  it('keeps a deletion version through relaunch and refuses a replayed live record', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    await phone.drafts.sync();
    const older = present(
      server.get('account-a', `draft.${id}`),
      'the live record',
    ).sealed;
    await phone.drafts.discard(id);
    await phone.drafts.sync();
    await phone.relaunch();
    server.remove('account-a', `draft.${id}`);
    await phone.drafts.sync();
    await phone.relaunch();
    server.put('account-a', `draft.${id}`, { sealed: older });
    await phone.drafts.sync();
    expect(phone.list()).toStrictEqual([]);
  });

  it('rebases a competing publication before the synchronization request finishes', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    await phone.drafts.sync();
    await mac.drafts.sync();
    await phone.drafts.update(
      { ...phone.draft(id), subject: 'Phone edit' },
      phone.draft(id),
    );
    await mac.drafts.update(
      { ...mac.draft(id), subject: 'Mac edit' },
      mac.draft(id),
    );
    const native = present(mac.storage.sync, 'sync boundary');
    const pull = native.pullDrafts;
    vi.spyOn(native, 'pullDrafts').mockImplementationOnce(async (...args) => {
      const result = await pull(...args);
      // The other device commits after this pull, so the ensuing write loses its CAS.
      await phone.drafts.sync();
      return result;
    });
    await mac.drafts.sync();
    expect(mac.list()).toHaveLength(2);
    expect(mac.draft(id).subject).toBe('Phone edit');
    expect(mac.list().find((draft) => draft.conflict)?.subject).toBe(
      'Mac edit',
    );
    await phone.drafts.sync();
    expect(phone.list()).toHaveLength(2);
  });

  it('retains earlier committed publications when a later Draft interrupts the pass', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const first = present(await phone.drafts.create(alex), 'a Draft');
    const second = present(await phone.drafts.create(alex), 'another Draft');
    await phone.drafts.sync();
    await phone.drafts.update(
      { ...phone.draft(first), subject: 'First edit' },
      phone.draft(first),
    );
    await phone.drafts.update(
      { ...phone.draft(second), subject: 'Second edit' },
      phone.draft(second),
    );
    const native = present(phone.storage.sync, 'sync boundary');
    const push = native.pushDraft;
    vi.spyOn(native, 'pushDraft')
      .mockImplementationOnce(async (...args) => {
        const result = await push(...args);
        await phone.drafts.update(
          { ...phone.draft(first), subject: 'Later first edit' },
          phone.draft(first),
        );
        return result;
      })
      .mockRejectedValueOnce(
        Object.assign(new Error('Unavailable'), { code: 'unavailable' }),
      );
    await phone.drafts.sync();
    await phone.relaunch();
    await phone.drafts.sync();
    const mac = await device(server);
    await mac.drafts.sync();
    expect(mac.list()).toHaveLength(2);
    expect(mac.draft(first).subject).toBe('Later first edit');
    expect(mac.draft(second).subject).toBe('Second edit');
  });

  it('synchronizes once edits pause', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const storage = createSyntheticDrafts(() => 'account-a', {
      server,
    });
    const snapshot = connected('account-a');
    const drafts = createDrafts(
      storage.native,
      {
        getSnapshot: () => ({ snapshot, busy: false, failed: false }),
        subscribe: () => () => undefined,
      },
      { native: present(storage.sync, 'Draft sync'), delay: 1 },
    );
    await drafts.load();
    await drafts.sync();
    const id = present(await drafts.create(alex), 'a Draft');
    await vi.waitFor(() => {
      expect(server.identifiers('account-a')).toStrictEqual([`draft.${id}`]);
    });
    await drafts.sync();

    const record = () =>
      server.open(
        present(server.get('account-a', `draft.${id}`), 'the record').sealed,
        'account-a',
        `draft.${id}`,
      );
    // An edit made while storage is locked synchronizes once Save Drafts stores it.
    storage.setLocked(true);
    const draft = present(draftOf(drafts.getSnapshot(), id), 'the Draft');
    await drafts.update({ ...draft, subject: 'Saved later' }, draft);
    // The edit's own synchronization runs, and fails, while storage is still locked.
    const failedEdit = drafts.getSnapshot();
    await vi.waitFor(() => {
      expect(drafts.getSnapshot()).not.toBe(failedEdit);
      expect(ready(drafts.getSnapshot()).save).toBe('locked');
    });
    await drafts.sync();
    expect(record()).not.toContain('Saved later');
    storage.setLocked(false);
    await expect(drafts.save()).resolves.toBe(true);
    await vi.waitFor(() => {
      expect(record()).toContain('Saved later');
    });
  });
});
