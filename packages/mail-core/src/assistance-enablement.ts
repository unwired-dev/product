import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import {
  rejectionCode,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';

// Mail Assistance Enablement as native device storage returns it: the signed-in, admitted Product
// Account, or null without one, the Mail Profiles that opted in on this device, and those of them
// that also opted in to Private Cloud Mail Assistance. Storage saved before that separate consent
// has none, so earlier local consent never permits Private Cloud Compute.
const Enablement = Schema.Struct({
  owner: Schema.NullOr(Schema.NonEmptyString),
  profiles: Schema.Array(Schema.NonEmptyString),
  privateCloud: Schema.Array(Schema.NonEmptyString).pipe(
    Schema.withDecodingDefaultKey(Effect.succeed([])),
  ),
});
export type MailAssistanceEnablement = typeof Enablement.Type;

const decodeEnablement = Schema.decodeUnknownEffect(Enablement);

// The native host's device-only enablement for the signed-in Product Account. It is never
// synchronized, and every account purge removes it.
export interface NativeMailAssistance {
  // Resolves `{ owner, profiles, privateCloud }`; an account that is pending or being removed has
  // no owner.
  readonly mailAssistance: () => Promise<unknown>;
  // Replaces both sets of enabled Profiles together; refused unless `owner` is still the signed-in
  // account.
  readonly setMailAssistance: (
    owner: string,
    profiles: readonly string[],
    privateCloud: readonly string[],
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

// Private Cloud Mail Assistance also needs that Profile's Mail Assistance Enablement.
export const privateCloudEnabled = (
  enablement: MailAssistanceEnablement | undefined,
  account: string | undefined,
  profile: string,
) =>
  mailAssistanceEnabled(enablement, account, profile) &&
  enablement?.privateCloud.includes(profile) === true;

// What one Settings switch changes: a Profile's Mail Assistance, or its Private Cloud consent.
type Choice = Readonly<{
  profile: string;
  enabled: boolean;
  choice: 'local' | 'privateCloud';
}>;

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
  let failedSave: (Choice & Readonly<{ owner: string }>) | undefined =
    undefined;
  const listeners = new Set<() => void>();
  const publish = (next: MailAssistanceEnablement | undefined) => {
    enablement = next;
    for (const listener of listeners) {
      listener();
    }
  };
  // Turning it on never starts inference; each assistance action stays an explicit request.
  // Turning a Profile's Mail Assistance off also withdraws its Private Cloud consent.
  const save = (owner: string, { profile, enabled, choice }: Choice) => {
    // Private Cloud consent is only given on top of that Profile's Mail Assistance Enablement.
    if (
      desired?.owner !== owner ||
      (choice === 'privateCloud' &&
        enabled &&
        !desired.profiles.includes(profile))
    ) {
      return Promise.resolve();
    }
    const saving = generation;
    change += 1;
    const revision = change;
    const without = (profiles: readonly string[]) =>
      profiles.filter((item) => item !== profile);
    const chosen = (profiles: readonly string[]) =>
      enabled ? [...without(profiles), profile] : without(profiles);
    const update = (current: MailAssistanceEnablement) =>
      choice === 'local'
        ? {
            owner,
            profiles: chosen(current.profiles),
            privateCloud: enabled
              ? current.privateCloud
              : without(current.privateCloud),
          }
        : {
            owner,
            profiles: current.profiles,
            privateCloud: chosen(current.privateCloud),
          };
    desired = update(desired);
    const { profiles, privateCloud } = desired;
    failedSave = undefined;
    saveState = 'saving';
    // Off applies before queueing storage, and earlier saves cannot turn it back on.
    if (!enabled) {
      enablement = update(
        enablement ?? { owner, profiles: [], privateCloud: [] },
      );
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
              native.setMailAssistance(owner, profiles, privateCloud),
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
                failedSave = { owner, profile, enabled, choice };
                saveState = 'failed';
                // A failed turn-on lives only in the retry, never in what later saves write.
                if (enabled && desired?.owner === owner) {
                  desired =
                    choice === 'local'
                      ? { ...desired, profiles: without(desired.profiles) }
                      : {
                          ...desired,
                          privateCloud: without(desired.privateCloud),
                        };
                }
                publish(enablement);
              }
            }),
          ),
        ),
    );
  };
  return {
    getSaveState: () => saveState,
    // The choice that failed to save, until a later change or retry.
    getFailedSave: () => failedSave,
    retrySave: (owner: string) =>
      failedSave === undefined || failedSave.owner !== owner
        ? Promise.resolve()
        : save(failedSave.owner, failedSave),
    setEnabled: (owner: string, profile: string, enabled: boolean) =>
      save(owner, { profile, enabled, choice: 'local' }),
    // A Profile's Private Cloud consent, given only while its Mail Assistance is on.
    setPrivateCloud: (owner: string, profile: string, enabled: boolean) =>
      save(owner, { profile, enabled, choice: 'privateCloud' }),
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
