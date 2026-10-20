import type { Translate } from '@private-email/localization';

import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { ImapSetup } from './imap-setup.ts';
import type {
  MailboxConnection,
  MailGrantProvider,
  PrivateSync,
  RegistrationSnapshot,
  SignInProvider,
} from './registration-snapshot.ts';
import type { NativeRegistrationVault } from './registration-vault.ts';

import {
  decodeDiagnostic,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';
import { createRegistrationFlow } from './registration-flow.ts';
import {
  RegistrationSnapshotSchema,
  mailboxesOf,
  trustedDevicesOf,
} from './registration-snapshot.ts';

// A malformed native capability cannot offer an authorization action.
export const microsoftMailAvailable = Schema.is(
  Schema.Struct({ microsoftMail: Schema.Literal(true) }),
);

export {
  MailProviderSchema,
  PrivateSyncStateSchema,
  RegistrationSnapshotSchema,
  defaultProfile,
  mailboxesOf,
  profilesOf,
  trustedDevicesOf,
  unavailableProfile,
} from './registration-snapshot.ts';
export type {
  MailboxConnection,
  MailGrantProvider,
  MailProfile,
  MailProvider,
  PrivateSync,
  RegistrationSnapshot,
  SignInProvider,
  TrustedDevice,
} from './registration-snapshot.ts';

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
export type RevocationFailure = 'mismatch' | 'failed';

export type RecoveryFailure = 'rejected' | 'failed';

const isEnrollmentCodeInvalid = Schema.is(
  Schema.Struct({ code: Schema.Literal('enrollment-code-invalid') }),
);
const isEnrollmentUnavailable = Schema.is(
  Schema.Struct({ code: Schema.Literal('enrollment-unavailable') }),
);
export type EnrollmentFailure = 'code-invalid' | 'unavailable' | 'failed';

const ImapFailureSchema = Schema.Literals([
  'imap-refused',
  'imap-insecure',
  'smtp-refused',
  'smtp-insecure',
]);
export type ImapFailure = typeof ImapFailureSchema.Type | 'failed';
const imapFailureCode = Schema.decodeUnknownOption(
  Schema.Struct({ code: ImapFailureSchema }),
);

const ProfileFailureSchema = Schema.Literals([
  'upgrade-required',
  'profile-in-use',
  'profile-changed',
]);
// Why a Mail Profile change was refused; nothing changed.
export type ProfileFailure = typeof ProfileFailureSchema.Type | 'failed';
const profileFailureCode = Schema.decodeUnknownOption(
  Schema.Struct({ code: ProfileFailureSchema }),
);

export type RegistrationState = Readonly<{
  snapshot: RegistrationSnapshot;
  busy: boolean;
  failed: boolean;
  // Saved registration cannot be read until the device is unlocked; the snapshot is not its status.
  locked?: true;
  // A failed link leaves the Product Account and its sign-ins unchanged.
  linkFailure?: LinkFailure;
  // Why an IMAP mailbox could not be added beside others; nothing changed.
  imapFailure?: ImapFailure;
  profileFailure?: ProfileFailure;
  // The connection whose New Mail Notifications could not be changed; its policy is unchanged.
  notificationFailure?: string;
  recoveryKeyFailure?: RecoveryKeyFailure;
  // A failed Recovery Key unlock leaves this device and the account's keys unchanged.
  recoveryFailure?: RecoveryFailure;
  // A failed approval leaves this device and the requesting one unchanged.
  enrollmentFailure?: EnrollmentFailure;
  // A failed removal step keeps any prepared proposal; a mismatch sends nothing.
  revocationFailure?: RevocationFailure;
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

// A refused Mail Profile change leaves the snapshot as it was, with the reason.
const profileRefusal = (
  snapshot: RegistrationSnapshot,
  cause: unknown,
): RegistrationState => ({
  ...settled(snapshot),
  profileFailure: Option.match(profileFailureCode(cause), {
    onNone: () => 'failed' as const,
    onSome: ({ code }) => code,
  }),
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

// The same mismatch while confirming the replacement Recovery Key of a prepared removal.
class RevocationKeyMismatch extends Schema.TaggedError<RevocationKeyMismatch>()(
  'RevocationKeyMismatch',
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

class ProfileRefused extends Schema.TaggedError<ProfileRefused>()(
  'ProfileRefused',
  {
    failure: ProfileFailureSchema,
  },
) {}

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
  const profile = profileFailureCode(cause);
  if (Option.isSome(profile)) {
    return new ProfileRefused({ failure: profile.value.code });
  }
  return isRecoveryKeyMismatch(cause)
    ? new RecoveryKeyMismatch()
    : new RegistrationFailed({ cause, diagnostic: rejectionDiagnostic(cause) });
};

// Composes a registration program and decodes its snapshot.
const request = Effect.fnUntraced(function* (
  program: Effect.Effect<unknown, unknown>,
) {
  const value = yield* program.pipe(Effect.mapError(registrationError));
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

const revocationFailed = (
  snapshot: RegistrationSnapshot,
): RegistrationState => ({
  ...settled(snapshot),
  revocationFailure: 'failed',
});

// A request that expired, was cancelled or was already approved cannot be approved again.
const enrollmentFailed = (
  snapshot: RegistrationSnapshot,
  cause: unknown,
): RegistrationState => ({
  ...settled(snapshot),
  enrollmentFailure: isEnrollmentUnavailable(cause) ? 'unavailable' : 'failed',
});

export function createRegistration(vault: NativeRegistrationVault) {
  const native = createRegistrationFlow(vault);
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
  // Only within this instance: the native operation gate queues native steps across instances
  // and JavaScript reloads.
  const semaphore = Semaphore.makeUnsafe(1);
  type MailboxLoading = 'automatic' | 'explicit';
  type Listener = (
    mailboxLoading?: MailboxLoading,
    repairedImap?: string,
  ) => void;
  const listeners = new Set<Listener>();
  const publish = (
    next: RegistrationState,
    mailboxLoading: MailboxLoading = 'automatic',
    repairedImap?: string,
  ) => {
    state = next;
    for (const listener of listeners) {
      listener(mailboxLoading, repairedImap);
    }
  };
  const execute = (
    operation: Effect.Effect<
      RegistrationSnapshot,
      | RegistrationCancelled
      | RegistrationLocked
      | RecoveryKeyMismatch
      | RevocationKeyMismatch
      | RecoveryKeyRejected
      | EnrollmentCodeInvalid
      | LinkRefused
      | ProfileRefused
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
      imapSetup,
    }: Readonly<{
      foreground?: boolean;
      accountChange?: 'sign-in' | 'removal';
      mailboxLoading?: MailboxLoading;
      imapSetup?: ImapSetup;
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
        let repairedImap: string | undefined = undefined;
        const next = yield* operation.pipe(
          Effect.map((snapshot) => {
            if (snapshot.kind === 'signed-out') {
              return settled(snapshot);
            }
            const { imapConnected, ...shown } = snapshot;
            if (imapSetup !== undefined) {
              repairedImap = mailboxesOf(snapshot).find(
                (mailbox) =>
                  mailbox.provider === 'imap' &&
                  mailbox.state === 'connected' &&
                  mailbox.address === imapSetup.address &&
                  (imapConnected === undefined
                    ? mailbox.imap?.host === imapSetup.host.toLowerCase() &&
                      mailbox.imap.port === imapSetup.port &&
                      mailbox.imap.username === imapSetup.username
                    : mailbox.id === imapConnected),
              )?.id;
            }
            return settled(shown);
          }),
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
            RevocationKeyMismatch: () =>
              Effect.sync((): RegistrationState => ({
                ...settled(state.snapshot),
                revocationFailure: 'mismatch',
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
            ProfileRefused: ({ failure }) =>
              Effect.sync((): RegistrationState => ({
                ...settled(state.snapshot),
                profileFailure: failure,
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
          repairedImap,
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
  const restoredAccount = request(native.restore()).pipe(
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
    subscribe: (listener: Listener) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    restore: () => restore(),
    // The host restores once at startup, however many windows or screens it opens.
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
          // Product Sign-In never starts a mailbox authorization: the person chooses the first
          // mailbox's provider.
          const snapshot = yield* request(native.signIn(provider));
          publish({ snapshot, busy: true, failed: false });
          if (snapshot.kind !== 'mailbox-needed') {
            return snapshot;
          }
          // Saved mailboxes that all need authorization again are authorized again, starting with
          // the first one authorized through its provider's sign-in. An IMAP password is entered
          // again in its own setup.
          const granted = mailboxesOf(snapshot).find(
            ({ provider: mailboxProvider }) => mailboxProvider !== 'imap',
          );
          return granted === undefined
            ? snapshot
            : yield* request(native.authorizeMailbox(granted.id));
        }),
        undefined,
        { accountChange: 'sign-in' },
      ),
    addMailbox: (
      provider: MailGrantProvider = 'gmail',
      chooseAccount = false,
    ) => execute(request(native.addMailbox(provider, chooseAccount))),
    authorizeMailbox: (connection: string) =>
      execute(request(native.authorizeMailbox(connection))),
    connectImap: (setup: ImapSetup) =>
      execute(
        request(native.connectImap(setup)),
        (snapshot, cause) => ({
          ...settled(snapshot),
          imapFailure: Option.match(imapFailureCode(cause), {
            onNone: () => 'failed' as const,
            onSome: ({ code }) => code,
          }),
        }),
        { imapSetup: setup },
      ),
    removeMailbox: (connection: string) =>
      execute(request(native.removeMailbox(connection))),
    createProfile: (name: string) =>
      execute(request(native.createProfile(name)), profileRefusal),
    renameProfile: (profile: string, name: string) =>
      execute(request(native.renameProfile(profile, name)), profileRefusal),
    removeProfile: (profile: string) =>
      execute(request(native.removeProfile(profile)), profileRefusal),
    moveMailbox: (connection: string, profile: string) =>
      execute(request(native.moveMailbox(connection, profile)), profileRefusal),
    notifyMailbox: (connection: string, enabled: boolean) =>
      execute(
        request(native.notifyMailbox(connection, enabled)),
        (snapshot) => ({
          ...settled(snapshot),
          notificationFailure: connection,
        }),
      ),
    link: (provider: SignInProvider) =>
      execute(
        request(native.link(provider)).pipe(
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
      execute(request(native.confirmRecoveryKey(entry)), (snapshot) => ({
        ...settled(snapshot),
        recoveryKeyFailure: 'failed',
      })),
    recoverWithRecoveryKey: (entry: string) =>
      execute(
        request(native.recoverWithRecoveryKey(entry)).pipe(
          Effect.flatMap(recoveryOutcome),
        ),
        (snapshot) => ({ ...settled(snapshot), recoveryFailure: 'failed' }),
      ),
    approveEnrollment: (requestId: string, code: string) =>
      execute(
        request(native.approveEnrollment(requestId, code)),
        enrollmentFailed,
      ),
    declineEnrollment: (requestId: string) =>
      execute(request(native.declineEnrollment(requestId)), enrollmentFailed),
    revokeTrustedDevice: (trustedDeviceId: string) =>
      execute(
        request(native.revokeTrustedDevice(trustedDeviceId)),
        revocationFailed,
      ),
    confirmRevocation: (entry: string) =>
      execute(
        request(native.confirmRevocation(entry)).pipe(
          Effect.catchTag('RecoveryKeyMismatch', () =>
            Effect.fail(new RevocationKeyMismatch()),
          ),
        ),
        revocationFailed,
      ),
    cancelRevocation: () =>
      execute(request(native.cancelRevocation()), revocationFailed),
    // oxlint-disable-next-line node/no-sync -- The async private-sync program performs no synchronous Node I/O.
    refreshPrivateSync: () => execute(request(native.refreshPrivateSync())),
    // Background work learned of a newer key epoch; a failure leaves the status as it was.
    adoptKeyRotation: () =>
      execute(request(native.adoptKeyRotation()), settled, {
        foreground: true,
      }),
    signOut: () =>
      execute(
        request(native.signOut()),
        (snapshot) => ({
          ...settled(snapshot),
          removalFailure: 'sign-out',
        }),
        { accountChange: 'removal' },
      ),
    deleteProductAccount: () =>
      execute(
        request(native.deleteProductAccount()),
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
const providerName = (t: Translate, provider: SignInProvider) =>
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

const otherSignInProvider = (provider: SignInProvider): SignInProvider =>
  provider === 'apple' ? 'google' : 'apple';

// Account settings: which identities open this Product Account.
function signInMethodsCopy(
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

const linkFailureCopy = (
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

// fallow-ignore-next-line complexity -- One branch per registration state; the screen suite covers each.
function registrationCopy(t: Translate, snapshot: RegistrationSnapshot) {
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
      // Gmail-only accounts keep naming Gmail; any other provider makes it mail in general.
      const gmailOnly = mailboxesOf(snapshot).every(
        ({ provider }) => provider === 'gmail',
      );
      return {
        title: gmailOnly
          ? t(`registration.${snapshot.kind}.title`)
          : t(`registration.${snapshot.kind}.titleMail`),
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
function privateSyncCopy(t: Translate, snapshot: PrivateSyncState) {
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
const offersRecovery = (privateSync: PrivateSync | undefined) =>
  privateSync === 'enrollment-needed' || privateSync === 'enrollment-pending';

// Only a device holding the account keys approves another device or removes a Trusted Device.
const approvesDevices = (privateSync: PrivateSync | undefined) =>
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
function registrationActions(snapshot: RegistrationSnapshot, failed: boolean) {
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
const inboxSetup = (snapshot: RegistrationSnapshot) => {
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
function inboxLanding(
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

function identityOf(
  t: Translate,
  account: Exclude<RegistrationSnapshot, { kind: 'signed-out' }>,
  linkFailure: LinkFailure | undefined,
) {
  const methods = signInMethodsCopy(t, account);
  const { link } = methods;
  return {
    name: account.contactEmail,
    provider: t('registration.account', {
      provider: providerName(t, account.signInProvider),
    }),
    signInMethods: {
      description: methods.description,
      link:
        link === undefined
          ? undefined
          : {
              provider: link,
              label: t('signInMethods.link', {
                provider: providerName(t, link),
              }),
            },
      failure:
        linkFailure === undefined
          ? undefined
          : linkFailureCopy(
              t,
              linkFailure,
              otherSignInProvider(account.signInProvider),
            ),
    },
  };
}

// Hosts hand the mailboxes and choices to the Inbox's context; the same snapshot keeps the same
// values, so a busy or failure change alone does not re-render or reload the Inbox.
const landingValues = new WeakMap<
  RegistrationSnapshot,
  Readonly<{
    mailboxes: readonly MailboxConnection[];
    choices:
      | Readonly<Record<InboxChoice['destination'], InboxChoice>>
      | undefined;
  }>
>();

function landingValuesOf(snapshot: RegistrationSnapshot) {
  const known = landingValues.get(snapshot);
  if (known !== undefined) {
    return known;
  }
  const { account, setup } = inboxLanding(snapshot, undefined);
  const values = {
    mailboxes: mailboxesOf(snapshot),
    // What the host stores when the person picks a destination; only while an Inbox can open.
    choices:
      account === undefined
        ? undefined
        : ({
            inbox: { account, destination: 'inbox', setup },
            account: { account, destination: 'account', setup },
          } as const),
  };
  landingValues.set(snapshot, values);
  return values;
}

// Everything the registration gate shows in this state. Hosts keep one choice per window, store
// the returned `choice` back (an invalidated one becomes undefined) and only render the rest.
export function registrationScreen(
  t: Translate,
  state: RegistrationState,
  choice: InboxChoice | undefined,
) {
  const { snapshot, failed } = state;
  const landing = inboxLanding(snapshot, choice);
  const { mailboxes, choices } = landingValuesOf(snapshot);
  const actions = registrationActions(snapshot, failed);
  const signedIn = snapshot.kind === 'signed-out' ? undefined : snapshot;
  return {
    // Locked storage hides the snapshot, whatever it says.
    destination: state.locked === true ? 'locked' : landing.destination,
    choice: landing.valid ? choice : undefined,
    choices,
    // Account setup is waiting for the person before the Inbox.
    setupPending: landing.setup !== '',
    copy: registrationCopy(t, snapshot),
    actions: {
      ...actions,
      signIn: actions.signIn.map((offer) => ({
        ...offer,
        label: t(`registration.${offer.offer}`, {
          provider: providerName(t, offer.provider),
        }),
      })),
    },
    // The Product Account's identity: who signed in, and with which Sign-In Providers.
    identity:
      signedIn === undefined
        ? undefined
        : identityOf(t, signedIn, state.linkFailure),
    // Mailbox authorization, separate from the Product Account's identity.
    mailboxes,
    privateSync: {
      copy: signedIn === undefined ? undefined : privateSyncCopy(t, signedIn),
      offersRecovery: offersRecovery(signedIn?.privateSync),
      approvesDevices: approvesDevices(signedIn?.privateSync),
    },
  } as const;
}

export type RegistrationScreen = ReturnType<typeof registrationScreen>;

// A prepared removal waiting for its replacement Recovery Key to be confirmed, if any.
export function revocationProposal(
  t: Translate,
  account: Readonly<{
    trustedDevices?: string;
    revocationDevice?: string;
    revocationRecoveryKey?: string;
  }>,
) {
  const { revocationDevice: id, revocationRecoveryKey: recoveryKey } = account;
  if (id === undefined || recoveryKey === undefined) {
    return undefined;
  }
  const device = trustedDevicesOf(account).find((item) => item.id === id);
  return { name: device?.name ?? t('revocation.device'), recoveryKey };
}

export const revocationNotice = (
  t: Translate,
  account: Readonly<{
    revocationNotice?: 'removed' | 'renewed' | 'unconfirmed' | 'superseded';
  }>,
  failed: boolean,
) => {
  if (failed) {
    return t('revocation.failed');
  }
  return account.revocationNotice === undefined
    ? undefined
    : t(`revocation.${account.revocationNotice}`);
};
