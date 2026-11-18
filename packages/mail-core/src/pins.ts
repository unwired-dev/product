import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { DraftStorageFailure } from './draft-native.ts';
import type { Registration } from './registration.ts';

import { runLogged } from './diagnostics.ts';
import { malformed, native, ownerMismatch } from './draft-native.ts';
import { ownerOf } from './drafts.ts';
import { createSubscribable } from './subscribable.ts';

// A Pin: the Mailbox Connection, the Thread's identity in it and when it was pinned, in
// milliseconds since the epoch. The Thread is the provider's conversation, or one message that has
// none. A Pin never changes a provider flag or star.
const PinSchema = Schema.Struct({
  connection: Schema.NonEmptyString,
  thread: Schema.NonEmptyString,
  pinnedAt: Schema.Finite,
});
export type Pin = typeof PinSchema.Type;

const DocumentSchema = Schema.fromJsonString(
  Schema.Struct({ pins: Schema.Array(PinSchema) }),
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

// The signed-in Product Account's Pins on this device: one document native code keeps encrypted
// for the account that wrote it, like its Mail Templates. Every call rejects with 'locked' while
// the device is locked.
export interface NativePins {
  // Resolves `{ owner, revision, document }`; `document` is null when the account has none.
  readonly openPins: () => Promise<unknown>;
  // Replaces the document only from `expectedRevision` and resolves `{ owner, revision }`.
  readonly commitPins: (
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
    : Effect.logError('Pin storage failed:', error.diagnostic);

// The Thread a message is pinned as: its provider conversation, or the message itself when it has
// none, as an IMAP message.
export const pinnedThread = (
  message: Readonly<{ id: string; threadId?: string }>,
) =>
  message.threadId === undefined || message.threadId === ''
    ? message.id
    : message.threadId;

const isPin = (connection: string, thread: string) => (pin: Pin) =>
  pin.connection === connection && pin.thread === thread;

// Each pinned Thread, stored on this device without network access. Pins are not synchronized
// yet.
export function createPins(
  storage: NativePins,
  registration: Pick<Registration, 'getSnapshot'>,
) {
  const semaphore = Semaphore.makeUnsafe(1);
  // Counts kept Pins and Unpins, so hosts read the Pins again after each, also one storage already
  // held: a host whose last read failed then recovers.
  const changes = createSubscribable(0);
  const signedIn = () => ownerOf(registration.getSnapshot().snapshot);
  // The Pins of `account`, the Product Account signed in when the action was called, so an action
  // that waited, or whose read finished, while another account signed in reads and writes nothing
  // of it.
  const opened = (account: string | undefined) =>
    Effect.gen(function* () {
      const { owner, revision, document } = yield* native(
        storage.openPins,
        OpenedSchema,
      );
      if (owner !== account || signedIn() !== account) {
        return yield* ownerMismatch();
      }
      return { owner, revision, pins: document?.pins ?? [] };
    });

  // Resolves whether storage holds what `change` makes of the stored Pins; returning them unchanged
  // writes nothing. No connection or Thread is refused.
  const changing = (
    connection: string,
    thread: string,
    change: (pins: readonly Pin[]) => readonly Pin[],
  ) => {
    if (connection === '' || thread === '') {
      return Promise.resolve(false);
    }
    const account = signedIn();
    return runLogged(
      Effect.gen(function* () {
        const { owner, revision, pins } = yield* opened(account);
        const next = change(pins);
        if (next === pins) {
          changes.set(changes.getSnapshot() + 1);
          return true;
        }
        const document = yield* Schema.encodeEffect(DocumentSchema)({
          pins: next,
        }).pipe(Effect.mapError(malformed));
        const committed = yield* native(
          () => storage.commitPins(owner, revision, document),
          CommittedSchema,
        );
        if (committed.owner !== owner) {
          return yield* ownerMismatch();
        }
        changes.set(changes.getSnapshot() + 1);
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
    // Calls `listener` after each Pin or Unpin storage holds.
    subscribe: changes.subscribe,
    // The Pins of `connections`, such as a Mail Profile's, or undefined while storage cannot read
    // them.
    pins: (connections: readonly string[]) =>
      runLogged(
        opened(signedIn()).pipe(
          Effect.map(({ pins }) =>
            pins.filter((pin) => connections.includes(pin.connection)),
          ),
          // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
          Effect.catchTag('DraftStorageFailure', (error) =>
            report(error).pipe(Effect.as(undefined)),
          ),
        ),
      ),
    // Pins `connection`'s Thread `thread`; one already pinned keeps its first date.
    pin: (connection: string, thread: string) =>
      changing(connection, thread, (pins) =>
        pins.some(isPin(connection, thread))
          ? pins
          : [...pins, { connection, thread, pinnedAt: Date.now() }],
      ),
    // Unpins `connection`'s Thread `thread` alone.
    unpin: (connection: string, thread: string) =>
      changing(connection, thread, (pins) =>
        pins.some(isPin(connection, thread))
          ? pins.filter((pin) => !isPin(connection, thread)(pin))
          : pins,
      ),
    // Carries `connection`'s Pin of Thread `from` to `to`, keeping its date, also where `to` was
    // pinned again since, as an IMAP message's to the ID a move gave it; without `to`, the Pin is
    // removed.
    move: (connection: string, from: string, to: string | undefined) =>
      changing(connection, from, (pins) => {
        const moved = pins.find(isPin(connection, from));
        if (moved === undefined) {
          return pins;
        }
        const others = pins.filter(
          (pin) =>
            pin !== moved && (to === undefined || !isPin(connection, to)(pin)),
        );
        return to === undefined
          ? others
          : [...others, { ...moved, thread: to }];
      }),
  };
}
export type Pins = ReturnType<typeof createPins>;
