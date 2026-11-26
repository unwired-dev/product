import type { Translate } from '@private-email/localization';

import * as DateTime from 'effect/DateTime';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { Draft } from './draft-model.ts';
import type { DraftsState } from './drafts.ts';
import type { NotificationSettings } from './notifications.ts';
import type { Registration } from './registration.ts';

import { rejectionDiagnostic, runLogged } from './diagnostics.ts';
import { malformed, native, ownerMismatch } from './draft-native.ts';
import {
  preferencePasses,
  PushedSchema,
  reportPreference,
} from './draft-sync.ts';
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
const Version = Schema.Int.check(Schema.isGreaterThanOrEqualTo(1));
const NullableReminder = Schema.NullOr(SendReminderSchema);
const sameReminder = Schema.toEquivalence(NullableReminder);
// A reminder's Private Sync record as this device last read or wrote it: the record's identifier,
// naming the Mail Profile and Draft, its write count, its Convex revision, the reminder, null once
// removed, and the random identifier of the write that made it.
const SyncedSchema = Schema.Struct({
  id: Schema.NonEmptyString,
  version: Version,
  updatedAt: Schema.Finite,
  reminder: NullableReminder,
  write: Schema.NonEmptyString,
});
type Synced = typeof SyncedSchema.Type;
const SentSchema = Schema.Struct({
  id: Schema.NonEmptyString,
  version: Version,
  write: Schema.NonEmptyString,
});
type Sent = typeof SentSchema.Type;
const StoredDocumentSchema = Schema.Struct({
  reminders: Schema.Array(SendReminderSchema),
  // Each record's base: a reminder that differs from it has a change to publish.
  synced: Schema.optionalKey(Schema.Array(SyncedSchema)),
  // Each write sent and not yet known to have landed or lost, so reading one back after a lost
  // reply is no conflict.
  sent: Schema.optionalKey(Schema.Array(SentSchema)),
  // Each record a Send or Discard here removed while Private Sync may not hold the removal yet,
  // with a random token: a removal to publish until a write made since is known to have landed.
  cancelled: Schema.optionalKey(
    Schema.Array(
      Schema.Struct({
        id: Schema.NonEmptyString,
        token: Schema.NonEmptyString,
      }),
    ),
  ),
  // Each record whose current reminder this device set, so its notification is this device's to
  // post; one another device's record set is none. Reminders stored before notify nowhere.
  notifies: Schema.optionalKey(Schema.Array(Schema.NonEmptyString)),
});
type Reminders = typeof StoredDocumentSchema.Type;
const DocumentSchema = Schema.fromJsonString(StoredDocumentSchema);
const sameDocument = Schema.toEquivalence(StoredDocumentSchema);
const OpenedSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  document: Schema.NullOr(DocumentSchema),
});
const CommittedSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
});
const PulledSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  records: Schema.Array(
    Schema.Struct({
      id: Schema.NonEmptyString,
      version: Version,
      updatedAt: Schema.Finite,
      // Decoded one by one, so a record this device cannot read changes nothing.
      reminder: Schema.NullOr(Schema.String),
    }),
  ),
  unreadable: Schema.Array(Schema.NonEmptyString),
});
// What a record seals: the Draft's reminder, null once removed, and its write's identifier, so this
// device tells its own writes from another device's identical one.
const RecordJsonSchema = Schema.fromJsonString(
  Schema.Struct({ reminder: NullableReminder, write: Schema.NonEmptyString }),
);
const decodeRecord = Schema.decodeUnknownOption(RecordJsonSchema);
// Native code accepts a Private Sync record identifier of at most 200 characters.
const publishable = (id: string) => id.length <= 200;

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

// The account's Send Reminders in Private Sync, one record per Mail Profile and Draft. Native code
// seals each record to the account and an opaque identifier derived from the record's, so Convex
// holds only ciphertext. Every call rejects with 'unavailable' while this device holds no keys or Product
// Sign-In session.
export interface NativeSendReminderSync {
  // Resolves `{ owner, records: [{ id, version, updatedAt, reminder }], unreadable }`, `reminder`
  // being the JSON the record seals. `unreadable` names the records of `known` that exist but do not
  // open here.
  readonly pullSendReminders: (
    owner: string,
    known: readonly string[],
  ) => Promise<unknown>;
  // Writes record `id`, sealing `reminder` (the reminder or its removal, as JSON), only
  // while it is still at `expectedUpdatedAt` (absent: while there is none). Resolves
  // `{ owner, committed, updatedAt? }`.
  readonly pushSendReminder: (
    owner: string,
    record: Readonly<{
      id: string;
      version: number;
      reminder: string;
      expectedUpdatedAt?: number;
    }>,
  ) => Promise<unknown>;
}

