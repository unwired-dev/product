import * as Context from 'effect/Context';
import * as Effect from 'effect/Effect';
import * as Layer from 'effect/Layer';
import * as ManagedRuntime from 'effect/ManagedRuntime';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

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

export interface NativeInboxStorage {
  readonly open: (seed: string) => Promise<unknown>;
  readonly setUnread: (id: string, unread: boolean) => Promise<unknown>;
}

class PrivateStorage extends Context.Service<
  PrivateStorage,
  NativeInboxStorage
>()('@private-email/mail-core/PrivateStorage') {}

// oxlint-disable-next-line unicorn/throw-new-error -- Schema's tagged-error class factory.
class StorageFailure extends Schema.TaggedError<StorageFailure>()(
  'StorageFailure',
  {
    kind: Schema.Literals(['locked', 'failed']),
  },
) {}

export type InboxState =
  | { readonly kind: 'loading' | 'locked' | 'failed' }
  | {
      readonly kind: 'ready';
      readonly messages: typeof Snapshot.Type.messages;
    };

export function createPersistentInbox(
  storage: NativeInboxStorage,
  initialMessages: () => Promise<
    ReadonlyArray<typeof MessageSchema.Type>
  > = () => Promise.resolve(fixtureMessages),
) {
  const runtime = ManagedRuntime.make(Layer.succeed(PrivateStorage, storage));
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
    operation: (native: NativeInboxStorage) => Promise<unknown>,
  ) =>
    runtime.runPromise(
      Effect.gen(function* () {
        const native = yield* PrivateStorage;
        const value = yield* Effect.tryPromise({
          try: () => operation(native),
          catch: (error) =>
            new StorageFailure({ kind: isLocked(error) ? 'locked' : 'failed' }),
        });
        const snapshot = yield* decodeSnapshot(value).pipe(
          Effect.mapError(() => new StorageFailure({ kind: 'failed' })),
        );
        publish({ kind: 'ready', messages: snapshot.messages });
      }).pipe(
        // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
        Effect.catchTag('StorageFailure', (error) =>
          Effect.sync(() => {
            publish({ kind: error.kind });
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
      execute(async (native) =>
        native.open(JSON.stringify(await initialMessages())),
      ),
    setUnread: (id: string, unread: boolean) =>
      execute((native) => native.setUnread(id, unread)),
    dispose: () => runtime.dispose(),
  };
}

export type PersistentInbox = ReturnType<typeof createPersistentInbox>;
