import type {
  NativeBlockedSenderSync,
  NativeBlockedSenders,
} from '@private-email/mail-core/blocked-senders';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import {
  blockedAddress,
  blockedDomain,
  createBlockedSenders,
} from '@private-email/mail-core/blocked-senders';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type { SyntheticProductSync } from '../src/testing/drafts.ts';

import { createSyntheticProductSync } from '../src/testing/drafts.ts';

const november8 = Date.UTC(2026, 10, 8);

const openRecord = Schema.decodeUnknownOption(
  Schema.fromJsonString(
    Schema.Struct({
      id: Schema.String,
      version: Schema.Finite,
      senders: Schema.String,
    }),
  ),
);

// Product Sync as native code moves Blocked Sender records for `owner`: one record per Mail
// Profile under an identifier derived from its own.
const remote = (server: SyntheticProductSync): NativeBlockedSenderSync => ({
  pullBlockedSenders: (owner, known) => {
    const refused = server.reach();
    if (refused !== undefined) {
      return Promise.reject(refused);
    }
    const opened = server
      .list(owner, 'profile-blocked-senders.')
      .map(({ identifier, sealed, updatedAt }) => {
        const record = Option.getOrUndefined(
          openRecord(server.open(sealed, owner, identifier) ?? ''),
        );
        return record === undefined ||
          identifier !== `profile-blocked-senders.${record.id}`
          ? { identifier }
          : { identifier, record: { ...record, updatedAt } };
      });
    return Promise.resolve({
      owner,
      records: opened.flatMap(({ record }) =>
        record === undefined ? [] : [record],
      ),
      unreadable: known.filter((id) =>
        opened.some(
          ({ identifier, record }) =>
            identifier === `profile-blocked-senders.${id}` &&
            record === undefined,
        ),
      ),
    });
  },
  pushBlockedSenders: async (
    owner,
    { id, version, senders, expectedUpdatedAt },
  ) => {
    const refused = server.reach();
    if (refused !== undefined) {
      throw refused;
    }
    const identifier = `profile-blocked-senders.${id}`;
    return {
      owner,
      ...server.put(owner, identifier, {
        sealed: server.seal(
          owner,
          identifier,
          JSON.stringify({ id, version, senders }),
        ),
        expected: expectedUpdatedAt,
      }),
    };
  },
});

// Native Blocked Sender storage as the store sees it: one document for the signed-in account,
// replaced only from the revision read. The clock starts on 8 November. With `server`, the store
// also synchronizes through it as `sync`.
const storage = (
  server?: SyntheticProductSync,
  hooks: Readonly<{
    removed?: () => void;
    adoptKeyRotation?: () => Promise<unknown>;
  }> = {},
) => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(november8);
  onTestFinished(() => {
    vi.useRealTimers();
  });
  const state: {
    account: string;
    // `cached` while registration has not verified again, as offline after a relaunch.
    kind: 'connected' | 'cached';
    locked: boolean;
    revision: number;
    owner?: string;
    document?: string;
    commits: number;
    // Runs before the next commit, as another writer would.
    before?: () => void;
  } = {
    account: 'account-1',
    kind: 'connected',
    locked: false,
    revision: 0,
    commits: 0,
  };
  const refuse = (code: string) =>
    Promise.reject(Object.assign(new Error(code), { code }));
  const native: NativeBlockedSenders = {
    openBlockedSenders: () =>
      state.locked
        ? refuse('locked')
        : Promise.resolve({
            owner: state.account,
            revision: state.revision,
            document: state.owner === state.account ? state.document : null,
          }),
    commitBlockedSenders: (owner, expectedRevision, document) => {
      state.before?.();
      state.before = undefined;
      if (state.locked) {
        return refuse('locked');
      }
      if (owner !== state.account) {
        return refuse('mailbox-invalidated');
      }
      if (state.revision !== expectedRevision) {
        return refuse('conflict');
      }
      state.commits += 1;
      Object.assign(state, { revision: expectedRevision + 1, owner, document });
      return Promise.resolve({ owner, revision: state.revision });
    },
  };
  // Registration as the store reads it: whichever account is signed in now.
  const registration = {
    getSnapshot: () => ({
      snapshot: {
        kind: state.kind,
        productAccountId: state.account,
        signInProvider: 'google',
        mailboxes: '[]',
      } satisfies RegistrationSnapshot,
      busy: false,
      failed: false,
    }),
  };
  const sync = server === undefined ? undefined : remote(server);
  const relaunch = () =>
    createBlockedSenders(
      native,
      registration,
      sync === undefined ? undefined : { native: sync, ...hooks },
    );
  return { state, store: relaunch(), relaunch, sync };
};

