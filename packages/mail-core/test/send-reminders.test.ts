import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type { NativeSendReminders } from '@private-email/mail-core/send-reminders';

import {
  createSendReminders,
  reminderDay,
  mobileReminderTimes,
  reminderTimes,
} from '@private-email/mail-core/send-reminders';

// Tomorrow, 09:00 in Prague, as the approved banner shows it.
const tomorrowMorning = Date.UTC(2026, 10, 13, 8);
const keys = {
  draft: 'keys-for-the-flat',
  dueAt: tomorrowMorning,
  timeZone: 'Europe/Prague',
};

// A formatted part as Hermes gives it: GMT+01:00 as "GMT", then "+", "01" and ":00" apart.
const splitOffset = (
  part: Intl.DateTimeFormatPart,
): Intl.DateTimeFormatPart[] => {
  const offset = /^GMT(?<sign>[+-])(?<hours>\d\d):(?<minutes>\d\d)$/u.exec(
    part.value,
  );
  if (part.type !== 'timeZoneName' || offset === null) {
    return [part];
  }
  const { sign = '', hours = '', minutes = '' } = offset.groups ?? {};
  return [
    { type: 'timeZoneName', value: 'GMT' },
    { type: 'literal', value: sign },
    { type: 'minute', value: hours },
    { type: 'literal', value: `:${minutes}` },
  ];
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

describe('reminder menu times', () => {
  it('offers this evening at 20:00 only while it is ahead, and tomorrow at 9:00 across a clock change', () => {
    expect.hasAssertions();
    // Saturday 24 October 2026, 10:00 in Prague; summer time ends that night.
    const morning = Date.UTC(2026, 9, 24, 8);
    expect(reminderTimes(morning, 'Europe/Prague')).toStrictEqual([
      { time: 'thisEvening', dueAt: Date.UTC(2026, 9, 24, 18) },
      { time: 'tomorrowMorning', dueAt: Date.UTC(2026, 9, 25, 8) },
    ]);
    const night = Date.UTC(2026, 9, 24, 18, 30);
    expect(reminderTimes(night, 'Europe/Prague')).toStrictEqual([
      { time: 'tomorrowMorning', dueAt: Date.UTC(2026, 9, 25, 8) },
    ]);
    expect(reminderTimes(morning, 'Mars/Olympus')).toStrictEqual([]);
  });

  it('offers the iPhone and iPad times, This Weekend on iPhone only from Sunday to Thursday', () => {
    expect.hasAssertions();
    // Monday 12 October 2026, noon in Prague.
    const monday = Date.UTC(2026, 9, 12, 10);
    expect(mobileReminderTimes(monday, 'Europe/Prague', true)).toStrictEqual([
      { time: 'thisEvening', dueAt: Date.UTC(2026, 9, 12, 16) },
      { time: 'tomorrowMorning', dueAt: Date.UTC(2026, 9, 13, 6) },
      { time: 'thisWeekend', dueAt: Date.UTC(2026, 9, 17, 7) },
      { time: 'nextWeek', dueAt: Date.UTC(2026, 9, 19, 6) },
    ]);
    // Sunday 25 October 2026, 10:00 in Prague, after summer time ended: Next Week skips tomorrow.
    const sunday = Date.UTC(2026, 9, 25, 9);
    expect(mobileReminderTimes(sunday, 'Europe/Prague', true)).toStrictEqual([
      { time: 'thisEvening', dueAt: Date.UTC(2026, 9, 25, 17) },
      { time: 'tomorrowMorning', dueAt: Date.UTC(2026, 9, 26, 7) },
      { time: 'thisWeekend', dueAt: Date.UTC(2026, 9, 31, 8) },
      { time: 'nextWeek', dueAt: Date.UTC(2026, 10, 2, 7) },
    ]);
    // Friday 13 November 2026, 19:30 in Prague: the evening has passed and the weekend is next.
    const friday = Date.UTC(2026, 10, 13, 18, 30);
    const fridayTimes = [
      { time: 'tomorrowMorning', dueAt: Date.UTC(2026, 10, 14, 7) },
      { time: 'nextWeek', dueAt: Date.UTC(2026, 10, 16, 7) },
    ];
    expect(
      [true, false].map((weekend) =>
        mobileReminderTimes(friday, 'Europe/Prague', weekend),
      ),
    ).toStrictEqual([fridayTimes, fridayTimes]);
    expect(mobileReminderTimes(monday, 'Europe/Prague', false)).toHaveLength(3);
    expect(mobileReminderTimes(monday, 'Mars/Olympus', true)).toStrictEqual([]);
  });

  it('reads the same times where the engine splits the time zone offset into parts, as Hermes does', () => {
    expect.hasAssertions();
    const { formatToParts } = Intl.DateTimeFormat.prototype;
    const split = vi
      .spyOn(Intl.DateTimeFormat.prototype, 'formatToParts')
      .mockImplementation(function (this: Intl.DateTimeFormat, at) {
        return formatToParts.call(this, at).flatMap(splitOffset);
      });
    try {
      // Friday 13 November 2026, 14:28 in Prague.
      const afternoon = Date.UTC(2026, 10, 13, 13, 28);
      expect(reminderTimes(afternoon, 'Europe/Prague')).toStrictEqual([
        { time: 'thisEvening', dueAt: Date.UTC(2026, 10, 13, 19) },
        { time: 'tomorrowMorning', dueAt: Date.UTC(2026, 10, 14, 8) },
      ]);
      expect(reminderDay(keys, Date.UTC(2026, 10, 12, 23, 30))).toBe(0);
    } finally {
      split.mockRestore();
    }
  });

  it('counts the due day in the reminder’s own time zone', () => {
    expect.hasAssertions();
    // 23:30 UTC on 12 November is already 13 November in Prague.
    const lateEvening = Date.UTC(2026, 10, 12, 23, 30);
    expect(reminderDay(keys, lateEvening)).toBe(0);
    expect(reminderDay(keys, lateEvening - 3_600_000)).toBe(1);
  });
});
