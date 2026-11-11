import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';

import type { StoredPayload } from './registration-replies.ts';
import type {
  ChosenFolders,
  ProfileColor,
  ProfileStyle,
} from './registration-snapshot.ts';
import type {
  NativeRegistrationVault,
  ProfileRecord,
  ProfileState,
  RegistrationRecord,
} from './registration-vault.ts';

import { failWith, nativeSteps } from './registration-native.ts';
import { RegistrationRejected } from './registration-rejection.ts';
import { EncryptedPayload } from './registration-replies.ts';
import {
  ProfileColorSchema,
  ProfileIconSchema,
  defaultProfile,
  unavailableProfile,
} from './registration-snapshot.ts';
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
const isColor = Schema.is(ProfileColorSchema);
const isIcon = Schema.is(ProfileIconSchema);

// A Profile's style as a record or state entry carries it, without absent keys.
const styleOf = ({
  color,
  icon,
}: Readonly<{ color?: string; icon?: string }>) => ({
  ...(color === undefined ? {} : { color }),
  ...(icon === undefined ? {} : { icon }),
});
const sameState = Schema.toEquivalence(ProfileStateSchema);
// A connection's chosen Spam and Trash folders, without absent keys.
const chosenOf = ({ junk, trash }: ChosenFolders): ChosenFolders => ({
  ...(junk === undefined ? {} : { junk }),
  ...(trash === undefined ? {} : { trash }),
});

// Product Sync holds the Profile without a name: it was removed.
const isRemoved = (profile: Profile) =>
  profile.version !== undefined && profile.name === undefined;

const stateOf = (value: RegistrationRecord) => {
  const sync = value.productSync;
  return sync === undefined || sync === 'unreadable' ? undefined : sync.vault;
};

// The Mail Profile owning one incarnation of a connection: its synchronized owner, unless that
// Profile was removed, and otherwise the Default Profile.
// The version of an incarnation's ownership, or 0 while no ownership names it. Every move raises it.
const ownershipVersion = (
  state: ProfileState,
  record: string | undefined,
  epoch: string | undefined,
) =>
  state.owners.find(
    (candidate) => candidate.record === record && candidate.epoch === epoch,
  )?.version ?? 0;

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

// This device's connections whose current incarnation has New Mail Notifications turned on in
// Product Sync. Unreadable Profile state or keys turn every connection's notifications off.
export const notifyingConnections = (value: RegistrationRecord) => {
  const state = value.profiles;
  const vault = stateOf(value);
  if (state === undefined || state === 'unreadable' || vault === undefined) {
    return new Set<string>();
  }
  return new Set(
    value.mailboxes.flatMap(({ id, epoch }) => {
      const record = vault.mailboxes.find(
        (mailbox) => mailbox.id === id,
      )?.record;
      return state.notifications?.some(
        (policy) =>
          policy.record === record && policy.epoch === epoch && policy.enabled,
      ) === true
        ? [id]
        : [];
    }),
  );
};

// The Spam and Trash folders chosen in Product Sync for the current incarnation of each of this
// device's connections that has a choice. Unreadable Profile state or keys leave every choice out.
export const chosenFolders = (value: RegistrationRecord) => {
  const state = value.profiles;
  const vault = stateOf(value);
  if (state === undefined || state === 'unreadable' || vault === undefined) {
    return new Map<string, ChosenFolders>();
  }
  return new Map(
    value.mailboxes.flatMap(({ id, epoch }) => {
      const record = vault.mailboxes.find(
        (mailbox) => mailbox.id === id,
      )?.record;
      const choice = state.folders?.find(
        (folders) => folders.record === record && folders.epoch === epoch,
      );
      return choice === undefined ? [] : [[id, chosenOf(choice)] as const];
    }),
  );
};

