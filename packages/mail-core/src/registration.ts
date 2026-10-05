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
  // Only in the reply to a removal of another Trusted Device: 'unconfirmed' when this device has
  // not adopted its own new keys, for example because another device removed it first.
  revocationNotice: Schema.optionalKey(
    Schema.Literals(['removed', 'unconfirmed']),
  ),
});
export const RegistrationSnapshotSchema = Schema.Union([
  Schema.Struct({
    kind: Schema.Literal('signed-out'),
    // This device purged the Product Account after it was removed, or was refused after a removal,
    // or after the Product Account was deleted from this device or another.
    notice: Schema.optionalKey(
      Schema.Literals(['revoked', 'refused', 'deleted']),
    ),
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
  Schema.Struct({
    kind: Schema.Literal('connected'),
    ...Account.fields,
    providerSubject: Schema.NonEmptyString,
    address: Schema.NonEmptyString,
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
  readonly authorizeGmail: (reselect: boolean) => Promise<unknown>;
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

// A connected status is only valid while its verification succeeds.
const pending = (snapshot: RegistrationSnapshot): RegistrationSnapshot => {
  if (snapshot.kind !== 'connected') {
    return snapshot;
  }
  const {
    address: _address,
    kind: _kind,
    providerSubject: _providerSubject,
    ...account
  } = snapshot;
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

class RegistrationFailed extends Schema.TaggedError<RegistrationFailed>()(
  'RegistrationFailed',
  // The diagnostic is logged instead of the cause; see rejectionDiagnostic.
  { cause: Schema.Defect(), diagnostic: Schema.String },
) {}

const decodeSnapshot = Schema.decodeUnknownEffect(RegistrationSnapshotSchema);

// Calls a native registration operation and decodes the snapshot it resolves with.
const request = Effect.fnUntraced(function* (
  operation: () => Promise<unknown>,
) {
  const value = yield* Effect.tryPromise({
    try: operation,
    catch: (cause) => {
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
        : new RegistrationFailed({
            cause,
            diagnostic: rejectionDiagnostic(cause),
          });
    },
  });
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

export function createRegistration(native: NativeRegistration) {
  let state: RegistrationState = {
    snapshot: { kind: 'signed-out' },
    busy: true,
    failed: false,
  };
  let restored = false;
  // The verification queued for the activation currently being reported, if any.
  let activation: Promise<void> | null = null;
  // One operation runs at a time; foreground verification queues behind interactive work.
  const semaphore = Semaphore.makeUnsafe(1);
  const listeners = new Set<() => void>();
  const publish = (next: RegistrationState) => {
    state = next;
    for (const listener of listeners) {
      listener();
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
      | RegistrationFailed
    >,
    onFailure: (
      snapshot: RegistrationSnapshot,
      cause: unknown,
    ) => RegistrationState = (snapshot) => ({
      ...settled(snapshot),
      failed: true,
    }),
    foreground = false,
  ) =>
    runLogged(
      Effect.gen(function* () {
        const previous = state;
        // A retry keeps the locked state rather than revealing a snapshot it could not read.
        if (foreground) {
          publish({ ...state, busy: true });
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
  const restore = (foreground = false) =>
    execute(
      request(native.restore),
      (snapshot) => ({ ...settled(pending(snapshot)), failed: true }),
      foreground,
    );
  return {
    getSnapshot: () => state,
    subscribe: (listener: () => void) => {
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
    resume: () => {
      if (activation === null) {
        activation = restore(true);
        queueMicrotask(() => {
          activation = null;
        });
      }
      return activation;
    },
    register: (provider: SignInProvider) =>
      execute(
        Effect.gen(function* () {
          // Commit Product Sign-In before starting the separate Gmail consent session.
          const snapshot = yield* request(() => native.signIn(provider));
          publish({ snapshot, busy: true, failed: false });
          return snapshot.kind === 'mailbox-needed'
            ? yield* request(() => native.authorizeGmail(false))
            : snapshot;
        }),
      ),
    authorizeGmail: (reselect: boolean) =>
      execute(request(() => native.authorizeGmail(reselect))),
    link: (provider: SignInProvider) =>
      execute(
        request(() => native.link(provider)),
        (snapshot, cause) => ({
          ...settled(snapshot),
          linkFailure: Option.getOrElse(
            Option.map(linkFailureCode(cause), ({ code }) => code),
            (): LinkFailure => 'failed',
          ),
        }),
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
      execute(request(native.signOut), (snapshot) => ({
        ...settled(snapshot),
        removalFailure: 'sign-out',
      })),
    deleteProductAccount: () =>
      execute(request(native.deleteProductAccount), (snapshot, cause) => ({
        ...settled(snapshot),
        removalFailure: isRemovalRefused(cause)
          ? 'deletion-refused'
          : 'deletion',
      })),
  };
}

export type Registration = ReturnType<typeof createRegistration>;

export const providerNames = {
  google: 'Google',
  apple: 'Apple',
} as const satisfies Record<SignInProvider, string>;

const mailboxReasons = {
  cancelled:
    'Gmail authorization was cancelled. Your Product Account is retained. Retry or choose another Google mailbox.',
  declined:
    'Gmail access was not granted. Your Product Account is retained. Retry or choose another Google mailbox.',
  'gmail-unavailable':
    'Gmail is unavailable for this authorization. Your Product Account is retained. Retry or choose another Google mailbox.',
  interrupted:
    'Gmail authorization was interrupted. Your Product Account is retained. Retry to finish setup.',
  unavailable: (provider: SignInProvider) =>
    `Your saved Product Account could not be verified. It is retained on this device. Retry when you are online, or sign in again with ${providerNames[provider]}.`,
} as const;

const mailboxNeeded = {
  google:
    'Your Product Account is ready. Grant Gmail access to finish setup. You can use another Google account for your mailbox.',
  // Sign in with Apple identifies the Product Account only; it never grants mailbox access.
  apple:
    'Your Product Account is ready. Signing in with Apple does not give access to mail. Authorize a Google account with Gmail to finish setup.',
} as const satisfies Record<SignInProvider, string>;

function accountLine(
  snapshot: Readonly<{ signInProvider: SignInProvider; contactEmail?: string }>,
) {
  const signedIn = `Signed in with ${providerNames[snapshot.signInProvider]}`;
  return snapshot.contactEmail === undefined
    ? `${signedIn}.`
    : `${signedIn}. Contact email: ${snapshot.contactEmail}.`;
}

export const otherSignInProvider = (
  provider: SignInProvider,
): SignInProvider => (provider === 'apple' ? 'google' : 'apple');

// Account settings: which identities open this Product Account.
export function signInMethodsCopy(
  snapshot: Readonly<{
    signInProvider: SignInProvider;
    alternateSignIn?: SignInProvider;
  }>,
) {
  const current = providerNames[snapshot.signInProvider];
  if (snapshot.alternateSignIn !== undefined) {
    return {
      description: `Sign in with ${current} or ${providerNames[snapshot.alternateSignIn]} to open this Product Account.`,
      link: undefined,
    };
  }
  const other = otherSignInProvider(snapshot.signInProvider);
  return {
    description: `Only ${current} opens this Product Account. Linking ${providerNames[other]} adds another way to sign in. First verify ${current}, then sign in with ${providerNames[other]}. It does not connect a mailbox.`,
    link: other,
  };
}

export function linkFailureCopy(
  failure: LinkFailure,
  provider: SignInProvider,
) {
  const name = providerNames[provider];
  switch (failure) {
    case 'identity-owned': {
      return `That ${name} sign-in already belongs to another Product Account. Accounts are never merged, so it was not linked.`;
    }
    case 'stale-authentication': {
      return `Linking needs a recent sign-in with both providers. Try again to link ${name}.`;
    }
    case 'failed': {
      return `${name} could not be linked. Your Product Account is unchanged. Try again.`;
    }
    default: {
      const exhaustive: never = failure;
      return exhaustive;
    }
  }
}

export const lockedCopy = {
  title: 'Unlock your device',
  description:
    "Unwired Mail cannot read this device's protected data while it is locked. Unlock your device to continue.",
} as const;

const signedOutNotices = {
  revoked: {
    title: 'This device was removed',
    description:
      'One of your trusted devices removed this one from your Product Account, so its account data, keys and mailbox access were deleted from this device. Anything copied from it before then cannot be erased remotely. Your mail in Gmail is not affected.',
  },
  deleted: {
    title: 'Product Account deleted',
    description:
      'This Product Account was permanently deleted, so its account data, keys and mailbox access were removed from this device. Anything copied from another device while it was offline cannot be erased remotely. Your mail in Gmail is not affected.',
  },
  refused: {
    title: 'This device cannot join',
    description:
      'Your Product Account currently does not accept new devices because a device was removed from it, so nothing was saved on this device. Your mail in Gmail is not affected.',
  },
} as const;

// Leaving this device is distinct from deleting the Product Account everywhere.
export const accountRemovalCopy = {
  title: 'This device and your account',
  signOut: 'Sign out of this device',
  signOutConfirm:
    'Signing out removes this device from your Product Account and deletes its account data, keys and mailbox access from this device. Save and confirm any Recovery Key shown first. Your other devices and your mail in Gmail are not affected. To use this device again, sign in and approve it from a trusted device or with your Recovery Key.',
  delete: 'Delete Product Account',
  deleteConfirm:
    'Deleting your Product Account permanently removes it, its private data and its sign-ins from Unwired Mail. Other devices remove their local data when they reconnect; copies on offline or compromised devices cannot be erased remotely. It cannot be undone. Your mail stays in Gmail, and authorization you gave Google is not revoked. You sign in again to confirm.',
  deletePermanently: 'Delete permanently',
  cancel: 'Cancel',
  'sign-out':
    'Sign-out could not be confirmed. Retry sign-out when you are online to finish removing this device and its local account data. Save and confirm any Recovery Key shown before signing out.',
  'deletion-refused':
    'Your Product Account was not deleted, and nothing was removed. Try again and sign in with the Apple or Google account that opens it.',
  deletion:
    'Deletion could not be confirmed. Your Product Account may already be deleted. Retry deletion when you are online to confirm it and finish removing local account data.',
} as const;

export function registrationCopy(snapshot: RegistrationSnapshot) {
  switch (snapshot.kind) {
    case 'signed-out': {
      if (snapshot.notice !== undefined) {
        return { ...signedOutNotices[snapshot.notice], account: undefined };
      }
      return {
        title: 'Welcome to Unwired Mail',
        description:
          'Create your Product Account with Apple or Google, then choose whether to grant Gmail access.',
        account: undefined,
      };
    }
    case 'mailbox-needed': {
      if (snapshot.removalPending !== undefined) {
        return {
          title:
            snapshot.removalPending === 'sign-out'
              ? 'Finish signing out'
              : 'Confirm account deletion',
          description: accountRemovalCopy[snapshot.removalPending],
          account: accountLine(snapshot),
        };
      }
      const { reason, signInProvider } = snapshot;
      let description: string = mailboxNeeded[signInProvider];
      if (reason === 'unavailable') {
        description = mailboxReasons.unavailable(signInProvider);
      } else if (reason !== undefined) {
        description = mailboxReasons[reason];
      }
      return {
        title: 'Connect your Gmail',
        description,
        account: accountLine(snapshot),
      };
    }
    case 'connected': {
      return {
        title: 'Gmail connected',
        description: `${snapshot.address} is connected on this device.`,
        account: accountLine(snapshot),
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

const enrollmentNotices = {
  renewed:
    'The previous request expired or was declined, so this device shows a new code.',
  rejected:
    'The last approval could not be verified on this device, so nothing was unlocked. Approve it again with the new code.',
} as const;

const privateSyncText = {
  'setup-pending': {
    title: 'Private sync',
    description:
      'Private sync setup has not finished. It continues the next time your Product Account is verified. Sign in again to finish it now.',
  },
  'recovery-key': {
    title: 'Save your Recovery Key',
    description:
      'Your product data is end-to-end encrypted. If you lose every trusted device, this Recovery Key is the only way to unlock it. Write it down and keep it somewhere safe. Unwired Mail cannot show it to anyone else or reset it.',
  },
  ready: {
    title: 'Private sync is on',
    description:
      'Your product data is end-to-end encrypted. Only your trusted devices can read it.',
  },
  'enrollment-needed': {
    title: 'Unlock private data on this device',
    description:
      'This Product Account already has end-to-end encrypted data, so this device needs its keys. Approve it from one of your trusted devices or use your Recovery Key. Nothing was reset or replaced.',
  },
  'enrollment-pending': {
    title: 'Approve this device',
    description:
      'This Product Account already has end-to-end encrypted data. Signing in does not unlock it. On one of your trusted devices, open Unwired Mail and enter this code to approve this device.',
  },
  unavailable: {
    title: 'Private sync is unavailable',
    description:
      'Private sync data on this device could not be read, so private sync is paused here. Your sign-in and mailbox keep working, and nothing was reset or replaced.',
  },
} as const satisfies Record<
  PrivateSync,
  Readonly<{ title: string; description: string }>
>;

// Private product data on this device; mailbox credentials never take part in it.
export function privateSyncCopy(snapshot: PrivateSyncState) {
  if (snapshot.privateSync === undefined) {
    return undefined;
  }
  const { title, description } = privateSyncText[snapshot.privateSync];
  const notice =
    snapshot.enrollmentNotice === undefined
      ? ''
      : ` ${enrollmentNotices[snapshot.enrollmentNotice]}`;
  return {
    title,
    description:
      snapshot.privateSync === 'enrollment-pending'
        ? description + notice
        : description,
    mailboxes:
      snapshot.privateSyncMailboxes === undefined
        ? undefined
        : `Encrypted mailbox list: ${snapshot.privateSyncMailboxes.replaceAll('\n', ', ')}.`,
    pending:
      snapshot.privateSyncPending === undefined
        ? undefined
        : 'Your connected mailbox is not saved to private sync yet. Sign in again to save it.',
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

export const recoveryKeyConfirmationCopy = {
  prompt:
    'To confirm you saved it, enter the last four characters of your Recovery Key.',
  label: 'Last four characters',
  confirm: 'Confirm Recovery Key',
  mismatch:
    'That does not match the end of your Recovery Key. Check your written copy and try again.',
  failed: 'Your Recovery Key could not be confirmed. Try again.',
} as const;

// On a device without the account keys; the Recovery Key is checked only on this device.
export const recoveryCopy = {
  title: 'Use your Recovery Key',
  description:
    'If none of your trusted devices is available, enter the Recovery Key you wrote down when you created your Product Account. It is checked on this device and never sent to Unwired Mail.',
  label: 'Recovery Key',
  unlock: 'Unlock with Recovery Key',
  rejected:
    'That Recovery Key does not unlock this Product Account. Check each character of your written copy and try again. Your encrypted product data is kept.',
  failed:
    'Recovery could not finish. Your encrypted product data is kept. Try again to resume.',
  // Nothing offers a reset: encrypted product data stays locked, and mail stays with Gmail.
  lost: 'If you have lost every trusted device and your Recovery Key, your encrypted product data cannot be recovered, and Unwired Mail cannot unlock it for you. Your mail in Gmail is not affected.',
} as const;

// Recovery Key entry is offered only where the account has keys that this device lacks.
export const offersRecovery = (privateSync: PrivateSync | undefined) =>
  privateSync === 'enrollment-needed' || privateSync === 'enrollment-pending';

export const enrollmentCopy = {
  // On the device waiting for approval.
  check: 'Check for approval',
  // On a trusted device.
  find: 'Check for a new device',
  title: 'Approve a new device',
  description: (device: string) =>
    `Your ${device} asked to unlock your private data. Approve it only if it is your device and shows a code. Enter that code here.`,
  label: 'Code from the new device',
  approve: 'Approve device',
  decline: 'Decline',
  'code-invalid':
    'That code is not valid. Check the code shown on the new device and try again.',
  unavailable:
    'That request is no longer available. The new device shows a new code; check for it again.',
  failed: 'The device could not be approved. Try again.',
} as const;

const addedDate = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' });

// On a device holding the account keys; removal needs a new sign-in and then a new Recovery Key.
export const revocationCopy = {
  title: 'Trusted devices',
  description:
    'These other devices can read your private data. Remove one you no longer use, or one that was lost or stolen.',
  added: (registeredAt: number) => `Added ${addedDate.format(registeredAt)}`,
  remove: (name: string) => `Remove ${name}`,
  confirm: (name: string) =>
    `Removing ${name} blocks it from your Product Account, push notifications and private sync right away, and your other devices switch to new keys. It deletes its account data the next time it connects, but anything it already holds while offline or compromised cannot be erased remotely. You sign in again to confirm, then save a new Recovery Key.`,
  cancel: 'Cancel',
  removed:
    'The device was removed. Save your new Recovery Key. Keep your previous key until all remaining devices have connected and switched to the new keys; until then, recovery still uses the previous key.',
  unconfirmed:
    'The device is removed, but this device has not confirmed new keys for it. If another of your devices removed it first, save the Recovery Key that device shows. Otherwise check again when you are online.',
  failed: 'The device could not be removed. Try again.',
} as const;

export const revocationNotice = (
  account: Readonly<{ revocationNotice?: 'removed' | 'unconfirmed' }>,
  failed: boolean,
) => {
  if (failed) {
    return revocationCopy.failed;
  }
  return account.revocationNotice === undefined
    ? undefined
    : revocationCopy[account.revocationNotice];
};