describe('blocked sender addresses', () => {
  it('match one plain address as a whole, without case', () => {
    expect.hasAssertions();
    expect(blockedAddress('  Offers@GrowthLeads.io ')).toBe(
      'offers@growthleads.io',
    );
    expect(blockedAddress("o'brien+news@mail.xn--p1ai")).toBe(
      "o'brien+news@mail.xn--p1ai",
    );
    for (const refused of [
      'Growth Leads <offers@growthleads.io>',
      'growthleads.io',
      '@growthleads.io',
      'offers@growthleads.io, news@growthleads.io',
      'offers@localhost',
      'a..b@growthleads.io',
      '.offers@growthleads.io',
      'offers.@growthleads.io',
      'offers@growthleads..io',
      'offers@-growthleads.io',
      'offers@growthleads.--',
      'offers@growthleads.xn--io-',
      'off\u0000ers@growthleads.io',
      'off\u0007ers@growthleads.io',
      `${'a'.repeat(250)}@growthleads.io`,
      '',
    ]) {
      expect(blockedAddress(refused)).toBeUndefined();
    }
  });
});

describe('stored Blocked Senders', () => {
  it('keeps each Profile its own Blocked Senders across a relaunch', async () => {
    expect.hasAssertions();
    const { store, relaunch } = storage();
    await expect(store.blockedSenders('work')).resolves.toStrictEqual([]);
    await expect(store.block('work', 'Offers@GrowthLeads.io')).resolves.toBe(
      true,
    );
    vi.setSystemTime(november8 + 1000);
    await store.block('home', 'offers@growthleads.io');
    const relaunched = relaunch();
    await expect(relaunched.blockedSenders('work')).resolves.toStrictEqual([
      {
        profile: 'work',
        address: 'offers@growthleads.io',
        blockedAt: november8,
        moved: 0,
      },
    ]);
    await expect(relaunched.blockedSenders('home')).resolves.toStrictEqual([
      {
        profile: 'home',
        address: 'offers@growthleads.io',
        blockedAt: november8 + 1000,
        moved: 0,
      },
    ]);
  });

  it("unblocks an address in one Profile and leaves another Profile's block", async () => {
    expect.hasAssertions();
    const { store } = storage();
    await store.block('work', 'offers@growthleads.io');
    await store.block('home', 'offers@growthleads.io');
    await expect(store.unblock('work', 'Offers@growthleads.io')).resolves.toBe(
      true,
    );
    await expect(store.blockedSenders('work')).resolves.toStrictEqual([]);
    await expect(store.blockedSenders('home')).resolves.toStrictEqual([
      {
        profile: 'home',
        address: 'offers@growthleads.io',
        blockedAt: november8,
        moved: 0,
      },
    ]);
  });

  it('keeps the first date of an address blocked again', async () => {
    expect.hasAssertions();
    const { state, store } = storage();
    await store.block('work', 'offers@growthleads.io');
    const { commits } = state;
    vi.setSystemTime(november8 + 1000);
    await expect(store.block('work', 'OFFERS@growthleads.io')).resolves.toBe(
      true,
    );
    // Unblocking an address that is not blocked writes nothing either.
    await expect(store.unblock('work', 'news@growthleads.io')).resolves.toBe(
      true,
    );
    expect(state.commits).toBe(commits);
    await expect(store.blockedSenders('work')).resolves.toStrictEqual([
      {
        profile: 'work',
        address: 'offers@growthleads.io',
        blockedAt: november8,
        moved: 0,
      },
    ]);
  });

  it('never stores a display name, domain, list or Profile-less block', async () => {
    expect.hasAssertions();
    const error = vi.spyOn(console, 'error');
    const { state, store } = storage();
    for (const refused of [
      'Growth Leads <offers@growthleads.io>',
      'growthleads.io',
      'offers@growthleads.io; news@growthleads.io',
    ]) {
      await expect(store.block('work', refused)).resolves.toBe(false);
    }
    await expect(store.unblock('', 'offers@growthleads.io')).resolves.toBe(
      false,
    );
    expect(state.commits + error.mock.calls.length).toBe(0);
  });

  it('blocks and unblocks without a verified Product Sign-In session', async () => {
    expect.hasAssertions();
    const { state, store, relaunch } = storage();
    state.kind = 'cached';
    await expect(store.block('work', 'offers@growthleads.io')).resolves.toBe(
      true,
    );
    await expect(store.block('work', 'news@growthleads.io')).resolves.toBe(
      true,
    );
    await expect(store.unblock('work', 'offers@growthleads.io')).resolves.toBe(
      true,
    );
    await expect(relaunch().blockedSenders('work')).resolves.toStrictEqual([
      {
        profile: 'work',
        address: 'news@growthleads.io',
        blockedAt: november8,
        moved: 0,
      },
    ]);
  });

  it('changes nothing when another write moved the revision on', async () => {
    expect.hasAssertions();
    const error = vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    await store.block('work', 'offers@growthleads.io');
    const { document } = state;
    state.before = () => {
      state.revision += 1;
    };
    await expect(store.block('work', 'news@growthleads.io')).resolves.toBe(
      false,
    );
    expect(state.document).toBe(document);
    expect(error).toHaveBeenCalledWith(
      expect.anything(),
      'Blocked Sender storage failed:',
      'code conflict',
    );
  });

  it('reads and writes nothing while the device is locked', async () => {
    expect.hasAssertions();
    const error = vi.spyOn(console, 'error');
    const { state, store } = storage();
    state.locked = true;
    await expect(store.block('work', 'offers@growthleads.io')).resolves.toBe(
      false,
    );
    await expect(store.blockedSenders('work')).resolves.toBeUndefined();
    expect(state.commits + error.mock.calls.length).toBe(0);
  });

  it("lists none of another account's Blocked Senders and writes nothing into them", async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    await store.block('work', 'offers@growthleads.io');
    const { document } = state;
    state.before = () => {
      state.account = 'account-2';
    };
    await expect(store.unblock('work', 'offers@growthleads.io')).resolves.toBe(
      false,
    );
    expect(state.document).toBe(document);
    await expect(store.blockedSenders('work')).resolves.toStrictEqual([]);
  });

  it('counts the moves a document stored before senders kept their count recorded since the block', async () => {
    expect.hasAssertions();
    const { state, store } = storage();
    const receipt = (
      receivedAt: string,
      address = 'offers@growthleads.io',
    ) => ({
      connection: 'connection-1',
      address,
      receivedAt,
    });
    Object.assign(state, {
      owner: state.account,
      revision: 1,
      document: JSON.stringify({
        senders: [
          {
            profile: 'work',
            address: 'offers@growthleads.io',
            blockedAt: november8,
          },
          {
            profile: 'work',
            address: 'noreply@crypto-daily.co',
            blockedAt: november8,
          },
        ],
        receipts: [
          receipt('2026-11-08T10:00:00Z', 'noreply@crypto-daily.co'),
          receipt('2026-11-07T09:00:00Z'),
          receipt('2026-11-09T09:00:00Z'),
        ],
      }),
    });
    await expect(store.blockedSenders('work')).resolves.toMatchObject([
      { moved: 1 },
      { moved: 1 },
    ]);
    // Moves that push the oldest receipts out keep every sender's history.
    await store.screen(
      'work',
      { id: 'connection-1', moves: true },
      Array.from({ length: 1000 }, (_, index) => ({
        id: `next-${index}`,
        address: 'offers@growthleads.io',
        receivedAt: `2026-11-10T09:00:00.${String(index).padStart(3, '0')}Z`,
      })),
    );
    await expect(store.blockedSenders('work')).resolves.toMatchObject([
      { address: 'offers@growthleads.io', moved: 1001 },
      { address: 'noreply@crypto-daily.co', moved: 1 },
    ]);
  });

  it('lists nothing from a stored document that does not decode or holds an invalid address', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    Object.assign(state, {
      owner: state.account,
      revision: 1,
      document: '{"senders":[{"profile":"work"}]}',
    });
    await expect(store.blockedSenders('work')).resolves.toBeUndefined();
    await expect(store.block('work', 'offers@growthleads.io')).resolves.toBe(
      false,
    );
    expect(state.commits).toBe(0);
    state.document =
      '{"senders":[{"profile":"work","address":"a..b@growthleads.io","blockedAt":0}]}';
    await expect(store.blockedSenders('work')).resolves.toBeUndefined();
  });

  it("screens arrivals by their Profile's Blocked Senders and moves each one once", async () => {
    expect.hasAssertions();
    const { store, relaunch } = storage();
    await store.block('work', 'offers@growthleads.io');
    const receivedAt = '2026-11-08T09:00:00.000Z';
    const arrivals = [
      { id: 'blocked', address: ' Offers@GrowthLeads.io', receivedAt },
      { id: 'other', address: 'maya@example.invalid', receivedAt },
    ];
    await expect(
      store.screen('work', { id: 'connection-1', moves: true }, arrivals),
    ).resolves.toStrictEqual({
      blocked: new Set(['blocked']),
      move: ['blocked'],
    });
    // Reported again, as after a restore to the Inbox renamed it, it is still blocked but never
    // moved again.
    await expect(
      relaunch().screen('work', { id: 'connection-1', moves: true }, [
        { id: 'restored', address: 'offers@growthleads.io', receivedAt },
      ]),
    ).resolves.toStrictEqual({ blocked: new Set(['restored']), move: [] });
    // A receipt names its connection; another Profile's Blocked Senders never apply.
    await expect(
      store.screen('work', { id: 'connection-2', moves: true }, arrivals),
    ).resolves.toStrictEqual({
      blocked: new Set(['blocked']),
      move: ['blocked'],
    });
    await expect(
      store.screen('home', { id: 'connection-3', moves: true }, arrivals),
    ).resolves.toStrictEqual({ blocked: new Set(), move: [] });
    // Unblocking keeps the receipts.
    await store.unblock('work', 'offers@growthleads.io');
    await store.block('work', 'offers@growthleads.io');
    await expect(
      store.screen('work', { id: 'connection-1', moves: true }, arrivals),
    ).resolves.toStrictEqual({ blocked: new Set(['blocked']), move: [] });
  });

  it('counts a Blocked Sender’s moves since it was blocked, beyond the kept receipts', async () => {
    expect.hasAssertions();
    const { store } = storage();
    await store.block('work', 'offers@growthleads.io');
    const arrival = (id: string) => [
      { id, address: 'offers@growthleads.io', receivedAt: `${id}T09:00:00Z` },
    ];
    await store.screen(
      'work',
      { id: 'connection-1', moves: true },
      arrival('2026-11-08'),
    );
    await store.screen(
      'work',
      { id: 'connection-2', moves: true },
      arrival('2026-11-09'),
    );
    // A connection without a Trash keeps the arrival unnotified but moves and counts nothing.
    await expect(
      store.screen(
        'work',
        { id: 'connection-1', moves: false },
        arrival('2026-11-10'),
      ),
    ).resolves.toStrictEqual({ blocked: new Set(['2026-11-10']), move: [] });
    await expect(store.blockedSenders('work')).resolves.toMatchObject([
      { moved: 2 },
    ]);
    // More moves than the receipts keep still count.
    await store.screen(
      'work',
      { id: 'connection-1', moves: true },
      Array.from({ length: 1000 }, (_, index) => ({
        id: `bulk-${index}`,
        address: 'offers@growthleads.io',
        receivedAt: `bulk-${index}`,
      })),
    );
    await expect(store.blockedSenders('work')).resolves.toMatchObject([
      { moved: 1002 },
    ]);
    // Blocked again later, it counts none of the moves from before.
    vi.setSystemTime(november8 + 1000);
    await store.unblock('work', 'offers@growthleads.io');
    vi.setSystemTime(november8 + 2000);
    await store.block('work', 'offers@growthleads.io');
    await expect(store.blockedSenders('work')).resolves.toMatchObject([
      { blockedAt: november8 + 2000, moved: 0 },
    ]);
  });

  it('moves nothing whose receipt cannot be written, and screens nothing it cannot read', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    await store.block('work', 'offers@growthleads.io');
    const arrivals = [
      {
        id: 'blocked',
        address: 'offers@growthleads.io',
        receivedAt: '2026-11-08T09:00:00.000Z',
      },
    ];
    state.before = () => {
      state.locked = true;
    };
    await expect(
      store.screen('work', { id: 'connection-1', moves: true }, arrivals),
    ).resolves.toStrictEqual({ blocked: new Set(['blocked']), move: [] });
    await expect(
      store.screen('work', { id: 'connection-1', moves: true }, arrivals),
    ).resolves.toBeUndefined();
  });

  it('screens nothing for an account that signed in while the screening waited', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    state.account = 'account-2';
    await store.block('work', 'offers@growthleads.io');
    const { document } = state;
    state.account = 'account-1';
    const waiting = store.block('home', 'offers@growthleads.io');
    const screening = store.screen(
      'work',
      { id: 'connection-1', moves: true },
      [
        {
          id: 'blocked',
          address: 'offers@growthleads.io',
          receivedAt: '2026-11-08T09:00:00.000Z',
        },
      ],
    );
    state.account = 'account-2';
    await waiting;
    await expect(screening).resolves.toBeUndefined();
    expect(state.document).toBe(document);
  });
});

