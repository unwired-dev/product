import { productSyncKeyRotationRequiredErrorCode } from '@private-email/contracts/productSync';
import * as Arr from 'effect/Array';
import * as Effect from 'effect/Effect';
import * as Order from 'effect/Order';
import * as Random from 'effect/Random';
import * as Schema from 'effect/Schema';

import type {
  MailboxChange,
  MailboxDescriptor,
  NativeRegistrationVault,
  ProductSyncState,
  RegistrationRecord,
} from './registration-vault.ts';
import type { PrivateSyncStateSchema } from './registration.ts';

import {
  backendCode,
  endsAccess,
  failWith,
  nativeSteps,
  unreadable,
} from './registration-native.ts';
import {
  EncryptedPayload,
  Initialization,
  StoredPayload,
  StoredPayloadPage,
} from './registration-replies.ts';
import { MailboxDescriptorSchema } from './registration-vault.ts';

// The epoch every device gives a descriptor written before epochs, so their upgrades agree.
const legacyEpoch = 'legacy';
// Convex serves at most this many records per page.
const pageSize = 100;

const KeyRing = Schema.Struct({
  recoveryEnvelope: EncryptedPayload,
  recoveryVerifier: Schema.NonEmptyString,
  deviceKey: Schema.NonEmptyString,
});
const Admission = Schema.Struct({ admitted: Schema.Boolean });
const Opened = Schema.Array(Schema.NullOr(MailboxDescriptorSchema));
type PrivateSyncState = typeof PrivateSyncStateSchema.Type;

// A removal moved the account to a newer key epoch; the write is sealed again after adopting it.
class KeyRotationRequired extends Schema.TaggedError<KeyRotationRequired>()(
  'KeyRotationRequired',
  {},
) {}

type Vault = NonNullable<ProductSyncState['vault']>;
type Removal = Vault['removals'][number];
// One of this device's connections as synchronization sees it.
type Connection = Vault['mailboxes'][number] &
  Readonly<{ address: string; epoch?: string; usable: boolean }>;
type Stored = Map<
  string,
  Readonly<{ descriptor?: MailboxDescriptor; updatedAt: number }>
>;
// What synchronization does with one connection: purge it, publish its descriptor (at its own
// epoch, or a fresh one when it has none), record the descriptor's epoch and possibly publish an
// update, or leave it as it is.
type Action =
  | Readonly<{ kind: 'purge' }>
  | Readonly<{ kind: 'publish'; epoch?: string; canAdopt: boolean }>
  | Readonly<{ kind: 'record'; epoch: string; publish: boolean }>
  | Readonly<{ kind: 'keep' }>;

const purge: Action = { kind: 'purge' };
const keep: Action = { kind: 'keep' };
const publishOwn = (connection: Connection, canAdopt: boolean): Action => ({
  kind: 'publish',
  ...(connection.epoch === undefined ? {} : { epoch: connection.epoch }),
  canAdopt,
});

// The only copy of a Recovery Key not yet backed up, or a removal whose outcome is unknown.
const holdsUnsettledKeys = (vault: Vault | undefined) =>
  (vault?.recoveryKey !== undefined && !vault.recoveryKeyConfirmed) ||
  vault?.revocation?.submitted === true;

// Pre-epoch removal intent names the legacy incarnation, including after another device's
// upgrade. It is never a wildcard over later additions.
const matches = (removal: Removal, descriptor: MailboxDescriptor) =>
  descriptor.epoch === undefined ||
  (removal.epoch ?? legacyEpoch) === descriptor.epoch;

// A removed descriptor purges every authorization except one added on this device after the
// removal by explicit consent, which starts a new epoch.
const removedAction = (
  connection: Connection,
  sameEpoch: boolean,
  recreation: boolean,
): Action => {
  if (
    connection.published ||
    (connection.epoch !== undefined && sameEpoch) ||
    (!connection.newlyAuthorized && !recreation)
  ) {
    return purge;
  }
  return connection.usable ? publishOwn(connection, true) : keep;
};

