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

// A dot-atom local part (RFC 5322, with RFC 6531's non-ASCII letters) and a domain of letter, digit
// and hyphen labels ending in an alphabetic or IDNA top-level label: no empty, leading or trailing
// dot, no hyphen at a label's edge, and nothing a display name, list or control character adds.
const atom = String.raw`[\p{L}\p{N}!#$%&'*+/=?^_\x60{|}~-]+`;
const label = '[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?';
const plainAddress = new RegExp(
  `^${atom}(?:\\.${atom})*@(?:${label}\\.)+(?:[a-z]{2,63}|xn--[a-z0-9-]{0,58}[a-z0-9])$`,
  'u',
);

// The address a Blocked Sender matches: one plain address, compared as a whole without case, as
// recipient deduplication compares them. A display name, bare domain or list is none.
export const blockedAddress = (address: string) => {
  const normalized = address.trim().toLowerCase();
  return normalized.length <= 254 && plainAddress.test(normalized)
    ? normalized
    : undefined;
};

// A Blocked Sender: an exact normalized address, the Mail Profile that blocks it and when, in
// milliseconds since the epoch, and how many arrivals this device moved to Trash for it since then;
// a block stored before #2141 has no count.
const AddressSchema = Schema.String.check(
  Schema.makeFilter((address) => blockedAddress(address) === address),
);
const BlockedSenderSchema = Schema.Struct({
  profile: Schema.NonEmptyString,
  address: AddressSchema,
  blockedAt: Schema.Finite,
  moved: Schema.optionalKey(Schema.Int),
});
export type BlockedSender = typeof BlockedSenderSchema.Type;

// An address a Mail Profile stopped blocking and when, kept so a device that synchronizes later
// takes the unblock rather than bringing the block back.
const UnblockedSchema = Schema.Struct({
  profile: Schema.NonEmptyString,
  address: AddressSchema,
  unblockedAt: Schema.Finite,
});
type Unblocked = typeof UnblockedSchema.Type;

// One address's latest block or unblock in a Profile and when it was made, as Private Sync holds
// it.
const ChangeSchema = Schema.Struct({
  address: AddressSchema,
  blocked: Schema.Boolean,
  at: Schema.Finite,
});
type Change = typeof ChangeSchema.Type;
// What a Profile's record seals: each of its addresses' latest change.
const RecordJsonSchema = Schema.fromJsonString(
  Schema.Struct({
    profile: Schema.NonEmptyString,
    changes: Schema.Array(ChangeSchema),
  }),
);
const decodeRecord = Schema.decodeUnknownOption(RecordJsonSchema);
const PulledSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  records: Schema.Array(
    Schema.Struct({
      id: Schema.NonEmptyString,
      version: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
      updatedAt: Schema.Finite,
      // Decoded one by one, so a record this device cannot read changes nothing.
      senders: Schema.NullOr(Schema.String),
    }),
  ),
  unreadable: Schema.Array(Schema.NonEmptyString),
});
// Native code accepts a Private Sync record identifier of at most 200 characters.
const publishable = (profile: string) => profile.length <= 200;

// A device-local receipt: this device took one blocked arrival of a connection to Trash, where the
// connection has one, so an arrival reported again, as when the person restores it to the Inbox,
// is not moved again while its receipt is kept. Its sender and receipt time name it, since a move renames an IMAP or
// Microsoft message.
const ReceiptSchema = Schema.Struct({
  connection: Schema.NonEmptyString,
  address: Schema.NonEmptyString,
  receivedAt: Schema.NonEmptyString,
});
type Receipt = typeof ReceiptSchema.Type;

// The newest receipts kept; an arrival whose receipt fell out of them can move again.
const receiptLimit = 1000;

