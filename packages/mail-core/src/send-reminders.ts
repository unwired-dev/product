import * as DateTime from 'effect/DateTime';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { DraftStorageFailure } from './draft-native.ts';
import type { Registration } from './registration.ts';

import { runLogged } from './diagnostics.ts';
import { malformed, native, ownerMismatch } from './draft-native.ts';
import { ownerOf } from './drafts.ts';

// A Send Reminder: the Draft it belongs to, the Mail Profile that owns that Draft, the instant it is
// due in milliseconds since the epoch and the time zone it was set in. It carries no Draft content
// and never authorizes delivery.
export const SendReminderSchema = Schema.Struct({
  draft: Schema.NonEmptyString,
  profile: Schema.NonEmptyString,
  dueAt: Schema.Int,
  timeZone: Schema.String.check(
    Schema.makeFilter((zone) => Option.isSome(DateTime.zoneMakeNamed(zone))),
  ),
});
export type SendReminder = typeof SendReminderSchema.Type;

const isReminder = Schema.is(SendReminderSchema);
const DocumentSchema = Schema.fromJsonString(
  Schema.Struct({ reminders: Schema.Array(SendReminderSchema) }),
);
const OpenedSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  document: Schema.NullOr(DocumentSchema),
});
const CommittedSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
});

// The signed-in Product Account's Send Reminders on this device: one document native code keeps
// encrypted for the account that wrote it, like its Mail Templates. Every call rejects with
// 'locked' while the device is locked.
export interface NativeSendReminders {
  // Resolves `{ owner, revision, document }`; `document` is null when the account has none.
  readonly openSendReminders: () => Promise<unknown>;
  // Replaces the document only from `expectedRevision` and resolves `{ owner, revision }`.
  readonly commitSendReminders: (
    owner: string,
    expectedRevision: number,
    document: string,
  ) => Promise<unknown>;
}

// Locked storage is expected while the device is locked; any other failure is logged.
const report = (
  error: Readonly<Pick<DraftStorageFailure, 'kind' | 'diagnostic'>>,
) =>
  error.kind === 'locked'
    ? Effect.void
    : Effect.logError('Send Reminder storage failed:', error.diagnostic);

// Each Draft's Send Reminder, stored on this device without network access. Reminders are not
// synchronized and notify nobody yet.
export function createSendReminders(
  storage: NativeSendReminders,
  registration: Pick<Registration, 'getSnapshot'>,
) {
  const semaphore = Semaphore.makeUnsafe(1);
  const signedIn = () => ownerOf(registration.getSnapshot().snapshot);
  // The Send Reminders of `account`, the Product Account signed in when the action was called, so
  // an action that waited, or whose read finished, while another account signed in reads and
  // writes nothing of it.
  const opened = (account: string | undefined) =>
    Effect.gen(function* () {
      const { owner, revision, document } = yield* native(
        storage.openSendReminders,
        OpenedSchema,
      );
      if (owner !== account || signedIn() !== account) {
        return yield* ownerMismatch();
      }
      return { owner, revision, reminders: document?.reminders ?? [] };
    });

  // Resolves whether storage holds what `change` makes of `profile`'s Draft `draft` reminder:
  // another Profile's reminder for that Draft is refused, and returning the reminders unchanged
  // writes nothing.
  const changing = (
    profile: string,
    draft: string,
    change: (others: readonly SendReminder[]) => readonly SendReminder[],
  ) => {
    const account = signedIn();
    return runLogged(
      Effect.gen(function* () {
        const { owner, revision, reminders } = yield* opened(account);
        const current = reminders.find((reminder) => reminder.draft === draft);
        if (current !== undefined && current.profile !== profile) {
          return false;
        }
        const next = change(reminders.filter((each) => each !== current));
        if (current === undefined && next.length === reminders.length) {
          return true;
        }
        const document = yield* Schema.encodeEffect(DocumentSchema)({
          reminders: next,
        }).pipe(Effect.mapError(malformed));
        const committed = yield* native(
          () => storage.commitSendReminders(owner, revision, document),
          CommittedSchema,
        );
        if (committed.owner !== owner) {
          return yield* ownerMismatch();
        }
        return true;
      }).pipe(
        semaphore.withPermit,
        // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
        Effect.catchTag('DraftStorageFailure', (error) =>
          report(error).pipe(Effect.as(false)),
        ),
      ),
    );
  };

  return {
    // `profile`'s Send Reminders, or undefined while storage cannot read them.
    reminders: (profile: string) =>
      runLogged(
        opened(signedIn()).pipe(
          Effect.map(({ reminders }) =>
            reminders.filter((reminder) => reminder.profile === profile),
          ),
          // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
          Effect.catchTag('DraftStorageFailure', (error) =>
            report(error).pipe(Effect.as(undefined)),
          ),
        ),
      ),
    // Sets the Draft's one reminder for `profile`, replacing the one it has. Resolves whether
    // storage holds it; an invalid instant or time zone is never stored.
    remind: (profile: string, reminder: Omit<SendReminder, 'profile'>) => {
      const stored = { ...reminder, profile };
      return isReminder(stored)
        ? changing(profile, stored.draft, (others) => [...others, stored])
        : Promise.resolve(false);
    },
    // Removes `profile`'s reminder for Draft `draft`. Resolves whether storage no longer holds it.
    cancel: (profile: string, draft: string) =>
      changing(profile, draft, (others) => others),
  };
}
export type SendReminders = ReturnType<typeof createSendReminders>;