// An authorization from before a removal and a later addition is not carried over.
const laterIncarnationAction = (
  connection: Connection,
  descriptor: MailboxDescriptor,
  {
    recreation,
    unchanged,
  }: Readonly<{ recreation: boolean; unchanged: boolean }>,
): Action => {
  if (
    connection.published ||
    (!connection.newlyAuthorized && !recreation && !unchanged)
  ) {
    return purge;
  }
  // Explicit recreation advances the epoch even if the old removal was never published.
  if (connection.epoch !== undefined && recreation) {
    return publishOwn(connection, true);
  }
  return {
    kind: 'record',
    epoch: descriptor.epoch ?? legacyEpoch,
    publish: false,
  };
};

// First authorization on a new device also upgrades an epochless descriptor to legacy; using its
// fresh epoch would make existing legacy devices lose their valid grants. Published epochs survive
// older-client rewrites, and retained recreation advances them.
const sameIncarnationAction = (
  connection: Connection,
  descriptor: MailboxDescriptor,
  recreation: boolean,
): Action => {
  const epoch =
    descriptor.epoch === undefined && !connection.published && !recreation
      ? legacyEpoch
      : (connection.epoch ?? descriptor.epoch ?? legacyEpoch);
  return {
    kind: 'record',
    epoch,
    publish:
      connection.usable &&
      (descriptor.address !== connection.address || descriptor.epoch !== epoch),
  };
};

// What to do with a connection, given its descriptor as Product Sync stores it.
// fallow-ignore-next-line complexity -- Each condition is one rule of the descriptor epoch protocol.
const actionFor = (
  connection: Connection,
  stored: Stored,
  removals: readonly Removal[],
): Action => {
  const record = stored.get(connection.record);
  if (record === undefined) {
    // Only fresh consent can adopt a losing compare-and-set's winner for an absent descriptor.
    return connection.usable
      ? publishOwn(
          connection,
          !connection.published && connection.newlyAuthorized,
        )
      : keep;
  }
  // A record that fails to open or decode is never shown and never replaced.
  const { descriptor } = record;
  if (descriptor === undefined) {
    return keep;
  }
  const sameEpoch = descriptor.epoch === connection.epoch;
  const recreation = removals.some(
    (removal) => removal.id === connection.id && matches(removal, descriptor),
  );
  if (descriptor.removed === true) {
    return removedAction(connection, sameEpoch, recreation);
  }
  // Only a known descriptor still at its observed epoch proves no intervening removal. An absent
  // descriptor cannot rule out an add/remove/re-add while this device was offline.
  const unchanged =
    connection.observed === true &&
    connection.observedEpoch !== undefined &&
    connection.observedEpoch === (descriptor.epoch ?? '');
  // A descriptor without an epoch predates epochs and is the same incarnation; once upgraded it
  // carries the fixed legacy epoch. A connection without an epoch predates epochs too, so only
  // that legacy epoch, or an observation, shows it was not removed and added again.
  const compatible =
    sameEpoch ||
    descriptor.epoch === undefined ||
    (connection.epoch === undefined &&
      (descriptor.epoch === legacyEpoch || unchanged));
  return compatible
    ? sameIncarnationAction(connection, descriptor, recreation)
    : laterIncarnationAction(connection, descriptor, { recreation, unchanged });
};

const pendingState = (sync: ProductSyncState): PrivateSyncState => {
  if (sync.materialInitialized !== true) {
    return { privateSync: 'setup-pending' };
  }
  return sync.enrollment === undefined
    ? { privateSync: 'enrollment-needed' }
    : {
        privateSync: 'enrollment-pending',
        enrollmentCode: sync.enrollment.code,
        ...(sync.enrollment.notice === undefined
          ? {}
          : { enrollmentNotice: sync.enrollment.notice }),
      };
};

const keyState = (vault: Vault, holdsKey: boolean): PrivateSyncState => {
  if (!vault.published) {
    return { privateSync: 'setup-pending' };
  }
  if (!vault.recoveryKeyConfirmed && vault.recoveryKey !== undefined) {
    return { privateSync: 'recovery-key', recoveryKey: vault.recoveryKey };
  }
  return { privateSync: holdsKey ? 'ready' : 'enrollment-needed' };
};