// The display position and Color synchronized for the current incarnation of each of this device's
// connections. A position counts only within the Profile that owns the connection now. Unreadable
// Profile state or keys leave every connection unarranged and uncolored.
export const connectionDisplay = (value: RegistrationRecord) => {
  const state = value.profiles;
  const vault = stateOf(value);
  const positions = new Map<string, number>();
  const colors = new Map<string, ProfileColor>();
  if (state === undefined || state === 'unreadable' || vault === undefined) {
    return { positions, colors };
  }
  for (const { id, epoch } of value.mailboxes) {
    const record = vault.mailboxes.find((mailbox) => mailbox.id === id)?.record;
    const display = state.display?.find(
      (item) => item.record === record && item.epoch === epoch,
    );
    if (
      display?.position !== undefined &&
      display.profile === ownerOf(state, record, epoch) &&
      display.ownership === ownershipVersion(state, record, epoch)
    ) {
      positions.set(id, display.position);
    }
    if (isColor(display?.color)) {
      colors.set(id, display.color);
    }
  }
  return { positions, colors };
};

type SendingIdentity = Partial<
  Readonly<Record<'record' | 'epoch' | 'address', string | undefined>>
>;
const sameIdentity = (
  current: SendingIdentity | undefined,
  next: SendingIdentity | undefined,
) =>
  current?.record === next?.record &&
  current?.epoch === next?.epoch &&
  current?.address === next?.address;

// The write that makes `identity` a Profile's Default Sending Identity, or none when it already is.
const sendingWrite = (
  state: ProfileState,
  profile: string,
  identity:
    | Readonly<{ record: string; epoch: string; address: string }>
    | undefined,
) => {
  const current = state.sending?.find((item) => item.profile === profile);
  if (sameIdentity(current?.identity, identity)) {
    return undefined;
  }
  return {
    record: {
      kind: 'sending' as const,
      profile,
      version: (current?.version ?? 0) + 1,
      ...(identity === undefined ? {} : { identity }),
    },
    expectedUpdatedAt: current?.updatedAt,
  };
};

// The connections whose primary address is the Default Sending Identity of the Mail Profile that
// owns them now. A default naming a removed or re-added incarnation, a connection now in another
// Profile or another address marks none, so no other identity stands in for it. Unreadable
// Profile state or keys mark none.
export const sendingDefaults = (value: RegistrationRecord) => {
  const state = value.profiles;
  const vault = stateOf(value);
  if (state === undefined || state === 'unreadable' || vault === undefined) {
    return new Set<string>();
  }
  const records = new Map(
    vault.mailboxes.map(({ id, record }) => [id, record]),
  );
  return new Set(
    value.mailboxes.flatMap(({ id, epoch, address }) => {
      const record = records.get(id);
      const owner = ownerOf(state, record, epoch);
      const identity = state.sending?.find(
        ({ profile }) => profile === owner,
      )?.identity;
      return identity !== undefined &&
        sameIdentity(identity, { record, epoch, address })
        ? [id]
        : [];
    }),
  );
};

// The Mail Profiles besides the Default Profile, as JSON text, or undefined without any: each one's
// identifier, name and style this client knows, and whether that name is not yet synchronized.
export const profileList = (value: RegistrationRecord) => {
  const state = value.profiles;
  const profiles = (
    state === undefined || state === 'unreadable' ? [] : state.profiles
  ).flatMap(
    ({ id, name, pending, pendingRemoval, pendingStyle, ...storedStyle }) => {
      const { color, icon } = pendingStyle ?? storedStyle;
      const shown = pendingRemoval === true ? undefined : (pending ?? name);
      return shown === undefined
        ? []
        : [
            {
              id,
              name: shown,
              ...(isColor(color) && color !== 'graphite' ? { color } : {}),
              ...(isIcon(icon) ? { icon } : {}),
              ...(pending === undefined ? {} : { pending: true }),
            },
          ];
    },
  );
  return profiles.length === 0 ? undefined : JSON.stringify(profiles);
};

// A pre-publication edit stays pending until an authenticated record carries the whole style.
const pendingStyleOf = (
  known: Profile | undefined,
  stored: Pick<Profile, 'color' | 'icon'>,
) => {
  const pendingStyle = known?.pendingStyle;
  return pendingStyle === undefined ||
    (pendingStyle.color === stored.color && pendingStyle.icon === stored.icon)
    ? {}
    : { pendingStyle };
};

