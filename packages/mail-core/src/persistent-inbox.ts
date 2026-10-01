import * as Effect from 'effect/Effect';
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

class StorageFailure extends Schema.TaggedError<StorageFailure>()(
  'StorageFailure',
  {
    kind: Schema.Literals(['locked', 'failed']),
    cause: Schema.Defect(),
  },
) {}

export type InboxState =
  | { readonly kind: 'loading' | 'locked' | 'failed' }
  | {
      readonly kind: 'ready';
      readonly messages: typeof Snapshot.Type.messages;
    };

// A locked store is expected while the device is locked; any other failure is logged.
// Native rejections carry only a code and a fixed message; decode failures log the
// SchemaError message, which names the failing path without its value.
const synchronize = Effect.fnUntraced(
  function* (operation: () => Promise<unknown>) {
    const value = yield* Effect.tryPromise({
      try: operation,
      catch: (cause) =>
        new StorageFailure({
          kind: isLocked(cause) ? 'locked' : 'failed',
          cause,
        }),
    });
    const snapshot = yield* decodeSnapshot(value).pipe(
      Effect.mapError(
        (error) => new StorageFailure({ kind: 'failed', cause: error.message }),
      ),
    );
    return { kind: 'ready', messages: snapshot.messages } as const;
  },
  // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
  Effect.catchTag('StorageFailure', (error) =>
    (error.kind === 'failed'
      ? Effect.logError('Private Inbox storage failed', error.cause)
      : Effect.void
    ).pipe(Effect.as({ kind: error.kind })),
  ),
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
  const execute = (operation: () => Promise<unknown>) =>
    Effect.runPromise(
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
      execute(async () =>
        storage.open(JSON.stringify(await initialMessages())),
      ),
    setUnread: (id: string, unread: boolean) =>
      execute(() => storage.setUnread(id, unread)),
  };
}

export type PersistentInbox = ReturnType<typeof createPersistentInbox>;