const report = reportPreference('Send Reminder');

// A reminder's record identifier: its Mail Profile and Draft, so another Profile's reminder for the
// same Draft is a record of its own.
const recordId = ({
  profile,
  draft,
}: Pick<SendReminder, 'profile' | 'draft'>) => JSON.stringify([profile, draft]);
const byRecord = (reminders: readonly SendReminder[]) =>
  new Map(reminders.map((reminder) => [recordId(reminder), reminder]));
const byId = <T extends Readonly<{ id: string }>>(items: readonly T[] = []) =>
  new Map(items.map((item) => [item.id, item]));

// Each record whose reminder differs from the record it was made from, or that a cancellation
// removes, with that record: a change, or a removal, to publish.
const pendingOf = ({ reminders, synced, cancelled }: Reminders) => {
  const live = byRecord(reminders);
  const bases = byId(synced);
  const removals = byId(cancelled);
  return [
    ...new Set([...live.keys(), ...bases.keys(), ...removals.keys()]),
  ].flatMap((id) => {
    const reminder = live.get(id) ?? null;
    const base = bases.get(id);
    const cancellation = removals.get(id)?.token;
    return sameReminder(base?.reminder ?? null, reminder) &&
      cancellation === undefined
      ? []
      : [{ id, reminder, base, cancellation }];
  });
};

// A random identifier for one write, as Draft assets are named.
const writeId = () => {
  let id = '';
  while (id.length < 24) {
    id += Math.random().toString(36).slice(2);
  }
  return id.slice(0, 24);
};

// Takes one record newer than the one this device read. This device's own write read back, as after
// a lost reply, changes nothing. A reminder without a change to publish takes the record. A removal
// wins either way, so a stale write never restores a removed reminder: a pending removal, also a
// cancellation, outlives the record, and a removal record ends a pending change. Of two changes,
// the one written first wins, so both devices end with one reminder.
// fallow-ignore-next-line complexity -- Each condition is one merge rule above.
const adoptRecord = (
  {
    live,
    bases,
    sent,
    cancelled,
    notifies,
  }: Readonly<{
    live: Map<string, SendReminder>;
    bases: Map<string, Synced>;
    sent: Set<Sent>;
    cancelled: ReadonlyMap<string, unknown>;
    notifies: Set<string>;
  }>,
  record: Synced,
) => {
  const local = live.get(record.id) ?? null;
  const pending = !sameReminder(bases.get(record.id)?.reminder ?? null, local);
  const own = [...sent].some(
    ({ id, write }) => id === record.id && write === record.write,
  );
  bases.set(record.id, record);
  for (const item of sent) {
    if (item.id === record.id && item.version <= record.version) {
      sent.delete(item);
    }
  }
  if (own || (pending && local === null) || cancelled.has(record.id)) {
    return;
  }
  notifies.delete(record.id);
  if (record.reminder === null) {
    live.delete(record.id);
  } else {
    live.set(record.id, record.reminder);
  }
};

// Merges records another device wrote. A version authenticates one immutable record, so an older or
// replayed one changes nothing.
const adopt = (document: Reminders, records: readonly Synced[]) => {
  const live = byRecord(document.reminders);
  const bases = byId(document.synced);
  const sent = new Set(document.sent);
  const cancelled = byId(document.cancelled);
  const notifies = new Set(document.notifies);
  for (const record of records.filter(
    ({ id, version }) => version > (bases.get(id)?.version ?? 0),
  )) {
    adoptRecord({ live, bases, sent, cancelled, notifies }, record);
  }
  const next = {
    ...document,
    reminders: [...live.values()],
    synced: [...bases.values()],
    sent: [...sent],
    ...(document.notifies === undefined ? {} : { notifies: [...notifies] }),
  };
  return sameDocument(document, next) ? document : next;
};

// The records this device can read; one that does not decode, or names another Draft, is
// unreadable and changes nothing.
const readable = (pulled: typeof PulledSchema.Type) => {
  const unreadable = new Set(pulled.unreadable);
  const records = pulled.records.flatMap(({ reminder: json, ...record }) => {
    const sealed = Option.getOrUndefined(decodeRecord(json ?? ''));
    if (
      sealed === undefined ||
      (sealed.reminder !== null && recordId(sealed.reminder) !== record.id)
    ) {
      unreadable.add(record.id);
      return [];
    }
    return [{ ...record, ...sealed }];
  });
  return { records, unreadable };
};

