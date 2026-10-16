import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';

import type { RegistrationRejected } from './registration-rejection.ts';
import type { StoredPayload } from './registration-replies.ts';
import type {
  NativeRegistrationVault,
  ProfileRecord,
  ProfileState,
  RegistrationRecord,
} from './registration-vault.ts';

import { failWith, nativeSteps } from './registration-native.ts';
import { EncryptedPayload } from './registration-replies.ts';
import { defaultProfile, unavailableProfile } from './registration-snapshot.ts';
import {
  ProfileRecordSchema,
  ProfileStateSchema,
} from './registration-vault.ts';

type Profile = ProfileState['profiles'][number];
type Owner = ProfileState['owners'][number];
type Stored = typeof StoredPayload.Type;

const Opened = Schema.Array(Schema.NullOr(ProfileRecordSchema));
const Sealed = Schema.Struct({
  payloadIdentifier: Schema.NonEmptyString,
  encryptedPayload: EncryptedPayload,
});
const emptyState: ProfileState = { profiles: [], owners: [] };
const sameState = Schema.toEquivalence(ProfileStateSchema);

// Product Sync holds the Profile without a name: it was removed.
const isRemoved = (profile: Profile) =>
  profile.version !== undefined && profile.name === undefined;

const stateOf = (value: RegistrationRecord) => {
  const sync = value.productSync;
  return sync === undefined || sync === 'unreadable' ? undefined : sync.vault;
};

// The Mail Profile owning one incarnation of a connection: its synchronized owner, unless that
// Profile was removed, and otherwise the Default Profile.
const ownerOf = (
  state: ProfileState,
  record: string | undefined,
  epoch: string | undefined,
) => {
  const owner = state.owners.find(
    (candidate) => candidate.record === record && candidate.epoch === epoch,
  )?.profile;
  return owner === undefined ||
    state.profiles.some((profile) => profile.id === owner && isRemoved(profile))
    ? defaultProfile
    : owner;
};

// One of this device's connections as its ownership names it: its descriptor record and epoch.
const incarnationOf = (value: RegistrationRecord, connection: string) => {
  const record = stateOf(value)?.mailboxes.find(
    ({ id }) => id === connection,
  )?.record;
  const epoch = value.mailboxes.find(({ id }) => id === connection)?.epoch;
  return record === undefined || epoch === undefined
    ? failWith('unavailable')
    : Effect.succeed({ record, epoch });
};

// Only the Default Profile and Profiles Product Sync holds can receive a connection.
const receives = (state: ProfileState, profile: string) =>
  profile === defaultProfile ||
  state.profiles.some(
    ({ id, name, version }) =>
      id === profile && name !== undefined && version !== undefined,
  );

// This device confirmed that some connection belongs to another Profile.
const confirmsOwner = (state: ProfileState) =>
  state.owners.some(
    ({ record, epoch }) => ownerOf(state, record, epoch) !== defaultProfile,
  );

// The Mail Profile owning each of this device's connections, by connection. Connections not listed
// belong to the Default Profile. Once an owner was confirmed, unreadable Profile state, or keys
// this device cannot read to name its connections' records, leave every connection's owner
// unknown rather than the Default Profile's, so no window reads another Profile's mail.
export const profileOwners = (value: RegistrationRecord) => {
  const state = value.profiles;
  const vault = stateOf(value);
  if (state === undefined) {
    return new Map<string, string>();
  }
  if (state === 'unreadable' || vault === undefined) {
    return state !== 'unreadable' && !confirmsOwner(state)
      ? new Map<string, string>()
      : new Map(value.mailboxes.map(({ id }) => [id, unavailableProfile]));
  }
  const records = new Map(
    vault.mailboxes.map(({ id, record }) => [id, record]),
  );
  return new Map(
    value.mailboxes.flatMap(({ id, epoch }) => {
      const owner = ownerOf(state, records.get(id), epoch);
      return owner === defaultProfile ? [] : [[id, owner] as const];
    }),
  );
};

