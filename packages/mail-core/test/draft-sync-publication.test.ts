import { createDrafts } from '../src/drafts.ts';
import { createSyntheticProductSync } from '../src/testing/drafts.ts';
import {
  alex,
  complete,
  connected,
  device,
  present,
  ready,
} from './draft-sync-fixture.ts';

// Separate local stores share native CAS storage while keeping independent synchronization bases.
const writer = async (phone: Awaited<ReturnType<typeof device>>) => {
  const drafts = createDrafts(
    phone.storage.native,
    {
      getSnapshot: () => ({
        snapshot: connected('account-a'),
        busy: false,
        failed: false,
      }),
      subscribe: () => () => undefined,
    },
    { native: present(phone.storage.sync, 'Draft sync'), delay: 60_000 },
  );
  await drafts.load();
  await drafts.sync();
  return drafts;
};

describe('first Draft publication recovery', () => {
  it('accepts an older competing first publication after a newer local intent', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    await phone.drafts.update(
      { ...phone.draft(id), subject: 'First' },
      phone.draft(id),
    );
    server.setReachable(false);
    const other = await writer(phone);
    server.setReachable(true);
    const sync = present(phone.storage.sync, 'Draft sync');
    const firstStarted = Promise.withResolvers<undefined>();
    const secondStarted = Promise.withResolvers<undefined>();
    const firstRelease = Promise.withResolvers<undefined>();
    const secondRelease = Promise.withResolvers<undefined>();
    const push = sync.pushDraft;
    const held = vi
      .spyOn(sync, 'pushDraft')
      .mockImplementationOnce(async (...args) => {
        firstStarted.resolve(undefined);
        await firstRelease.promise;
        return push(...args);
      })
      .mockImplementationOnce(async (...args) => {
        secondStarted.resolve(undefined);
        await secondRelease.promise;
        return push(...args);
      });
    const firstPass = phone.drafts.sync();
    let secondPass: ReturnType<typeof other.sync> | undefined = undefined;
    let editing = id;
    try {
      await firstStarted.promise;
      const before = present(
        ready(other.getSnapshot()).drafts.find((draft) => draft.id === id),
        'other Draft',
      );
      await other.update({ ...before, subject: 'Second' }, before, (next) => {
        editing = next;
      });
      secondPass = other.sync();
      await secondStarted.promise;
      firstRelease.resolve(undefined);
      await firstPass;
    } finally {
      firstRelease.resolve(undefined);
      secondRelease.resolve(undefined);
      await firstPass;
      await secondPass;
      held.mockRestore();
    }
    const copy = present(
      ready(other.getSnapshot()).drafts.find(
        (draft) => draft.conflict === true,
      ),
      'Second copy',
    );
    expect({ subject: copy.subject, editing }).toStrictEqual({
      subject: 'Second',
      editing: copy.id,
    });
    await phone.relaunch();
    await phone.drafts.sync();
    const mac = await device(server);
    await mac.drafts.sync();
    expect(phone.list()).toStrictEqual(mac.list());
    expect(
      mac
        .list()
        .map(({ subject }) => subject)
        .toSorted(),
    ).toStrictEqual(['First', 'Second']);
    expect(mac.list().find((draft) => draft.id === id)?.subject).toBe('First');
  });

  it('keeps a shared-store Discard while its announced first publication is in flight', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    await phone.drafts.update(
      { ...phone.draft(id), subject: 'Discarded while pending' },
      phone.draft(id),
    );
    const sync = present(phone.storage.sync, 'Draft sync');
    const started = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    const push = sync.pushDraft;
    const held = vi
      .spyOn(sync, 'pushDraft')
      .mockImplementationOnce(async (...args) => {
        started.resolve(undefined);
        await release.promise;
        return push(...args);
      });
    const passing = phone.drafts.sync();
    try {
      await started.promise;
      server.setReachable(false);
      const other = await writer(phone);
      await other.discard(id);
      server.setReachable(true);
      await other.sync();
      server.loseNextReply();
    } finally {
      release.resolve(undefined);
      await passing;
      held.mockRestore();
    }
    await phone.relaunch();
    await phone.drafts.sync();
    const mac = await device(server);
    await mac.drafts.sync();
    expect({ local: phone.list(), remote: mac.list() }).toStrictEqual({
      local: [],
      remote: [],
    });
  });

  it.each([
    { name: 'unchanged', edits: [], expected: [] },
    {
      name: 'divergent',
      edits: ['Divergent edit'],
      expected: [{ subject: 'Divergent edit', conflict: true }],
    },
  ])(
    'accepts a tombstone after an unconfirmed publication with $name content',
    async ({ edits, expected }) => {
      expect.hasAssertions();
      const server = createSyntheticProductSync();
      const phone = await device(server);
      const id = present(await phone.drafts.create(alex), 'a Draft');
      await phone.drafts.update(
        { ...phone.draft(id), subject: 'Published' },
        phone.draft(id),
      );
      server.loseNextReply();
      await phone.drafts.sync();
      const mac = await device(server);
      await mac.drafts.discard(id);
      await mac.drafts.sync();
      for (const subject of edits) {
        await phone.drafts.update(
          { ...phone.draft(id), subject },
          phone.draft(id),
        );
      }
      await phone.drafts.sync();
      await phone.relaunch();
      await phone.drafts.sync();
      await mac.drafts.sync();
      expect(phone.list()).toStrictEqual(mac.list());
      expect(
        phone.list().map(({ subject, conflict }) => ({ subject, conflict })),
      ).toStrictEqual(expected);
    },
  );

  it('retries a first publication that failed before writing, through relaunch', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    await phone.drafts.update(
      { ...phone.draft(id), subject: 'Still local' },
      phone.draft(id),
    );
    const draft = phone.draft(id);
    const sync = present(phone.storage.sync, 'Draft sync');
    const push = vi
      .spyOn(sync, 'pushDraft')
      .mockRejectedValueOnce(
        Object.assign(new Error('Unavailable'), { code: 'unavailable' }),
      );
    try {
      await phone.drafts.sync();
    } finally {
      push.mockRestore();
    }
    await phone.relaunch();
    await phone.drafts.sync();
    await mac.drafts.sync();
    expect(phone.list()).toStrictEqual([draft]);
    expect(mac.list()).toStrictEqual([draft]);
  });

  it('does not publish a Draft discarded while its first asset uploads', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    phone.storage.addFile('file:///plan.pdf', 'plan bytes');
    await phone.drafts.attach(id, [
      {
        name: 'plan.pdf',
        type: 'application/pdf',
        source: { kind: 'file', uri: 'file:///plan.pdf' },
      },
    ]);
    await vi.waitFor(() => {
      complete(phone.draft(id), phone.draft(id).attachments?.[0]?.id);
    });
    const sync = present(phone.storage.sync, 'Draft sync');
    const started = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    const upload = sync.uploadDraftAsset;
    const held = vi
      .spyOn(sync, 'uploadDraftAsset')
      .mockImplementationOnce(async (...args) => {
        const result = await upload(...args);
        started.resolve(undefined);
        await release.promise;
        return result;
      });
    const passing = phone.drafts.sync();
    try {
      await started.promise;
      await phone.drafts.discard(id);
    } finally {
      release.resolve(undefined);
      await passing;
      held.mockRestore();
    }
    await mac.drafts.sync();
    await phone.relaunch();
    await phone.drafts.sync();
    expect({ local: phone.list(), remote: mac.list() }).toStrictEqual({
      local: [],
      remote: [],
    });
  });

  it('preserves competing first publications through relaunch', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    let editing = id;
    await phone.drafts.update(
      { ...phone.draft(id), subject: 'First' },
      phone.draft(id),
      (next) => {
        editing = next;
      },
    );
    server.setReachable(false);
    const other = await writer(phone);
    server.setReachable(true);
    const sync = present(phone.storage.sync, 'Draft sync');
    const started = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    const push = sync.pushDraft;
    const held = vi
      .spyOn(sync, 'pushDraft')
      .mockImplementationOnce(async (...args) => {
        started.resolve(undefined);
        await release.promise;
        return push(...args);
      });
    const passing = phone.drafts.sync();
    try {
      await started.promise;
      const before = present(
        ready(other.getSnapshot()).drafts.find((draft) => draft.id === id),
        'other Draft',
      );
      await other.update({ ...before, subject: 'Second' }, before);
      await other.sync();
    } finally {
      release.resolve(undefined);
      await passing;
      held.mockRestore();
    }
    const retained = 'First';
    const localCopy = present(
      phone.list().find((draft) => draft.conflict === true),
      'local copy',
    );
    expect({ subject: localCopy.subject, editing }).toStrictEqual({
      subject: retained,
      editing: localCopy.id,
    });
    await phone.relaunch();
    await phone.drafts.sync();
    const mac = await device(server);
    await mac.drafts.sync();
    expect(
      mac
        .list()
        .map(({ subject }) => subject)
        .toSorted(),
    ).toStrictEqual(['First', 'Second']);
    expect(phone.list()).toStrictEqual(mac.list());
    const copy = present(
      mac.list().find((draft) => draft.conflict === true),
      'copy',
    );
    expect({
      original: mac.list().find((draft) => draft.id === id)?.subject,
      copy: copy.subject,
    }).toStrictEqual({
      original: 'Second',
      copy: retained,
    });
  });

  it('does not publish without its durable intent after a local storage CAS rebase', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const earlier = present(await phone.drafts.create(alex), 'earlier Draft');
    await phone.drafts.sync();
    const id = present(await phone.drafts.create(alex), 'new Draft');
    await phone.drafts.update(
      { ...phone.draft(id), subject: 'First' },
      phone.draft(id),
    );
    server.setReachable(false);
    const other = await writer(phone);
    const before = present(
      ready(other.getSnapshot()).drafts.find((draft) => draft.id === id),
      'other Draft',
    );
    await other.update({ ...before, subject: 'Second' }, before);
    server.setReachable(true);
    server.loseNextReply();
    await phone.drafts.sync();
    await phone.drafts.discard(id);
    await phone.relaunch();
    await phone.drafts.sync();
    const mac = await device(server);
    await mac.drafts.sync();
    expect({
      local: phone.list().map((draft) => draft.id),
      remote: mac.list().map((draft) => draft.id),
    }).toStrictEqual({ local: [earlier], remote: [earlier] });
  });
});