describe('synchronized Blocked Senders', () => {
  // Two Trusted Devices of one Product Account sharing Product Sync.
  const devices = () => {
    const server = createSyntheticProductSync();
    return { server, mac: storage(server), phone: storage(server) };
  };
  const offers = 'offers@growthleads.io';
  const deals = 'deals@growthleads.io';

  it('carries a block and its unblock to another device in the same Profile only', async () => {
    expect.hasAssertions();
    const { server, mac, phone } = devices();
    await mac.store.block('work', 'Offers@GrowthLeads.io');
    await mac.store.synchronize();
    await phone.store.synchronize();
    await expect(phone.store.blockedSenders('work')).resolves.toStrictEqual([
      { profile: 'work', address: offers, blockedAt: november8, moved: 0 },
    ]);
    await expect(phone.store.blockedSenders('home')).resolves.toStrictEqual([]);
    // Convex names the record by its Profile alone, never by a sender.
    expect(server.identifiers('account-1')).toStrictEqual([
      'profile-blocked-senders.work',
    ]);

    // A move count stays with the device that moved the mail.
    await mac.store.screen('work', { id: 'connection-1', moves: true }, [
      { id: 'a', address: offers, receivedAt: '2026-11-08T09:00:00.000Z' },
    ]);
    vi.setSystemTime(november8 + 1000);
    await phone.store.block('work', deals);
    await phone.store.synchronize();
    await mac.store.synchronize();
    await expect(mac.store.blockedSenders('work')).resolves.toStrictEqual([
      { profile: 'work', address: offers, blockedAt: november8, moved: 1 },
      {
        profile: 'work',
        address: deals,
        blockedAt: november8 + 1000,
        moved: 0,
      },
    ]);

    vi.setSystemTime(november8 + 2000);
    await phone.store.unblock('work', offers);
    await phone.store.synchronize();
    await mac.store.synchronize();
    await expect(mac.store.blockedSenders('work')).resolves.toStrictEqual([
      {
        profile: 'work',
        address: deals,
        blockedAt: november8 + 1000,
        moved: 0,
      },
    ]);
  });

  it('counts the moves of a sender blocked again on another device from the new block', async () => {
    expect.hasAssertions();
    const { mac, phone } = devices();
    await mac.store.block('work', offers);
    await mac.store.synchronize();
    await phone.store.synchronize();
    await mac.store.screen('work', { id: 'connection-1', moves: true }, [
      { id: 'a', address: offers, receivedAt: '2026-11-08T09:00:00.000Z' },
    ]);
    vi.setSystemTime(november8 + 1000);
    await phone.store.unblock('work', offers);
    await phone.store.block('work', offers);
    await phone.store.synchronize();
    await mac.store.synchronize();
    await expect(mac.store.blockedSenders('work')).resolves.toStrictEqual([
      {
        profile: 'work',
        address: offers,
        blockedAt: november8 + 1001,
        moved: 0,
      },
    ]);
  });

  it('keeps offline changes on the device and publishes them once Product Sync is back', async () => {
    expect.hasAssertions();
    const { server, mac, phone } = devices();
    server.setReachable(false);
    await expect(mac.store.block('work', offers)).resolves.toBe(true);
    await mac.store.synchronize();
    await expect(mac.store.blockedSenders('work')).resolves.toStrictEqual([
      { profile: 'work', address: offers, blockedAt: november8, moved: 0 },
    ]);
    expect(server.identifiers('account-1')).toStrictEqual([]);

    server.setReachable(true);
    await mac.store.synchronize();
    await phone.store.synchronize();
    await expect(phone.store.blockedSenders('work')).resolves.toStrictEqual([
      { profile: 'work', address: offers, blockedAt: november8, moved: 0 },
    ]);
  });

  it.each([
    ['the Mac', 'the phone', ['mac', 'phone', 'mac']],
    ['the phone', 'the Mac', ['phone', 'mac', 'phone']],
  ] as const)(
    'converges on the later change of each address when %s synchronizes before %s',
    async (_first, _second, order) => {
      expect.hasAssertions();
      const { server, mac, phone } = devices();
      await mac.store.block('work', offers);
      await mac.store.synchronize();
      await phone.store.synchronize();

      server.setReachable(false);
      vi.setSystemTime(november8 + 10);
      await phone.store.unblock('work', offers);
      vi.setSystemTime(november8 + 20);
      await mac.store.unblock('work', offers);
      await mac.store.block('work', deals);
      vi.setSystemTime(november8 + 30);
      await mac.store.block('work', offers);
      vi.setSystemTime(november8 + 40);
      await phone.store.block('work', deals);
      vi.setSystemTime(november8 + 50);
      await phone.store.unblock('work', deals);

      server.setReachable(true);
      const named = { mac, phone };
      for (const device of order) {
        await named[device].store.synchronize();
      }
      const converged = [
        {
          profile: 'work',
          address: offers,
          blockedAt: november8 + 30,
          moved: 0,
        },
      ];
      await expect(mac.store.blockedSenders('work')).resolves.toStrictEqual(
        converged,
      );
      await expect(phone.store.blockedSenders('work')).resolves.toStrictEqual(
        converged,
      );
    },
  );

  it('writes again from the newer record when another device wrote meanwhile', async () => {
    expect.hasAssertions();
    const { mac, phone } = devices();
    await mac.store.block('work', offers);
    await mac.store.synchronize();
    await phone.store.synchronize();
    // The Mac writes the record between the phone's read and its write.
    const pull = phone.sync!.pullBlockedSenders;
    vi.spyOn(phone.sync!, 'pullBlockedSenders').mockImplementationOnce(
      async (owner, known) => {
        const stale = await pull(owner, known);
        await mac.store.block('work', deals);
        await mac.store.synchronize();
        return stale;
      },
    );
    const push = vi.spyOn(phone.sync!, 'pushBlockedSenders');
    vi.setSystemTime(november8 + 1000);
    await phone.store.block('work', 'news@growthleads.io');
    await phone.store.synchronize();
    await expect(
      Promise.all(push.mock.results.map(({ value }) => value)),
    ).resolves.toMatchObject([{ committed: false }, { committed: true }]);
    await mac.store.synchronize();
    for (const device of [mac, phone]) {
      const senders = await device.store.blockedSenders('work');
      expect(new Set(senders?.map(({ address }) => address))).toStrictEqual(
        new Set([offers, deals, 'news@growthleads.io']),
      );
    }
  });

  it('changes nothing for a record that does not open or names another Profile, and keeps it', async () => {
    expect.hasAssertions();
    const { server, mac, phone } = devices();
    await mac.store.block('work', offers);
    await mac.store.block('home', deals);
    await mac.store.synchronize();
    await phone.store.synchronize();

    // The work record served under the home Profile's identifier.
    const work = String(
      server.get('account-1', 'profile-blocked-senders.work')?.sealed,
    );
    server.replace('account-1', 'profile-blocked-senders.home', work);
    // A record that opens but names another Profile.
    server.replace(
      'account-1',
      'profile-blocked-senders.work',
      server.seal(
        'account-1',
        'profile-blocked-senders.work',
        JSON.stringify({
          id: 'work',
          version: 9,
          senders: JSON.stringify({
            profile: 'home',
            changes: [{ address: offers, blocked: false, at: november8 + 5 }],
          }),
        }),
      ),
    );
    const replaced = server.get(
      'account-1',
      'profile-blocked-senders.work',
    )?.sealed;
    vi.setSystemTime(november8 + 1000);
    await phone.store.block('home', 'news@growthleads.io');
    await phone.store.synchronize();
    await expect(phone.store.blockedSenders('work')).resolves.toStrictEqual([
      { profile: 'work', address: offers, blockedAt: november8, moved: 0 },
    ]);
    await expect(phone.store.blockedSenders('home')).resolves.toMatchObject([
      { address: deals },
      { address: 'news@growthleads.io' },
    ]);
    expect(
      server.get('account-1', 'profile-blocked-senders.home')?.sealed,
    ).toBe(work);
    expect(
      server.get('account-1', 'profile-blocked-senders.work')?.sealed,
    ).toBe(replaced);
  });

  it('adopts a newer key epoch and publishes the change it held', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const adoptKeyRotation = vi.fn<() => Promise<unknown>>(() =>
      Promise.resolve(),
    );
    const { store, sync } = storage(server, { adoptKeyRotation });
    vi.spyOn(sync!, 'pushBlockedSenders').mockRejectedValueOnce(
      Object.assign(new Error('rotated'), { code: 'key-rotation-required' }),
    );
    await store.block('work', offers);
    await store.synchronize();
    expect(adoptKeyRotation.mock.calls).toStrictEqual([[]]);
    expect(server.identifiers('account-1')).toStrictEqual([
      'profile-blocked-senders.work',
    ]);
  });

  it('reports a device removal native code found while synchronizing', async () => {
    expect.hasAssertions();
    const removed = vi.fn<() => void>();
    const { store, sync } = storage(createSyntheticProductSync(), {
      removed,
    });
    vi.spyOn(sync!, 'pullBlockedSenders').mockRejectedValue(
      Object.assign(new Error('revoked'), { code: 'mailbox-revoked' }),
    );
    vi.spyOn(console, 'error').mockReturnValue();
    await store.synchronize();
    expect(removed).toHaveBeenCalledWith();
  });
});