// The Mail Profiles besides the Default Profile, as JSON text, or undefined without any: each one's
// identifier and name, and whether that name is not yet synchronized.
export const profileList = (value: RegistrationRecord) => {
  const state = value.profiles;
  const profiles = (
    state === undefined || state === 'unreadable' ? [] : state.profiles
  ).flatMap(({ id, name, pending }) => {
    const shown = pending ?? name;
    return shown === undefined
      ? []
      : [
          {
            id,
            name: shown,
            ...(pending === undefined ? {} : { pending: true }),
          },
        ];
  });
  return profiles.length === 0 ? undefined : JSON.stringify(profiles);
};

// The stored state of one Profile as a record read from Product Sync leaves it. A removal drops the
// name this device has not yet published; a published name equal to it settles it.
const readProfile = (
  known: Profile | undefined,
  { id, name, version }: Extract<ProfileRecord, { kind: 'profile' }>,
  updatedAt: number,
): Profile => {
  const pending =
    name === undefined || known?.pending === name ? undefined : known?.pending;
  return {
    id,
    ...(name === undefined ? {} : { name }),
    version,
    updatedAt,
    ...(pending === undefined ? {} : { pending }),
  };
};

const withRecord = (
  state: ProfileState,
  record: ProfileRecord,
  updatedAt: number,
): ProfileState => {
  if (record.kind === 'profile') {
    const known = state.profiles.find(({ id }) => id === record.id);
    const profile = readProfile(known, record, updatedAt);
    return {
      ...state,
      profiles:
        known === undefined
          ? [...state.profiles, profile]
          : state.profiles.map((item) => (item === known ? profile : item)),
    };
  }
  const owner: Owner = {
    record: record.record,
    epoch: record.epoch,
    profile: record.profile,
    version: record.version,
    updatedAt,
  };
  return {
    ...state,
    owners: [
      ...state.owners.filter(({ record: known }) => known !== record.record),
      owner,
    ],
  };
};

// Convex's row revision cannot make an older authenticated record newer than one already read.
const olderRecord = (state: ProfileState, record: ProfileRecord) => {
  const version =
    record.kind === 'profile'
      ? state.profiles.find(({ id }) => id === record.id)?.version
      : state.owners.find((owner) => owner.record === record.record)?.version;
  return version !== undefined && record.version < version;
};

const named = (name: string) => {
  const trimmed = name.trim();
  return trimmed.length === 0
    ? failWith('unavailable')
    : Effect.succeed(trimmed);
};

type Write = Readonly<{
  record: ProfileRecord;
  expectedUpdatedAt: number | undefined;
}>;

// The state with each opened record Convex stores, and whether any was older than one already
// confirmed, which is left out.
const merged = (
  state: ProfileState,
  opened: ReadonlyArray<ProfileRecord | null>,
  records: readonly Stored[],
) => {
  let next = state;
  let replayed = false;
  for (const [index, record] of opened.entries()) {
    if (record !== null) {
      replayed ||= olderRecord(next, record);
      next = olderRecord(next, record)
        ? next
        : withRecord(next, record, records[index]?.updatedAt ?? 0);
    }
  }
  return { next, replayed };
};

// Convex stores exactly these sealed writes.
const wrote = (
  sealed: ReadonlyArray<
    Readonly<{
      payloadIdentifier: string;
      encryptedPayload: typeof EncryptedPayload.Type;
    }>
  >,
  stored: readonly Stored[],
) => {
  const ours = new Map(
    sealed.map(({ payloadIdentifier, encryptedPayload }) => [
      payloadIdentifier,
      encryptedPayload.ciphertextBase64,
    ]),
  );
  return (
    stored.length === sealed.length &&
    stored.every(
      ({ payloadIdentifier, encryptedPayload }) =>
        ours.get(payloadIdentifier) === encryptedPayload.ciphertextBase64,
    )
  );
};

