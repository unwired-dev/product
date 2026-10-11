import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import {
  rejectionCode,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';

// Mail Assistance Enablement as native device storage returns it: the signed-in, admitted Product
// Account, or null without one, and the Mail Profiles that opted in on this device.
const Enablement = Schema.Struct({
  owner: Schema.NullOr(Schema.NonEmptyString),
  profiles: Schema.Array(Schema.NonEmptyString),
});
export type MailAssistanceEnablement = typeof Enablement.Type;

const decodeEnablement = Schema.decodeUnknownEffect(Enablement);

// The native host's device-only enablement for the signed-in Product Account. It is never
// synchronized, and every account purge removes it.
export interface NativeMailAssistance {
  // Resolves `{ owner, profiles }`; an account that is pending or being removed has no owner.
  readonly mailAssistance: () => Promise<unknown>;
  // Replaces the enabled Profiles; refused unless `owner` is still the signed-in account.
  readonly setMailAssistance: (
    owner: string,
    profiles: readonly string[],
  ) => Promise<unknown>;
}

// Off until this device's enablement for the same Product Account and Mail Profile is read.
export const mailAssistanceEnabled = (
  enablement: MailAssistanceEnablement | undefined,
  account: string | undefined,
  profile: string,
) =>
  enablement !== undefined &&
  account !== undefined &&
  enablement.owner === account &&
  enablement.profiles.includes(profile);

// A native call or its reply failed; its cause is logged only as a diagnostic.
class MailAssistanceNativeFailure extends Schema.TaggedError<MailAssistanceNativeFailure>()(
  'MailAssistanceNativeFailure',
  { cause: Schema.Defect() },
) {}

const call = (request: () => Promise<unknown>) =>
  Effect.tryPromise({
    try: request,
    catch: (cause) => new MailAssistanceNativeFailure({ cause }),
  }).pipe(
    Effect.flatMap((reply) =>
      decodeEnablement(reply).pipe(
        Effect.mapError((cause) => new MailAssistanceNativeFailure({ cause })),
      ),
    ),
  );

// Locked storage, or an account whose removal began, simply leaves enablement off.
const expected = new Set(['mailbox-invalidated', 'locked']);
const logFailure =
  (message: string) =>
  ({ cause }: Readonly<{ cause: unknown }>) =>
    expected.has(rejectionCode(cause) ?? '')
      ? Effect.void
      : Effect.logError(message, rejectionDiagnostic(cause));

export function createMailAssistanceEnablement(native: NativeMailAssistance) {
  const operations = Semaphore.makeUnsafe(1);
  let enablement: MailAssistanceEnablement | undefined = undefined;
  let loaded: string | undefined = undefined;
  let generation = 0;
  let change = 0;
  let desired: MailAssistanceEnablement | undefined = undefined;
  let saveState: 'idle' | 'saving' | 'failed' = 'idle';
  let failedSave:
    | Readonly<{ owner: string; profile: string; enabled: boolean }>
    | undefined = undefined;
  const listeners = new Set<() => void>();
  const publish = (next: MailAssistanceEnablement | undefined) => {
    enablement = next;
    for (const listener of listeners) {
      listener();
    }
  };
  // Turning it on never starts inference; each assistance action stays an explicit request.
  const setEnabled = (owner: string, profile: string, enabled: boolean) => {
    if (desired?.owner !== owner) {
      return Promise.resolve();
    }
    const saving = generation;
    change += 1;
    const revision = change;
    const others = desired.profiles.filter((item) => item !== profile);
    const profiles = enabled ? [...others, profile] : others;
    desired = { owner, profiles };
    failedSave = undefined;
    saveState = 'saving';
    // Off applies before queueing storage, and earlier saves cannot turn it back on.
    if (!enabled) {
      enablement = {
        owner,
        profiles: (enablement?.profiles ?? []).filter(
          (item) => item !== profile,
        ),
      };
    }
    publish(enablement);
    return runLogged(
      operations
        .withPermit(
          Effect.gen(function* () {
            if (generation !== saving) {
              return;
            }
            const saved = yield* call(() =>
              native.setMailAssistance(owner, profiles),
            );
            // A registration change meanwhile reads the enablement again instead.
            if (generation === saving && change === revision) {
              saveState = 'idle';
              publish(saved);
            }
          }),
        )
        .pipe(
          Effect.catchTag('MailAssistanceNativeFailure', (failure) =>
            Effect.gen(function* () {
              yield* logFailure(
                'Mail Assistance Enablement could not be saved:',
              )(failure);
              if (generation === saving && change === revision) {
                failedSave = { owner, profile, enabled };
                saveState = 'failed';
                publish(enablement);
              }
            }),
          ),
        ),
    );
  };
  return {
    getSaveState: () => saveState,
    retrySave: (owner: string) =>
      failedSave === undefined || failedSave.owner !== owner
        ? Promise.resolve()
        : setEnabled(failedSave.owner, failedSave.profile, failedSave.enabled),
    setEnabled,
    getSnapshot: () => enablement,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    // Reads the enablement again whenever the registration `scope` (its account, admission and
    // removal) changes. Until that read settles assistance is off, so a purged account signing in
    // again never sees its earlier enablement; an unchanged scope keeps assistance running.
    load: (scope: string) => {
      if (scope === loaded) {
        return Promise.resolve();
      }
      loaded = scope;
      generation += 1;
      const reading = generation;
      desired = undefined;
      failedSave = undefined;
      saveState = 'idle';
      publish(undefined);
      return runLogged(
        operations
          .withPermit(
            call(() => native.mailAssistance()).pipe(
              Effect.tap((read) =>
                Effect.sync(() => {
                  if (generation === reading) {
                    desired = read;
                    publish(read);
                  }
                }),
              ),
            ),
          )
          .pipe(
            Effect.asVoid,
            Effect.catchTag(
              'MailAssistanceNativeFailure',
              logFailure('Mail Assistance Enablement could not be read:'),
            ),
          ),
      );
    },
  };
}

export type MailAssistanceEnablementStore = ReturnType<
  typeof createMailAssistanceEnablement
>;
