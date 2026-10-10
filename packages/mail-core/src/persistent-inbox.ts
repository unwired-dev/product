import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import {
  decodeDiagnostic,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';
import { fixtureMessages, MessageSchema } from './index.ts';

const Snapshot = Schema.Struct({
  version: Schema.Literal(1),
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  messages: Schema.Array(MessageSchema),
});
const decodeSnapshot = Schema.decodeUnknownEffect(
  Schema.fromJsonString(Snapshot),
);
const isLocked = Schema.is(Schema.Struct({ code: Schema.Literal('locked') }));
const encodeSeed = Schema.encodeUnknownEffect(
  Schema.fromJsonString(Schema.Array(MessageSchema)),
);

export interface NativeInboxStorage {
  readonly open: (seed: string) => Promise<unknown>;
  readonly setUnread: (id: string, unread: boolean) => Promise<unknown>;
}

// Protected device data is unavailable while the device is locked; it is an expected state.
class StorageLocked extends Schema.TaggedError<StorageLocked>()(
  'StorageLocked',
  {},
) {}

class StorageFailure extends Schema.TaggedError<StorageFailure>()(
  'StorageFailure',
  {
    cause: Schema.Defect(),
    // Logged instead of the cause; see rejectionDiagnostic.
    diagnostic: Schema.String,
  },
) {}

export type InboxState =
  | { readonly kind: 'loading' | 'locked' | 'failed' }
  | {
      readonly kind: 'ready';
      readonly messages: typeof Snapshot.Type.messages;
    };

const invalid = (error: Schema.SchemaError) =>
  new StorageFailure({ cause: error, diagnostic: decodeDiagnostic(error) });

// Calls a native storage operation or seed provider.
const call = (operation: () => Promise<unknown>) =>
  Effect.tryPromise({
    try: operation,
    catch: (cause) =>
      isLocked(cause)
        ? new StorageLocked()
        : new StorageFailure({ cause, diagnostic: rejectionDiagnostic(cause) }),
  });

// A locked store is expected while the device is locked; any other failure is logged.
const synchronize = Effect.fnUntraced(
  function* (
    operation: Effect.Effect<unknown, StorageLocked | StorageFailure>,
  ) {
    const snapshot = yield* decodeSnapshot(yield* operation).pipe(
      Effect.mapError(invalid),
    );
    return { kind: 'ready', messages: snapshot.messages } as const;
  },
  Effect.catchTags({
    StorageLocked: () => Effect.succeed({ kind: 'locked' } as const),
    StorageFailure: (error) =>
      Effect.logError('Private Inbox storage failed:', error.diagnostic).pipe(
        Effect.as({ kind: 'failed' } as const),
      ),
  }),
);

export function createPersistentInbox(
  storage: NativeInboxStorage,
  initialMessages: () => Promise<
    ReadonlyArray<typeof MessageSchema.Type>
  > = () => Promise.resolve(fixtureMessages),
) {
  const semaphore = Semaphore.makeUnsafe(1);
  let state: InboxState = { kind: 'loading' };
  const listeners = new Set<() => void>();
  const publish = (next: InboxState) => {
    state = next;
    for (const listener of listeners) {
      listener();
    }
  };
  const execute = (
    operation: Effect.Effect<unknown, StorageLocked | StorageFailure>,
  ) =>
    runLogged(
      synchronize(operation).pipe(
        Effect.flatMap((next) =>
          Effect.sync(() => {
            publish(next);
          }),
        ),
        semaphore.withPermit,
      ),
    );
  return {
    getSnapshot: () => state,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    load: () =>
      execute(
        Effect.gen(function* () {
          const seed = yield* encodeSeed(yield* call(initialMessages)).pipe(
            Effect.mapError(invalid),
          );
          return yield* call(() => storage.open(seed));
        }),
      ),
    setUnread: (id: string, unread: boolean) =>
      execute(call(() => storage.setUnread(id, unread))),
  };
}

export type PersistentInbox = ReturnType<typeof createPersistentInbox>;