// `document` knowing a committed write, unless it already knows one as new, and no longer holding
// the cancellation the write carried.
const settled = (
  document: Reminders,
  written: Synced,
  cancellation: string | undefined,
) => {
  const base = document.synced?.find(({ id }) => id === written.id);
  if (base !== undefined && base.version >= written.version) {
    return document;
  }
  return {
    ...document,
    synced: [
      ...(document.synced ?? []).filter(({ id }) => id !== written.id),
      written,
    ],
    sent: (document.sent ?? []).filter(
      ({ id, version }) => id !== written.id || version > written.version,
    ),
    cancelled: (document.cancelled ?? []).filter(
      ({ token }) => token !== cancellation,
    ),
  };
};

// Each Draft's Send Reminder, stored on this device without network access. With `sync`, reminders
// also synchronize through Private Sync: after each change and on `synchronize`. The device that set
// a reminder's current value posts its notification (`notifying`).
export function createSendReminders(
  storage: NativeSendReminders,
  registration: Pick<Registration, 'getSnapshot'>,
  sync?: Readonly<{
    native: NativeSendReminderSync;
    // Called when native code purged the account because this device was removed.
    removed?: () => void;
    // Adopts a key epoch another device's removal moved the account to.
    adoptKeyRotation?: () => Promise<unknown>;
  }>,
) {
  const semaphore = Semaphore.makeUnsafe(1);
  // Told after each change this device stores, such as a reminder another device set, and after
  // each synchronization, so a read that failed meanwhile is made again.
  const listeners = new Set<() => void>();
  const notify = () => {
    for (const listener of listeners) {
      listener();
    }
  };
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
      return { owner, revision, document: document ?? { reminders: [] } };
    });

  // Stores what `change` makes of `account`'s stored reminders and resolves it. It refuses with
  // undefined, and returning the document unchanged writes nothing.
  const changed = (
    account: string | undefined,
    change: (document: Reminders) => Reminders | undefined,
  ) =>
    Effect.gen(function* () {
      const { owner, revision, document } = yield* opened(account);
      const next = change(document);
      if (next === undefined || next === document) {
        return next;
      }
      const encoded = yield* Schema.encodeEffect(DocumentSchema)(next).pipe(
        Effect.mapError(malformed),
      );
      const committed = yield* native(
        () => storage.commitSendReminders(owner, revision, encoded),
        CommittedSchema,
      );
      if (committed.owner !== owner) {
        return yield* ownerMismatch();
      }
      notify();
      return next;
    }).pipe(semaphore.withPermit);

  // Publishes one change by compare-and-set from the record it was made from, remembering the write
  // first so reading it back after a lost reply is no conflict. Its version is above every write of
  // the Draft's reminder that may still land, so each write is told apart. Resolves whether another
  // device's write won.
  const publish = Effect.fnUntraced(function* (
    remote: NativeSendReminderSync,
    account: string,
    {
      id,
      reminder,
      base,
      cancellation,
      sent,
    }: Readonly<
      ReturnType<typeof pendingOf>[number] & { sent: readonly Sent[] }
    >,
  ) {
    const version =
      Math.max(
        base?.version ?? 0,
        ...sent.filter((item) => item.id === id).map((item) => item.version),
      ) + 1;
    const write = writeId();
    const json = yield* Schema.encodeEffect(RecordJsonSchema)({
      reminder,
      write,
    }).pipe(Effect.mapError(malformed));
    yield* changed(account, (stored) => ({
      ...stored,
      sent: [...(stored.sent ?? []), { id, version, write }],
    }));
    const pushed: typeof PushedSchema.Type = yield* native(
      () =>
        remote.pushSendReminder(account, {
          id,
          version,
          reminder: json,
          ...(base === undefined ? {} : { expectedUpdatedAt: base.updatedAt }),
        }),
      PushedSchema,
    );
    if (pushed.owner !== account) {
      return yield* ownerMismatch();
    }
    if (!pushed.committed) {
      return true;
    }
    const written = {
      id,
      version,
      updatedAt: pushed.updatedAt,
      reminder,
      write,
    };
    yield* changed(account, (stored) => settled(stored, written, cancellation));
    return false;
  });

  // One pass: adopts what other devices wrote, then publishes each change it can. A change to a
  // Draft whose record does not open here waits, and one for a Draft identifier native code cannot
  // publish stays on this device. Resolves whether another device's write won meanwhile.
  const pass = Effect.fnUntraced(function* (remote: NativeSendReminderSync) {
    const account = signedIn();
    if (account === undefined) {
      return false;
    }
    const { document } = yield* opened(account);
    const pulled = yield* native(
      () =>
        remote.pullSendReminders(
          account,
          (document.synced ?? []).map(({ id }) => id),
        ),
      PulledSchema,
    );
    if (pulled.owner !== account) {
      return yield* ownerMismatch();
    }
    const { records, unreadable } = readable(pulled);
    const adopted = yield* changed(account, (stored) => adopt(stored, records));
    const current = adopted ?? document;
    let conflicted = false;
    for (const change of pendingOf(current).filter(
      ({ id }) => !unreadable.has(id) && publishable(id),
    )) {
      conflicted =
        (yield* publish(remote, account, {
          ...change,
          sent: current.sent ?? [],
        })) || conflicted;
    }
    return conflicted;
  });

  const passes = preferencePasses('Send Reminder', pass, sync);
  const synchronize = async () => {
    await passes();
    notify();
  };

  // Resolves whether storage holds `reminder`, or its removal when null, as `profile`'s reminder for
  // Draft `draft`, then publishes it. A reminder for a Draft another Profile's reminder names is
  // refused. With Private Sync, each removal is also kept as a cancellation to publish, so a reminder
  // another device set meanwhile is removed when it arrives.
  const changing = async (
    profile: string,
    draft: string,
    reminder: SendReminder | null,
  ) => {
    const id = recordId({ profile, draft });
    const stored = await runLogged(
      changed(signedIn(), (document) => {
        const current = document.reminders.find(
          (each) => recordId(each) === id,
        );
        const others = document.reminders.filter((each) => each !== current);
        const notifies = (document.notifies ?? []).filter(
          (each) => each !== id,
        );
        if (reminder !== null) {
          // Choosing the value it already has is no new revision, so it moves no notification.
          if (current !== undefined && sameReminder(current, reminder)) {
            return document;
          }
          return current === undefined &&
            others.some((each) => each.draft === draft)
            ? undefined
            : {
                ...document,
                reminders: [...others, reminder],
                cancelled: (document.cancelled ?? []).filter(
                  (each) => each.id !== id,
                ),
                notifies: [...notifies, id],
              };
        }
        if (sync !== undefined) {
          return {
            ...document,
            reminders: others,
            cancelled: [
              ...(document.cancelled ?? []).filter((each) => each.id !== id),
              { id, token: writeId() },
            ],
            notifies,
          };
        }
        return current === undefined
          ? document
          : { ...document, reminders: others, notifies };
      }).pipe(
        Effect.map((next) => next !== undefined),
        Effect.catchTag('DraftStorageFailure', (error) =>
          report(error).pipe(Effect.as(false)),
        ),
      ),
    );
    if (stored) {
      void synchronize();
    }
    return stored;
  };

  return {
    // `profile`'s Send Reminders, or undefined while storage cannot read them.
    reminders: (profile: string) =>
      runLogged(
        opened(signedIn()).pipe(
          Effect.map(({ document }) =>
            document.reminders.filter(
              (reminder) => reminder.profile === profile,
            ),
          ),
          // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
          Effect.catchTag('DraftStorageFailure', (error) =>
            report(error).pipe(Effect.as(undefined)),
          ),
        ),
      ),
    // Every Profile's reminders whose notification this device posts, those it set itself, with the
    // account that owns them; undefined while storage cannot read them.
    notifying: () =>
      runLogged(
        opened(signedIn()).pipe(
          Effect.map(({ owner, document }) => {
            const notifies = new Set(document.notifies);
            return {
              owner,
              reminders: document.reminders.filter((reminder) =>
                notifies.has(recordId(reminder)),
              ),
            };
          }),
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
        ? changing(profile, stored.draft, stored)
        : Promise.resolve(false);
    },
    // Removes `profile`'s reminder for Draft `draft`. Resolves whether storage no longer holds it.
    cancel: (profile: string, draft: string) => changing(profile, draft, null),
    // Merges Private Sync into this device's reminders and publishes this device's changes;
    // resolves once no pass is running.
    synchronize,
    // Calls `listener` after each change this device stores and after each synchronization;
    // returns its removal.
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
}
export type SendReminders = ReturnType<typeof createSendReminders>;

// A due reminder's notification, as native code schedules it for its due instant. Its identifier
// names the reminder's record and instant, so a changed instant withdraws the old notification, and
// marks one that shows the Draft, which native code withdraws when previews are turned off.
const ScheduledReminderSchema = Schema.Struct({
  id: Schema.String,
  title: Schema.String,
  body: Schema.String,
  // Groups it with its Mail Profile's other notifications.
  profile: Schema.String,
  dueAt: Schema.Int,
  previews: Schema.Boolean,
});
type ScheduledReminder = typeof ScheduledReminderSchema.Type;
// What one scheduling handed native code: for whom, under which permission, and the notifications.
const sameScheduling = Schema.toEquivalence(
  Schema.Struct({
    owner: Schema.String,
    authorization: Schema.String,
    notifications: Schema.Array(ScheduledReminderSchema),
  }),
);

// The native host's Send Reminder notifications.
export interface NativeReminderNotifications {
  // Makes `owner`'s Send Reminder notifications, pending or delivered, exactly `notifications`
  // while `owner` is signed in: each one still ahead is scheduled for its instant, replacing one
  // under its identifier, and every other is withdrawn.
  readonly scheduleReminderNotifications: (
    owner: string,
    notifications: readonly ScheduledReminder[],
  ) => Promise<unknown>;
}

// What a due reminder's notification shows: with `previews`, the Draft's subject and recipients,
// otherwise nothing of the Draft. It offers nothing that sends the Draft.
const reminderNotificationContent = (
  t: Translate,
  previews: boolean,
  draft: Pick<Draft, 'subject' | 'to' | 'cc' | 'bcc'>,
) => {
  if (!previews) {
    return { title: '', body: t('notifications.reminder') };
  }
  const names = [...draft.to, ...draft.cc, ...draft.bcc].map(
    ({ name, address }) => name ?? address,
  );
  const last = names.pop();
  return {
    title: draft.subject === '' ? t('notifications.noSubject') : draft.subject,
    body:
      last === undefined
        ? t('notifications.reminderOwn')
        : t('notifications.reminderTo', {
            recipients:
              names.length === 0
                ? last
                : t('notifications.reminderRecipients', {
                    names: names.join(', '),
                    last,
                  }),
          }),
  };
};

// Keeps this device's Send Reminder notifications on the reminders it set, for Drafts it lists, at
// its Show Sender and Subject level, after every change to those reminders, the Drafts or the
// notification settings. Nothing changes while the Drafts or reminders cannot be read, so a locked
// device or a launch still opening storage withdraws nothing.
export function followReminderNotifications(
  host: NativeReminderNotifications,
  {
    reminders,
    drafts,
    settings,
    translate,
  }: Readonly<{
    reminders: Pick<SendReminders, 'notifying' | 'subscribe'>;
    drafts: Readonly<{
      getSnapshot: () => DraftsState;
      subscribe: (listener: () => void) => () => void;
    }>;
    settings: Readonly<{
      getSnapshot: () => NotificationSettings | undefined;
      subscribe: (listener: () => void) => () => void;
    }>;
    translate: () => Translate;
  }>,
) {
  // What native code last accepted, so an unchanged set is not scheduled again.
  let scheduled: Parameters<typeof sameScheduling>[0] | undefined = undefined;
  const pass = Effect.gen(function* () {
    const listed = drafts.getSnapshot();
    const current = settings.getSnapshot();
    if (listed.kind !== 'ready' || current === undefined) {
      return;
    }
    const notifying = yield* Effect.promise(reminders.notifying);
    if (notifying === undefined) {
      return;
    }
    const t = translate();
    const notifications = notifying.reminders.flatMap(
      ({ profile, draft: id, dueAt }) => {
        const draft = listed.drafts.find((each) => each.id === id);
        return draft === undefined
          ? []
          : [
              {
                id: `send-reminder.${current.previews ? 'preview.' : ''}${dueAt}.${recordId({ profile, draft: id })}`,
                ...reminderNotificationContent(t, current.previews, draft),
                profile,
                dueAt,
                previews: current.previews,
              },
            ];
      },
    );
    const next = {
      owner: notifying.owner,
      authorization: current.authorization,
      notifications,
    };
    if (scheduled !== undefined && sameScheduling(next, scheduled)) {
      return;
    }
    yield* Effect.tryPromise(() =>
      host.scheduleReminderNotifications(notifying.owner, notifications),
    );
    scheduled = next;
  }).pipe(
    Effect.catchTag('UnknownError', ({ cause }) =>
      Effect.logError(
        'Send Reminder notifications could not be scheduled:',
        rejectionDiagnostic(cause),
      ),
    ),
  );
  // One pass runs at a time; a change meanwhile runs one more after it.
  let running = false;
  let again = false;
  const follow = () => {
    if (running) {
      again = true;
      return;
    }
    running = true;
    const run = async (): Promise<void> => {
      again = false;
      await runLogged(pass);
      if (again) {
        return run();
      }
      running = false;
    };
    void run();
  };
  reminders.subscribe(follow);
  drafts.subscribe(follow);
  settings.subscribe(follow);
  follow();
}

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