// Other devices this one can approve or remove, only while it holds the account keys.
const deviceState = (sync: ProductSyncState): PrivateSyncState => {
  // The newest request Convex listed as open; it rejects an approval that arrives too late.
  const request = sync.requests.reduce<
    (typeof sync.requests)[number] | undefined
  >(
    (newest, next) =>
      newest === undefined || newest.expiresAt < next.expiresAt ? next : newest,
    undefined,
  );
  return {
    ...(request === undefined
      ? {}
      : { enrollmentRequest: request.id, enrollmentDevice: request.device }),
    ...(sync.trustedDevices.length === 0
      ? {}
      : {
          trustedDevices: JSON.stringify(
            sync.trustedDevices.map(({ id, name, registeredAt }) => ({
              id,
              name,
              registeredAt,
            })),
          ),
        }),
  };
};

// The status values this device's Product Sync state shows.
export function privateSyncState(value: RegistrationRecord): PrivateSyncState {
  const sync = value.productSync;
  if (sync === undefined) {
    return {};
  }
  if (sync === 'unreadable') {
    return { privateSync: 'unavailable' };
  }
  // A Pending Device shows its Enrollment Code until it is admitted, even with keys it stored.
  if (sync.pending) {
    return pendingState(sync);
  }
  const { vault } = sync;
  // A Trusted Device without local keys never creates replacements for existing key material;
  // its Recovery Key unlocks it. An unknown state, such as a receipt saved before Product Sync,
  // waits for verification.
  if (vault === undefined) {
    return {
      privateSync:
        sync.materialInitialized === true
          ? 'enrollment-needed'
          : 'setup-pending',
    };
  }
  // Unsettled material stays visible, but does not confer device-key custody.
  if (vault.published && !holdsUnsettledKeys(vault) && !sync.deviceKey) {
    return { privateSync: 'enrollment-needed' };
  }
  const records = new Map(
    vault.mailboxes.map(({ id, record }) => [id, record]),
  );
  // A usable mailbox not yet read back needs a backend session, such as after an Apple relaunch.
  const unsaved = value.mailboxes.some(
    (mailbox) =>
      !mailbox.authorizationNeeded &&
      vault.savedMailboxes?.[records.get(mailbox.id) ?? ''] !== mailbox.address,
  );
  return {
    ...keyState(vault, sync.deviceKey),
    ...(vault.published && sync.deviceKey ? deviceState(sync) : {}),
    // A prepared removal shows its replacement Recovery Key until it is confirmed or cancelled.
    ...(vault.revocation === undefined
      ? {}
      : {
          revocationDevice: vault.revocation.device,
          revocationRecoveryKey: vault.revocation.recoveryKey,
        }),
    ...(vault.readMailboxes === undefined || vault.readMailboxes.length === 0
      ? {}
      : { privateSyncMailboxes: vault.readMailboxes.join('\n') }),
    ...(vault.published && unsaved
      ? { privateSyncPending: 'mailbox' as const }
      : {}),
  };
}

