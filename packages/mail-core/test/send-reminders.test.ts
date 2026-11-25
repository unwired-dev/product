import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type {
  NativeSendReminderSync,
  NativeSendReminders,
  SendReminder,
} from '@private-email/mail-core/send-reminders';

import {
  createSendReminders,
  reminderCity,
  reminderDay,
  mobileReminderTimes,
  reminderTimes,
} from '@private-email/mail-core/send-reminders';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type { SyntheticProductSync } from '../src/testing/drafts.ts';

import { createSyntheticProductSync } from '../src/testing/drafts.ts';

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

const openRecord = Schema.decodeUnknownOption(
  Schema.fromJsonString(
    Schema.Struct({
      id: Schema.String,
      version: Schema.Finite,
      reminder: Schema.String,
    }),
  ),
);

// Product Sync as native code moves reminder records for `owner`: one record per Draft under an
// identifier derived from the Draft's.
const remote = (server: SyntheticProductSync): NativeSendReminderSync => ({
  pullSendReminders: (owner, known) => {
    const refused = server.reach();
    if (refused !== undefined) {
      return Promise.reject(refused);
    }
    const opened = server
      .list(owner, 'send-reminder.')
      .map(({ identifier, sealed, updatedAt }) => {
        const record = Option.getOrUndefined(
          openRecord(server.open(sealed, owner, identifier) ?? ''),
        );
        return record === undefined ||
          identifier !== `send-reminder.${record.id}`
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
            identifier === `send-reminder.${id}` && record === undefined,
        ),
      ),
    });
  },
  pushSendReminder: async (
    owner,
    { id, version, reminder, expectedUpdatedAt },
  ) => {
    const refused = server.reach();
    if (refused !== undefined) {
      throw refused;
    }
    const identifier = `send-reminder.${id}`;
    return {
      owner,
      ...server.put(owner, identifier, {
        sealed: server.seal(
          owner,
          identifier,
          JSON.stringify({ id, version, reminder }),
        ),
        expected: expectedUpdatedAt,
      }),
    };
  },
});

