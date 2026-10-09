import { createDrafts } from '../src/drafts.ts';
import { applyText } from '../src/semantic-document.ts';
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

// Controlled interruptions at the external write boundary, shared by the named recovery cases.
const interruptUpdate = async (
  phone: Awaited<ReturnType<typeof device>>,
  mac: Awaited<ReturnType<typeof device>>,
  {
    server,
    id,
    action,
    outcome,
  }: Readonly<{
    server: ReturnType<typeof createSyntheticProductSync>;
    id: string;
    action: 'discard' | 'edit';
    outcome: 'lost reply' | 'failed confirmation save' | 'competing update';
  }>,
) => {
  await (action === 'discard'
    ? phone.drafts.discard(id)
    : phone.drafts.update(
        { ...phone.draft(id), subject: 'After' },
        phone.draft(id),
      ));
  if (outcome === 'lost reply') {
    server.loseNextReply();
  } else if (outcome === 'competing update') {
    await mac.drafts.update(
      { ...mac.draft(id), subject: 'Independent' },
      mac.draft(id),
    );
    await mac.drafts.sync();
  }
};

const confirmation = (
  phone: Awaited<ReturnType<typeof device>>,
  outcome: string,
) => {
  if (outcome === 'failed confirmation save') {
    phone.storage.failNextCommit('locked');
  }
};

const changeHeld = async (
  drafts: ReturnType<typeof createDrafts>,
  id: string,
  action: 'discard' | 'edit' | 'revert',
) => {
  if (action === 'discard') {
    await drafts.discard(id);
  } else {
    const before = present(
      ready(drafts.getSnapshot()).drafts.find((draft) => draft.id === id),
      'held Draft',
    );
    await drafts.update(
      { ...before, subject: action === 'revert' ? 'Before' : 'After' },
      before,
    );
  }
};