// Mail Profile definitions and connection ownership in End-to-End Encrypted Product Sync. Native
// code seals each record under an identifier bound to its Profile or connection, so Convex learns
// neither names nor ownership. Profile writes compare and set; a device that loses applies its
// pending name to the winner on its next pass. Moving a connection and removing a Profile need
// Product Sync and change nothing when another device wrote first.
export function createMailProfileProgram<E>(
  vault: NativeRegistrationVault,
  {
    list,
    writeAll,
    descriptorEpochs,
    freshId,
  }: Readonly<{
    list: (
      prefix: string,
      read: (
        records: readonly Stored[],
      ) => Effect.Effect<void, RegistrationRejected>,
    ) => Effect.Effect<Stored[], E | RegistrationRejected>;
    // Compare-and-set of every record in one transaction; uncommitted, it returns what is stored.
    writeAll: (
      writes: ReadonlyArray<
        Readonly<{
          record: string;
          sealed: typeof EncryptedPayload.Type;
          expectedUpdatedAt: number | undefined;
        }>
      >,
    ) => Effect.Effect<
      Readonly<{ committed: boolean; payloads: readonly Stored[] }>,
      E
    >;
    // Every mailbox descriptor's epoch by record; null once removed.
    descriptorEpochs: Effect.Effect<ReadonlyMap<string, string | null>, E>;
    freshId: Effect.Effect<string>;
  }>,
) {
  const { native, step, saved } = nativeSteps(vault);
  // Unreadable Profile state is never replaced by what this device could rebuild from records.
  const known = saved.pipe(
    Effect.flatMap(({ profiles }) =>
      profiles === 'unreadable'
        ? failWith('unavailable')
        : Effect.succeed(profiles ?? emptyState),
    ),
  );
  const save = (before: ProfileState, state: ProfileState) =>
    sameState(before, state)
      ? Effect.void
      : step(() => vault.recordProfiles(state));

  // Every Profile definition and ownership record, merged into the state this device knows. An
  // ownership record that does not open here keeps what this device last read of it.
  // Every stored record's Profile definition or ownership, or null where it does not open here.
  const openAll = Effect.fnUntraced(function* (records: readonly Stored[]) {
    const opened =
      records.length === 0
        ? []
        : yield* native(() => vault.openProfileRecords(records), Opened);
    if (opened.length !== records.length) {
      return yield* failWith('unavailable');
    }
    return opened;
  });

  // Learns what Convex stores. Records older than one already confirmed are refused, after the
  // others are saved: a later refusal must not discard records this read already confirmed.
  const learn = Effect.fnUntraced(function* (
    state: ProfileState,
    records: readonly Stored[],
  ) {
    const opened = yield* openAll(records);
    const { next, replayed } = merged(state, opened, records);
    yield* save(state, next);
    if (replayed) {
      return yield* failWith('unavailable');
    }
    return { state: next, readable: !opened.includes(null) };
  });

  // Every Profile definition and ownership record, merged into the state this device knows.
  // Confirmed owners and version floors stay even when their ciphertext is absent; owners return
  // to the Default Profile only through an explicit record.
  // Each page is saved before the next request, which can fail.
  const refreshed = Effect.fnUntraced(function* (state: ProfileState) {
    let learned = { state, readable: true };
    const read = Effect.fnUntraced(function* (records: readonly Stored[]) {
      const next = yield* learn(learned.state, records);
      learned = {
        state: next.state,
        readable: learned.readable && next.readable,
      };
    });
    for (const prefix of ['profile.', 'mailbox-profile.']) {
      yield* list(prefix, read);
    }
    return learned;
  });

  // Seals the records and compares and sets them together; the state learns what Convex stores
  // afterwards. Only stored records that open here as these writes prove they committed.
  const put = Effect.fnUntraced(function* (
    state: ProfileState,
    writes: readonly Write[],
  ) {
    const sealed = yield* Effect.forEach(
      writes,
      ({ record }) => native(() => vault.sealProfileRecord(record), Sealed),
      { concurrency: 1 },
    );
    const { committed, payloads } = yield* writeAll(
      sealed.map(({ payloadIdentifier, encryptedPayload }, index) => ({
        record: payloadIdentifier,
        sealed: encryptedPayload,
        expectedUpdatedAt: writes[index]?.expectedUpdatedAt,
      })),
    );
    const learned = yield* learn(state, payloads);
    return {
      ...learned,
      committed: committed && learned.readable && wrote(sealed, payloads),
    };
  });

  // A write that needs Product Sync: the state keeps what Convex stores, and losing to another
  // device's write changes nothing here.
  const commit = Effect.fnUntraced(function* (
    state: ProfileState,
    writes: readonly Write[],
  ) {
    const { readable, committed } = yield* put(state, writes);
    if (!committed) {
      return yield* failWith(readable ? 'profile-changed' : 'unavailable');
    }
  });

  // Reads every Profile record and publishes the names this device chose. A name another device
  // overwrote meanwhile is published again on the next pass.
  const synchronize = Effect.gen(function* () {
    let { state } = yield* refreshed(yield* known);
    for (const { id, pending, version, updatedAt } of state.profiles) {
      if (pending !== undefined) {
        ({ state } = yield* put(state, [
          {
            record: {
              kind: 'profile',
              id,
              version: (version ?? 0) + 1,
              name: pending,
            },
            expectedUpdatedAt: updatedAt,
          },
        ]));
      }
    }
  });

  // Names a new Profile in the vault, which publishes it once Product Sync is reachable. Its
  // opaque identifier never changes.
  const create = Effect.fnUntraced(function* (name: string) {
    const pending = yield* named(name);
    const state = yield* known;
    const id = yield* freshId;
    yield* step(() =>
      vault.recordProfiles({
        ...state,
        profiles: [...state.profiles, { id, pending }],
      }),
    );
  });

  const rename = Effect.fnUntraced(function* (id: string, name: string) {
    const chosen = yield* named(name);
    const state = yield* known;
    const profile = state.profiles.find((item) => item.id === id);
    if (profile === undefined || isRemoved(profile)) {
      return yield* failWith('unavailable');
    }
    const { pending: _, ...stored } = profile;
    const renamed =
      chosen === profile.name ? stored : { ...stored, pending: chosen };
    yield* save(state, {
      ...state,
      profiles: state.profiles.map((item) =>
        item === profile ? renamed : item,
      ),
    });
  });

  // Removes a Profile that owns no live connection. Even a locally pending Profile needs a
  // tombstone, since an unanswered first publication can still arrive.
  const remove = Effect.fnUntraced(function* (id: string) {
    if (id === defaultProfile) {
      return yield* failWith('unavailable');
    }
    const { state, readable } = yield* refreshed(yield* known);
    // Unknown ownership cannot prove a Profile is empty.
    if (!readable) {
      return yield* failWith('unavailable');
    }
    const profile = state.profiles.find((item) => item.id === id);
    if (profile === undefined || isRemoved(profile)) {
      return;
    }
    const epochs = yield* descriptorEpochs;
    const owned = state.owners.filter((owner) => owner.profile === id);
    // An owned connection whose descriptor Product Sync no longer lists may still be live.
    if (owned.some((owner) => !epochs.has(owner.record))) {
      return yield* failWith('unavailable');
    }
    if (owned.some((owner) => epochs.get(owner.record) === owner.epoch)) {
      return yield* failWith('profile-in-use');
    }
    yield* commit(state, [
      {
        record: { kind: 'profile', id, version: (profile.version ?? 0) + 1 },
        expectedUpdatedAt: profile.updatedAt,
      },
    ]);
  });

  // Moves the current incarnation of one of this device's connections to a published Profile, or
  // back to the Default Profile. Its identity, authorization, cache and Drafts stay in place. A move
  // into another Profile rewrites that Profile's definition in the same transaction, so it and a
  // concurrent removal of that Profile never both commit.
  const move = Effect.fnUntraced(function* (
    value: RegistrationRecord,
    connection: string,
    profile: string,
  ) {
    const { record, epoch } = yield* incarnationOf(value, connection);
    const { state } = yield* refreshed(yield* known);
    if (!receives(state, profile)) {
      return yield* failWith('unavailable');
    }
    if (ownerOf(state, record, epoch) === profile) {
      return;
    }
    const current = state.owners.find((owner) => owner.record === record);
    const target = state.profiles.find(({ id }) => id === profile);
    yield* commit(state, [
      {
        record: {
          kind: 'mailbox',
          record,
          epoch,
          version: (current?.version ?? 0) + 1,
          profile,
        },
        expectedUpdatedAt: current?.updatedAt,
      },
      ...(target?.version === undefined
        ? []
        : [
            {
              record: {
                kind: 'profile' as const,
                id: profile,
                version: target.version + 1,
                ...(target.name === undefined ? {} : { name: target.name }),
              },
              expectedUpdatedAt: target.updatedAt,
            },
          ]),
    ]);
  });

  return { synchronize, create, rename, remove, move };
}