const dayLength = 86_400_000;

// `at`'s date and time on the clocks of `timeZone`, counted as if they were UTC, or none in a time
// zone the platform does not know. Effect's zoned DateTime reads the offset from the time zone's
// name, which Hermes splits into parts ("GMT", "+", "01", …), so on the device it reads every
// offset as zero; the date and time parts read the same everywhere.
const wallClock = (timeZone: string) =>
  Option.map(DateTime.zoneMakeNamed(timeZone), () => {
    const format = new Intl.DateTimeFormat('en-US', {
      timeZone,
      hourCycle: 'h23',
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
      hour: 'numeric',
      minute: 'numeric',
    });
    return (at: number) => {
      const parts = new Map(
        format
          .formatToParts(at)
          .map(({ type, value }) => [type, Number(value)]),
      );
      const part = (type: Intl.DateTimeFormatPartTypes) => parts.get(type) ?? 0;
      return Date.UTC(
        part('year'),
        part('month') - 1,
        part('day'),
        part('hour'),
        part('minute'),
      );
    };
  });

// The instant `clock` reads `wall` at, its offset taken where that instant falls.
const instantAt = (clock: (at: number) => number, wall: number) => {
  const guess = wall - (clock(wall) - wall);
  return wall - (clock(guess) - guess);
};

const hourLength = 3_600_000;

// The choices `offer` builds from `now` in `timeZone`, the device's, where `at(days, hour)` is
// `hour` o'clock `days` after today and `weekday` today's, 1 Monday to 7 Sunday. None in a time
// zone the platform does not know.
const offerFrom = <A>(
  now: number,
  timeZone: string,
  offer: (at: (days: number, hour: number) => number, weekday: number) => A[],
): A[] =>
  Option.match(wallClock(timeZone), {
    onNone: () => [],
    onSome: (clock) => {
      const today = Math.floor(clock(now) / dayLength);
      return offer(
        (days, hour) =>
          instantAt(clock, (today + days) * dayLength + hour * hourLength),
        // 1 January 1970 was a Thursday.
        ((today + 3) % 7) + 1,
      );
    },
  });

// The times the Mac reminder menu offers: This Evening at 20:00 while it is still ahead, then
// Tomorrow Morning at 9:00.
export const reminderTimes = (now: number, timeZone: string) =>
  offerFrom(now, timeZone, (at) => {
    const evening = at(0, 20);
    return [
      ...(evening > now
        ? [{ time: 'thisEvening', dueAt: evening } as const]
        : []),
      { time: 'tomorrowMorning', dueAt: at(1, 9) } as const,
    ];
  });

// The times the iPhone and iPad reminder choices offer, as their frames draw them: This Evening at
// 18:00 while it is still ahead, Tomorrow Morning at 8:00, with `weekend` (iPhone) This Weekend on
// Saturday at 9:00 from Sunday to Thursday, and Next Week on the first Monday after tomorrow at
// 8:00.
export const mobileReminderTimes = (
  now: number,
  timeZone: string,
  weekend: boolean,
) =>
  offerFrom(now, timeZone, (at, weekday) => {
    // Days to the first `day` (1 Monday to 7 Sunday) after tomorrow.
    const after = (day: number) => ((day - weekday + 12) % 7) + 2;
    const evening = at(0, 18);
    const saturday = after(6);
    return [
      ...(evening > now
        ? [{ time: 'thisEvening', dueAt: evening } as const]
        : []),
      { time: 'tomorrowMorning', dueAt: at(1, 8) } as const,
      ...(weekend && saturday < 7
        ? [{ time: 'thisWeekend', dueAt: at(saturday, 9) } as const]
        : []),
      { time: 'nextWeek', dueAt: at(after(1), 8) } as const,
    ];
  });

// How many days after `now`'s day the reminder is due, both days in the reminder's time zone: 0
// today, 1 tomorrow.
export const reminderDay = (
  { dueAt, timeZone }: Pick<SendReminder, 'dueAt' | 'timeZone'>,
  now: number,
) => {
  const clock = Option.getOrElse(wallClock(timeZone), () => (at: number) => at);
  const day = (at: number) => Math.floor(clock(at) / dayLength);
  return day(dueAt) - day(now);
};

// The city a time zone is named after, such as Prague for Europe/Prague.
export const reminderCity = (timeZone: string) =>
  (timeZone.split('/').at(-1) ?? timeZone).replaceAll('_', ' ');
