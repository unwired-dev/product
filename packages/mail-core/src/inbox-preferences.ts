import * as Arr from 'effect/Array';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type {
  FavoriteEntries,
  SectionFolders,
  Sections,
} from './mailbox-views.ts';
import type { Registration } from './registration.ts';

import { runLogged } from './diagnostics.ts';
import { malformed, native, ownerMismatch } from './draft-native.ts';
import {
  preferencePasses,
  PushedSchema,
  reportPreference,
} from './draft-sync.ts';
import { ownerOf } from './drafts.ts';
import {
  FavoriteEntriesSchema,
  SectionFoldersSchema,
} from './mailbox-views.ts';
import { mailboxesOf, profilesOf } from './registration-snapshot.ts';

// How tightly a Thread list lays out its rows. Comfortable is the default.
export const ListDensitySchema = Schema.Literals(['comfortable', 'compact']);
export type ListDensity = typeof ListDensitySchema.Type;
const isListDensity = Schema.is(ListDensitySchema);
// How many preview lines a Mac Inbox row shows: none to three.
export const PreviewLinesSchema = Schema.Literals([0, 1, 2, 3]);
export type PreviewLines = typeof PreviewLinesSchema.Type;
const isPreviewLines = Schema.is(PreviewLinesSchema);
const isFavoriteEntries = Schema.is(FavoriteEntriesSchema);
// A connection's section choices name the incarnation they were made for, so a connection removed
// and added again starts shown with its folders in the server's order.
const ShownChoiceSchema = Schema.Struct({
  epoch: Schema.String,
  shown: Schema.Boolean,
});
const FoldersChoiceSchema = Schema.Struct({
  epoch: Schema.String,
  folders: SectionFoldersSchema,
});
const isShownChoice = Schema.is(ShownChoiceSchema);
const isFoldersChoice = Schema.is(FoldersChoiceSchema);
// The same empty Favorites and folders every read, so a React snapshot of none stays equal.
const noFavorites: FavoriteEntries = [];
const noFolders: SectionFolders = [];
const noSections: Sections = {};
// Each Mailbox Connection's section keeps whether it shows and its folders in fields of their own,
// so a device that hides one and another that reorders its folders keep both edits.
const shownField = (connection: string) => `sectionShown:${connection}`;
const foldersField = (connection: string) => `sectionFolders:${connection}`;

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

