import type {
  NativeInboxPreferenceSync,
  NativeInboxPreferences,
} from '@private-email/mail-core/inbox-preferences';
import type { FavoriteEntries } from '@private-email/mail-core/mailboxes';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import { createInboxPreferences } from '@private-email/mail-core/inbox-preferences';
import {
  favoriteRows,
  folderRows,
  moveFavorite,
  moveFolder,
  sectionFolders,
  sectionShown,
  toggleFavorite,
  showFolder,
} from '@private-email/mail-core/mailboxes';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type { SyntheticProductSync } from '../src/testing/drafts.ts';

import { createSyntheticProductSync } from '../src/testing/drafts.ts';

const november8 = Date.UTC(2026, 10, 8);
const prefix = 'profile-inbox-preferences.';

const decodePulled = Schema.decodeUnknownSync(
  Schema.Struct({
    records: Schema.Array(
      Schema.Struct({ preferences: Schema.fromJsonString(Schema.Unknown) }),
    ),
  }),
);
const openRecord = Schema.decodeUnknownOption(
  Schema.fromJsonString(
    Schema.Struct({
      id: Schema.String,
      version: Schema.Finite,
      preferences: Schema.String,
    }),
  ),
);

// Product Sync as native code moves Inbox preference records for `owner`: one record per Mail
// Profile under an identifier derived from its own.
const remote = (server: SyntheticProductSync): NativeInboxPreferenceSync => ({
  pullInboxPreferences: (owner, known) => {
    const refused = server.reach();
    if (refused !== undefined) {
      return Promise.reject(refused);
    }
    const opened = server
      .list(owner, prefix)
      .map(({ identifier, sealed, updatedAt }) => {
        const record = Option.getOrUndefined(
          openRecord(server.open(sealed, owner, identifier) ?? ''),
        );
        return record === undefined || identifier !== `${prefix}${record.id}`
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
            identifier === `${prefix}${id}` && record === undefined,
        ),
      ),
    });
  },
  pushInboxPreferences: async (
    owner,
    { id, version, preferences, expectedUpdatedAt },
  ) => {
    const refused = server.reach();
    if (refused !== undefined) {
      throw refused;
    }
    const identifier = `${prefix}${id}`;
    return {
      owner,
      ...server.put(owner, identifier, {
        sealed: server.seal(
          owner,
          identifier,
          JSON.stringify({ id, version, preferences }),
        ),
        expected: expectedUpdatedAt,
      }),
    };
  },
});