type Stored = Readonly<{
  senders: readonly BlockedSender[];
  receipts: readonly Receipt[];
  unblocked: readonly Unblocked[];
}>;
const DocumentSchema = Schema.fromJsonString(
  Schema.Struct({
    senders: Schema.Array(BlockedSenderSchema),
    receipts: Schema.optionalKey(Schema.Array(ReceiptSchema)),
    unblocked: Schema.optionalKey(Schema.Array(UnblockedSchema)),
  }),
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

// The signed-in Product Account's Blocked Senders on this device: one document native code keeps
// encrypted for the account that wrote it, like its Mail Templates. Every call rejects with
// 'locked' while the device is locked.
export interface NativeBlockedSenders {
  // Resolves `{ owner, revision, document }`; `document` is null when the account has none.
  readonly openBlockedSenders: () => Promise<unknown>;
  // Replaces the document only from `expectedRevision` and resolves `{ owner, revision }`.
  readonly commitBlockedSenders: (
    owner: string,
    expectedRevision: number,
    document: string,
  ) => Promise<unknown>;
}

// Each Mail Profile's Blocked Senders in Private Sync, one record per Profile. Native code seals
// each record to the account and an opaque identifier derived from the Profile's, so Convex holds
// only ciphertext. Every call rejects with 'unavailable' while this device holds no keys or
// Product Sign-In session.
export interface NativeBlockedSenderSync {
  // Resolves `{ owner, records: [{ id, version, updatedAt, senders }], unreadable }`, `senders`
  // being the JSON the record seals. `unreadable` names the Profiles of `known` whose record exists
  // but does not open here.
  readonly pullBlockedSenders: (
    owner: string,
    known: readonly string[],
  ) => Promise<unknown>;
  // Writes Profile `id`'s record, sealing `senders`, only while it is still at `expectedUpdatedAt`
  // (absent: while there is none). Resolves `{ owner, committed, updatedAt? }`.
  readonly pushBlockedSenders: (
    owner: string,
    record: Readonly<{
      id: string;
      version: number;
      senders: string;
      expectedUpdatedAt?: number;
    }>,
  ) => Promise<unknown>;
}

const report = reportPreference('Blocked Sender');

const isProfileAddress =
  (profile: string, address: string) =>
  (sender: Readonly<{ profile: string; address: string }>) =>
    sender.profile === profile && sender.address === address;

// `profile`'s changes this device holds: a block for each Blocked Sender and an unblock for each
// address it stopped blocking.
const changesOf = (stored: Stored, profile: string): Change[] => [
  ...stored.senders
    .filter((sender) => sender.profile === profile)
    .map(({ address, blockedAt }) => ({
      address,
      blocked: true,
      at: blockedAt,
    })),
  ...stored.unblocked
    .filter((unblocked) => unblocked.profile === profile)
    .map(({ address, unblockedAt }) => ({
      address,
      blocked: false,
      at: unblockedAt,
    })),
];

// Each address's later change, by address. At the same instant an unblock wins, since it moves
// nothing; so devices converge whatever order they merge in.
const merged = (changes: readonly Change[]) => {
  const latest = new Map<string, Change>();
  for (const change of changes) {
    const kept = latest.get(change.address);
    latest.set(
      change.address,
      kept === undefined ||
        change.at > kept.at ||
        (change.at === kept.at && !change.blocked)
        ? change
        : kept,
    );
  }
  return Arr.sort(
    latest.values(),
    Order.mapInput(Order.String, ({ address }: Change) => address),
  );
};
const sameChanges = Schema.toEquivalence(Schema.Array(ChangeSchema));

// `stored` with `remote`, another device's changes of `profile`, merged in. A Blocked Sender that
// stays blocked keeps this device's move count, and one blocked elsewhere starts at none.
const adopt = (stored: Stored, profile: string, remote: readonly Change[]) => {
  const local = merged(changesOf(stored, profile));
  const next = merged([...local, ...remote]);
  if (sameChanges(local, next)) {
    return stored;
  }
  const latest = new Map(next.map((change) => [change.address, change]));
  return {
    ...stored,
    senders: [
      ...stored.senders.flatMap((sender) => {
        if (sender.profile !== profile) {
          return [sender];
        }
        const change = latest.get(sender.address);
        return change?.blocked === true
          ? [{ ...sender, blockedAt: change.at }]
          : [];
      }),
      ...next
        .filter(
          ({ address, blocked }) =>
            blocked && !stored.senders.some(isProfileAddress(profile, address)),
        )
        .map(({ address, at }) => ({
          profile,
          address,
          blockedAt: at,
          moved: 0,
        })),
    ],
    unblocked: [
      ...stored.unblocked.filter((unblocked) => unblocked.profile !== profile),
      ...next
        .filter(({ blocked }) => !blocked)
        .map(({ address, at }) => ({ profile, address, unblockedAt: at })),
    ],
  };
};

// The records this device can read; one that does not decode, or names another Profile, is
// unreadable and changes nothing.
const readable = (pulled: typeof PulledSchema.Type) => {
  const unreadable = new Set(pulled.unreadable);
  const records = pulled.records.flatMap(({ senders, ...record }) => {
    const sealed = Option.getOrUndefined(decodeRecord(senders ?? ''));
    if (sealed?.profile !== record.id) {
      unreadable.add(record.id);
      return [];
    }
    return [{ ...record, changes: merged(sealed.changes) }];
  });
  return { records, unreadable };
};

type Pulled = Readonly<{
  version: number;
  updatedAt: number;
  changes: readonly Change[];
}>;

// The Profiles that have changes on this device.
const profilesOf = (stored: Stored) => [
  ...new Set(
    [...stored.senders, ...stored.unblocked].map(({ profile }) => profile),
  ),
];

// A sender's move count. One stored before senders kept it counts its kept receipts that arrived
// since it was blocked.
const movedFor = (sender: BlockedSender, receipts: readonly Receipt[]) =>
  sender.moved ??
  receipts.filter(
    (receipt) =>
      receipt.address === sender.address &&
      Date.parse(receipt.receivedAt) >= sender.blockedAt,
  ).length;

// Each Mail Profile's Blocked Senders, stored on this device without network access, and the
// receipts of the arrivals they moved to Trash. With `sync`, the Blocked Senders also synchronize
// through Private Sync: after each block or unblock and on `synchronize`. Receipts and move counts
// stay on this device.
export function createBlockedSenders(
  storage: NativeBlockedSenders,
  registration: Pick<Registration, 'getSnapshot'>,
  sync?: Readonly<{
    native: NativeBlockedSenderSync;
    // Called when native code purged the account because this device was removed.
    removed?: () => void;
    // Adopts a key epoch another device's removal moved the account to.
    adoptKeyRotation?: () => Promise<unknown>;
  }>,
) {
  const semaphore = Semaphore.makeUnsafe(1);
  // Told after each change this device stores, such as a block or a receipt.
  const listeners = new Set<() => void>();
  const changed = () => {
    for (const listener of listeners) {
      listener();
    }
  };
  const signedIn = () => ownerOf(registration.getSnapshot().snapshot);
  // The Blocked Senders of `account`, the Product Account signed in when the action was called, so
  // an action that waited, or whose read finished, while another account signed in reads and
  // writes nothing of it.
  const opened = (account: string | undefined) =>
    Effect.gen(function* () {
      const { owner, revision, document } = yield* native(
        storage.openBlockedSenders,
        OpenedSchema,
      );
      if (owner !== account || signedIn() !== account) {
        return yield* ownerMismatch();
      }
      return {
        owner,
        revision,
        senders: document?.senders ?? [],
        receipts: document?.receipts ?? [],
        unblocked: document?.unblocked ?? [],
      };
    });

  // Replaces the stored Blocked Senders, unblocks and receipts from the revision `stored` read.
  const commit = (
    { owner, revision }: Readonly<{ owner: string; revision: number }>,
    { senders, receipts, unblocked }: Stored,
  ) =>
    Effect.gen(function* () {
      const document = yield* Schema.encodeEffect(DocumentSchema)({
        senders,
        receipts,
        unblocked,
      }).pipe(Effect.mapError(malformed));
      const committed = yield* native(
        () => storage.commitBlockedSenders(owner, revision, document),
        CommittedSchema,
      );
      if (committed.owner !== owner) {
        return yield* ownerMismatch();
      }
      changed();
    });

  // Writes `profile`'s changes by compare-and-set from `record`, the one this pass read, when they
  // differ from it. Resolves whether another device's write won.
  const publish = Effect.fnUntraced(function* (
    remote: NativeBlockedSenderSync,
    account: string,
    {
      profile,
      changes,
      record,
    }: Readonly<{
      profile: string;
      changes: readonly Change[];
      record: Pulled | undefined;
    }>,
  ) {
    if (record !== undefined && sameChanges(record.changes, changes)) {
      return false;
    }
    const senders = yield* Schema.encodeEffect(RecordJsonSchema)({
      profile,
      changes,
    }).pipe(Effect.mapError(malformed));
    const pushed = yield* native(
      () =>
        remote.pushBlockedSenders(account, {
          id: profile,
          version: (record?.version ?? 0) + 1,
          senders,
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

  // One pass: merges every Profile's record into this device's Blocked Senders, then writes by
  // compare-and-set each record the merge changed. A Profile whose record does not open here keeps
  // its record. Resolves whether another device's write won meanwhile.
  const pass = Effect.fnUntraced(function* (remote: NativeBlockedSenderSync) {
    const account = signedIn();
    if (account === undefined) {
      return false;
    }
    const before = yield* opened(account);
    const pulled = yield* native(
      () => remote.pullBlockedSenders(account, profilesOf(before)),
      PulledSchema,
    );
    if (pulled.owner !== account) {
      return yield* ownerMismatch();
    }
    const { records, unreadable } = readable(pulled);
    const stored = yield* Effect.gen(function* () {
      const read = yield* opened(account);
      const next = records.reduce<Stored>(
        (document, { id, changes }) => adopt(document, id, changes),
        read,
      );
      if (next !== read) {
        yield* commit(read, next);
      }
      return next;
    }).pipe(semaphore.withPermit);
    let conflicted = false;
    for (const profile of profilesOf(stored).filter(
      (id) => !unreadable.has(id) && publishable(id),
    )) {
      conflicted =
        (yield* publish(remote, account, {
          profile,
          changes: merged(changesOf(stored, profile)),
          record: records.find(({ id }) => id === profile),
        })) || conflicted;
    }
    return conflicted;
  });

  const synchronize = preferencePasses('Blocked Sender', pass, sync);

  // Resolves whether storage holds what `change` makes of the stored Blocked Senders, and then
  // publishes it; returning them unchanged writes nothing. No Profile, or an address that is not
  // one plain address, is refused.
  const changing = async (
    profile: string,
    address: string,
    change: (stored: Stored, address: string) => Stored,
  ) => {
    const normalized = blockedAddress(address);
    if (profile === '' || normalized === undefined) {
      return false;
    }
    const account = signedIn();
    const stored = await runLogged(
      Effect.gen(function* () {
        const read = yield* opened(account);
        const next = change(read, normalized);
        if (next !== read) {
          yield* commit(read, next);
        }
        return true;
      }).pipe(
        semaphore.withPermit,
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
    // `profile`'s Blocked Senders, or undefined while storage cannot read them.
    blockedSenders: (profile: string) =>
      runLogged(
        opened(signedIn()).pipe(
          Effect.map(({ senders, receipts }) =>
            senders
              .filter((sender) => sender.profile === profile)
              .map((sender) => ({
                ...sender,
                moved: movedFor(sender, receipts),
              })),
          ),
          // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
          Effect.catchTag('DraftStorageFailure', (error) =>
            report(error).pipe(Effect.as(undefined)),
          ),
        ),
      ),
    // Blocks `address` for `profile`; one it already blocks keeps its first date.
    block: (profile: string, address: string) =>
      changing(profile, address, (stored, normalized) => {
        if (stored.senders.some(isProfileAddress(profile, normalized))) {
          return stored;
        }
        const unblocked = stored.unblocked.find(
          isProfileAddress(profile, normalized),
        );
        return {
          ...stored,
          senders: [
            ...stored.senders,
            {
              profile,
              address: normalized,
              // After the unblock it ends, even when the clock went back.
              blockedAt: Math.max(
                Date.now(),
                (unblocked?.unblockedAt ?? 0) + 1,
              ),
              moved: 0,
            },
          ],
          unblocked: stored.unblocked.filter((kept) => kept !== unblocked),
        };
      }),
    // Which of a connection's newly arriving `messages` its Mail Profile `profile` blocks: `blocked`
    // names each, which gets no notification, and `move` those this call recorded a receipt for,
    // which the caller moves to Trash. An arrival with a kept receipt is not moved again, and a receipt
    // storage refuses moves nothing. A connection that `moves` nothing to Trash now records no
    // receipt. Undefined while storage cannot read the Blocked Senders.
    screen: (
      profile: string,
      connection: Readonly<{ id: string; moves: boolean }>,
      messages: ReadonlyArray<
        Readonly<{ id: string; address: string; receivedAt: string }>
      >,
    ) => {
      const account = signedIn();
      return runLogged(
        Effect.gen(function* () {
          const stored = yield* opened(account);
          const arrivals = messages.flatMap(({ id, receivedAt, ...sender }) => {
            const address = blockedAddress(sender.address);
            return address !== undefined &&
              stored.senders.some(isProfileAddress(profile, address))
              ? [
                  {
                    id,
                    receipt: { connection: connection.id, address, receivedAt },
                  },
                ]
              : [];
          });
          const blocked = new Set(arrivals.map(({ id }) => id));
          const moving = arrivals.filter(
            ({ receipt }) =>
              connection.moves &&
              !stored.receipts.some(
                (kept) =>
                  kept.connection === receipt.connection &&
                  kept.address === receipt.address &&
                  kept.receivedAt === receipt.receivedAt,
              ),
          );
          const move = moving.map(({ id }) => id);
          if (move.length === 0) {
            return { blocked, move };
          }
          const recorded = yield* commit(stored, {
            // A count outlives the receipts, which only keep an arrival from moving twice, so every
            // sender's is stored before older receipts are dropped.
            senders: stored.senders.map((sender) => ({
              ...sender,
              moved:
                movedFor(sender, stored.receipts) +
                moving.filter(
                  ({ receipt }) =>
                    sender.profile === profile &&
                    receipt.address === sender.address,
                ).length,
            })),
            receipts: [
              ...stored.receipts,
              ...moving.map(({ receipt }) => receipt),
            ].slice(-receiptLimit),
            unblocked: stored.unblocked,
          }).pipe(
            Effect.as(true),
            Effect.catchTag('DraftStorageFailure', (error) =>
              report(error).pipe(Effect.as(false)),
            ),
          );
          return { blocked, move: recorded ? move : [] };
        }).pipe(
          semaphore.withPermit,
          // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
          Effect.catchTag('DraftStorageFailure', (error) =>
            report(error).pipe(Effect.as(undefined)),
          ),
        ),
      );
    },
    // Unblocks `address` for `profile` alone, keeping the unblock for Private Sync.
    unblock: (profile: string, address: string) =>
      changing(profile, address, (stored, normalized) => {
        const sender = stored.senders.find(
          isProfileAddress(profile, normalized),
        );
        return sender === undefined
          ? stored
          : {
              ...stored,
              senders: stored.senders.filter((kept) => kept !== sender),
              unblocked: [
                ...stored.unblocked.filter(
                  (kept) => !isProfileAddress(profile, normalized)(kept),
                ),
                {
                  profile,
                  address: normalized,
                  // After the block it ends, even when the clock went back.
                  unblockedAt: Math.max(Date.now(), sender.blockedAt + 1),
                },
              ],
            };
      }),
    // Merges Private Sync into this device's Blocked Senders and publishes this device's changes;
    // resolves once no pass is running.
    synchronize,
  };
}
export type BlockedSenders = ReturnType<typeof createBlockedSenders>;
