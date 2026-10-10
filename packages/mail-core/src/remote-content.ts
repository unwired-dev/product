import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import { rejectionDiagnostic, runLogged } from './diagnostics.ts';

// How Remote Message Content loads on this device: ask for each presentation (the default),
// never, or always. A Mailbox Connection may override the device's choice.
const Policy = Schema.Literals(['ask', 'never', 'always']);
export type RemoteContentPolicy = typeof Policy.Type;

const Settings = Schema.Struct({
  policy: Policy,
  overrides: Schema.Record(Schema.String, Policy),
});
export type RemoteContentSettings = typeof Settings.Type;

const defaults: RemoteContentSettings = { policy: 'ask', overrides: {} };

// Unreadable or missing settings fall back to asking, which loads nothing without consent.
const decodeStored = Schema.decodeUnknownOption(
  Schema.Struct({ settings: Schema.fromJsonString(Settings) }),
);
// oxlint-disable-next-line node/no-sync -- Pure JSON serialization of locally chosen settings, not synchronous I/O.
const encodeSettings = Schema.encodeSync(Schema.fromJsonString(Settings));

// The native host's device-local settings and the Authorized Remote Content Cache.
export interface NativeRemoteContent {
  // Resolves `{ settings }`: the stored JSON text, or null.
  readonly remoteContentSettings: () => Promise<unknown>;
  readonly setRemoteContentSettings: (settings: string) => Promise<unknown>;
  // Clear Remote Content: removes every cached entry; mail and bodies stay.
  readonly clearRemoteContent: () => Promise<unknown>;
}

export const remoteContentPolicy = (
  settings: RemoteContentSettings,
  connection: string,
): RemoteContentPolicy => settings.overrides[connection] ?? settings.policy;

// A native settings or cache call that failed; its cause is logged only as a diagnostic.
class RemoteContentNativeFailure extends Schema.TaggedError<RemoteContentNativeFailure>()(
  'RemoteContentNativeFailure',
  { cause: Schema.Defect() },
) {}

const call = (request: () => Promise<unknown>) =>
  Effect.tryPromise({
    try: request,
    catch: (cause) => new RemoteContentNativeFailure({ cause }),
  });

const logFailure =
  (message: string) =>
  ({ cause }: Readonly<{ cause: unknown }>) =>
    Effect.logError(message, rejectionDiagnostic(cause));

export function createRemoteContentSettings(native: NativeRemoteContent) {
  const operations = Semaphore.makeUnsafe(1);
  let settings = defaults;
  const listeners = new Set<() => void>();
  const publish = (next: RemoteContentSettings) => {
    settings = next;
    for (const listener of listeners) {
      listener();
    }
  };
  const save = (
    update: (current: RemoteContentSettings) => RemoteContentSettings,
  ) =>
    runLogged(
      operations
        .withPermit(
          Effect.gen(function* () {
            const next = update(settings);
            yield* call(() =>
              native.setRemoteContentSettings(encodeSettings(next)),
            );
            publish(next);
          }),
        )
        .pipe(
          Effect.asVoid,
          Effect.catchTag(
            'RemoteContentNativeFailure',
            logFailure('Remote content settings could not be saved:'),
          ),
        ),
    );
  return {
    getSnapshot: () => settings,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    load: () =>
      runLogged(
        operations
          .withPermit(
            call(() => native.remoteContentSettings()).pipe(
              Effect.tap((reply) =>
                Effect.sync(() => {
                  publish(
                    Option.getOrElse(
                      Option.map(
                        decodeStored(reply),
                        (stored) => stored.settings,
                      ),
                      () => defaults,
                    ),
                  );
                }),
              ),
              Effect.asVoid,
            ),
          )
          .pipe(
            Effect.catchTag(
              'RemoteContentNativeFailure',
              logFailure('Remote content settings could not be read:'),
            ),
          ),
      ),
    setPolicy: (policy: RemoteContentPolicy) =>
      save((current) => ({ ...current, policy })),
    // Without a policy the connection follows the device's choice again.
    setOverride: (connection: string, policy?: RemoteContentPolicy) =>
      save((current) => {
        const { [connection]: _previous, ...others } = current.overrides;
        return {
          ...current,
          overrides:
            policy === undefined ? others : { ...others, [connection]: policy },
        };
      }),
    // Resolves whether every cached entry was removed.
    clear: () =>
      runLogged(
        call(() => native.clearRemoteContent()).pipe(
          Effect.as(true),
          Effect.catchTag('RemoteContentNativeFailure', (failure) =>
            logFailure('Remote content could not be cleared:')(failure).pipe(
              Effect.as(false),
            ),
          ),
        ),
      ),
  };
}

export type RemoteContentSettingsStore = ReturnType<
  typeof createRemoteContentSettings
>;