// Native Inbox preference storage as the store sees it: one document for the signed-in account,
// replaced only from the revision read. The clock starts on 8 November. With `server`, the store
// also synchronizes through it.
const storage = (server?: SyntheticProductSync) => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(november8);
  onTestFinished(() => {
    vi.useRealTimers();
  });
  const state: {
    account: string;
    locked: boolean;
    revision: number;
    owner?: string;
    document?: string;
    commits: number;
  } = { account: 'account-1', locked: false, revision: 0, commits: 0 };
  const refuse = (code: string) =>
    Promise.reject(Object.assign(new Error(code), { code }));
  const native: NativeInboxPreferences = {
    openInboxPreferences: () =>
      state.locked
        ? refuse('locked')
        : Promise.resolve({
            owner: state.account,
            revision: state.revision,
            document: state.owner === state.account ? state.document : null,
          }),
    commitInboxPreferences: (owner, expectedRevision, document) => {
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
  const registration = {
    getSnapshot: () => ({
      snapshot: {
        kind: 'connected',
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
    createInboxPreferences(
      native,
      registration,
      sync === undefined ? undefined : { native: sync },
    );
  return { state, store: relaunch(), relaunch, sync };
};

describe('stored Inbox preferences', () => {
  it("keeps each Profile's list density across a relaunch, Comfortable by default", async () => {
    expect.hasAssertions();
    const { store, relaunch } = storage();
    const initial = store.listDensity('work');
    const listener = vi.fn<() => void>();
    store.subscribe(listener);
    const stored = await store.setListDensity('work', 'compact');
    const relaunched = relaunch();
    const unread = relaunched.listDensity('work');
    await relaunched.load();
    expect({
      initial,
      stored,
      notified: listener.mock.calls.length > 0,
      chosen: [store.listDensity('work'), store.listDensity('home')],
      unread,
      relaunched: relaunched.listDensity('work'),
    }).toStrictEqual({
      initial: 'comfortable',
      stored: true,
      notified: true,
      chosen: ['compact', 'comfortable'],
      unread: 'comfortable',
      relaunched: 'compact',
    });
  });

  it('keeps the choice while the device is locked, and shows none of another account', async () => {
    expect.hasAssertions();
    const error = vi.spyOn(console, 'error');
    const { state, store } = storage();
    await store.setListDensity('work', 'compact');
    state.locked = true;
    const whileLocked = await store.setListDensity('work', 'comfortable');
    const kept = store.listDensity('work');
    state.locked = false;
    state.account = 'account-2';
    const signedOver = store.listDensity('work');
    await store.load();
    expect({
      whileLocked,
      kept,
      signedOver,
      loaded: store.listDensity('work'),
      logged: error.mock.calls,
    }).toStrictEqual({
      whileLocked: false,
      kept: 'compact',
      signedOver: 'comfortable',
      loaded: 'comfortable',
      logged: [],
    });
  });

  it('reports a failed read as unreadable for its own account only, until a read succeeds', async () => {
    expect.hasAssertions();
    const { state, store } = storage();
    await store.load();
    state.locked = true;
    await store.load();
    const failed = [store.unreadable(), store.sections('work')];
    state.account = 'account-2';
    const signedOver = store.unreadable();
    // Another account's failure keeps this one's, so its earlier read stays unused.
    await store.load();
    state.account = 'account-1';
    const back = [store.unreadable(), store.sections('work')];
    state.locked = false;
    await store.load();
    expect({
      failed,
      signedOver,
      back,
      read: [store.unreadable(), store.sections('work')],
    }).toStrictEqual({
      failed: [true, undefined],
      signedOver: false,
      back: [true, undefined],
      read: [false, {}],
    });
  });
});

describe('synchronized Inbox preferences', () => {
  // Two Trusted Devices of one Product Account sharing Product Sync.
  const devices = () => {
    const server = createSyntheticProductSync();
    return { server, mac: storage(server), phone: storage(server) };
  };

  it('carries a density to another device in the same Profile only', async () => {
    expect.hasAssertions();
    const { server, mac, phone } = devices();
    await mac.store.setListDensity('work', 'compact');
    await mac.store.synchronize();
    await phone.store.synchronize();
    expect(phone.store.listDensity('work')).toBe('compact');
    expect(phone.store.listDensity('home')).toBe('comfortable');
    // Convex names the record by its Profile alone.
    expect(server.identifiers('account-1')).toStrictEqual([`${prefix}work`]);

    vi.setSystemTime(november8 + 1000);
    await phone.store.setListDensity('work', 'comfortable');
    await phone.store.synchronize();
    await mac.store.synchronize();
    expect(mac.store.listDensity('work')).toBe('comfortable');
  });

  it("sets several Profiles' preview length in one write, kept across a relaunch and carried to another device", async () => {
    expect.hasAssertions();
    const { mac, phone } = devices();
    const initial = mac.store.previewLines('work');
    const stored = await mac.store.setPreviewLines(['default', 'work'], 3);
    const { commits } = mac.state;
    const relaunched = mac.relaunch();
    await relaunched.load();
    await mac.store.synchronize();
    await phone.store.synchronize();
    expect({
      initial,
      stored,
      commits,
      relaunched: [
        relaunched.previewLines('default'),
        relaunched.previewLines('work'),
        relaunched.previewLines('home'),
      ],
      phone: [
        phone.store.previewLines('work'),
        phone.store.listDensity('work'),
      ],
    }).toStrictEqual({
      initial: undefined,
      stored: true,
      commits: 1,
      relaunched: [3, 3, undefined],
      phone: [3, 'comfortable'],
    });
  });

  it("carries a Profile's Favorites, kept across a relaunch, to another device, keeping a row a newer build added", async () => {
    expect.hasAssertions();
    const { mac, phone } = devices();
    // Two edits sent before either is read both stand, and a newer build's row keeps its place.
    const [stored] = await Promise.all([
      mac.store.changeFavorites('work', (entries) =>
        toggleFavorite([{ row: 'UNREAD', shown: false }, ...entries], 'SPAM'),
      ),
      mac.store.changeFavorites('work', (entries) =>
        moveFavorite(entries, 'TRASH', 1),
      ),
    ]);
    const relaunched = mac.relaunch();
    await relaunched.load();
    await mac.store.synchronize();
    await phone.store.synchronize();
    // The rows the sidebar shows, in order.
    const rows = (entries: FavoriteEntries) =>
      favoriteRows(entries)
        .filter(({ shown }) => shown)
        .map(({ row }) => row);
    const initial = rows(phone.store.favorites('home'));
    expect({
      initial,
      stored,
      relaunched: rows(relaunched.favorites('work')),
      phone: phone.store.favorites('work'),
      home: phone.store.favorites('home'),
    }).toStrictEqual({
      initial: ['ALL_INBOXES', 'SENT', 'ARCHIVE', 'ALL_MAIL', 'SPAM', 'TRASH'],
      stored: true,
      relaunched: ['ALL_INBOXES', 'TRASH', 'SENT', 'ARCHIVE', 'ALL_MAIL'],
      phone: [
        { row: 'UNREAD', shown: false },
        { row: 'ALL_INBOXES', shown: true },
        { row: 'TRASH', shown: true },
        { row: 'SENT', shown: true },
        { row: 'ARCHIVE', shown: true },
        { row: 'ALL_MAIL', shown: true },
        { row: 'SPAM', shown: false },
      ],
      home: [],
    });
  });

  it("carries a Profile's hidden accounts and its folders' order to another device; edits each device made before either pulled all stand, an Inbox stays shown and a folder another device lists keeps its place", async () => {
    expect.hasAssertions();
    const { mac, phone } = devices();
    const names = ['INBOX', 'Archive', 'Receipts', 'Travel'];
    // Before either pulls, the phone hides an account while the Mac hides one of that account's
    // folders and edits the other account's, hiding one that only it lists.
    const stored = await phone.store.showSection('work', 'fastmail', false);
    await Promise.all([
      mac.store.changeFolders('work', 'fastmail', (folders) =>
        showFolder(folders, ['INBOX', 'Spam'], { name: 'Spam', shown: false }),
      ),
      mac.store.changeFolders('work', 'gmail', (folders) =>
        showFolder(folders, ['Elsewhere'], { name: 'Elsewhere', shown: false }),
      ),
      mac.store.changeFolders('work', 'gmail', (folders) =>
        showFolder(folders, names, { name: 'Travel', shown: false }),
      ),
      mac.store.changeFolders('work', 'gmail', (folders) =>
        showFolder(folders, names, { name: 'INBOX', shown: false }),
      ),
      mac.store.changeFolders('work', 'gmail', (folders) =>
        moveFolder(folders, names, { name: 'Receipts', to: () => 0 }),
      ),
    ]);
    await phone.store.synchronize();
    await mac.store.synchronize();
    await phone.store.synchronize();
    const sections = { ...mac.store.sections('work') };
    expect({
      stored,
      unread: phone.relaunch().sections('work'),
      shown: ['gmail', 'fastmail'].map((id) => sectionShown(sections, id)),
      folders: folderRows(sectionFolders(sections, 'gmail'), [...names, 'New']),
      kept: sectionFolders(sections, 'gmail').at(-1),
      fastmail: sectionFolders(sections, 'fastmail'),
      same: phone.store.sections('work'),
      home: phone.store.sections('home'),
    }).toStrictEqual({
      stored: true,
      unread: undefined,
      shown: [true, false],
      folders: [
        { name: 'Receipts', shown: true },
        { name: 'INBOX', shown: true },
        { name: 'Archive', shown: true },
        { name: 'Travel', shown: false },
        { name: 'New', shown: true },
      ],
      kept: { name: 'Elsewhere', shown: false },
      fastmail: [
        { name: 'INBOX', shown: true },
        { name: 'Spam', shown: false },
      ],
      same: sections,
      home: {},
    });
  });

  it("writes nothing for an Inbox tap, so another device's folder hide stands", async () => {
    expect.hasAssertions();
    const { mac, phone } = devices();
    const names = ['INBOX', 'Travel'];
    await mac.store.changeFolders('work', 'gmail', (folders) =>
      showFolder(folders, names, { name: 'Travel', shown: false }),
    );
    await mac.store.synchronize();
    // The phone has yet to pull the hide when its Inbox row is tapped, later.
    vi.setSystemTime(november8 + 1000);
    await phone.store.changeFolders('work', 'gmail', (folders) =>
      showFolder(folders, names, { name: 'INBOX', shown: false }),
    );
    await phone.store.synchronize();
    expect(
      folderRows(
        sectionFolders({ ...phone.store.sections('work') }, 'gmail'),
        names,
      ),
    ).toStrictEqual([
      { name: 'INBOX', shown: true },
      { name: 'Travel', shown: false },
    ]);
  });

  it.each([
    ['the Mac', ['mac', 'phone', 'mac']],
    ['the phone', ['phone', 'mac', 'phone']],
  ] as const)(
    'converges on the later choice when %s synchronizes first, and publishes offline choices',
    async (_first, order) => {
      expect.hasAssertions();
      const { server, mac, phone } = devices();
      server.setReachable(false);
      await mac.store.setListDensity('work', 'compact');
      vi.setSystemTime(november8 + 10);
      await phone.store.setListDensity('work', 'comfortable');
      await phone.store.setListDensity('work', 'compact');
      vi.setSystemTime(november8 + 20);
      await mac.store.setListDensity('work', 'comfortable');
      await mac.store.synchronize();
      expect(server.identifiers('account-1')).toStrictEqual([]);

      server.setReachable(true);
      const named = { mac, phone };
      for (const device of order) {
        await named[device].store.synchronize();
      }
      expect(mac.store.listDensity('work')).toBe('comfortable');
      expect(phone.store.listDensity('work')).toBe('comfortable');
    },
  );

  it('writes again from the newer record when another device wrote meanwhile', async () => {
    expect.hasAssertions();
    const { mac, phone } = devices();
    await mac.store.setListDensity('work', 'compact');
    await mac.store.synchronize();
    // The Mac writes the record between the phone's read and its write.
    const pull = phone.sync!.pullInboxPreferences;
    vi.spyOn(phone.sync!, 'pullInboxPreferences').mockImplementationOnce(
      async (owner, known) => {
        const stale = await pull(owner, known);
        vi.setSystemTime(november8 + 500);
        await mac.store.setListDensity('home', 'compact');
        await mac.store.synchronize();
        return stale;
      },
    );
    const push = vi.spyOn(phone.sync!, 'pushInboxPreferences');
    vi.setSystemTime(november8 + 1000);
    await phone.store.setListDensity('home', 'comfortable');
    await phone.store.synchronize();
    await expect(
      Promise.all(push.mock.results.map(({ value }) => value)),
    ).resolves.toMatchObject([{ committed: false }, { committed: true }]);
    await mac.store.synchronize();
    for (const device of [mac, phone]) {
      expect(device.store.listDensity('work')).toBe('compact');
      expect(device.store.listDensity('home')).toBe('comfortable');
    }
  });

  it('changes nothing for a record that does not open or names another Profile, and keeps it', async () => {
    expect.hasAssertions();
    const { server, mac, phone } = devices();
    await mac.store.setListDensity('work', 'compact');
    await mac.store.setListDensity('home', 'compact');
    await mac.store.synchronize();
    await phone.store.synchronize();

    // The work record served under the home Profile's identifier.
    const work = String(server.get('account-1', `${prefix}work`)?.sealed);
    server.replace('account-1', `${prefix}home`, work);
    // A record that opens but names another Profile.
    server.replace(
      'account-1',
      `${prefix}work`,
      server.seal(
        'account-1',
        `${prefix}work`,
        JSON.stringify({
          id: 'work',
          version: 9,
          preferences: JSON.stringify({
            profile: 'home',
            fields: { density: { value: 'comfortable', at: november8 + 5 } },
          }),
        }),
      ),
    );
    const replaced = server.get('account-1', `${prefix}work`)?.sealed;
    vi.setSystemTime(november8 + 1000);
    await phone.store.setListDensity('home', 'comfortable');
    await phone.store.synchronize();
    expect(phone.store.listDensity('work')).toBe('compact');
    expect(phone.store.listDensity('home')).toBe('comfortable');
    expect(server.get('account-1', `${prefix}home`)?.sealed).toBe(work);
    expect(server.get('account-1', `${prefix}work`)?.sealed).toBe(replaced);
  });

  it('keeps and publishes a preference a newer build wrote', async () => {
    expect.hasAssertions();
    const { server, mac } = devices();
    const newer = {
      density: { value: 'compact', at: november8 },
      previewLines: { value: 3, at: november8 },
    };
    const sealed = (fields: object) =>
      server.seal(
        'account-1',
        `${prefix}work`,
        JSON.stringify({
          id: 'work',
          version: 1,
          preferences: JSON.stringify({ profile: 'work', fields }),
        }),
      );
    server.put('account-1', `${prefix}work`, {
      sealed: sealed(newer),
      expected: undefined,
    });
    await mac.store.synchronize();
    expect(mac.store.listDensity('work')).toBe('compact');

    vi.setSystemTime(november8 + 1000);
    await mac.store.setListDensity('work', 'comfortable');
    await mac.store.synchronize();
    const pulled = decodePulled(
      await remote(server).pullInboxPreferences('account-1', []),
    );
    expect(pulled.records).toStrictEqual([
      {
        preferences: {
          profile: 'work',
          fields: {
            density: { value: 'comfortable', at: november8 + 1000 },
            previewLines: { value: 3, at: november8 },
          },
        },
      },
    ]);
  });
});
