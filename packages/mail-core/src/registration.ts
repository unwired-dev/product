import type { Translate } from '@private-email/localization';

import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import {
  decodeDiagnostic,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';

const SignInProviderSchema = Schema.Literals(['google', 'apple']);
export type SignInProvider = typeof SignInProviderSchema.Type;

// End-to-End Encrypted Product Sync on this device.
const PrivateSyncSchema = Schema.Literals([
  'setup-pending',
  'recovery-key',
  'ready',
  'enrollment-needed',
  // Waiting for a trusted device to approve this one with the code it shows.
  'enrollment-pending',
  // This device's Product Sync state cannot be read; registration and mail stay usable.
  'unavailable',
]);
export type PrivateSync = typeof PrivateSyncSchema.Type;

const TrustedDevicesSchema = Schema.fromJsonString(
  Schema.Array(
    Schema.Struct({
      id: Schema.NonEmptyString,
      name: Schema.NonEmptyString,
      // Milliseconds since 1970, within the JavaScript Date range used for display.
      registeredAt: Schema.Finite.check(
        Schema.isBetween({
          minimum: -8_640_000_000_000_000,
          maximum: 8_640_000_000_000_000,
        }),
      ),
    }),
  ),
);
const decodeTrustedDevices = Schema.decodeOption(TrustedDevicesSchema);
const trustedDevicesText = Schema.NonEmptyString.check(
  Schema.makeFilter((value) => Option.isSome(decodeTrustedDevices(value))),
);

// This device's Mailbox Connections in the order they were added. 'cached' opens only the saved
// Inbox until Gmail verifies again; 'authorization' needs Gmail authorized again first.
const MailboxesSchema = Schema.fromJsonString(
  Schema.Array(
    Schema.Struct({
      id: Schema.NonEmptyString,
      address: Schema.NonEmptyString,
      state: Schema.Literals(['connected', 'cached', 'authorization']),
      // A removal/recreation changes this owner lifetime; ordinary verification does not.
      epoch: Schema.optionalKey(Schema.NonEmptyString),
    }),
  ).check(
    Schema.makeFilter(
      (mailboxes) =>
        new Set(mailboxes.map(({ id }) => id)).size === mailboxes.length,
    ),
  ),
);
const decodeMailboxes = Schema.decodeOption(MailboxesSchema);
const mailboxesText = Schema.NonEmptyString.check(
  Schema.makeFilter((value) => Option.isSome(decodeMailboxes(value))),
);
export type MailboxConnection = (typeof MailboxesSchema.Type)[number];

const Account = Schema.Struct({
  productAccountId: Schema.NonEmptyString,
  signInProvider: SignInProviderSchema,
  // An unanswered removal stays resumable instead of reopening account access.
  removalPending: Schema.optionalKey(Schema.Literals(['sign-out', 'deletion'])),
  // The other Sign-In Provider explicitly linked to the same Product Account.
  alternateSignIn: Schema.optionalKey(SignInProviderSchema),
  // Display and contact information only; it never links identities or selects a mailbox.
  contactEmail: Schema.optionalKey(Schema.NonEmptyString),
  // Absent where a host has no Product Sync backend.
  privateSync: Schema.optionalKey(PrivateSyncSchema),
  // Shown only until its setup is confirmed; never stored outside native device storage.
  recoveryKey: Schema.optionalKey(Schema.NonEmptyString),
  // Mailbox addresses read back and decrypted from Product Sync, one per line.
  privateSyncMailboxes: Schema.optionalKey(Schema.NonEmptyString),
  // The connected mailbox is not yet saved to Product Sync; a sign-in will save it.
  privateSyncPending: Schema.optionalKey(Schema.Literal('mailbox')),
  // Shown on a device waiting for approval; it never leaves native device storage otherwise.
  enrollmentCode: Schema.optionalKey(Schema.NonEmptyString),
  // Why an earlier request ended without unlocking this device.
  enrollmentNotice: Schema.optionalKey(
    Schema.Literals(['renewed', 'rejected']),
  ),
  // Only in the reply to a Recovery Key attempt that unlocked nothing.
  recoveryNotice: Schema.optionalKey(Schema.Literal('rejected')),
  // Another device of this Product Account waiting for this trusted device's approval.
  enrollmentRequest: Schema.optionalKey(Schema.NonEmptyString),
  enrollmentDevice: Schema.optionalKey(Schema.NonEmptyString),
  // JSON text listing the account's other Trusted Devices that this device can remove.
  trustedDevices: Schema.optionalKey(trustedDevicesText),
  // JSON text listing this device's Mailbox Connections; absent before the first one.
  mailboxes: Schema.optionalKey(mailboxesText),
  // Only in the reply to a removal of another Trusted Device: 'unconfirmed' when this device has
  // not adopted its own new keys, for example because another device removed it first.
  revocationNotice: Schema.optionalKey(
    Schema.Literals(['removed', 'unconfirmed']),
  ),
});
// The account's Product Sync state, which native device storage reports.
export const PrivateSyncStateSchema = Schema.Struct({
  privateSync: Account.fields.privateSync,
  recoveryKey: Account.fields.recoveryKey,
  privateSyncMailboxes: Account.fields.privateSyncMailboxes,
  privateSyncPending: Account.fields.privateSyncPending,
  enrollmentCode: Account.fields.enrollmentCode,
  enrollmentNotice: Account.fields.enrollmentNotice,
  enrollmentRequest: Account.fields.enrollmentRequest,
  enrollmentDevice: Account.fields.enrollmentDevice,
  trustedDevices: Account.fields.trustedDevices,
});
export const RegistrationSnapshotSchema = Schema.Union([
  Schema.Struct({
    kind: Schema.Literal('signed-out'),
    // This device purged the Product Account after it was removed, or after the Product Account
    // was deleted from this device or another.
    notice: Schema.optionalKey(Schema.Literals(['revoked', 'deleted'])),
  }),
  // Signed in but not admitted: until a Trusted Device approves it or the Recovery Key unlocks
  // it, this device has no account data, no Product Sync and no mailbox.
  Schema.Struct({
    kind: Schema.Literal('device-pending'),
    ...Account.fields,
  }),
  Schema.Struct({
    kind: Schema.Literal('mailbox-needed'),
    ...Account.fields,
    reason: Schema.optionalKey(
      Schema.Literals([
        'cancelled',
        'declined',
        'gmail-unavailable',
        'interrupted',
        'unavailable',
      ]),
    ),
  }),
  // At least one mailbox verified.
  Schema.Struct({
    kind: Schema.Literal('connected'),
    ...Account.fields,
    mailboxes: mailboxesText,
  }),
  // Only saved Inboxes open, until registration verifies again.
  Schema.Struct({
    kind: Schema.Literal('cached'),
    ...Account.fields,
    mailboxes: mailboxesText,
  }),
]);
export type RegistrationSnapshot = typeof RegistrationSnapshotSchema.Type;

export type TrustedDevice = Readonly<{
  id: string;
  name: string;
  registeredAt: number;
}>;

// The native snapshot boundary has already validated this JSON text.
export const trustedDevicesOf = (
  snapshot: RegistrationSnapshot | Readonly<{ trustedDevices?: string }>,
): readonly TrustedDevice[] =>
  !('trustedDevices' in snapshot) || snapshot.trustedDevices === undefined
    ? []
    : Option.getOrThrow(decodeTrustedDevices(snapshot.trustedDevices));

// The native snapshot boundary has already validated this JSON text.
export const mailboxesOf = (
  snapshot: RegistrationSnapshot | Readonly<{ mailboxes?: string }>,
): readonly MailboxConnection[] =>
  !('mailboxes' in snapshot) || snapshot.mailboxes === undefined
    ? []
    : Option.getOrThrow(decodeMailboxes(snapshot.mailboxes));
const sameSnapshot = Schema.toEquivalence(RegistrationSnapshotSchema);

// Native hosts reject with the registration failure code; a cancelled session is not a failure.
const isCancelled = Schema.is(
  Schema.Struct({ code: Schema.Literal('cancelled') }),
);
const isLocked = Schema.is(Schema.Struct({ code: Schema.Literal('locked') }));
const isRemovalRefused = Schema.is(
  Schema.Struct({
    code: Schema.Literals(['removal-refused', 'stale-authentication']),
  }),
);

const LinkFailureSchema = Schema.Literals([
  'identity-owned',
  'stale-authentication',
]);
export type LinkFailure = typeof LinkFailureSchema.Type | 'failed';
const linkFailureCode = Schema.decodeUnknownOption(
  Schema.Struct({ code: LinkFailureSchema }),
);

const isRecoveryKeyMismatch = Schema.is(
  Schema.Struct({ code: Schema.Literal('recovery-key-mismatch') }),
);
export type RecoveryKeyFailure = 'mismatch' | 'failed';

export type RecoveryFailure = 'rejected' | 'failed';

const isEnrollmentCodeInvalid = Schema.is(
  Schema.Struct({ code: Schema.Literal('enrollment-code-invalid') }),
);
const isEnrollmentUnavailable = Schema.is(
  Schema.Struct({ code: Schema.Literal('enrollment-unavailable') }),
);
export type EnrollmentFailure = 'code-invalid' | 'unavailable' | 'failed';

export interface NativeRegistration {
  readonly restore: () => Promise<unknown>;
  readonly signIn: (provider: SignInProvider) => Promise<unknown>;
  // Adds a Gmail mailbox; the first one suggests the Google sign-in unless `chooseAccount`.
  // Adding a mailbox that is already connected authorizes it again instead.
  readonly addMailbox: (chooseAccount: boolean) => Promise<unknown>;
  // Authorizes Gmail again for one Mailbox Connection, with the same Google account.
  readonly authorizeGmail: (connection: string) => Promise<unknown>;
  // Removes a Mailbox Connection from this Product Account; its Gmail mail is untouched.
  readonly removeMailbox: (connection: string) => Promise<unknown>;
  // Verifies the current Product Account and the identity being linked, interactively.
  readonly link: (provider: SignInProvider) => Promise<unknown>;
  // Confirms Recovery Key setup with the final group the person wrote down.
  readonly confirmRecoveryKey: (entry: string) => Promise<unknown>;
  // Unlocks this device's private data with the Recovery Key when no trusted device can.
  readonly recoverWithRecoveryKey: (entry: string) => Promise<unknown>;
  // Seals this device's keys to another device, unlocked by the code that device shows.
  readonly approveEnrollment: (
    requestId: string,
    code: string,
  ) => Promise<unknown>;
  readonly declineEnrollment: (requestId: string) => Promise<unknown>;
  // Removes another Trusted Device after an interactive Product Sign-In and rotates the keys.
  readonly revokeTrustedDevice: (trustedDeviceId: string) => Promise<unknown>;
  // Checks for an approval of this device, or for another device waiting for one.
  readonly refreshPrivateSync: () => Promise<unknown>;
  // Unregisters this Trusted Device, then removes the Product Account's data from this device.
  readonly signOut: () => Promise<unknown>;
  // Permanently deletes the Product Account after an interactive Product Sign-In.
  readonly deleteProductAccount: () => Promise<unknown>;
}

// Shared flows compose with the store's run; native adapters keep their Promise interface.
export type RegistrationPrograms = {
  readonly [Method in keyof NativeRegistration]: (
    ...args: Parameters<NativeRegistration[Method]>
  ) => Effect.Effect<unknown, unknown>;
};

type RegistrationState = Readonly<{
  snapshot: RegistrationSnapshot;
  busy: boolean;
  failed: boolean;
  // Saved registration cannot be read until the device is unlocked; the snapshot is not its status.
  locked?: true;
  // A failed link leaves the Product Account and its sign-ins unchanged.
  linkFailure?: LinkFailure;
  recoveryKeyFailure?: RecoveryKeyFailure;
  // A failed Recovery Key unlock leaves this device and the account's keys unchanged.
  recoveryFailure?: RecoveryFailure;
  // A failed approval leaves this device and the requesting one unchanged.
  enrollmentFailure?: EnrollmentFailure;
  revocationFailed?: true;
  // Removal may have applied before its reply or local cleanup failed; retry confirms it.
  removalFailure?: RemovalFailure;
}>;

export type AccountRemoval = 'sign-out' | 'deletion';
// Convex refused the deletion before removing anything, for example after a stale sign-in.
export type RemovalFailure = AccountRemoval | 'deletion-refused';

// A connected status, and the connections it listed, are only valid while verification succeeds.
const pending = (snapshot: RegistrationSnapshot): RegistrationSnapshot => {
  if (snapshot.kind !== 'connected') {
    return snapshot;
  }
  const { kind: _kind, mailboxes: _mailboxes, ...account } = snapshot;
  return { ...account, kind: 'mailbox-needed' };
};

const settled = (snapshot: RegistrationSnapshot): RegistrationState => ({
  snapshot,
  busy: false,
  failed: false,
});

class RegistrationCancelled extends Schema.TaggedError<RegistrationCancelled>()(
  'RegistrationCancelled',
  {},
) {}

// Protected device data is unavailable while the device is locked; it is an expected state.
class RegistrationLocked extends Schema.TaggedError<RegistrationLocked>()(
  'RegistrationLocked',
  {},
) {}

// An entry that does not match the Recovery Key's final group is an expected state.
class RecoveryKeyMismatch extends Schema.TaggedError<RecoveryKeyMismatch>()(
  'RecoveryKeyMismatch',
  {},
) {}

// A Recovery Key that does not open this account's keys is an expected state. It carries the
// device's current status, which the sign-in renewed for the attempt may have changed.
class RecoveryKeyRejected extends Schema.TaggedError<RecoveryKeyRejected>()(
  'RecoveryKeyRejected',
  { snapshot: RegistrationSnapshotSchema },
) {}

// A mistyped approval code is caught on this device before anything is sent.
class EnrollmentCodeInvalid extends Schema.TaggedError<EnrollmentCodeInvalid>()(
  'EnrollmentCodeInvalid',
  {},
) {}

// A link the backend refused, for example an identity owned by another Product Account, leaves
// the Product Account and its sign-ins unchanged; it is an expected outcome.
class LinkRefused extends Schema.TaggedError<LinkRefused>()('LinkRefused', {
  failure: LinkFailureSchema,
}) {}

class RegistrationFailed extends Schema.TaggedError<RegistrationFailed>()(
  'RegistrationFailed',
  // The diagnostic is logged instead of the cause; see rejectionDiagnostic.
  { cause: Schema.Defect(), diagnostic: Schema.String },
) {}

const decodeSnapshot = Schema.decodeUnknownEffect(RegistrationSnapshotSchema);

const registrationError = (cause: unknown) => {
  if (isCancelled(cause)) {
    return new RegistrationCancelled();
  }
  if (isLocked(cause)) {
    return new RegistrationLocked();
  }
  if (isEnrollmentCodeInvalid(cause)) {
    return new EnrollmentCodeInvalid();
  }
  return isRecoveryKeyMismatch(cause)
    ? new RecoveryKeyMismatch()
    : new RegistrationFailed({ cause, diagnostic: rejectionDiagnostic(cause) });
};

// Composes a registration program or a legacy native operation and decodes its snapshot.
const request = Effect.fnUntraced(function* (
  operation: () => Promise<unknown> | Effect.Effect<unknown, unknown>,
) {
  const program = yield* Effect.try({
    try: () => {
      const result = operation();
      return Effect.isEffect(result)
        ? result.pipe(Effect.mapError(registrationError))
        : Effect.tryPromise({ try: () => result, catch: registrationError });
    },
    catch: registrationError,
  });
  const value = yield* program;
  return yield* decodeSnapshot(value).pipe(
    Effect.mapError(
      (error) =>
        new RegistrationFailed({
          cause: error,
          diagnostic: decodeDiagnostic(error),
        }),
    ),
  );
});

// A rejected Recovery Key arrives as a status with a notice; for example, it can show the new
// Enrollment Code that replaced an expired request while the key was checked.
const recoveryOutcome = (snapshot: RegistrationSnapshot) => {
  if (snapshot.kind === 'signed-out' || snapshot.recoveryNotice === undefined) {
    return Effect.succeed(snapshot);
  }
  const { recoveryNotice: _notice, ...current } = snapshot;
  return Effect.fail(new RecoveryKeyRejected({ snapshot: current }));
};

// A request that expired, was cancelled or was already approved cannot be approved again.
const enrollmentFailed = (
  snapshot: RegistrationSnapshot,
  cause: unknown,
): RegistrationState => ({
  ...settled(snapshot),
  enrollmentFailure: isEnrollmentUnavailable(cause) ? 'unavailable' : 'failed',
});

export function createRegistration(
  native: NativeRegistration | RegistrationPrograms,
) {
  let state: RegistrationState = {
    snapshot: { kind: 'signed-out' },
    busy: true,
    failed: false,
  };
  let restored = false;
  // The verification queued for the activation currently being reported, if any.
  let activation: Promise<void> | null = null;
  // Accepted account changes replace this fence; a late mailbox failure cannot relabel removal.
  let accountIntent = { removing: false };
  // One operation runs at a time; foreground verification queues behind interactive work.
  const semaphore = Semaphore.makeUnsafe(1);
  type MailboxLoading = 'automatic' | 'explicit';
  const listeners = new Set<(mailboxLoading?: MailboxLoading) => void>();
  const publish = (
    next: RegistrationState,
    mailboxLoading: MailboxLoading = 'automatic',
  ) => {
    state = next;
    for (const listener of listeners) {
      listener(mailboxLoading);
    }
  };
  const execute = (
    operation: Effect.Effect<
      RegistrationSnapshot,
      | RegistrationCancelled
      | RegistrationLocked
      | RecoveryKeyMismatch
      | RecoveryKeyRejected
      | EnrollmentCodeInvalid
      | LinkRefused
      | RegistrationFailed
    >,
    onFailure: (
      snapshot: RegistrationSnapshot,
      cause: unknown,
    ) => RegistrationState = (snapshot) => ({
      ...settled(snapshot),
      failed: true,
    }),
    {
      foreground = false,
      accountChange,
      mailboxLoading = 'automatic',
    }: Readonly<{
      foreground?: boolean;
      accountChange?: 'sign-in' | 'removal';
      mailboxLoading?: MailboxLoading;
    }> = {},
  ) =>
    runLogged(
      Effect.gen(function* () {
        if (accountChange !== undefined) {
          accountIntent = { removing: accountChange === 'removal' };
        }
        const previous = state;
        // A retry keeps the locked state rather than revealing a snapshot it could not read.
        if (foreground) {
          publish({ ...state, busy: true }, mailboxLoading);
        } else {
          publish(
            state.locked
              ? {
                  snapshot: state.snapshot,
                  busy: true,
                  failed: false,
                  locked: true,
                }
              : { snapshot: state.snapshot, busy: true, failed: false },
          );
        }
        const next = yield* operation.pipe(
          Effect.map(settled),
          Effect.catchTags({
            RegistrationCancelled: () =>
              Effect.sync(() => settled(state.snapshot)),
            RegistrationLocked: () =>
              Effect.sync((): RegistrationState => ({
                ...settled(state.snapshot),
                locked: true,
              })),
            RecoveryKeyMismatch: () =>
              Effect.sync((): RegistrationState => ({
                ...settled(state.snapshot),
                recoveryKeyFailure: 'mismatch',
              })),
            RecoveryKeyRejected: ({ snapshot }) =>
              Effect.sync((): RegistrationState => ({
                ...settled(snapshot),
                recoveryFailure: 'rejected',
              })),
            EnrollmentCodeInvalid: () =>
              Effect.sync((): RegistrationState => ({
                ...settled(state.snapshot),
                enrollmentFailure: 'code-invalid',
              })),
            LinkRefused: ({ failure }) =>
              Effect.sync((): RegistrationState => ({
                ...settled(state.snapshot),
                linkFailure: failure,
              })),
            RegistrationFailed: (error) =>
              Effect.logError('Registration failed:', error.diagnostic).pipe(
                Effect.andThen(
                  Effect.sync(() => onFailure(state.snapshot, error.cause)),
                ),
              ),
          }),
        );
        // Returning from an authorization sheet must not erase unchanged setup feedback.
        publish(
          foreground &&
            !previous.locked &&
            !next.locked &&
            !next.failed &&
            sameSnapshot(previous.snapshot, next.snapshot)
            ? { ...previous, busy: false }
            : next,
          mailboxLoading,
        );
      }).pipe(
        // An activation can arrive before a pending operation reports that storage was locked.
        (program) =>
          foreground
            ? program.pipe(Semaphore.withPermits(semaphore, 1), Effect.asVoid)
            : program.pipe(
                Semaphore.withPermitsIfAvailable(semaphore, 1),
                Effect.asVoid,
              ),
      ),
    );
  const restoredAccount = request(native.restore).pipe(
    Effect.map((snapshot) =>
      snapshot.kind === 'signed-out' &&
      snapshot.notice === undefined &&
      state.snapshot.kind === 'signed-out'
        ? state.snapshot
        : snapshot,
    ),
  );
  const restore = (
    foreground = false,
    mailboxLoading: MailboxLoading = 'automatic',
  ) =>
    execute(
      restoredAccount,
      (snapshot) => ({ ...settled(pending(snapshot)), failed: true }),
      { foreground, mailboxLoading },
    );
  const resume = () => {
    if (activation === null) {
      activation = restore(true);
      queueMicrotask(() => {
        activation = null;
      });
    }
    return activation;
  };
  return {
    getSnapshot: () => state,
    subscribe: (listener: (mailboxLoading?: MailboxLoading) => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    restore: () => restore(),
    // Every mounted host view restores through the same store; only the first mount verifies.
    restoreOnce: () => {
      if (restored) {
        return Promise.resolve();
      }
      restored = true;
      return restore();
    },
    // Every activation verifies the saved account and retries unavailable protected storage.
    // Each Mac window's gate reports the same activation synchronously; they share one restore.
    resume,
    // Mailbox work found this device removed and native code purged it. Only the purging call could
    // report why, so a restore that confirms the sign-out keeps that explanation.
    deviceRemoved: () => {
      const expected = accountIntent;
      return execute(
        restoredAccount.pipe(
          Effect.map((snapshot): RegistrationSnapshot =>
            snapshot.kind === 'signed-out' &&
            snapshot.notice === undefined &&
            expected === accountIntent &&
            (!expected.removing || state.snapshot.kind !== 'signed-out')
              ? { kind: 'signed-out', notice: 'revoked' }
              : snapshot,
          ),
        ),
        undefined,
        { foreground: true },
      );
    },
    // Cache-only retry verifies registration before attempting provider synchronization.
    refreshInbox: async (
      load: () => Promise<void>,
      mailboxLoading: MailboxLoading = 'automatic',
    ) => {
      // Scoped wakes verify independently: a coalesced foreground restore could auto-load
      // unrelated newly revealed connections before the wake's route is checked.
      await (mailboxLoading === 'explicit'
        ? restore(true, mailboxLoading)
        : resume());
      await load();
    },
    register: (provider: SignInProvider) =>
      execute(
        Effect.gen(function* () {
          // Commit Product Sign-In before starting the separate Gmail consent session.
          const snapshot = yield* request(() => native.signIn(provider));
          publish({ snapshot, busy: true, failed: false });
          if (snapshot.kind !== 'mailbox-needed') {
            return snapshot;
          }
          // Saved mailboxes that all need Gmail again are authorized again, starting with the first.
          const [saved] = mailboxesOf(snapshot);
          return yield* request(() =>
            saved === undefined
              ? native.addMailbox(false)
              : native.authorizeGmail(saved.id),
          );
        }),
        undefined,
        { accountChange: 'sign-in' },
      ),
    addMailbox: (chooseAccount = false) =>
      execute(request(() => native.addMailbox(chooseAccount))),
    authorizeGmail: (connection: string) =>
      execute(request(() => native.authorizeGmail(connection))),
    removeMailbox: (connection: string) =>
      execute(request(() => native.removeMailbox(connection))),
    link: (provider: SignInProvider) =>
      execute(
        request(() => native.link(provider)).pipe(
          // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
          Effect.catchTag('RegistrationFailed', (error) =>
            Effect.fail(
              Option.match(linkFailureCode(error.cause), {
                onNone: () => error,
                onSome: ({ code }) => new LinkRefused({ failure: code }),
              }),
            ),
          ),
        ),
        (snapshot) => ({ ...settled(snapshot), linkFailure: 'failed' }),
      ),
    confirmRecoveryKey: (entry: string) =>
      execute(
        request(() => native.confirmRecoveryKey(entry)),
        (snapshot) => ({ ...settled(snapshot), recoveryKeyFailure: 'failed' }),
      ),
    recoverWithRecoveryKey: (entry: string) =>
      execute(
        request(() => native.recoverWithRecoveryKey(entry)).pipe(
          Effect.flatMap(recoveryOutcome),
        ),
        (snapshot) => ({ ...settled(snapshot), recoveryFailure: 'failed' }),
      ),
    approveEnrollment: (requestId: string, code: string) =>
      execute(
        request(() => native.approveEnrollment(requestId, code)),
        enrollmentFailed,
      ),
    declineEnrollment: (requestId: string) =>
      execute(
        request(() => native.declineEnrollment(requestId)),
        enrollmentFailed,
      ),
    revokeTrustedDevice: (trustedDeviceId: string) =>
      execute(
        request(() => native.revokeTrustedDevice(trustedDeviceId)),
        (snapshot) => ({ ...settled(snapshot), revocationFailed: true }),
      ),
    refreshPrivateSync: () => execute(request(native.refreshPrivateSync)),
    signOut: () =>
      execute(
        request(native.signOut),
        (snapshot) => ({
          ...settled(snapshot),
          removalFailure: 'sign-out',
        }),
        { accountChange: 'removal' },
      ),
    deleteProductAccount: () =>
      execute(
        request(native.deleteProductAccount),
        (snapshot, cause) => ({
          ...settled(snapshot),
          removalFailure: isRemovalRefused(cause)
            ? 'deletion-refused'
            : 'deletion',
        }),
        { accountChange: 'removal' },
      ),
  };
}

export type Registration = ReturnType<typeof createRegistration>;

// The name shown for a sign-in provider.
export const providerName = (t: Translate, provider: SignInProvider) =>
  t(`providers.${provider}`);

function accountLine(
  t: Translate,
  snapshot: Readonly<{ signInProvider: SignInProvider; contactEmail?: string }>,
) {
  const provider = providerName(t, snapshot.signInProvider);
  return snapshot.contactEmail === undefined
    ? t('registration.account', { provider })
    : t('registration.accountWithEmail', {
        provider,
        email: snapshot.contactEmail,
      });
}

export const otherSignInProvider = (
  provider: SignInProvider,
): SignInProvider => (provider === 'apple' ? 'google' : 'apple');

// Account settings: which identities open this Product Account.
export function signInMethodsCopy(
  t: Translate,
  snapshot: Readonly<{
    signInProvider: SignInProvider;
    alternateSignIn?: SignInProvider;
  }>,
) {
  const current = providerName(t, snapshot.signInProvider);
  if (snapshot.alternateSignIn !== undefined) {
    return {
      description: t('signInMethods.linked', {
        current,
        other: providerName(t, snapshot.alternateSignIn),
      }),
      link: undefined,
    };
  }
  const other = otherSignInProvider(snapshot.signInProvider);
  return {
    description: t('signInMethods.only', {
      current,
      other: providerName(t, other),
    }),
    link: other,
  };
}

export const linkFailureCopy = (
  t: Translate,
  failure: LinkFailure,
  provider: SignInProvider,
) => t(`linkFailure.${failure}`, { provider: providerName(t, provider) });

// An account whose sign-out or deletion has not finished; that replaces any other setup.
function removalPendingCopy(
  t: Translate,
  snapshot: Readonly<{
    removalPending?: AccountRemoval;
    signInProvider: SignInProvider;
    contactEmail?: string;
  }>,
) {
  if (snapshot.removalPending === undefined) {
    return undefined;
  }
  return {
    title: t(`registration.removalPending.${snapshot.removalPending}`),
    description: t(`accountRemoval.${snapshot.removalPending}`),
    account: accountLine(t, snapshot),
  };
}

// A retained account without a usable mailbox. Sign in with Apple identifies the Product Account
// only; it never grants mailbox access.
function mailboxNeededCopy(
  t: Translate,
  snapshot: Extract<RegistrationSnapshot, { kind: 'mailbox-needed' }>,
) {
  const { reason, signInProvider } = snapshot;
  return {
    title: t('registration.mailboxNeeded.title'),
    description: t(`registration.mailboxNeeded.${reason ?? signInProvider}`, {
      provider: providerName(t, signInProvider),
    }),
    account: accountLine(t, snapshot),
  };
}

// A device after the Product Account's first waits for a Trusted Device or the Recovery Key.
function devicePendingDescription(
  t: Translate,
  privateSync: PrivateSync | undefined,
) {
  if (privateSync === 'setup-pending') {
    return t('registration.devicePending.setup-pending');
  }
  return privateSync === 'enrollment-pending'
    ? t('registration.devicePending.approval')
    : t('registration.devicePending.retry');
}

const addressesIn = (
  snapshot: RegistrationSnapshot,
  state: MailboxConnection['state'],
) =>
  mailboxesOf(snapshot)
    .filter((mailbox) => mailbox.state === state)
    .map(({ address }) => address);

export function registrationCopy(t: Translate, snapshot: RegistrationSnapshot) {
  switch (snapshot.kind) {
    case 'signed-out': {
      const page = snapshot.notice ?? 'welcome';
      return {
        title: t(`registration.${page}.title`),
        description: t(`registration.${page}.description`),
        account: undefined,
      };
    }
    case 'mailbox-needed': {
      return removalPendingCopy(t, snapshot) ?? mailboxNeededCopy(t, snapshot);
    }
    case 'device-pending': {
      return (
        removalPendingCopy(t, snapshot) ?? {
          title: t('registration.devicePending.title'),
          description: devicePendingDescription(t, snapshot.privateSync),
          account: accountLine(t, snapshot),
        }
      );
    }
    case 'connected':
    case 'cached': {
      const addresses = addressesIn(snapshot, snapshot.kind);
      return {
        title: t(`registration.${snapshot.kind}.title`),
        description: t(`registration.${snapshot.kind}.description`, {
          addresses: addresses.join(', '),
          count: addresses.length,
        }),
        account: accountLine(t, snapshot),
      };
    }
    default: {
      const exhaustive: never = snapshot;
      return exhaustive;
    }
  }
}

type PrivateSyncState = Readonly<{
  privateSync?: PrivateSync;
  recoveryKey?: string;
  privateSyncMailboxes?: string;
  privateSyncPending?: 'mailbox';
  enrollmentCode?: string;
  enrollmentNotice?: 'renewed' | 'rejected';
}>;

// Private product data on this device; mailbox credentials never take part in it.
export function privateSyncCopy(t: Translate, snapshot: PrivateSyncState) {
  if (snapshot.privateSync === undefined) {
    return undefined;
  }
  const description = t(`privateSync.${snapshot.privateSync}.description`);
  return {
    title: t(`privateSync.${snapshot.privateSync}.title`),
    description:
      snapshot.privateSync === 'enrollment-pending' &&
      snapshot.enrollmentNotice !== undefined
        ? t('privateSync.withNotice', {
            description,
            notice: t(`privateSync.${snapshot.enrollmentNotice}`),
          })
        : description,
    mailboxes:
      snapshot.privateSyncMailboxes === undefined
        ? undefined
        : t('privateSync.mailboxes', {
            mailboxes: snapshot.privateSyncMailboxes.replaceAll('\n', ', '),
          }),
    pending:
      snapshot.privateSyncPending === undefined
        ? undefined
        : t('privateSync.pending'),
    // Each is present only in its own state.
    recoveryKey:
      snapshot.privateSync === 'recovery-key'
        ? snapshot.recoveryKey
        : undefined,
    enrollmentCode:
      snapshot.privateSync === 'enrollment-pending'
        ? snapshot.enrollmentCode
        : undefined,
  };
}

// Native confirmation ignores case and separators; keep only the four characters that count.
export const recoveryKeyEntry = (text: string) =>
  text.replaceAll(/[\s-]/gu, '').toUpperCase().slice(0, 4);

// Recovery Key entry is offered only where the account has keys that this device lacks.
export const offersRecovery = (privateSync: PrivateSync | undefined) =>
  privateSync === 'enrollment-needed' || privateSync === 'enrollment-pending';

// Only a device holding the account keys approves another device or removes a Trusted Device.
export const approvesDevices = (privateSync: PrivateSync | undefined) =>
  privateSync === 'ready' || privateSync === 'recovery-key';

// A retained account can be reopened with its own or its linked Sign-In Provider,
// which also finishes Product Sync setup that could not reach the backend.
function offersSignInAgain(snapshot: RegistrationSnapshot, failed: boolean) {
  if (snapshot.kind === 'signed-out' || snapshot.removalPending !== undefined) {
    return false;
  }
  // A Pending Device is admitted by approval or the Recovery Key, not by another sign-in.
  if (snapshot.kind === 'device-pending') {
    return failed;
  }
  return (
    snapshot.privateSync === 'setup-pending' ||
    snapshot.privateSyncPending !== undefined ||
    (snapshot.kind === 'mailbox-needed' &&
      (failed ||
        snapshot.reason === 'interrupted' ||
        snapshot.reason === 'unavailable'))
  );
}

// A sign-in the registration page offers; `offer` names its `registration.*` label.
export type SignInOffer = Readonly<{
  offer: 'signInWith' | 'signInAgain' | 'signInInstead';
  provider: SignInProvider;
}>;

// The registration page's actions in this state, in page order; hosts only render them.
export function registrationActions(
  snapshot: RegistrationSnapshot,
  failed: boolean,
) {
  const account = snapshot.kind !== 'signed-out';
  const removing = account && snapshot.removalPending !== undefined;
  let signIn: readonly SignInOffer[] = [];
  if (!account) {
    signIn = [
      { offer: 'signInWith', provider: 'apple' },
      { offer: 'signInWith', provider: 'google' },
    ];
  } else if (offersSignInAgain(snapshot, failed)) {
    signIn = [
      { offer: 'signInAgain', provider: snapshot.signInProvider },
      // Offered even when this device has not seen the link; Convex decides.
      {
        offer: 'signInInstead',
        provider: otherSignInProvider(snapshot.signInProvider),
      },
    ];
  }
  return {
    // The first mailbox suggests the Google sign-in, or any Google account can be chosen.
    firstMailbox:
      snapshot.kind === 'mailbox-needed' &&
      !removing &&
      mailboxesOf(snapshot).length === 0,
    signIn,
    retry: failed,
    // Until a removal finishes, only the removal itself stays available.
    settings: account && !removing,
  } as const;
}

// A connected mailbox's Inbox can open unless a sign-out or deletion is unfinished.
export const canOpenInbox = (snapshot: RegistrationSnapshot) =>
  (snapshot.kind === 'connected' || snapshot.kind === 'cached') &&
  snapshot.removalPending === undefined;

// The account setup that needs the person before the Inbox, described so that newly appearing
// setup differs from setup already pending; empty when none: a Recovery Key to confirm or enter,
// a device approval on either side, or a mailbox not yet saved to private sync.
export const inboxSetup = (snapshot: RegistrationSnapshot) => {
  if (snapshot.kind !== 'connected' && snapshot.kind !== 'cached') {
    return '';
  }
  const privateSync =
    snapshot.privateSync === 'setup-pending' ||
    offersRecovery(snapshot.privateSync)
      ? snapshot.privateSync
      : undefined;
  return [
    snapshot.recoveryKey === undefined ? undefined : 'recovery-key',
    snapshot.enrollmentCode === undefined
      ? undefined
      : `enrollment-code:${snapshot.enrollmentCode}`,
    snapshot.enrollmentRequest,
    snapshot.privateSyncPending,
    privateSync,
  ]
    .filter((part) => part !== undefined)
    .join(' ');
};

// Launch lands on the Inbox unless account setup needs the person first.
export const opensInbox = (snapshot: RegistrationSnapshot) =>
  canOpenInbox(snapshot) && inboxSetup(snapshot) === '';

// The person's choice between the account page and a connected Inbox, made for one Product Account
// with the setup that was pending then.
export type InboxChoice = Readonly<{
  account: string;
  destination: 'inbox' | 'account';
  setup: string;
}>;

// The Product Account whose Inbox can open now, if any.
const openInboxAccount = (snapshot: RegistrationSnapshot) =>
  canOpenInbox(snapshot) && snapshot.kind !== 'signed-out'
    ? snapshot.productAccountId
    : undefined;

// A choice belongs to one open Inbox: sign-out, removal or another Product Account forgets it, and
// choosing the Inbox over pending setup does not hide setup that appears later.
const choiceApplies = (
  choice: InboxChoice,
  account: string | undefined,
  setup: string,
) =>
  choice.account === account &&
  (choice.destination === 'account' || setup === '' || setup === choice.setup);

// Where a host lands, and whether an earlier choice still applies.
export function inboxLanding(
  snapshot: RegistrationSnapshot,
  choice: InboxChoice | undefined,
) {
  const account = openInboxAccount(snapshot);
  const setup = inboxSetup(snapshot);
  const valid = choice !== undefined && choiceApplies(choice, account, setup);
  // Without an open Inbox the account page shows; otherwise a valid choice, then pending setup.
  let destination: InboxChoice['destination'] = 'account';
  if (valid) {
    ({ destination } = choice);
  } else if (account !== undefined && setup === '') {
    destination = 'inbox';
  }
  return { account, setup, valid, destination } as const;
}

export const revocationNotice = (
  t: Translate,
  account: Readonly<{ revocationNotice?: 'removed' | 'unconfirmed' }>,
  failed: boolean,
) => {
  if (failed) {
    return t('revocation.failed');
  }
  return account.revocationNotice === undefined
    ? undefined
    : t(`revocation.${account.revocationNotice}`);
};