describe('blocked domains', () => {
  const receivedAt = '2026-11-08T09:00:00.000Z';
  const withSubdomains = { subdomains: true, exempt: [] };
  const arrival = (id: string, address: string) => ({
    id,
    address,
    receivedAt,
  });

  it('match one plain domain without case, in its ASCII form', () => {
    expect.hasAssertions();
    expect(blockedDomain(' @NW-Deals.com ')).toBe('nw-deals.com');
    expect(blockedDomain('xn--pple-43d.com')).toBe('xn--pple-43d.com');
    for (const refused of [
      'offers@nw-deals.com',
      'Northwind Deals',
      'nw-deals.com, northwind.io',
      'com',
      '\u0430pple.com',
      '\u212Aey.example',
      'nw-deals..com',
      '-nw-deals.com',
      '',
    ]) {
      expect(blockedDomain(refused)).toBeUndefined();
    }
  });

  const work = {
    profile: 'work',
    domain: 'nw-deals.com',
    subdomains: true,
    exempt: ['eva@nw-deals.com'],
    blockedAt: november8,
    moved: 0,
  };
  // Storage holding `work` and the home Profile's block of mail.nw-deals.com alone.
  const blocked = async () => {
    const stored = storage();
    await expect(
      stored.store.blockDomain('work', '@NW-Deals.com', {
        subdomains: true,
        exempt: ['Eva@nw-deals.com', 'eva@nw-deals.com'],
      }),
    ).resolves.toBe(true);
    await stored.store.blockDomain('home', 'mail.nw-deals.com', {
      subdomains: false,
      exempt: [],
    });
    return stored;
  };

  it('keeps each Profile its own Blocked Domains with their choices across a relaunch', async () => {
    expect.hasAssertions();
    const { relaunch } = await blocked();
    await expect(relaunch().blockedDomains('work')).resolves.toStrictEqual([
      work,
    ]);
    await expect(relaunch().blockedDomains('home')).resolves.toMatchObject([
      { domain: 'mail.nw-deals.com', subdomains: false },
    ]);
  });

  it('keeps the first date of the same choices and never stores an invalid domain or exemption', async () => {
    expect.hasAssertions();
    const error = vi.spyOn(console, 'error');
    const { state, store } = await blocked();
    const { commits } = state;
    vi.setSystemTime(november8 + 1000);
    await store.blockDomain('work', 'nw-deals.com', work);
    const refused = await Promise.all([
      ...['offers@nw-deals.com', 'Northwind Deals', 'com'].map((domain) =>
        store.blockDomain('work', domain, withSubdomains),
      ),
      store.blockDomain('work', 'nw-deals.com', {
        subdomains: true,
        exempt: ['Eva <eva@nw-deals.com>'],
      }),
      store.blockDomain('', 'nw-deals.com', withSubdomains),
    ]);
    expect(refused).toStrictEqual([false, false, false, false, false]);
    expect(state.commits).toBe(commits);
    expect(error).not.toHaveBeenCalled();
  });

  it("replaces a block's choices from now and unblocks one Profile's domain alone", async () => {
    expect.hasAssertions();
    const { store } = await blocked();
    // Moves before other choices count for the block they replace.
    await store.screen('work', { id: 'connection-1', moves: true }, [
      arrival('a', 'offers@nw-deals.com'),
    ]);
    vi.setSystemTime(november8 + 1000);
    await store.blockDomain('work', 'nw-deals.com', {
      subdomains: false,
      exempt: [],
    });
    await expect(store.blockedDomains('work')).resolves.toStrictEqual([
      { ...work, subdomains: false, exempt: [], blockedAt: november8 + 1000 },
    ]);
    await expect(store.unblockDomain('work', 'NW-deals.com')).resolves.toBe(
      true,
    );
    await expect(store.blockedDomains('work')).resolves.toStrictEqual([]);
    await expect(store.blockedDomains('home')).resolves.toHaveLength(1);
  });

  it('screens arrivals at the domain, its subdomains when chosen, and never a lookalike or exemption', async () => {
    expect.hasAssertions();
    const { store } = storage();
    await store.blockDomain('work', 'nw-deals.com', {
      subdomains: true,
      exempt: ['eva@nw-deals.com'],
    });
    await store.blockDomain('work', 'northwind.io', {
      subdomains: false,
      exempt: [],
    });
    const arrivals = [
      arrival('domain', 'offers@NW-Deals.com'),
      arrival('subdomain', 'offers@mail.nw-deals.com'),
      arrival('exempt', 'Eva@nw-deals.com'),
      arrival('suffix', 'offers@nw-deals.com.evil.io'),
      arrival('prefix', 'offers@xnw-deals.com'),
      arrival('lookalike', 'offers@xn--nw-dels-4ve.com'),
      arrival('only', 'news@northwind.io'),
      arrival('not-subdomain', 'news@mail.northwind.io'),
      arrival('display', 'NW Deals <offers@growthleads.io>'),
      // The Kelvin sign lowercases to an ASCII k.
      arrival('kelvin', 'offers@\u212Aey.nw-deals.com'),
    ];
    await expect(
      store.screen('work', { id: 'connection-1', moves: true }, arrivals),
    ).resolves.toStrictEqual({
      blocked: new Set(['domain', 'subdomain', 'only']),
      move: ['domain', 'subdomain', 'only'],
    });
    await expect(
      store.screen('home', { id: 'connection-2', moves: true }, arrivals),
    ).resolves.toStrictEqual({ blocked: new Set(), move: [] });
    await expect(store.blockedDomains('work')).resolves.toMatchObject([
      { domain: 'nw-deals.com', moved: 2 },
      { domain: 'northwind.io', moved: 1 },
    ]);
    // Unblocking stops new matches; what moved stays moved.
    await store.unblockDomain('work', 'nw-deals.com');
    await expect(
      store.screen('work', { id: 'connection-1', moves: true }, [
        arrival('later', 'offers@nw-deals.com'),
      ]),
    ).resolves.toStrictEqual({ blocked: new Set(), move: [] });
  });

  it('counts an arrival for its exact Blocked Sender before a Blocked Domain, and moves it once', async () => {
    expect.hasAssertions();
    const { store } = storage();
    await store.block('work', 'offers@nw-deals.com');
    await store.blockDomain('work', 'nw-deals.com', withSubdomains);
    const arrivals = [
      arrival('exact', 'offers@nw-deals.com'),
      arrival('domain', 'news@nw-deals.com'),
    ];
    await expect(
      store.screen('work', { id: 'connection-1', moves: true }, arrivals),
    ).resolves.toStrictEqual({
      blocked: new Set(['exact', 'domain']),
      move: ['exact', 'domain'],
    });
    await expect(
      store.screen('work', { id: 'connection-1', moves: true }, arrivals),
    ).resolves.toStrictEqual({
      blocked: new Set(['exact', 'domain']),
      move: [],
    });
    await expect(store.blockedSenders('work')).resolves.toMatchObject([
      { moved: 1 },
    ]);
    await expect(store.blockedDomains('work')).resolves.toMatchObject([
      { moved: 1 },
    ]);
  });

  // Two Trusted Devices of one Product Account sharing Product Sync, and what the work Profile's
  // record seals.
  const devices = () => {
    const server = createSyntheticProductSync();
    const identifier = 'profile-blocked-senders.work';
    const sealed = () =>
      Schema.decodeSync(Schema.fromJsonString(Schema.Unknown))(
        Option.getOrThrow(
          openRecord(
            server.open(
              String(server.get('account-1', identifier)?.sealed),
              'account-1',
              identifier,
            ),
          ),
        ).senders,
      );
    return { sealed, mac: storage(server), phone: storage(server) };
  };

  it('keeps a record without domains in the shape devices before Blocked Domains read', async () => {
    expect.hasAssertions();
    const { sealed, mac } = devices();
    await mac.store.block('work', 'offers@growthleads.io');
    await mac.store.synchronize();
    expect(sealed()).toStrictEqual({
      profile: 'work',
      changes: [
        { address: 'offers@growthleads.io', blocked: true, at: november8 },
      ],
    });
  });

  it('carries a domain block, its choices and its unblock to another device in the same Profile', async () => {
    expect.hasAssertions();
    const { sealed, mac, phone } = devices();
    await mac.store.blockDomain('work', 'nw-deals.com', {
      subdomains: true,
      exempt: ['eva@nw-deals.com'],
    });
    await mac.store.synchronize();
    await phone.store.synchronize();
    await expect(phone.store.blockedDomains('work')).resolves.toStrictEqual([
      {
        profile: 'work',
        domain: 'nw-deals.com',
        subdomains: true,
        exempt: ['eva@nw-deals.com'],
        blockedAt: november8,
        moved: 0,
      },
    ]);
    await expect(phone.store.blockedDomains('home')).resolves.toStrictEqual([]);

    vi.setSystemTime(november8 + 1000);
    await phone.store.unblockDomain('work', 'nw-deals.com');
    await phone.store.synchronize();
    await mac.store.synchronize();
    await expect(mac.store.blockedDomains('work')).resolves.toStrictEqual([]);
    expect(sealed()).toStrictEqual({
      profile: 'work',
      changes: [],
      domains: [
        { domain: 'nw-deals.com', blocked: false, at: november8 + 1000 },
      ],
    });
  });

  it('keeps the same one of two blocks of a domain made at the same instant on every device', async () => {
    expect.hasAssertions();
    const { sealed, mac, phone } = devices();
    await mac.store.blockDomain('work', 'nw-deals.com', withSubdomains);
    await phone.store.blockDomain('work', 'nw-deals.com', {
      subdomains: false,
      exempt: [],
    });
    await phone.store.synchronize();
    await mac.store.synchronize();
    await phone.store.synchronize();
    const record = sealed();
    await mac.store.synchronize();
    expect(sealed()).toStrictEqual(record);
    await expect(phone.store.blockedDomains('work')).resolves.toStrictEqual(
      await mac.store.blockedDomains('work'),
    );
    await expect(mac.store.blockedDomains('work')).resolves.toMatchObject([
      { subdomains: true },
    ]);
  });
});
