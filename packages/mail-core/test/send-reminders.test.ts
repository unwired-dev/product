import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type { NativeSendReminders } from '@private-email/mail-core/send-reminders';

import { createSendReminders } from '@private-email/mail-core/send-reminders';

// Tomorrow, 09:00 in Prague, as the approved banner shows it.
const tomorrowMorning = Date.UTC(2026, 10, 13, 8);
const keys = {
  draft: 'keys-for-the-flat',
  dueAt: tomorrowMorning,
  timeZone: 'Europe/Prague',
};

// Native Send Reminder storage as the store sees it: one document for the signed-in account,
// replaced only from the revision read.
const storage = () => {
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
  const native: NativeSendReminders = {
    openSendReminders: () =>
      state.locked
        ? refuse('locked')
        : Promise.resolve({
            owner: state.account,
            revision: state.revision,
            document: state.owner === state.account ? state.document : null,
          }),
    commitSendReminders: (owner, expectedRevision, document) => {
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
  const relaunch = () => createSendReminders(native, registration);
  return { state, store: relaunch(), relaunch };
};

describe('stored Send Reminders', () => {
  it("keeps each Profile its own Drafts' reminders across a relaunch", async () => {
    expect.hasAssertions();
    const { store, relaunch } = storage();
    await expect(store.reminders('work')).resolves.toStrictEqual([]);
    await expect(store.remind('work', keys)).resolves.toBe(true);
    await store.remind('home', {
      draft: 'photos-from-the-wedding',
      dueAt: tomorrowMorning + 3_600_000,
      timeZone: 'America/New_York',
    });
    const relaunched = relaunch();
    await expect(relaunched.reminders('work')).resolves.toStrictEqual([
      { ...keys, profile: 'work' },
    ]);
    await expect(relaunched.reminders('home')).resolves.toStrictEqual([
      {
        draft: 'photos-from-the-wedding',
        profile: 'home',
        dueAt: tomorrowMorning + 3_600_000,
        timeZone: 'America/New_York',
      },
    ]);
  });

  it('replaces a Draft’s reminder and cancels it', async () => {
    expect.hasAssertions();
    const { store } = storage();
    await store.remind('work', keys);
    const evening = { ...keys, dueAt: tomorrowMorning + 11 * 3_600_000 };
    await expect(store.remind('work', evening)).resolves.toBe(true);
    await expect(store.reminders('work')).resolves.toStrictEqual([
      { ...evening, profile: 'work' },
    ]);
    await expect(store.cancel('work', keys.draft)).resolves.toBe(true);
    await expect(store.reminders('work')).resolves.toStrictEqual([]);
  });

  it('writes nothing to cancel a Draft without a reminder', async () => {
    expect.hasAssertions();
    const { state, store } = storage();
    await expect(store.cancel('work', keys.draft)).resolves.toBe(true);
    expect(state.commits).toBe(0);
  });

  it("refuses to set or cancel another Profile's Draft reminder", async () => {
    expect.hasAssertions();
    const { state, store } = storage();
    await store.remind('work', keys);
    const { document, commits } = state;
    await expect(store.remind('home', keys)).resolves.toBe(false);
    await expect(store.cancel('home', keys.draft)).resolves.toBe(false);
    expect(state).toMatchObject({ document, commits });
    await expect(store.reminders('home')).resolves.toStrictEqual([]);
  });

  it('never stores an invalid instant, time zone, Draft or Profile', async () => {
    expect.hasAssertions();
    const error = vi.spyOn(console, 'error');
    const { state, store } = storage();
    for (const refused of [
      { ...keys, dueAt: tomorrowMorning + 0.5 },
      { ...keys, dueAt: Number.NaN },
      { ...keys, dueAt: Number.POSITIVE_INFINITY },
      { ...keys, timeZone: 'Prague' },
      { ...keys, timeZone: '' },
      { ...keys, draft: '' },
    ]) {
      await expect(store.remind('work', refused)).resolves.toBe(false);
    }
    await expect(store.remind('', keys)).resolves.toBe(false);
    expect(state.commits + error.mock.calls.length).toBe(0);
  });

  it('sets and cancels without a verified Product Sign-In session', async () => {
    expect.hasAssertions();
    const { state, store, relaunch } = storage();
    state.kind = 'cached';
    await expect(store.remind('work', keys)).resolves.toBe(true);
    await expect(
      store.remind('work', { ...keys, draft: 'invoice' }),
    ).resolves.toBe(true);
    await expect(store.cancel('work', keys.draft)).resolves.toBe(true);
    await expect(relaunch().reminders('work')).resolves.toStrictEqual([
      { ...keys, draft: 'invoice', profile: 'work' },
    ]);
  });

  it('changes nothing when another write moved the revision on', async () => {
    expect.hasAssertions();
    const error = vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    await store.remind('work', keys);
    const { document } = state;
    state.before = () => {
      state.revision += 1;
    };
    await expect(store.cancel('work', keys.draft)).resolves.toBe(false);
    expect(state.document).toBe(document);
    expect(error).toHaveBeenCalledWith(
      expect.anything(),
      'Send Reminder storage failed:',
      'code conflict',
    );
  });

  it('reads and writes nothing while the device is locked', async () => {
    expect.hasAssertions();
    const error = vi.spyOn(console, 'error');
    const { state, store } = storage();
    state.locked = true;
    await expect(store.remind('work', keys)).resolves.toBe(false);
    await expect(store.reminders('work')).resolves.toBeUndefined();
    expect(state.commits + error.mock.calls.length).toBe(0);
  });

  it("lists none of another account's reminders and writes nothing into them", async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    await store.remind('work', keys);
    const { document } = state;
    state.before = () => {
      state.account = 'account-2';
    };
    await expect(store.cancel('work', keys.draft)).resolves.toBe(false);
    expect(state.document).toBe(document);
    await expect(store.reminders('work')).resolves.toStrictEqual([]);
  });

  it('lists nothing from a stored document that does not decode or holds an invalid reminder', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { state, store } = storage();
    Object.assign(state, {
      owner: state.account,
      revision: 1,
      document: '{"reminders":[{"draft":"keys-for-the-flat"}]}',
    });
    await expect(store.reminders('work')).resolves.toBeUndefined();
    await expect(store.remind('work', keys)).resolves.toBe(false);
    expect(state.commits).toBe(0);
    state.document = JSON.stringify({
      reminders: [{ ...keys, profile: 'work', timeZone: 'Mars/Olympus' }],
    });
    await expect(store.reminders('work')).resolves.toBeUndefined();
  });
});
