import type { NativeBlockedSenders } from '@private-email/mail-core/blocked-senders';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import {
  blockedAddress,
  createBlockedSenders,
} from '@private-email/mail-core/blocked-senders';

const november8 = Date.UTC(2026, 10, 8);

// Native Blocked Sender storage as the store sees it: one document for the signed-in account,
// replaced only from the revision read. The clock starts on 8 November.
const storage = () => {
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
  const relaunch = () => createBlockedSenders(native, registration);
  return { state, store: relaunch(), relaunch };
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
      },
    ]);
    await expect(relaunched.blockedSenders('home')).resolves.toStrictEqual([
      {
        profile: 'home',
        address: 'offers@growthleads.io',
        blockedAt: november8 + 1000,
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
      },
    ]);
  });

  it('never stores a display name, domain or list', async () => {
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
      { profile: 'work', address: 'news@growthleads.io', blockedAt: november8 },
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
});
