import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';

import type { StoredPayload } from './registration-replies.ts';
import type {
  NativeRegistrationVault,
  ProfileRecord,
  ProfileState,
  RegistrationRecord,
} from './registration-vault.ts';

import { failWith, nativeSteps } from './registration-native.ts';
import { EncryptedPayload } from './registration-replies.ts';
import {
  ProfileRecordSchema,
  ProfileStateSchema,
} from './registration-vault.ts';
import { defaultProfile } from './registration.ts';

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

// The Mail Profile owning each of this device's connections, by connection. Connections not listed
// belong to the Default Profile.
export const profileOwners = (value: RegistrationRecord) => {
  const vault = stateOf(value);
  const state = vault?.profiles;
  if (vault === undefined || state === undefined) {
    return new Map<string, string>();
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
  const profiles = (stateOf(value)?.profiles?.profiles ?? []).flatMap(
    ({ id, name, pending }) => {
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
    },
  );
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

// Mail Profile definitions and connection ownership in End-to-End Encrypted Product Sync. Native
// code seals each record under an identifier bound to its Profile or connection, so Convex learns
// neither names nor ownership. Profile writes compare and set; a device that loses applies its
// pending name to the winner on its next pass. Moving a connection and removing a Profile need
// Product Sync and change nothing when another device wrote first.
export function createMailProfileProgram<E>(
  vault: NativeRegistrationVault,
  {
    list,
    write,
    descriptorEpochs,
    freshId,
  }: Readonly<{
    list: (prefix: string) => Effect.Effect<Stored[], E>;
    write: (
      record: string,
      sealed: typeof EncryptedPayload.Type,
      expectedUpdatedAt: number | undefined,
    ) => Effect.Effect<Stored, E>;
    // Every mailbox descriptor's epoch by record; null once removed.
    descriptorEpochs: Effect.Effect<ReadonlyMap<string, string | null>, E>;
    freshId: Effect.Effect<string>;
  }>,
) {
  const { native, step, sync: syncState } = nativeSteps(vault);
  const known = syncState.pipe(
    Effect.map((sync) => sync.vault?.profiles ?? emptyState),
  );
  const save = (before: ProfileState, state: ProfileState) =>
    sameState(before, state)
      ? Effect.void
      : step(() => vault.recordProfiles(state));

  // Every Profile definition and ownership record, merged into the state this device knows. An
  // ownership record that does not open here keeps what this device last read of it.
  const refreshed = Effect.fnUntraced(function* (state: ProfileState) {
    const records = [
      ...(yield* list('profile.')),
      ...(yield* list('mailbox-profile.')),
    ];
    const opened =
      records.length === 0
        ? []
        : yield* native(() => vault.openProfileRecords(records), Opened);
    if (opened.length !== records.length) {
      return yield* failWith('unavailable');
    }
    // Retain confirmed owners and version floors even when ciphertext is absent; owners return
    // to Default through an explicit record.
    let next = state;
    let replayed = false;
    for (const [index, record] of opened.entries()) {
      if (record !== null) {
        if (olderRecord(next, record)) {
          replayed = true;
        } else {
          next = withRecord(next, record, records[index]?.updatedAt ?? 0);
        }
      }
    }
    // A later refusal must not discard authenticated records this read already confirmed.
    yield* save(state, next);
    if (replayed) {
      return yield* failWith('unavailable');
    }
    return { state: next, readable: !opened.includes(null) };
  });

  // Seals and compares and sets one record; the state learns what Convex stores afterwards.
  const put = Effect.fnUntraced(function* (
    state: ProfileState,
    record: ProfileRecord,
    expectedUpdatedAt: number | undefined,
  ) {
    const sealed = yield* native(() => vault.sealProfileRecord(record), Sealed);
    const stored = yield* write(
      sealed.payloadIdentifier,
      sealed.encryptedPayload,
      expectedUpdatedAt,
    );
    const [winner] = yield* native(
      () => vault.openProfileRecords([stored]),
      Opened,
    );
    if (winner !== undefined && winner !== null && olderRecord(state, winner)) {
      return yield* failWith('unavailable');
    }
    const readable = winner !== undefined && winner !== null;
    const next = readable ? withRecord(state, winner, stored.updatedAt) : state;
    yield* save(state, next);
    return {
      // Only a stored record that opens here proves which write won.
      readable,
      committed:
        readable &&
        stored.encryptedPayload.ciphertextBase64 ===
          sealed.encryptedPayload.ciphertextBase64,
      state: next,
    };
  });

  // A write that needs Product Sync: the state keeps what Convex stores, and losing to another
  // device's write changes nothing here.
  const commit = Effect.fnUntraced(function* ({
    state,
    record,
    expectedUpdatedAt,
  }: Readonly<{
    state: ProfileState;
    record: ProfileRecord;
    expectedUpdatedAt: number | undefined;
  }>) {
    const { readable, committed } = yield* put(
      state,
      record,
      expectedUpdatedAt,
    );
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
        ({ state } = yield* put(
          state,
          { kind: 'profile', id, version: (version ?? 0) + 1, name: pending },
          updatedAt,
        ));
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
    yield* commit({
      state,
      record: { kind: 'profile', id, version: (profile.version ?? 0) + 1 },
      expectedUpdatedAt: profile.updatedAt,
    });
  });

  // Moves the current incarnation of one of this device's connections to a published Profile, or
  // back to the Default Profile. Its identity, authorization, cache and Drafts stay in place.
  const move = Effect.fnUntraced(function* (
    value: RegistrationRecord,
    connection: string,
    profile: string,
  ) {
    const { record, epoch } = yield* incarnationOf(value, connection);
    const { state } = yield* refreshed(yield* known);
    const current = state.owners.find((owner) => owner.record === record);
    if (receives(state, profile) && ownerOf(state, record, epoch) !== profile) {
      return yield* commit({
        state,
        record: {
          kind: 'mailbox',
          record,
          epoch,
          version: (current?.version ?? 0) + 1,
          profile,
        },
        expectedUpdatedAt: current?.updatedAt,
      });
    }
    if (!receives(state, profile)) {
      return yield* failWith('unavailable');
    }
  });

  return { synchronize, create, rename, remove, move };
}