// The Mailbox Connection sections `fields` keep for each connection's incarnation in `epochs`; a
// connection they name is shown, with its folders in their own order, unless they say otherwise.
const sectionsOf = (
  fields: Fields,
  epochs: ReadonlyMap<string, string>,
): Sections => {
  const sections: Record<string, Sections[string]> = {};
  for (const [name, { value }] of Object.entries(fields)) {
    const [kind, connection] = name.split(/:(?<connection>.*)/su);
    if (connection !== undefined) {
      const section = sections[connection] ?? {
        shown: true,
        folders: noFolders,
      };
      const epoch = epochs.get(connection) ?? 'legacy';
      if (
        kind === 'sectionShown' &&
        isShownChoice(value) &&
        value.epoch === epoch
      ) {
        sections[connection] = { ...section, shown: value.shown };
      } else if (
        kind === 'sectionFolders' &&
        isFoldersChoice(value) &&
        value.epoch === epoch
      ) {
        sections[connection] = { ...section, folders: value.folders };
      }
    }
  }
  return sections;
};

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
  // Each Profile's sections as last read, kept while its fields and the connections' incarnations
  // stay, so a React snapshot stays equal.
  const sectionsRead = new WeakMap<
    Fields,
    Readonly<{ epochs: string; sections: Sections }>
  >();
  const signedIn = () => ownerOf(registration.getSnapshot().snapshot);
  // Each listed connection's incarnation; one listed before epochs, or not listed, is the legacy one.
  const epochs = () =>
    new Map(
      mailboxesOf(registration.getSnapshot().snapshot).map(({ id, epoch }) => [
        id,
        epoch ?? 'legacy',
      ]),
    );
  const epochOf = (connection: string) => epochs().get(connection) ?? 'legacy';
  // The preferences last read or written, and the Product Account they belong to.
  let shown: Readonly<{
    account: string;
    profiles: readonly ProfilePreferences[];
  }> = { account: '', profiles: [] };
  // The Product Accounts whose last read storage failed, so which of their connections are muted is
  // unknown.
  const failed = new Set<string | undefined>();
  // The Profiles the last pass asked Private Sync about for `account`, and those whose records it
  // could not read, once a pass merged what it pulled and no other device's write overtook it;
  // none since a pass failed or was overtaken.
  let pulled:
    | Readonly<{
        account: string;
        known: ReadonlySet<string>;
        unreadable: ReadonlySet<string>;
      }>
    | undefined = undefined;
  const notify = () => {
    for (const listener of listeners) {
      listener();
    }
  };
  const show = (account: string, profiles: readonly ProfilePreferences[]) => {
    shown = { account, profiles };
    failed.delete(account);
    notify();
  };

  // The preferences of `account`, the Product Account signed in when the action was called, so an
  // action that waited, or whose read finished, while another account signed in reads and writes
  // nothing of it.
  const opened = (account: string | undefined) =>
    Effect.gen(function* () {
      const { owner, revision, document } = yield* native(
        storage.openInboxPreferences,
        OpenedSchema,
      ).pipe(
        Effect.tapError(() =>
          Effect.sync(() => {
            failed.add(account);
            notify();
          }),
        ),
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
    // Every Profile stored here, registered or holding a connection, so a record of one that does
    // not open is reported unreadable rather than absent.
    const { snapshot } = registration.getSnapshot();
    const known = new Set([
      ...before.profiles.map(({ profile }) => profile),
      ...profilesOf(snapshot).map(({ id }) => id),
      ...mailboxesOf(snapshot).map(({ profile }) => profile),
    ]);
    const fetched = yield* native(
      () => remote.pullInboxPreferences(account, [...known]),
      PulledSchema,
    );
    if (fetched.owner !== account) {
      return yield* ownerMismatch();
    }
    const { records, unreadable } = readable(fetched);
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
    pulled = conflicted ? undefined : { account, known, unreadable };
    return conflicted;
  });

  const synchronize = preferencePasses(
    'Inbox preference',
    (remote: NativeInboxPreferenceSync) =>
      pass(remote).pipe(
        Effect.tapError(() =>
          Effect.sync(() => {
            pulled = undefined;
          }),
        ),
      ),
    sync,
  );

  // Sets field `name` of each of `profiles` to `value`, or to what `value` makes of the stored
  // value, after the value it replaces even when the clock went back. Resolves whether storage
  // holds it, and then publishes it.
  const choose = async (
    profiles: readonly string[],
    name: string,
    value:
      | ListDensity
      | PreviewLines
      | typeof ShownChoiceSchema.Type
      | ((
          stored: unknown,
        ) => FavoriteEntries | typeof FoldersChoiceSchema.Type | undefined),
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
          const chosen =
            typeof value === 'function' ? value(field?.value) : value;
          return chosen === undefined ||
            JSON.stringify(field?.value) === JSON.stringify(chosen)
            ? next
            : withFields(next, profile, {
                ...fields,
                [name]: {
                  value: chosen,
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
    // Reads the signed-in account's preferences for `listDensity`, `previewLines`, `favorites` and
    // `sections`; signed out, there are none.
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
    // `profile`'s Favorites rows in order, as last read; none until they are read, while storage
    // cannot read them, or when none were chosen.
    favorites: (profile: string): FavoriteEntries => {
      const value =
        shown.account === signedIn()
          ? fieldsOf(shown.profiles, profile).favorites?.value
          : undefined;
      return isFavoriteEntries(value) ? value : noFavorites;
    },
    // Chooses `profile`'s Favorites rows as `change` makes them from the stored ones, as
    // `setListDensity` does, so edits made before the last one is read keep each other. A `change`
    // that returns undefined writes nothing.
    changeFavorites: (
      profile: string,
      change: (entries: FavoriteEntries) => FavoriteEntries | undefined,
    ) =>
      choose([profile], 'favorites', (stored) =>
        change(isFavoriteEntries(stored) ? stored : noFavorites),
      ),
    // Whether storage failed the signed-in account's last read, so `sections` is undefined until a
    // read succeeds.
    unreadable: () => {
      const account = signedIn();
      return account !== undefined && failed.has(account);
    },
    // `profile`'s Mailbox Connection sections, as last read; undefined until they are read and since
    // storage last failed to read them, so a muted connection stays muted. Signed out, none is hidden.
    sections: (profile: string): Sections | undefined => {
      const account = signedIn();
      if (account === undefined) {
        return noSections;
      }
      if (failed.has(account) || shown.account !== account) {
        return undefined;
      }
      const fields = shown.profiles.find(
        (kept) => kept.profile === profile,
      )?.fields;
      if (fields === undefined) {
        return noSections;
      }
      const listed = epochs();
      const key = JSON.stringify([...listed]);
      const read = sectionsRead.get(fields);
      if (read?.epochs === key) {
        return read.sections;
      }
      const sections = sectionsOf(fields, listed);
      sectionsRead.set(fields, { epochs: key, sections });
      return sections;
    },
    // Whether this device holds what Private Sync last had for `profile`: the last pass asked for
    // its record, pulled it or found none, and merged it unovertaken. Without Private Sync, the stored preferences are all.
    pulled: (profile: string) =>
      sync === undefined ||
      (pulled !== undefined &&
        pulled.account === signedIn() &&
        pulled.known.has(profile) &&
        !pulled.unreadable.has(profile)),
    // Shows or hides `connection`'s section of `profile`, as `setListDensity` chooses.
    showSection: (profile: string, connection: string, visible: boolean) =>
      choose([profile], shownField(connection), {
        epoch: epochOf(connection),
        shown: visible,
      }),
    // Chooses `connection`'s folders of `profile` as `change` makes them from the stored ones, as
    // `changeFavorites` does.
    changeFolders: (
      profile: string,
      connection: string,
      change: (folders: SectionFolders) => SectionFolders | undefined,
    ) =>
      choose([profile], foldersField(connection), (stored) => {
        const epoch = epochOf(connection);
        const folders = change(
          isFoldersChoice(stored) && stored.epoch === epoch
            ? stored.folders
            : noFolders,
        );
        return folders === undefined ? undefined : { epoch, folders };
      }),
    // Merges Private Sync into this device's preferences and publishes this device's changes;
    // resolves once no pass is running.
    synchronize,
  };
}
export type InboxPreferences = ReturnType<typeof createInboxPreferences>;
