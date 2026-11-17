import type { NativePins } from '@private-email/mail-core/pins';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import { createPins } from '@private-email/mail-core/pins';

const november8 = Date.UTC(2026, 10, 8);

// Native Pin storage as the store sees it: one document for the signed-in account, replaced only
// from the revision read. The clock starts on 8 November.
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
  const native: NativePins = {
    openPins: () =>
      state.locked
        ? refuse('locked')
        : Promise.resolve({
            owner: state.account,
            revision: state.revision,
            document: state.owner === state.account ? state.document : null,
          }),
    commitPins: (owner, expectedRevision, document) => {
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
  const relaunch = () => createPins(native, registration);
  return { state, store: relaunch(), relaunch };
};

describe('stored Pins', () => {
  it("keeps each connection's Pins across a relaunch and lists only the connections asked for", async () => {
    expect.hasAssertions();
    const { store, relaunch } = storage();
    await expect(store.pins(['gmail'])).resolves.toStrictEqual([]);
    await expect(store.pin('gmail', 'thread-1')).resolves.toBe(true);
    vi.setSystemTime(november8 + 1000);
    await store.pin('imap', 'message-7');
    const relaunched = relaunch();
    await expect(relaunched.pins(['gmail'])).resolves.toStrictEqual([
      { connection: 'gmail', thread: 'thread-1', pinnedAt: november8 },
    ]);
    await expect(relaunched.pins(['imap', 'gmail'])).resolves.toStrictEqual([
      { connection: 'gmail', thread: 'thread-1', pinnedAt: november8 },
      { connection: 'imap', thread: 'message-7', pinnedAt: november8 + 1000 },
    ]);
    await expect(relaunched.pins([])).resolves.toStrictEqual([]);
  });

  it('unpins a Thread in one connection and leaves the same identity pinned in another', async () => {
    expect.hasAssertions();
    const { store } = storage();
    await store.pin('gmail', 'thread-1');
    await store.pin('outlook', 'thread-1');
    await expect(store.unpin('gmail', 'thread-1')).resolves.toBe(true);
    await expect(store.pins(['gmail', 'outlook'])).resolves.toStrictEqual([
      { connection: 'outlook', thread: 'thread-1', pinnedAt: november8 },
    ]);
  });

  it('keeps the first date of a Thread pinned again', async () => {
    expect.hasAssertions();
    const { state, store } = storage();
    await store.pin('gmail', 'thread-1');
    const { commits } = state;
    vi.setSystemTime(november8 + 1000);
    await expect(store.pin('gmail', 'thread-1')).resolves.toBe(true);
    // Unpinning a Thread that is not pinned writes nothing either.
    await expect(store.unpin('gmail', 'thread-2')).resolves.toBe(true);
    expect(state.commits).toBe(commits);
    await expect(store.pins(['gmail'])).resolves.toStrictEqual([
      { connection: 'gmail', thread: 'thread-1', pinnedAt: november8 },
    ]);
  });

  it('never stores a Pin without a connection or Thread', async () => {
    expect.hasAssertions();
    const error = vi.spyOn(console, 'error');
    const { state, store } = storage();
    await expect(store.pin('', 'thread-1')).resolves.toBe(false);
    await expect(store.pin('gmail', '')).resolves.toBe(false);
    await expect(store.unpin('', 'thread-1')).resolves.toBe(false);
    expect(state.commits + error.mock.calls.length).toBe(0);
  });

  it('pins and unpins without a verified Product Sign-In session', async () => {
    expect.hasAssertions();
    const { state, store, relaunch } = storage();
    state.kind = 'cached';
    await expect(store.pin('gmail', 'thread-1')).resolves.toBe(true);
    await expect(store.pin('gmail', 'thread-2')).resolves.toBe(true);
    await expect(store.unpin('gmail', 'thread-1')).resolves.toBe(true);
    await expect(relaunch().pins(['gmail'])).resolves.toStrictEqual([
      { connection: 'gmail', thread: 'thread-2', pinnedAt: november8 },
    ]);
  });

  it('changes nothing when another write moved the revision on', async () => {
    expect.hasAssertions();
    const error = vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    await store.pin('gmail', 'thread-1');
    const { document } = state;
    state.before = () => {
      state.revision += 1;
    };
    await expect(store.pin('gmail', 'thread-2')).resolves.toBe(false);
    expect(state.document).toBe(document);
    expect(error).toHaveBeenCalledWith(
      expect.anything(),
      'Pin storage failed:',
      'code conflict',
    );
  });

  it('reads and writes nothing while the device is locked', async () => {
    expect.hasAssertions();
    const error = vi.spyOn(console, 'error');
    const { state, store } = storage();
    state.locked = true;
    await expect(store.pin('gmail', 'thread-1')).resolves.toBe(false);
    await expect(store.pins(['gmail'])).resolves.toBeUndefined();
    expect(state.commits + error.mock.calls.length).toBe(0);
  });

  it("lists none of another account's Pins and writes nothing into them", async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    await store.pin('gmail', 'thread-1');
    const { document } = state;
    state.before = () => {
      state.account = 'account-2';
    };
    await expect(store.unpin('gmail', 'thread-1')).resolves.toBe(false);
    expect(state.document).toBe(document);
    await expect(store.pins(['gmail'])).resolves.toStrictEqual([]);
  });

  it('lists nothing from a stored document that does not decode', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    Object.assign(state, {
      owner: state.account,
      revision: 1,
      document: '{"pins":[{"connection":"gmail"}]}',
    });
    await expect(store.pins(['gmail'])).resolves.toBeUndefined();
    await expect(store.pin('gmail', 'thread-1')).resolves.toBe(false);
    expect(state.commits).toBe(0);
    state.document =
      '{"pins":[{"connection":"gmail","thread":"","pinnedAt":0}]}';
    await expect(store.pins(['gmail'])).resolves.toBeUndefined();
  });
});
