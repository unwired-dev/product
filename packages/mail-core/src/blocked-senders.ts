import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { DraftStorageFailure } from './draft-native.ts';
import type { Registration } from './registration.ts';

import { runLogged } from './diagnostics.ts';
import { malformed, native, ownerMismatch } from './draft-native.ts';
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
// milliseconds since the epoch.
const BlockedSenderSchema = Schema.Struct({
  profile: Schema.NonEmptyString,
  address: Schema.String.check(
    Schema.makeFilter((address) => blockedAddress(address) === address),
  ),
  blockedAt: Schema.Finite,
});
export type BlockedSender = typeof BlockedSenderSchema.Type;

// A device-local receipt: this device took one blocked arrival of a connection to Trash, where the
// connection has one, so an arrival reported again, as when the person restores it to the Inbox,
// is never moved again.
const ReceiptSchema = Schema.Struct({
  connection: Schema.NonEmptyString,
  message: Schema.NonEmptyString,
});
type Receipt = typeof ReceiptSchema.Type;

// The newest receipts kept; an arrival older than all of them is not reported again.
const receiptLimit = 1000;

const DocumentSchema = Schema.fromJsonString(
  Schema.Struct({
    senders: Schema.Array(BlockedSenderSchema),
    receipts: Schema.optionalKey(Schema.Array(ReceiptSchema)),
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

// Locked storage is expected while the device is locked; any other failure is logged.
const report = (
  error: Readonly<Pick<DraftStorageFailure, 'kind' | 'diagnostic'>>,
) =>
  error.kind === 'locked'
    ? Effect.void
    : Effect.logError('Blocked Sender storage failed:', error.diagnostic);

const isProfileAddress =
  (profile: string, address: string) => (sender: BlockedSender) =>
    sender.profile === profile && sender.address === address;

// Each Mail Profile's Blocked Senders, stored on this device without network access, and the
// receipts of the arrivals they moved to Trash. They are not synchronized yet.
export function createBlockedSenders(
  storage: NativeBlockedSenders,
  registration: Pick<Registration, 'getSnapshot'>,
) {
  const semaphore = Semaphore.makeUnsafe(1);
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
      };
    });

  // Replaces the stored Blocked Senders and receipts from the revision `stored` read.
  const commit = (
    { owner, revision }: Readonly<{ owner: string; revision: number }>,
    next: Readonly<{
      senders: readonly BlockedSender[];
      receipts: readonly Receipt[];
    }>,
  ) =>
    Effect.gen(function* () {
      const document = yield* Schema.encodeEffect(DocumentSchema)(next).pipe(
        Effect.mapError(malformed),
      );
      const committed = yield* native(
        () => storage.commitBlockedSenders(owner, revision, document),
        CommittedSchema,
      );
      if (committed.owner !== owner) {
        return yield* ownerMismatch();
      }
    });

  // Resolves whether storage holds what `change` makes of the stored Blocked Senders; returning
  // them unchanged writes nothing. No Profile, or an address that is not one plain address, is refused.
  const changing = (
    profile: string,
    address: string,
    change: (
      senders: readonly BlockedSender[],
      address: string,
    ) => readonly BlockedSender[],
  ) => {
    const normalized = blockedAddress(address);
    if (profile === '' || normalized === undefined) {
      return Promise.resolve(false);
    }
    const account = signedIn();
    return runLogged(
      Effect.gen(function* () {
        const stored = yield* opened(account);
        const next = change(stored.senders, normalized);
        if (next !== stored.senders) {
          yield* commit(stored, { senders: next, receipts: stored.receipts });
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
    // `profile`'s Blocked Senders, or undefined while storage cannot read them.
    blockedSenders: (profile: string) =>
      runLogged(
        opened(signedIn()).pipe(
          Effect.map(({ senders }) =>
            senders.filter((sender) => sender.profile === profile),
          ),
          // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
          Effect.catchTag('DraftStorageFailure', (error) =>
            report(error).pipe(Effect.as(undefined)),
          ),
        ),
      ),
    // Blocks `address` for `profile`; one it already blocks keeps its first date.
    block: (profile: string, address: string) =>
      changing(profile, address, (senders, normalized) =>
        senders.some(isProfileAddress(profile, normalized))
          ? senders
          : [
              ...senders,
              { profile, address: normalized, blockedAt: Date.now() },
            ],
      ),
    // Which of a connection's newly arriving `messages` its Mail Profile `profile` blocks: `blocked`
    // names each, which gets no notification, and `move` those this call recorded a receipt for,
    // which the caller moves to Trash. An arrival with a receipt is never moved again, and a receipt
    // storage refuses moves nothing. Undefined while storage cannot read the Blocked Senders.
    screen: (
      profile: string,
      connection: string,
      messages: ReadonlyArray<Readonly<{ id: string; address: string }>>,
    ) => {
      const account = signedIn();
      return runLogged(
        Effect.gen(function* () {
          const stored = yield* opened(account);
          const blocked = new Set(
            messages
              .filter(({ address }) => {
                const normalized = blockedAddress(address);
                return (
                  normalized !== undefined &&
                  stored.senders.some(isProfileAddress(profile, normalized))
                );
              })
              .map(({ id }) => id),
          );
          const move = [...blocked].filter(
            (id) =>
              !stored.receipts.some(
                (receipt) =>
                  receipt.connection === connection && receipt.message === id,
              ),
          );
          if (move.length === 0) {
            return { blocked, move };
          }
          const recorded = yield* commit(stored, {
            senders: stored.senders,
            receipts: [
              ...stored.receipts,
              ...move.map((message) => ({ connection, message })),
            ].slice(-receiptLimit),
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
    // Unblocks `address` for `profile` alone.
    unblock: (profile: string, address: string) =>
      changing(profile, address, (senders, normalized) =>
        senders.some(isProfileAddress(profile, normalized))
          ? senders.filter(
              (sender) => !isProfileAddress(profile, normalized)(sender),
            )
          : senders,
      ),
  };
}
export type BlockedSenders = ReturnType<typeof createBlockedSenders>;
