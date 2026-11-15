import * as Arr from 'effect/Array';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { Registration } from './registration.ts';

import { runLogged } from './diagnostics.ts';
import { malformed, native, ownerMismatch } from './draft-native.ts';
import {
  preferencePasses,
  PushedSchema,
  reportPreference,
} from './draft-sync.ts';
import { ownerOf } from './drafts.ts';

// How tightly a Thread list lays out its rows. Comfortable is the default.
export const ListDensitySchema = Schema.Literals(['comfortable', 'compact']);
export type ListDensity = typeof ListDensitySchema.Type;
const isListDensity = Schema.is(ListDensitySchema);
// How many preview lines a Mac Inbox row shows: none to three.
export const PreviewLinesSchema = Schema.Literals([0, 1, 2, 3]);
export type PreviewLines = typeof PreviewLinesSchema.Type;
const isPreviewLines = Schema.is(PreviewLinesSchema);

// One preference's latest value and when it was chosen, in milliseconds since the epoch. A field
// this build does not know is kept and published as it was.
const FieldSchema = Schema.Struct({ value: Schema.Json, at: Schema.Finite });
type Fields = Readonly<Record<string, typeof FieldSchema.Type>>;
// A Mail Profile's Inbox presentation preferences (ADR 0019's `mail-workflow-preferences:inbox`),
// as this device keeps them and as the Profile's record seals them.
const ProfilePreferencesSchema = Schema.Struct({
  profile: Schema.NonEmptyString,
  fields: Schema.Record(Schema.String, FieldSchema),
});
type ProfilePreferences = typeof ProfilePreferencesSchema.Type;
const DocumentSchema = Schema.fromJsonString(
  Schema.Struct({ profiles: Schema.Array(ProfilePreferencesSchema) }),
);
const RecordJsonSchema = Schema.fromJsonString(ProfilePreferencesSchema);
const decodeRecord = Schema.decodeUnknownOption(RecordJsonSchema);
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
      version: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
      updatedAt: Schema.Finite,
      // Decoded one by one, so a record this device cannot read changes nothing.
      preferences: Schema.NullOr(Schema.String),
    }),
  ),
  unreadable: Schema.Array(Schema.NonEmptyString),
});
// Native code accepts a Private Sync record identifier of at most 200 characters.
const publishable = (profile: string) => profile.length <= 200;

// The signed-in Product Account's Inbox preferences on this device: one document native code keeps
// encrypted for the account that wrote it, like its Blocked Senders. Every call rejects with
// 'locked' while the device is locked.
export interface NativeInboxPreferences {
  // Resolves `{ owner, revision, document }`; `document` is null when the account has none.
  readonly openInboxPreferences: () => Promise<unknown>;
  // Replaces the document only from `expectedRevision` and resolves `{ owner, revision }`.
  readonly commitInboxPreferences: (
    owner: string,
    expectedRevision: number,
    document: string,
  ) => Promise<unknown>;
}

// Each Mail Profile's Inbox preferences in Private Sync, one record per Profile. Native code seals
// each record to the account and an opaque identifier derived from the Profile's, so Convex holds
// only ciphertext. Every call rejects with 'unavailable' while this device holds no keys or
// Product Sign-In session.
export interface NativeInboxPreferenceSync {
  // Resolves `{ owner, records: [{ id, version, updatedAt, preferences }], unreadable }`,
  // `preferences` being the JSON the record seals. `unreadable` names the Profiles of `known` whose
  // record exists but does not open here.
  readonly pullInboxPreferences: (
    owner: string,
    known: readonly string[],
  ) => Promise<unknown>;
  // Writes Profile `id`'s record, sealing `preferences`, only while it is still at
  // `expectedUpdatedAt` (absent: while there is none). Resolves `{ owner, committed, updatedAt? }`.
  readonly pushInboxPreferences: (
    owner: string,
    record: Readonly<{
      id: string;
      version: number;
      preferences: string;
      expectedUpdatedAt?: number;
    }>,
  ) => Promise<unknown>;
}

const report = reportPreference('Inbox preference');

// Each field's later value. At the same instant the greater JSON wins, so devices converge whatever
// order they merge in.
const merged = (local: Fields, remote: Fields): Fields => {
  const next: Record<string, Fields[string]> = { ...local };
  for (const [name, field] of Object.entries(remote)) {
    const kept = next[name];
    if (
      kept === undefined ||
      field.at > kept.at ||
      (field.at === kept.at &&
        JSON.stringify(field.value) > JSON.stringify(kept.value))
    ) {
      next[name] = field;
    }
  }
  return next;
};
const canonical = (fields: Fields) =>
  JSON.stringify(
    Arr.sort(Object.keys(fields), Order.String).map((name) => [
      name,
      fields[name],
    ]),
  );