// Native Send Reminder storage as the store sees it: one document for the signed-in account,
// replaced only from the revision read. With `server`, the store also synchronizes through it.
const storage = (server?: SyntheticProductSync) => {
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
  const sync = server === undefined ? undefined : remote(server);
  const relaunch = () =>
    createSendReminders(
      native,
      registration,
      sync === undefined ? undefined : { native: sync },
    );
  return { state, store: relaunch(), relaunch, sync };
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

  it("refuses to set, and never cancels, another Profile's Draft reminder", async () => {
    expect.hasAssertions();
    const { state, store } = storage();
    await store.remind('work', keys);
    const { document, commits } = state;
    await expect(store.remind('home', keys)).resolves.toBe(false);
    await expect(store.cancel('home', keys.draft)).resolves.toBe(true);
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

describe('synchronized Send Reminders', () => {
  // Two Trusted Devices of one Product Account sharing Product Sync.
  const devices = () => {
    const server = createSyntheticProductSync();
    const mac = storage(server);
    const phone = storage(server);
    return { server, mac: mac.store, phone: phone.store, macSync: mac.sync };
  };
  const evening = { ...keys, dueAt: tomorrowMorning + 11 * 3_600_000 };
  // The stored record of `profile`'s reminder for `draft`.
  const recordOf = (profile: string, draft: string) =>
    `send-reminder.${JSON.stringify([profile, draft])}`;
  // Each reminder as a device shows it: its day after `now`'s and its time zone's city.
  const shownAs =
    (now: number) => (reminders: readonly SendReminder[] | undefined) =>
      reminders?.map((reminder) => ({
        ...reminder,
        day: reminderDay(reminder, now),
        city: reminderCity(reminder.timeZone),
      }));
  // What a stored record seals, as native code holds it.
  const sealedRecord = Schema.decodeUnknownSync(
    Schema.fromJsonString(
      Schema.Struct({ reminder: Schema.fromJsonString(Schema.Unknown) }),
    ),
  );

  it('carries a reminder set offline to another device, in the time zone it was set in', async () => {
    expect.hasAssertions();
    const { server, mac, phone } = devices();
    server.setReachable(false);
    await expect(mac.remind('work', keys)).resolves.toBe(true);
    await mac.synchronize();
    server.setReachable(true);
    await mac.synchronize();
    await phone.synchronize();
    // The other device shows it as set: tomorrow, 09:00 in Prague.
    await expect(
      phone.reminders('work').then(shownAs(Date.UTC(2026, 10, 12, 12))),
    ).resolves.toStrictEqual([
      { ...keys, profile: 'work', day: 1, city: 'Prague' },
    ]);
  });

  it("carries a reminder's change and its removal to another device", async () => {
    expect.hasAssertions();
    const { mac, phone } = devices();
    await mac.remind('work', keys);
    await mac.synchronize();
    await phone.synchronize();
    await phone.remind('work', evening);
    await phone.synchronize();
    await mac.synchronize();
    await expect(mac.reminders('work')).resolves.toStrictEqual([
      { ...evening, profile: 'work' },
    ]);

    // Sending or discarding the Draft cancels its reminder, which the other device then drops.
    await mac.cancel('work', keys.draft);
    await mac.synchronize();
    await phone.synchronize();
    await expect(phone.reminders('work')).resolves.toStrictEqual([]);
  });

  it('removes a reminder of a Draft sent or discarded before the reminder arrived', async () => {
    expect.hasAssertions();
    const { server, mac, phone } = devices();
    await mac.remind('work', keys);
    await mac.synchronize();
    await expect(phone.cancel('work', keys.draft)).resolves.toBe(true);
    await phone.synchronize();
    await mac.synchronize();
    await expect(phone.reminders('work')).resolves.toStrictEqual([]);
    await expect(mac.reminders('work')).resolves.toStrictEqual([]);

    // Also before the reminder reached Product Sync.
    const invoice = { ...keys, draft: 'invoice' };
    server.setReachable(false);
    await mac.remind('work', invoice);
    await mac.synchronize();
    await phone.cancel('work', invoice.draft);
    await phone.synchronize();
    server.setReachable(true);
    await phone.synchronize();
    await mac.synchronize();
    await phone.synchronize();
    await expect(phone.reminders('work')).resolves.toStrictEqual([]);
    await expect(mac.reminders('work')).resolves.toStrictEqual([]);
  });

  it('lets a Draft reminded again after a cancellation take the first write', async () => {
    expect.hasAssertions();
    const { mac, phone } = devices();
    await mac.remind('work', keys);
    await mac.synchronize();
    await phone.cancel('work', keys.draft);
    await phone.remind('work', evening);
    await phone.synchronize();
    await mac.synchronize();
    for (const device of [mac, phone]) {
      await expect(device.reminders('work')).resolves.toStrictEqual([
        { ...keys, profile: 'work' },
      ]);
    }
  });

  it('converges concurrent rescheduling on one reminder on both devices', async () => {
    expect.hasAssertions();
    const { mac, phone } = devices();
    await mac.remind('work', keys);
    await mac.synchronize();
    await phone.synchronize();

    await mac.remind('work', evening);
    await phone.remind('work', { ...keys, timeZone: 'America/New_York' });
    await mac.synchronize();
    await phone.synchronize();
    await mac.synchronize();

    const merged = [{ ...evening, profile: 'work' }];
    await expect(mac.reminders('work')).resolves.toStrictEqual(merged);
    await expect(phone.reminders('work')).resolves.toStrictEqual(merged);
  });

  it('never restores a removed reminder from a stale change', async () => {
    expect.hasAssertions();
    const { mac, phone } = devices();
    await mac.remind('work', keys);
    await mac.synchronize();
    await phone.synchronize();

    // Removed on one device, rescheduled offline on the other first or after.
    await mac.cancel('work', keys.draft);
    await phone.remind('work', evening);
    await mac.synchronize();
    await phone.synchronize();
    await mac.synchronize();
    await expect(mac.reminders('work')).resolves.toStrictEqual([]);
    await expect(phone.reminders('work')).resolves.toStrictEqual([]);

    await mac.remind('work', keys);
    await mac.synchronize();
    await phone.synchronize();
    await phone.remind('work', evening);
    await mac.cancel('work', keys.draft);
    await phone.synchronize();
    await mac.synchronize();
    await phone.synchronize();
    await expect(mac.reminders('work')).resolves.toStrictEqual([]);
    await expect(phone.reminders('work')).resolves.toStrictEqual([]);
  });

  it("leaves another Profile's reminders alone and seals no Draft content", async () => {
    expect.hasAssertions();
    const { server, mac, phone } = devices();
    const home = {
      draft: 'photos-from-the-wedding',
      dueAt: tomorrowMorning,
      timeZone: 'America/New_York',
    };
    const moved = { ...keys, dueAt: tomorrowMorning + 60_000 };
    await mac.remind('work', keys);
    await phone.remind('home', home);
    // The same Draft under another Profile, as after its connection moved between Profiles.
    await phone.remind('home', moved);
    await mac.synchronize();
    await phone.synchronize();
    await mac.synchronize();
    await expect(mac.reminders('home')).resolves.toStrictEqual([
      { ...home, profile: 'home' },
      { ...moved, profile: 'home' },
    ]);
    await expect(phone.cancel('home', keys.draft)).resolves.toBe(true);
    await phone.synchronize();
    await mac.synchronize();

    for (const device of [mac, phone]) {
      await expect(device.reminders('work')).resolves.toStrictEqual([
        { ...keys, profile: 'work' },
      ]);
      await expect(device.reminders('home')).resolves.toStrictEqual([
        { ...home, profile: 'home' },
      ]);
    }
    // Each record seals the reminder, or its removal, and a write identifier, and nothing of the
    // Draft.
    expect(
      server
        .list('account-1', 'send-reminder.')
        .map(
          ({ identifier, sealed }) =>
            sealedRecord(server.open(sealed, 'account-1', identifier)).reminder,
        ),
    ).toStrictEqual([
      { reminder: { ...keys, profile: 'work' }, write: expect.any(String) },
      { reminder: { ...home, profile: 'home' }, write: expect.any(String) },
      { reminder: null, write: expect.any(String) },
    ]);
  });

  it('changes nothing for a record that does not open, was moved or is older', async () => {
    expect.hasAssertions();
    const { server, mac, phone } = devices();
    const invoice = { ...keys, draft: 'invoice' };
    await mac.remind('work', keys);
    await mac.remind('work', invoice);
    await mac.synchronize();
    await phone.synchronize();
    const first = server.get('account-1', recordOf('work', keys.draft))?.sealed;
    await mac.remind('work', evening);
    await mac.synchronize();
    await phone.synchronize();
    const current = await phone.reminders('work');

    server.replace('account-1', recordOf('work', keys.draft), String(first));
    const moved = server.get('account-1', recordOf('work', keys.draft))?.sealed;
    server.replace('account-1', recordOf('work', 'invoice'), String(moved));
    await phone.synchronize();
    await expect(phone.reminders('work')).resolves.toStrictEqual(current);

    // A record that does not open is never taken for a removal, nor overwritten.
    server.replace('account-1', recordOf('work', 'invoice'), 'damaged');
    await phone.cancel('work', 'invoice');
    await phone.synchronize();
    expect(server.get('account-1', recordOf('work', 'invoice'))?.sealed).toBe(
      'damaged',
    );
  });

  it('takes back its own write whose reply was lost', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { server, mac, phone } = devices();
    server.loseNextReply();
    await mac.remind('work', keys);
    await mac.synchronize();
    await mac.synchronize();
    await phone.synchronize();

    const synced = [{ ...keys, profile: 'work' }];
    await expect(mac.reminders('work')).resolves.toStrictEqual(synced);
    await expect(phone.reminders('work')).resolves.toStrictEqual(synced);
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