// The stored state of one Profile as a record read from Product Sync leaves it. A removal drops the
// name this device has not yet published; a published name equal to it settles it.
const readProfile = (
  known: Profile | undefined,
  { id, name, version, ...style }: Extract<ProfileRecord, { kind: 'profile' }>,
  updatedAt: number,
): Profile => {
  const stored = { id, version, updatedAt };
  if (name === undefined) {
    return stored;
  }
  const pending = known?.pending === name ? undefined : known?.pending;
  return {
    ...stored,
    name,
    ...styleOf(style),
    ...pendingStyleOf(known, style),
    ...(pending === undefined ? {} : { pending }),
    ...(known?.pendingRemoval === true
      ? { pendingRemoval: true as const }
      : {}),
  };
};

// A connection's list with its entry replaced by the one just read.
const replacing = <Entry extends Readonly<{ record: string }>>(
  entries: readonly Entry[] | undefined,
  entry: Entry,
) => [
  ...(entries ?? []).filter(({ record }) => record !== entry.record),
  entry,
];

const withRecord = (
  state: ProfileState,
  record: ProfileRecord,
  {
    updatedAt,
    payloadIdentifier,
  }: Readonly<{
    updatedAt: number;
    payloadIdentifier?: string | undefined;
  }>,
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
  if (record.kind === 'folders') {
    const { kind: _, ...choice } = record;
    return {
      ...state,
      folders: replacing(state.folders, { ...choice, updatedAt }),
    };
  }
  if (record.kind === 'display') {
    const { kind: _, ...display } = record;
    return {
      ...state,
      display: replacing(state.display, { ...display, updatedAt }),
    };
  }
  if (record.kind === 'sending') {
    const { kind: _, ...sending } = record;
    return {
      ...state,
      sending: [
        ...(state.sending ?? []).filter(
          ({ profile }) => profile !== record.profile,
        ),
        { ...sending, updatedAt },
      ],
    };
  }
  if (record.kind === 'notifications') {
    const { kind: _, ...policy } = record;
    return {
      ...state,
      notifications: replacing(state.notifications, {
        ...policy,
        updatedAt,
        ...(payloadIdentifier === undefined
          ? {}
          : { identifier: payloadIdentifier }),
      }),
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
    owners: replacing(state.owners, owner),
  };
};

// Unmapped older policies also turn off when a notification record no longer opens here.
// Keep each version floor and row revision; an unreadable read never authorizes a write.
const withoutUnreadablePolicy = (
  state: ProfileState,
  identifier: string | undefined,
): ProfileState =>
  identifier?.startsWith('mailbox-notifications.') === true &&
  state.notifications?.some(
    (policy) =>
      (policy.identifier === identifier || policy.identifier === undefined) &&
      policy.enabled,
  ) === true
    ? {
        ...state,
        notifications: state.notifications.map((policy) =>
          policy.identifier === identifier || policy.identifier === undefined
            ? { ...policy, enabled: false }
            : policy,
        ),
      }
    : state;

// Its identifier does not say which Profile a Default Sending Identity record belongs to, so one that
// no longer opens here clears every Profile's identity until a readable record confirms it. Keeps
// each version floor and row revision.
const withoutUnreadableSending = (
  state: ProfileState,
  identifier: string | undefined,
): ProfileState =>
  identifier?.startsWith('profile-sending.') === true &&
  state.sending !== undefined
    ? {
        ...state,
        sending: state.sending.map(({ profile, version, updatedAt }) => ({
          profile,
          version,
          updatedAt,
        })),
      }
    : state;

// What a record that no longer opens here turns off.
const withoutUnreadable = (
  state: ProfileState,
  identifier: string | undefined,
) =>
  withoutUnreadableSending(
    withoutUnreadablePolicy(state, identifier),
    identifier,
  );

// The records of one connection-bound kind this state knows.
const connectionRecords = (
  state: ProfileState,
  kind: 'mailbox' | 'notifications' | 'folders' | 'display',
): ReadonlyArray<Readonly<{ record: string; version: number }>> =>
  ({
    mailbox: state.owners,
    notifications: state.notifications ?? [],
    folders: state.folders ?? [],
    display: state.display ?? [],
  })[kind];

// Only an IMAP connection chooses folders, and one folder cannot be both Spam and Trash.
const choosable = (
  value: RegistrationRecord,
  connection: string,
  { junk, trash }: ChosenFolders,
) =>
  (junk === undefined || junk !== trash) &&
  value.mailboxes.find(({ id }) => id === connection)?.provider === 'imap';

const sameChoice = (current: ChosenFolders, next: ChosenFolders) =>
  current.junk === next.junk && current.trash === next.trash;

// Convex's row revision cannot make an older authenticated record newer than one already read.
const knownVersion = (state: ProfileState, record: ProfileRecord) => {
  if (record.kind === 'profile') {
    return state.profiles.find(({ id }) => id === record.id)?.version;
  }
  if (record.kind === 'sending') {
    return state.sending?.find(({ profile }) => profile === record.profile)
      ?.version;
  }
  return connectionRecords(state, record.kind).find(
    (known) => known.record === record.record,
  )?.version;
};
const olderRecord = (state: ProfileState, record: ProfileRecord) => {
  const version = knownVersion(state, record);
  return version !== undefined && record.version < version;
};

// A connection this device can send from: neither receive-only nor needing authorization.
const sendable = (mailbox: RegistrationRecord['mailboxes'][number]) =>
  !mailbox.authorizationNeeded &&
  (mailbox.provider !== 'imap' || mailbox.smtp !== undefined);

const named = (name: string) => {
  const trimmed = name.trim();
  return trimmed.length === 0
    ? failWith('unavailable')
    : Effect.succeed(trimmed);
};

// The next definition publishes pending edits together, or only its identity/version for removal.
const publicationOf = (
  { id, version, pending, name, pendingStyle, ...stored }: Profile,
  removed: boolean,
): ProfileRecord => ({
  kind: 'profile',
  id,
  version: (version ?? 0) + 1,
  ...(removed
    ? {}
    : { name: pending ?? name, ...styleOf(pendingStyle ?? stored) }),
});

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
    const stored = records[index];
    if (record === null) {
      next = withoutUnreadable(next, stored?.payloadIdentifier);
    } else {
      replayed ||= olderRecord(next, record);
      next = olderRecord(next, record)
        ? next
        : withRecord(next, record, {
            updatedAt: stored?.updatedAt ?? 0,
            payloadIdentifier: stored?.payloadIdentifier,
          });
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

type Display = Readonly<{
  record: string;
  epoch: string;
  profile?: string;
  position?: number;
  ownership?: number;
  color?: string;
}>;

// The display record of one incarnation of a connection, or none for a new incarnation.
const displayOf = (state: ProfileState, record: string, epoch: string) =>
  state.display?.find((item) => item.record === record && item.epoch === epoch);
// Where a display record arranges its connection, and its stored Color, without absent keys.
const placeOf = (display: Omit<Display, 'record' | 'epoch'> | undefined) =>
  display?.profile === undefined ||
  display.position === undefined ||
  display.ownership === undefined
    ? {}
    : {
        profile: display.profile,
        position: display.position,
        ownership: display.ownership,
      };
const colorOf = (display: Omit<Display, 'record' | 'epoch'> | undefined) =>
  display?.color === undefined ? {} : { color: display.color };
const sameDisplay = (
  current: Omit<Display, 'record' | 'epoch'>,
  next: Omit<Display, 'record' | 'epoch'>,
) =>
  current.profile === next.profile &&
  current.position === next.position &&
  current.ownership === next.ownership &&
  current.color === next.color;

// Whether the Profile owns a live connection, one that may still be live, or none.
const ownership = (
  state: ProfileState,
  id: string,
  epochs: ReadonlyMap<string, string | null>,
) => {
  const owned = state.owners.filter((owner) => owner.profile === id);
  // An owned connection whose descriptor Product Sync no longer lists may still be live.
  if (owned.some((owner) => !epochs.has(owner.record))) {
    return 'unknown';
  }
  return owned.some((owner) => epochs.get(owner.record) === owner.epoch)
    ? 'live'
    : 'empty';
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
    // Readable mailbox descriptors' epochs by record; null once removed. Unreadable records
    // prevent publication without discarding evidence that cancels a stale removal.
    descriptorEpochs: Effect.Effect<
      Readonly<{
        epochs: ReadonlyMap<string, string | null>;
        readable: boolean;
      }>,
      E
    >;
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
    for (const prefix of [
      'profile.',
      'mailbox-profile.',
      'mailbox-notifications.',
      'mailbox-folders.',
      'mailbox-display.',
      'profile-sending.',
    ]) {
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

  // This Profile's live or unknown ownership cancels removal even when unrelated records cannot
  // open. Without that ownership, unreadable records keep removal pending.
  const pendingRemoval = Effect.fnUntraced(function* (
    state: ProfileState,
    id: string,
    readable: boolean,
  ) {
    return yield* descriptorEpochs.pipe(
      Effect.map(({ epochs, readable: descriptorsReadable }) => {
        if (ownership(state, id, epochs) !== 'empty') {
          return 'cancel' as const;
        }
        return readable && descriptorsReadable
          ? ('publish' as const)
          : ('retry' as const);
      }),
      Effect.catchIf(
        (error) =>
          error instanceof RegistrationRejected && error.code === 'unavailable',
        () => Effect.succeed('retry' as const),
      ),
    );
  });

  // Reads every Profile record and publishes pending names and unpublished style edits. A CAS
  // loss keeps those edits for the next pass; an authenticated matching record settles them.
  const synchronize = Effect.gen(function* () {
    const learned = yield* refreshed(yield* known);
    let { state } = learned;
    for (const profile of state.profiles) {
      const { id, pending, pendingStyle, updatedAt } = profile;
      const removal =
        profile.pendingRemoval === true
          ? yield* pendingRemoval(state, id, learned.readable)
          : undefined;
      // A later move invalidates the empty-Profile removal; retain its ownership instead.
      if (removal === 'cancel') {
        const { pendingRemoval: _, ...restored } = profile;
        const next = {
          ...state,
          profiles: state.profiles.map((item) =>
            item.id === id ? restored : item,
          ),
        };
        yield* save(state, next);
        state = next;
      } else if (
        removal !== 'retry' &&
        (pending !== undefined ||
          pendingStyle !== undefined ||
          removal === 'publish')
      ) {
        ({ state } = yield* put(state, [
          {
            record: publicationOf(profile, removal === 'publish'),
            expectedUpdatedAt: updatedAt,
          },
        ]));
      }
    }
  });

  // Names a new Profile in the vault, which publishes it with its style once Product Sync is
  // reachable, and returns its opaque identifier, which never changes.
  const create = Effect.fnUntraced(function* (
    name: string,
    style: ProfileStyle,
  ) {
    const pending = yield* named(name);
    const state = yield* known;
    const id = yield* freshId;
    yield* step(() =>
      vault.recordProfiles({
        ...state,
        profiles: [...state.profiles, { id, pending, ...styleOf(style) }],
      }),
    );
    return id;
  });

  const rename = Effect.fnUntraced(function* (id: string, name: string) {
    const chosen = yield* named(name);
    const state = yield* known;
    const profile = state.profiles.find((item) => item.id === id);
    if (
      profile === undefined ||
      isRemoved(profile) ||
      profile.pendingRemoval === true
    ) {
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

  // Replaces a Profile's style. A published Profile changes through Product Sync with its stored
  // name; one not yet published keeps the style to publish with its name.
  const restyle = Effect.fnUntraced(function* (
    id: string,
    style: ProfileStyle,
  ) {
    const before = yield* known;
    const draft = before.profiles.find((item) => item.id === id);
    if (
      draft !== undefined &&
      draft.pendingRemoval !== true &&
      (draft.version === undefined || draft.pendingStyle !== undefined)
    ) {
      const { color: _color, icon: _icon, ...rest } = draft;
      return yield* save(before, {
        ...before,
        profiles: before.profiles.map((item) =>
          item === draft
            ? { ...rest, ...styleOf(style), pendingStyle: styleOf(style) }
            : item,
        ),
      });
    }
    const { state } = yield* refreshed(before);
    const profile = state.profiles.find((item) => item.id === id);
    if (
      profile?.version === undefined ||
      profile.name === undefined ||
      profile.pendingRemoval === true
    ) {
      return yield* failWith('unavailable');
    }
    yield* commit(state, [
      {
        record: {
          kind: 'profile',
          id,
          version: profile.version + 1,
          name: profile.name,
          ...styleOf(style),
        },
        expectedUpdatedAt: profile.updatedAt,
      },
    ]);
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
    const described = yield* descriptorEpochs;
    if (!described.readable) {
      return yield* failWith('unavailable');
    }
    const owned = ownership(state, id, described.epochs);
    if (owned !== 'empty') {
      return yield* failWith(
        owned === 'live' ? 'profile-in-use' : 'unavailable',
      );
    }
    yield* commit(state, [
      {
        record: { kind: 'profile', id, version: (profile.version ?? 0) + 1 },
        expectedUpdatedAt: profile.updatedAt,
      },
    ]).pipe(
      // A delayed first publication can still arrive after the fence lifts. Keep its removal
      // durable until synchronization can publish the tombstone.
      Effect.catchIf(
        (error) =>
          error instanceof RegistrationRejected &&
          error.code === 'upgrade-required' &&
          profile.version === undefined,
        () =>
          save(state, {
            ...state,
            profiles: state.profiles.map((item) =>
              item === profile ? { id, pendingRemoval: true } : item,
            ),
          }),
      ),
    );
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
                ...(target.name === undefined
                  ? {}
                  : { name: target.name, ...styleOf(target) }),
              },
              expectedUpdatedAt: target.updatedAt,
            },
          ]),
    ]);
  });

  // Turns New Mail Notifications on or off for the current incarnation of one of this device's
  // connections. The change needs Product Sync: one that does not commit leaves the stored policy.
  const notify = Effect.fnUntraced(function* (
    value: RegistrationRecord,
    connection: string,
    enabled: boolean,
  ) {
    const { record, epoch } = yield* incarnationOf(value, connection);
    const { state, readable } = yield* refreshed(yield* known);
    if (!readable) {
      return yield* failWith('unavailable');
    }
    const current = state.notifications?.find(
      (policy) => policy.record === record,
    );
    if (current?.epoch === epoch && current.enabled === enabled) {
      return;
    }
    yield* commit(state, [
      {
        record: {
          kind: 'notifications',
          record,
          epoch,
          version: (current?.version ?? 0) + 1,
          enabled,
        },
        expectedUpdatedAt: current?.updatedAt,
      },
    ]);
  });

  // Chooses the folders the current incarnation of one of this device's IMAP connections uses as
  // Spam and Trash. The choice needs Product Sync: one that does not commit leaves the stored one.
  const chooseFolders = Effect.fnUntraced(function* (
    value: RegistrationRecord,
    connection: string,
    folders: ChosenFolders,
  ) {
    if (!choosable(value, connection, folders)) {
      return yield* failWith('unavailable');
    }
    const { record, epoch } = yield* incarnationOf(value, connection);
    const { state, readable } = yield* refreshed(yield* known);
    if (!readable) {
      return yield* failWith('unavailable');
    }
    const current = state.folders?.find((choice) => choice.record === record);
    if (current?.epoch === epoch && sameChoice(current, folders)) {
      return;
    }
    yield* commit(state, [
      {
        record: {
          kind: 'folders',
          record,
          epoch,
          version: (current?.version ?? 0) + 1,
          ...chosenOf(folders),
        },
        expectedUpdatedAt: current?.updatedAt,
      },
    ]);
  });

  // Refuses a display edit for an incarnation Product Sync no longer holds live: another device
  // removed the connection or added it again since this device last synchronized, so the edit
  // would overwrite the current incarnation's record. One that lands between this read and the
  // write is stored under the old epoch, which the current incarnation reads as no record.
  const stillLive = Effect.fnUntraced(function* (
    incarnations: ReadonlyArray<Readonly<{ record: string; epoch: string }>>,
  ) {
    const { epochs } = yield* descriptorEpochs;
    if (incarnations.some(({ record }) => !epochs.has(record))) {
      return yield* failWith('unavailable');
    }
    if (
      incarnations.some(({ record, epoch }) => epochs.get(record) !== epoch)
    ) {
      return yield* failWith('profile-changed');
    }
  });

  // Rewrites each incarnation's display record that changes. The change needs Product Sync: one
  // that does not commit leaves every stored record.
  // Once any record changes, every record is written, so an edit made concurrently on another
  // device conflicts with this one instead of combining with it.
  const commitDisplay = (state: ProfileState, displays: readonly Display[]) => {
    const writes = displays.map(({ record, epoch, ...next }) => {
      const current = state.display?.find((item) => item.record === record);
      return {
        // An incarnation without a record is unarranged and uncolored.
        changed: !sameDisplay(current?.epoch === epoch ? current : {}, next),
        write: {
          record: {
            kind: 'display' as const,
            record,
            epoch,
            version: (current?.version ?? 0) + 1,
            ...next,
          },
          expectedUpdatedAt: current?.updatedAt,
        },
      };
    });
    return writes.some(({ changed }) => changed)
      ? commit(
          state,
          writes.map(({ write }) => write),
        )
      : Effect.void;
  };

  // Arranges every connection of one Mail Profile in `order`, or with no order returns them to the
  // order they were added. Other Profiles' connections and every Color stay as they are.
  const arrange = Effect.fnUntraced(function* (
    value: RegistrationRecord,
    profile: string,
    order: readonly string[],
  ) {
    const { state, readable } = yield* refreshed(yield* known);
    if (!readable) {
      return yield* failWith('unavailable');
    }
    const records = new Map(
      stateOf(value)?.mailboxes.map(({ id, record }) => [id, record]),
    );
    const owned = value.mailboxes.filter(
      ({ id, epoch }) => ownerOf(state, records.get(id), epoch) === profile,
    );
    // Every connection a display record names has a record and an epoch.
    const incarnations = owned.flatMap(({ id, epoch }) => {
      const record = records.get(id);
      return record === undefined || epoch === undefined
        ? []
        : [{ id, record, epoch }];
    });
    const complete =
      order.length === owned.length &&
      owned.every(({ id }) => order.includes(id));
    if ((order.length > 0 && !complete) || incarnations.length < owned.length) {
      return yield* failWith('unavailable');
    }
    yield* stillLive(incarnations);
    yield* commitDisplay(
      state,
      incarnations.map(({ id, record, epoch }) => {
        const position = order.indexOf(id);
        return {
          record,
          epoch,
          ...(position === -1
            ? {}
            : {
                profile,
                position,
                ownership: ownershipVersion(state, record, epoch),
              }),
          ...colorOf(displayOf(state, record, epoch)),
        };
      }),
    );
  });

  // Gives the current incarnation of one of this device's connections a display Color, or none.
  const colorConnection = Effect.fnUntraced(function* (
    value: RegistrationRecord,
    connection: string,
    color: ProfileColor | undefined,
  ) {
    const { record, epoch } = yield* incarnationOf(value, connection);
    const { state, readable } = yield* refreshed(yield* known);
    if (!readable) {
      return yield* failWith('unavailable');
    }
    yield* stillLive([{ record, epoch }]);
    yield* commitDisplay(state, [
      {
        record,
        epoch,
        ...placeOf(displayOf(state, record, epoch)),
        ...(color === undefined ? {} : { color }),
      },
    ]);
  });

  // The primary address of a live connection the Profile owns and this device can send from.
  const sendingIdentity = Effect.fnUntraced(function* (
    value: RegistrationRecord,
    state: ProfileState,
    { profile, connection }: Readonly<{ profile: string; connection: string }>,
  ) {
    const mailbox = value.mailboxes.find(({ id }) => id === connection);
    const { record, epoch } = yield* incarnationOf(value, connection);
    if (
      mailbox === undefined ||
      !sendable(mailbox) ||
      ownerOf(state, record, epoch) !== profile
    ) {
      return yield* failWith('unavailable');
    }
    yield* stillLive([{ record, epoch }]);
    return { record, epoch, address: mailbox.address };
  });

  // Makes the primary address of one of this device's connections the Default Sending Identity of
  // the Mail Profile that owns it, or with no connection clears that Profile's default. A
  // connection this device cannot send from, receive-only or needing authorization, is refused.
  const chooseSending = Effect.fnUntraced(function* (
    value: RegistrationRecord,
    profile: string,
    connection: string | undefined,
  ) {
    const { state, readable } = yield* refreshed(yield* known);
    if (!readable || !receives(state, profile)) {
      return yield* failWith('unavailable');
    }
    const identity =
      connection === undefined
        ? undefined
        : yield* sendingIdentity(value, state, { profile, connection });
    const write = sendingWrite(state, profile, identity);
    if (write !== undefined) {
      yield* commit(state, [write]);
    }
  });

  return {
    synchronize,
    create,
    rename,
    restyle,
    remove,
    move,
    notify,
    chooseFolders,
    arrange,
    colorConnection,
    chooseSending,
  };
}