// End-to-End Encrypted Product Sync: initialization, admission and mailbox descriptors. Native code
// holds every key and seals and opens each record; this decides what to read and write.
export function createProductSyncProgram(vault: NativeRegistrationVault) {
  const { native, step, saved, convex, convexReply } = nativeSteps(vault);

  const syncState = saved.pipe(
    Effect.flatMap(({ productSync }) =>
      productSync === undefined || productSync === 'unreadable'
        ? failWith('unavailable')
        : Effect.succeed(productSync),
    ),
  );
  const freshEpoch = Effect.gen(function* () {
    const parts = [];
    for (let index = 0; index < 4; index += 1) {
      parts.push((yield* Random.nextIntBetween(0, 2 ** 32 - 1)).toString(16));
    }
    return parts.join('-');
  });

  // Every mailbox descriptor, read across all pages and opened on this device.
  const descriptors = Effect.gen(function* () {
    const records: Array<typeof StoredPayload.Type> = [];
    let cursor: string | null = null;
    let done = false;
    while (!done) {
      const page: typeof StoredPayloadPage.Type = yield* convex(
        {
          endpoint: 'query',
          path: 'productSync:listEncryptedPayloadsForTrustedDevice',
          args: {
            payloadIdentifierPrefix: 'mailbox.',
            paginationOpts: { cursor, numItems: pageSize },
          },
          session: true,
          device: true,
        },
        StoredPayloadPage,
      );
      records.push(...page.page);
      done = page.isDone;
      cursor = page.continueCursor;
    }
    const opened =
      records.length === 0
        ? []
        : yield* native(() => vault.openMailboxDescriptors(records), Opened);
    if (opened.length !== records.length) {
      return yield* failWith('unavailable');
    }
    const stored: Stored = new Map();
    for (const [index, { payloadIdentifier, updatedAt }] of records.entries()) {
      const descriptor = opened[index] ?? undefined;
      stored.set(payloadIdentifier, {
        ...(descriptor === undefined ? {} : { descriptor }),
        updatedAt,
      });
    }
    return stored;
  });

  // Compare-and-set: the stored descriptor, which differs from ours when another write won, or
  // undefined when it does not open here.
  const put = Effect.fnUntraced(function* (
    record: string,
    descriptor: MailboxDescriptor,
    expectedUpdatedAt: number | undefined,
  ) {
    const sealed = yield* native(
      () => vault.sealMailboxDescriptor(record, descriptor),
      EncryptedPayload,
    );
    const reply = yield* convexReply({
      endpoint: 'mutation',
      path: 'productSync:putEncryptedPayloadIfUnchanged',
      args: {
        payloadIdentifier: record,
        encryptedPayload: sealed,
        ...(expectedUpdatedAt === undefined ? {} : { expectedUpdatedAt }),
      },
      session: true,
      device: true,
    });
    if (!reply.succeeded) {
      const code = reply.errorData?.code;
      return yield* code === productSyncKeyRotationRequiredErrorCode
        ? Effect.fail(new KeyRotationRequired())
        : failWith(backendCode(code));
    }
    const stored = yield* Schema.decodeUnknownEffect(StoredPayload)(
      reply.value,
    ).pipe(Effect.catch(unreadable));
    if (stored.payloadIdentifier !== record) {
      return yield* failWith('unavailable');
    }
    const [winner] = yield* native(
      () => vault.openMailboxDescriptors([stored]),
      Opened,
    );
    return winner ?? undefined;
  });

  // Marks a removal in Product Sync: a tombstone where no descriptor exists, or the live one it
  // removes marked removed. Another device's later addition stays.
  const markRemoved = (
    removal: Removal,
    stored: Stored,
    live: MailboxDescriptor | undefined,
  ) => {
    if (!stored.has(removal.record)) {
      return put(
        removal.record,
        {
          provider: 'gmail',
          address: removal.address,
          epoch: removal.epoch ?? legacyEpoch,
          removed: true,
        },
        undefined,
      );
    }
    return live === undefined
      ? Effect.void
      : put(
          removal.record,
          { ...live, removed: true },
          stored.get(removal.record)?.updatedAt,
        );
  };

  // Marks this device's removals in Product Sync, purges connections another device removed or
  // added again since this device authorized them, publishes descriptors Product Sync lacks, and
  // reads every descriptor back. Returns the decrypted addresses, the descriptors confirmed for
  // this device's connections and every readable descriptor's epoch.
  // fallow-ignore-next-line complexity -- One pass saves at the same checkpoints native synchronization did.
  const mailboxes = Effect.gen(function* () {
    const value = yield* saved;
    const sync = yield* syncState;
    if (sync.vault === undefined) {
      return yield* failWith('unavailable');
    }
    const { removals } = sync.vault;
    const synced = new Map(
      sync.vault.mailboxes.map((entry) => [entry.id, entry]),
    );
    const connections: Connection[] = value.mailboxes.flatMap((mailbox) => {
      const entry = synced.get(mailbox.id);
      return entry === undefined
        ? []
        : [
            {
              ...entry,
              address: mailbox.address,
              ...(mailbox.epoch === undefined ? {} : { epoch: mailbox.epoch }),
              usable: !mailbox.authorizationNeeded,
            },
          ];
    });
    let stored = yield* descriptors;
    // A removal marks only the epoch it removed; a later addition from another device stays.
    const removes = (removal: Removal) => {
      const live = stored.get(removal.record)?.descriptor;
      return live !== undefined &&
        live.removed !== true &&
        matches(removal, live)
        ? live
        : undefined;
    };
    for (const removal of removals) {
      yield* markRemoved(removal, stored, removes(removal));
    }
    if (removals.length > 0) {
      stored = yield* descriptors;
    }

    // What this device's record learns, saved together as each step would leave it.
    const changes = new Map<string, MailboxChange>();
    const change = (id: string, update: Omit<MailboxChange, 'id'>) => {
      changes.set(id, { ...changes.get(id), ...update, id });
    };
    const epochOf = (connection: Connection) => {
      const changed = changes.get(connection.id);
      return changed !== undefined && 'epoch' in changed
        ? (changed.epoch ?? undefined)
        : connection.epoch;
    };
    const save = (settledRemovals: readonly string[] = []) =>
      step(() =>
        vault.recordMailboxChanges([...changes.values()], settledRemovals),
      );
    let purged: string[] = [];
    const removed = new Set<string>();
    let wrote = false;
    const publish = Effect.fnUntraced(function* (
      connection: Connection,
      epoch: string,
      canAdopt: boolean,
    ) {
      change(connection.id, { epoch });
      const winner = yield* put(
        connection.record,
        { provider: 'gmail', address: connection.address, epoch },
        stored.get(connection.record)?.updatedAt,
      );
      wrote = true;
      if (winner === undefined) {
        return;
      }
      if (winner.removed === true || (winner.epoch !== epoch && !canAdopt)) {
        purged.push(connection.id);
        return;
      }
      // Only fresh consent or a matching retained recreation can adopt a losing CAS's winner.
      change(connection.id, { epoch: winner.epoch ?? null, published: true });
      // A later list failure must not lose the confirmed CAS winner across relaunch.
      yield* save();
    });
    const apply = Effect.fnUntraced(function* (
      connection: Connection,
      action: Action,
    ) {
      if (action.kind === 'purge') {
        purged.push(connection.id);
      } else if (action.kind === 'publish') {
        yield* publish(
          connection,
          action.epoch ?? (yield* freshEpoch),
          action.canAdopt,
        );
      } else if (action.kind === 'record') {
        change(connection.id, { epoch: action.epoch });
        if (action.publish) {
          yield* publish(connection, action.epoch, false);
        }
      }
    });
    // Each purge stops its watch while its credential still exists; failed cleanup is retained.
    const purgeConnections = Effect.gen(function* () {
      for (const id of purged) {
        yield* save();
        yield* step(() => vault.purgeMailbox(id));
        removed.add(id);
      }
      purged = [];
    });

    for (const connection of connections) {
      // A later connection's failed write must not discard a removal already learned.
      yield* purgeConnections;
      yield* apply(connection, actionFor(connection, stored, removals));
    }
    yield* purgeConnections;
    if (removals.length > 0 || wrote) {
      stored = yield* descriptors;
    }
    // A removal that is marked, or overtaken by another addition, is done. Missing or unreadable
    // is no evidence that it committed.
    const settled = removals
      .filter((removal) => {
        const descriptor = stored.get(removal.record)?.descriptor;
        return (
          descriptor !== undefined &&
          (descriptor.removed === true || removes(removal) === undefined)
        );
      })
      .map(({ record }) => record);
    const confirmed: Record<string, string> = {};
    for (const connection of connections) {
      const descriptor = removed.has(connection.id)
        ? undefined
        : stored.get(connection.record)?.descriptor;
      // An older client may rewrite the descriptor without an epoch; that keeps the incarnation.
      // Read-back may observe a removal or recreation after this device's write or CAS adoption,
      // which cannot extend that consent to yet another incarnation.
      if (
        descriptor?.removed === true ||
        (descriptor?.epoch !== undefined &&
          descriptor.epoch !== epochOf(connection))
      ) {
        purged.push(connection.id);
      } else if (descriptor !== undefined) {
        change(connection.id, { published: true });
        if (descriptor.address === connection.address) {
          confirmed[connection.record] = connection.address;
        }
      }
    }
    yield* purgeConnections;
    yield* save(settled);
    yield* step(vault.removeQueuedPushRoutes);
    const readable = [...stored].flatMap(([record, { descriptor }]) =>
      descriptor === undefined ? [] : [[record, descriptor] as const],
    );
    const live = readable.flatMap(([, descriptor]) =>
      descriptor.removed === true ? [] : [descriptor.address],
    );
    return {
      addresses: Arr.sort([...new Set(live)], Order.String),
      confirmed,
      epochs: Object.fromEntries(
        readable.map(([record, descriptor]) => [
          record,
          descriptor.epoch ?? '',
        ]),
      ),
    };
  });

  // Keys are created and stored before initialization publishes them, so an interrupted attempt
  // resumes with the same keys. False when the account already holds other key material.
  const initialize = Effect.gen(function* () {
    const ring = yield* native(vault.createKeyRing, KeyRing);
    const { initialized } = yield* convex(
      {
        endpoint: 'mutation',
        path: 'productSync:initialize',
        args: {
          encryptedPayload: ring.recoveryEnvelope,
          recoveryVerifier: ring.recoveryVerifier,
          deviceEncryptionPublicKey: ring.deviceKey,
        },
        session: true,
        device: true,
      },
      Initialization,
    );
    yield* step(() => vault.recordInitialization(initialized));
    return initialized;
  });

  // A Trusted Device that lost its encryption key enrolls again as a new device. Never discards
  // the only copy of an unconfirmed Recovery Key or an unanswered removal.
  const reenrollWithoutKey = Effect.gen(function* () {
    let sync = yield* syncState;
    if (sync.vault?.revocation?.submitted === true) {
      yield* step(vault.adoptRotation);
      sync = yield* syncState;
    }
    if (holdsUnsettledKeys(sync.vault)) {
      return false;
    }
    yield* step(vault.reenroll);
    return true;
  });

  // Only uninitialized accounts create keys; losing initialization discards unpublished keys.
  // Initialization, admission and descriptor publication share one ordered account/session flow.
  // fallow-ignore-next-line complexity -- Each gate is one ordered step of initialization and admission.
  const settle = Effect.gen(function* () {
    let sync = yield* syncState;
    if (
      !sync.pending &&
      (sync.materialInitialized === true || sync.vault?.published === true) &&
      !sync.deviceKey
    ) {
      if (!(yield* reenrollWithoutKey)) {
        return;
      }
      sync = yield* syncState;
    }
    // A Pending Device first has to be admitted; until then it reads and writes nothing.
    if (sync.pending) {
      if (
        sync.materialInitialized !== true ||
        !(yield* native(vault.admitPendingDevice, Admission)).admitted
      ) {
        return;
      }
      sync = yield* syncState;
    }
    if (sync.vault === undefined && sync.materialInitialized !== false) {
      return;
    }
    if (sync.vault?.published === true) {
      yield* step(vault.adoptRotation);
    } else if (!(yield* initialize)) {
      return;
    }
    // A removal that landed meanwhile seals the pending changes again at its epoch.
    const readback = yield* mailboxes.pipe(
      Effect.catchTag('KeyRotationRequired', () =>
        step(vault.adoptRotation).pipe(Effect.andThen(mailboxes)),
      ),
    );
    yield* step(() =>
      vault.recordMailboxReadback(
        readback.addresses,
        readback.confirmed,
        readback.epochs,
      ),
    );
    yield* step(vault.refreshDevices);
  });

  // Synchronizes with this process's verified Product Sign-In. Product Sync stays pending on
  // failure; registration and the mailbox remain usable, and only the end of access fails it.
  const synchronize = Effect.gen(function* () {
    const value = yield* saved;
    if (!value.session || value.productSync === undefined) {
      return;
    }
    yield* step(vault.retryMailboxCleanup);
    yield* settle.pipe(
      Effect.catchTag('KeyRotationRequired', () => failWith('unavailable')),
      Effect.catchIf(
        ({ code }) => !endsAccess.has(code),
        ({ code }) => Effect.logError('Product Sync failed:', `code ${code}`),
      ),
    );
  }).pipe(
    Effect.ensuring(step(vault.finishSynchronization).pipe(Effect.ignore)),
  );

  return { synchronize };
}