const sameFields = (left: Fields, right: Fields) =>
  canonical(left) === canonical(right);

const fieldsOf = (profiles: readonly ProfilePreferences[], profile: string) =>
  profiles.find((kept) => kept.profile === profile)?.fields ?? {};

// `profiles` with `profile`'s fields replaced.
const withFields = (
  profiles: readonly ProfilePreferences[],
  profile: string,
  fields: Fields,
) => [
  ...profiles.filter((kept) => kept.profile !== profile),
  { profile, fields },
];

// The records this device can read; one that does not decode, or names another Profile, is
// unreadable and changes nothing.
const readable = (pulled: typeof PulledSchema.Type) => {
  const unreadable = new Set(pulled.unreadable);
  const records = pulled.records.flatMap(({ preferences, ...record }) => {
    const sealed = Option.getOrUndefined(decodeRecord(preferences ?? ''));
    if (sealed?.profile !== record.id) {
      unreadable.add(record.id);
      return [];
    }
    return [{ ...record, fields: sealed.fields }];
  });
  return { records, unreadable };
};

// Each Mail Profile's Inbox preferences, stored on this device without network access, such as its
// Thread-list density. With `sync`, they also synchronize through Private Sync: after each change
// and on `synchronize`.
export function createInboxPreferences(
  storage: NativeInboxPreferences,
  registration: Pick<Registration, 'getSnapshot'>,
  sync?: Readonly<{
    native: NativeInboxPreferenceSync;
    // Called when native code purged the account because this device was removed.
    removed?: () => void;
    // Adopts a key epoch another device's removal moved the account to.
    adoptKeyRotation?: () => Promise<unknown>;
  }>,
) {
  const semaphore = Semaphore.makeUnsafe(1);
  const listeners = new Set<() => void>();
  const signedIn = () => ownerOf(registration.getSnapshot().snapshot);
  // The preferences last read or written, and the Product Account they belong to.
  let shown: Readonly<{
    account: string;
    profiles: readonly ProfilePreferences[];
  }> = { account: '', profiles: [] };
  const show = (account: string, profiles: readonly ProfilePreferences[]) => {
    shown = { account, profiles };
    for (const listener of listeners) {
      listener();
    }
  };

  // The preferences of `account`, the Product Account signed in when the action was called, so an
  // action that waited, or whose read finished, while another account signed in reads and writes
  // nothing of it.
  const opened = (account: string | undefined) =>
    Effect.gen(function* () {
      const { owner, revision, document } = yield* native(
        storage.openInboxPreferences,
        OpenedSchema,
      );
      if (owner !== account || signedIn() !== account) {
        return yield* ownerMismatch();
      }
      return { owner, revision, profiles: document?.profiles ?? [] };
    });

  // Stores what `change` makes of the stored preferences and shows them; returning the same array
  // writes nothing.
  const changed = (
    account: string | undefined,
    change: (
      profiles: readonly ProfilePreferences[],
    ) => readonly ProfilePreferences[],
  ) =>
    Effect.gen(function* () {
      const { owner, revision, profiles } = yield* opened(account);
      const next = change(profiles);
      if (next !== profiles) {
        const document = yield* Schema.encodeEffect(DocumentSchema)({
          profiles: next,
        }).pipe(Effect.mapError(malformed));
        const committed = yield* native(
          () => storage.commitInboxPreferences(owner, revision, document),
          CommittedSchema,
        );
        if (committed.owner !== owner) {
          return yield* ownerMismatch();
        }
      }
      show(owner, next);
      return next;
    }).pipe(semaphore.withPermit);

  // Writes `profile`'s fields by compare-and-set from `record`, the one this pass read, when they
  // differ from it. Resolves whether another device's write won.
  const publish = Effect.fnUntraced(function* (
    remote: NativeInboxPreferenceSync,
    account: string,
    {
      profile,
      fields,
      record,
    }: Readonly<{
      profile: string;
      fields: Fields;
      record:
        | Readonly<{ version: number; updatedAt: number; fields: Fields }>
        | undefined;
    }>,
  ) {
    if (record !== undefined && sameFields(record.fields, fields)) {
      return false;
    }
    const preferences = yield* Schema.encodeEffect(RecordJsonSchema)({
      profile,
      fields,
    }).pipe(Effect.mapError(malformed));
    const pushed = yield* native(
      () =>
        remote.pushInboxPreferences(account, {
          id: profile,
          version: (record?.version ?? 0) + 1,
          preferences,
          ...(record === undefined
            ? {}
            : { expectedUpdatedAt: record.updatedAt }),
        }),
      PushedSchema,
    );
    if (pushed.owner !== account) {
      return yield* ownerMismatch();
    }
    return !pushed.committed;
  });

  // One pass: merges every Profile's record into this device's preferences, then writes by
  // compare-and-set each record the merge changed. A Profile whose record does not open here keeps
  // its record. Resolves whether another device's write won meanwhile.
  const pass = Effect.fnUntraced(function* (remote: NativeInboxPreferenceSync) {
    const account = signedIn();
    if (account === undefined) {
      return false;
    }
    const before = yield* opened(account);
    const pulled = yield* native(
      () =>
        remote.pullInboxPreferences(
          account,
          before.profiles.map(({ profile }) => profile),
        ),
      PulledSchema,
    );
    if (pulled.owner !== account) {
      return yield* ownerMismatch();
    }
    const { records, unreadable } = readable(pulled);
    const stored = yield* changed(account, (profiles) =>
      records.reduce((next, { id, fields }) => {
        const local = fieldsOf(next, id);
        const adopted = merged(local, fields);
        return sameFields(local, adopted)
          ? next
          : withFields(next, id, adopted);
      }, profiles),
    );
    let conflicted = false;
    for (const { profile, fields } of stored.filter(
      (kept) => !unreadable.has(kept.profile) && publishable(kept.profile),
    )) {
      conflicted =
        (yield* publish(remote, account, {
          profile,
          fields,
          record: records.find(({ id }) => id === profile),
        })) || conflicted;
    }
    return conflicted;
  });

  const synchronize = preferencePasses('Inbox preference', pass, sync);

  // Sets field `name` of each of `profiles` to `value`, after the value it replaces even when the
  // clock went back. Resolves whether storage holds it, and then publishes it.
  const choose = async (
    profiles: readonly string[],
    name: string,
    value: ListDensity | PreviewLines,
  ) => {
    const scopes = profiles.filter((profile) => profile !== '');
    if (scopes.length === 0) {
      return false;
    }
    const stored = await runLogged(
      changed(signedIn(), (kept) =>
        scopes.reduce((next, profile) => {
          const fields = fieldsOf(next, profile);
          const field = fields[name];
          return field?.value === value
            ? next
            : withFields(next, profile, {
                ...fields,
                [name]: {
                  value,
                  at: Math.max(Date.now(), (field?.at ?? 0) + 1),
                },
              });
        }, kept),
      ).pipe(
        Effect.as(true),
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
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    // `profile`'s Thread-list density as last read: Comfortable until it is read, while storage
    // cannot read it, or when none was chosen.
    listDensity: (profile: string): ListDensity => {
      const value =
        shown.account === signedIn()
          ? fieldsOf(shown.profiles, profile).density?.value
          : undefined;
      return isListDensity(value) ? value : 'comfortable';
    },
    // Reads the signed-in account's preferences for `listDensity` and `previewLines`; signed out,
    // there are none.
    load: async () => {
      const account = signedIn();
      if (account !== undefined) {
        await runLogged(
          changed(account, (profiles) => profiles).pipe(
            Effect.asVoid,
            Effect.catchTag('DraftStorageFailure', report),
          ),
        );
      }
    },
    // `profile`'s preview length as last read; undefined until it is read, while storage cannot read
    // it, or when none was chosen.
    previewLines: (profile: string): PreviewLines | undefined => {
      const value =
        shown.account === signedIn()
          ? fieldsOf(shown.profiles, profile).previewLines?.value
          : undefined;
      return isPreviewLines(value) ? value : undefined;
    },
    // Chooses `profile`'s Thread-list density, after the choice it replaces even when the clock
    // went back. Resolves whether storage holds it, and then publishes it.
    setListDensity: (profile: string, density: ListDensity) =>
      choose([profile], 'density', density),
    // Chooses the preview length of each of `profiles` in one write, as `setListDensity` does.
    setPreviewLines: (profiles: readonly string[], lines: PreviewLines) =>
      choose(profiles, 'previewLines', lines),
    // Merges Private Sync into this device's preferences and publishes this device's changes;
    // resolves once no pass is running.
    synchronize,
  };
}
export type InboxPreferences = ReturnType<typeof createInboxPreferences>;