describe('draft publication recovery', () => {
  it.each([
    { action: 'discard', expected: [] },
    { action: 'edit', expected: [{ subject: 'After', conflict: undefined }] },
    {
      action: 'revert',
      expected: [{ subject: 'Before', conflict: undefined }],
    },
  ] as const)(
    'recovers a confirmed update rejected before commit after a local $action and relaunch',
    async ({ action, expected }) => {
      expect.hasAssertions();
      const server = createSyntheticProductSync();
      const phone = await device(server);
      const id = present(await phone.drafts.create(alex), 'a Draft');
      await phone.drafts.update(
        { ...phone.draft(id), subject: 'Before' },
        phone.draft(id),
      );
      await phone.drafts.sync();
      await phone.drafts.update(
        { ...phone.draft(id), subject: 'Attempted' },
        phone.draft(id),
      );
      const held = vi
        .spyOn(present(phone.storage.sync, 'Draft sync'), 'pushDraft')
        .mockRejectedValueOnce(
          Object.assign(new Error('Unavailable'), { code: 'unavailable' }),
        );
      try {
        await phone.drafts.sync();
      } finally {
        held.mockRestore();
      }
      await changeHeld(phone.drafts, id, action);
      await phone.relaunch();
      await phone.drafts.sync();
      const mac = await device(server);
      await mac.drafts.sync();
      expect(phone.list()).toStrictEqual(mac.list());
      expect(
        phone.list().map(({ subject, conflict }) => ({ subject, conflict })),
      ).toStrictEqual(expected);
    },
  );

  it('keeps a shared-store Discard when its tombstone beats the held confirmed update', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    await phone.drafts.sync();
    await phone.drafts.update(
      { ...phone.draft(id), subject: 'In flight' },
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

  it('does not regress a newer confirmed floor when an earlier update reply arrives late', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    await phone.drafts.sync();
    await phone.drafts.update(
      { ...phone.draft(id), subject: 'First' },
      phone.draft(id),
    );
    const sync = present(phone.storage.sync, 'Draft sync');
    const started = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    const push = sync.pushDraft;
    const held = vi
      .spyOn(sync, 'pushDraft')
      .mockImplementationOnce(async (...args) => {
        const result = await push(...args);
        started.resolve(undefined);
        await release.promise;
        return result;
      });
    const passing = phone.drafts.sync();
    let first: string | undefined = undefined;
    let second: string | undefined = undefined;
    try {
      await started.promise;
      first = present(
        server.get('account-a', `draft.${id}`),
        'first record',
      ).sealed;
      const other = await writer(phone);
      const before = present(
        ready(other.getSnapshot()).drafts.find((draft) => draft.id === id),
        'other Draft',
      );
      await other.update({ ...before, subject: 'Second' }, before);
      await other.sync();
      second = present(
        server.get('account-a', `draft.${id}`),
        'second record',
      ).sealed;
      // A local CAS rebase learns the newer floor before the earlier reply arrives.
      await phone.drafts.create(alex);
    } finally {
      release.resolve(undefined);
      await passing;
      held.mockRestore();
    }
    server.replace('account-a', `draft.${id}`, present(first, 'first record'));
    const writes = vi.spyOn(sync, 'pushDraft');
    try {
      await phone.drafts.sync();
      expect(
        writes.mock.calls.filter(([, record]) => record.id === id),
      ).toStrictEqual([]);
      expect(phone.draft(id).subject).toBe('Second');
    } finally {
      writes.mockRestore();
    }
    server.replace(
      'account-a',
      `draft.${id}`,
      present(second, 'second record'),
    );
    await phone.relaunch();
    await phone.drafts.sync();
    expect(phone.draft(id).subject).toBe('Second');
    expect(phone.list().some((draft) => draft.conflict)).toBe(false);
  });

  it.each([
    { action: 'discard', expected: [] },
    { action: 'edit', expected: [{ subject: 'After', conflict: undefined }] },
    {
      action: 'revert',
      expected: [{ subject: 'Before', conflict: undefined }],
    },
  ] as const)(
    'keeps a shared-store $action through two held confirmed updates and a lost reply',
    async ({ action, expected }) => {
      expect.hasAssertions();
      const server = createSyntheticProductSync();
      const phone = await device(server);
      const id = present(await phone.drafts.create(alex), 'a Draft');
      await phone.drafts.update(
        { ...phone.draft(id), subject: 'Before' },
        phone.draft(id),
      );
      await phone.drafts.sync();
      await phone.drafts.update(
        { ...phone.draft(id), subject: 'First in flight' },
        phone.draft(id),
      );
      const sync = present(phone.storage.sync, 'Draft sync');
      const first = Promise.withResolvers<undefined>();
      const second = Promise.withResolvers<undefined>();
      const releaseFirst = Promise.withResolvers<undefined>();
      const releaseSecond = Promise.withResolvers<undefined>();
      const push = sync.pushDraft;
      const held = vi
        .spyOn(sync, 'pushDraft')
        .mockImplementationOnce(async (...args) => {
          first.resolve(undefined);
          await releaseFirst.promise;
          return push(...args);
        })
        .mockImplementationOnce(async (...args) => {
          second.resolve(undefined);
          await releaseSecond.promise;
          return push(...args);
        });
      const passing = phone.drafts.sync();
      let following: Promise<void> | undefined = undefined;
      try {
        await first.promise;
        server.setReachable(false);
        const other = await writer(phone);
        const before = present(
          ready(other.getSnapshot()).drafts.find((draft) => draft.id === id),
          'other Draft',
        );
        await other.update({ ...before, subject: 'Second in flight' }, before);
        server.setReachable(true);
        following = other.sync();
        await second.promise;
        await changeHeld(other, id, action);
        server.loseNextReply();
        releaseFirst.resolve(undefined);
        await passing;
      } finally {
        releaseFirst.resolve(undefined);
        releaseSecond.resolve(undefined);
        await Promise.all([passing, following]);
        held.mockRestore();
      }
      await phone.relaunch();
      await phone.drafts.sync();
      const mac = await device(server);
      await mac.drafts.sync();
      expect(phone.list()).toStrictEqual(mac.list());
      expect(
        phone.list().map(({ subject, conflict }) => ({ subject, conflict })),
      ).toStrictEqual(expected);
    },
  );

  it('does not write a synchronized Draft discarded while its new file uploads', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    await phone.drafts.update(
      {
        ...phone.draft(id),
        body: applyText(phone.draft(id).body, 'Before').document,
      },
      phone.draft(id),
    );
    await phone.drafts.sync();
    await mac.drafts.sync();
    phone.storage.addFile('file:///late.txt', 'late file bytes');
    const late = phone.drafts.prepare({ name: 'late.txt', type: 'text/plain' });
    await phone.drafts.update(
      { ...phone.draft(id), attachments: [late] },
      phone.draft(id),
    );
    await phone.drafts.importAsset(late, {
      kind: 'file',
      uri: 'file:///late.txt',
    });
    const record = () =>
      server.open(
        present(server.get('account-a', `draft.${id}`), 'the record').sealed,
        'account-a',
        `draft.${id}`,
      );

    // The Discard lands while the new file is still uploading.
    phone.storage.holdUploads();
    const passing = phone.drafts.sync();
    await vi.waitFor(() => {
      expect(
        server
          .identifiers('account-a')
          .some((each) => each.startsWith('draft-asset.')),
      ).toBe(true);
    });
    await phone.drafts.discard(id);
    phone.storage.releaseUploads();
    await passing;
    expect(record()).not.toContain('late.txt');

    await phone.drafts.sync();
    await mac.drafts.sync();
    expect(phone.list()).toStrictEqual([]);
    expect(mac.list()).toStrictEqual([]);
  });

  it.each([
    { action: 'discard', outcome: 'lost reply', expected: [] },
    {
      action: 'edit',
      outcome: 'lost reply',
      expected: [{ subject: 'After', conflict: undefined }],
    },
    { action: 'discard', outcome: 'failed confirmation save', expected: [] },
    {
      action: 'edit',
      outcome: 'failed confirmation save',
      expected: [{ subject: 'After', conflict: undefined }],
    },
    {
      action: 'discard',
      outcome: 'competing update',
      expected: [{ subject: 'Independent', conflict: true }],
    },
    {
      action: 'edit',
      outcome: 'competing update',
      expected: [
        { subject: 'Independent', conflict: undefined },
        { subject: 'After', conflict: true },
      ],
    },
  ] as const)(
    'keeps a local $action during a confirmed update with a $outcome, through relaunch',
    async ({ action, outcome, expected }) => {
      expect.hasAssertions();
      const server = createSyntheticProductSync();
      const phone = await device(server);
      const mac = await device(server);
      const id = present(await phone.drafts.create(alex), 'a Draft');
      await phone.drafts.update(
        { ...phone.draft(id), subject: 'Before' },
        phone.draft(id),
      );
      await phone.drafts.sync();
      await mac.drafts.sync();
      await phone.drafts.update(
        { ...phone.draft(id), subject: 'In flight' },
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
          const result = await push(...args);
          confirmation(phone, outcome);
          return result;
        });
      const passing = phone.drafts.sync();
      try {
        await started.promise;
        await interruptUpdate(phone, mac, { server, id, action, outcome });
      } finally {
        release.resolve(undefined);
        await passing;
        held.mockRestore();
      }
      await phone.relaunch();
      await phone.drafts.sync();
      await mac.drafts.sync();
      expect(phone.list()).toStrictEqual(mac.list());
      expect(
        phone
          .list()
          .map(({ subject, conflict }) => ({ subject, conflict }))
          .toSorted((left, right) => left.subject.localeCompare(right.subject)),
      ).toStrictEqual(
        expected.toSorted((left, right) =>
          left.subject.localeCompare(right.subject),
        ),
      );
    },
  );

  it('does not send a confirmed update when its local intent cannot be saved', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    await phone.drafts.sync();
    const before = present(
      server.get('account-a', `draft.${id}`),
      'confirmed record',
    ).sealed;
    await phone.drafts.update(
      { ...phone.draft(id), subject: 'Still local' },
      phone.draft(id),
    );
    phone.storage.failNextCommit('locked');
    await phone.drafts.sync();
    expect(server.get('account-a', `draft.${id}`)?.sealed).toBe(before);
    await phone.drafts.sync();
    const mac = await device(server);
    await mac.drafts.sync();
    expect(phone.list()).toStrictEqual(mac.list());
    expect(mac.draft(id).subject).toBe('Still local');
  });

  it('retains the confirmed version floor while an update remains unconfirmed', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    await phone.drafts.sync();
    const first = present(
      server.get('account-a', `draft.${id}`),
      'first record',
    ).sealed;
    await phone.drafts.update(
      { ...phone.draft(id), subject: 'Confirmed' },
      phone.draft(id),
    );
    await phone.drafts.sync();
    await phone.drafts.update(
      { ...phone.draft(id), subject: 'Unconfirmed' },
      phone.draft(id),
    );
    server.loseNextReply();
    await phone.drafts.sync();
    const pending = present(
      server.get('account-a', `draft.${id}`),
      'pending record',
    ).sealed;
    server.replace('account-a', `draft.${id}`, first);
    await phone.relaunch();
    await phone.drafts.sync();
    expect(phone.list().map(({ subject }) => subject)).toStrictEqual([
      'Unconfirmed',
    ]);
    expect(server.get('account-a', `draft.${id}`)?.sealed).toBe(first);
    server.replace('account-a', `draft.${id}`, pending);
    await phone.drafts.update(
      { ...phone.draft(id), subject: 'After' },
      phone.draft(id),
    );
    await phone.drafts.sync();
    const mac = await device(server);
    await mac.drafts.sync();
    expect(phone.list()).toStrictEqual(mac.list());
    expect(
      mac.list().map(({ subject, conflict }) => ({ subject, conflict })),
    ).toStrictEqual([{ subject: 'After', conflict: undefined }]);
  });

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
