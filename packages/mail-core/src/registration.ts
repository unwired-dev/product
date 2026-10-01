import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

const SignInProviderSchema = Schema.Literals(['google', 'apple']);
export type SignInProvider = typeof SignInProviderSchema.Type;

// End-to-End Encrypted Product Sync on this device.
const PrivateSyncSchema = Schema.Literals([
  'setup-pending',
  'recovery-key',
  'ready',
  'enrollment-needed',
]);
export type PrivateSync = typeof PrivateSyncSchema.Type;

const Account = Schema.Struct({
  productAccountId: Schema.NonEmptyString,
  signInProvider: SignInProviderSchema,
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
});
export const RegistrationSnapshotSchema = Schema.Union([
  Schema.Struct({ kind: Schema.Literal('signed-out') }),
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

// Native hosts reject with the registration failure code; a cancelled session is not a failure.
const isCancelled = Schema.is(
  Schema.Struct({ code: Schema.Literal('cancelled') }),
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

export interface NativeRegistration {
  readonly restore: () => Promise<unknown>;
  readonly signIn: (provider: SignInProvider) => Promise<unknown>;
  readonly authorizeGmail: (reselect: boolean) => Promise<unknown>;
  // Verifies the current Product Account and the identity being linked, interactively.
  readonly link: (provider: SignInProvider) => Promise<unknown>;
  // Confirms Recovery Key setup with the final group the person wrote down.
  readonly confirmRecoveryKey: (entry: string) => Promise<unknown>;
}

type RegistrationState = Readonly<{
  snapshot: RegistrationSnapshot;
  busy: boolean;
  failed: boolean;
  // A failed link leaves the Product Account and its sign-ins unchanged.
  linkFailure?: LinkFailure;
  recoveryKeyFailure?: RecoveryKeyFailure;
}>;

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

export function createRegistration(native: NativeRegistration) {
  let state: RegistrationState = {
    snapshot: { kind: 'signed-out' },
    busy: true,
    failed: false,
  };
  let running = false;
  let restored = false;
  const listeners = new Set<() => void>();
  const publish = (next: RegistrationState) => {
    state = next;
    for (const listener of listeners) {
      listener();
    }
  };
  // oxlint-disable-next-line node/no-sync -- Decode the native response boundary.
  const decode = Schema.decodeUnknownSync(RegistrationSnapshotSchema);
  const execute = async (
    operation: () => Promise<RegistrationSnapshot>,
    onFailure: (
      snapshot: RegistrationSnapshot,
      error: unknown,
    ) => RegistrationState = (snapshot) => ({
      ...settled(snapshot),
      failed: true,
    }),
  ) => {
    if (running) {
      return;
    }
    running = true;
    publish({ snapshot: state.snapshot, busy: true, failed: false });
    try {
      publish(settled(await operation()));
    } catch (error) {
      if (isCancelled(error)) {
        publish(settled(state.snapshot));
      } else {
        console.error('Registration failed', error);
        publish(onFailure(state.snapshot, error));
      }
    } finally {
      running = false;
    }
  };
  const restore = () =>
    execute(
      async () => decode(await native.restore()),
      (snapshot) => ({ ...settled(pending(snapshot)), failed: true }),
    );
  return {
    getSnapshot: () => state,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    restore,
    // Every mounted host view restores through the same store; only the first mount verifies.
    restoreOnce: () => {
      if (restored) {
        return Promise.resolve();
      }
      restored = true;
      return restore();
    },
    register: (provider: SignInProvider) =>
      execute(async () => {
        // Commit Product Sign-In before starting the separate Gmail consent session.
        const snapshot = decode(await native.signIn(provider));
        publish({ snapshot, busy: true, failed: false });
        return snapshot.kind === 'mailbox-needed'
          ? decode(await native.authorizeGmail(false))
          : snapshot;
      }),
    authorizeGmail: (reselect: boolean) =>
      execute(async () => decode(await native.authorizeGmail(reselect))),
    link: (provider: SignInProvider) =>
      execute(
        async () => decode(await native.link(provider)),
        (snapshot, error) => ({
          ...settled(snapshot),
          linkFailure: Option.getOrElse(
            Option.map(linkFailureCode(error), ({ code }) => code),
            (): LinkFailure => 'failed',
          ),
        }),
      ),
    confirmRecoveryKey: (entry: string) =>
      execute(
        async () => decode(await native.confirmRecoveryKey(entry)),
        (snapshot, error) => ({
          ...settled(snapshot),
          recoveryKeyFailure: isRecoveryKeyMismatch(error)
            ? 'mismatch'
            : 'failed',
        }),
      ),
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
    description: `Only ${current} opens this Product Account. Linking ${providerNames[other]} adds another way to sign in. It does not connect a mailbox.`,
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

export function registrationCopy(snapshot: RegistrationSnapshot) {
  switch (snapshot.kind) {
    case 'signed-out': {
      return {
        title: 'Welcome to Unwired Mail',
        description:
          'Create your Product Account with Apple or Google, then choose whether to grant Gmail access.',
        account: undefined,
      };
    }
    case 'mailbox-needed': {
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
}>;

// Private product data on this device; mailbox credentials never take part in it.
export function privateSyncCopy(snapshot: PrivateSyncState) {
  const mailboxes =
    snapshot.privateSyncMailboxes === undefined
      ? undefined
      : `Encrypted mailbox list: ${snapshot.privateSyncMailboxes.split('\n').join(', ')}.`;
  switch (snapshot.privateSync) {
    case undefined: {
      return undefined;
    }
    case 'setup-pending': {
      return {
        title: 'Private sync',
        description:
          'Private sync setup has not finished. It continues the next time your Product Account is verified. Sign in again to finish it now.',
        mailboxes,
        recoveryKey: undefined,
      };
    }
    case 'recovery-key': {
      return {
        title: 'Save your Recovery Key',
        description:
          'Your product data is end-to-end encrypted. If you lose every trusted device, this Recovery Key is the only way to unlock it. Write it down and keep it somewhere safe. Unwired Mail cannot show it to anyone else or reset it.',
        mailboxes,
        recoveryKey: snapshot.recoveryKey,
      };
    }
    case 'ready': {
      return {
        title: 'Private sync is on',
        description:
          'Your product data is end-to-end encrypted. Only your trusted devices can read it.',
        mailboxes,
        recoveryKey: undefined,
      };
    }
    case 'enrollment-needed': {
      return {
        title: 'Unlock private data on this device',
        description:
          'This Product Account already has end-to-end encrypted data, so this device needs its keys. Approve it from one of your trusted devices or use your Recovery Key. Nothing was reset or replaced.',
        mailboxes,
        recoveryKey: undefined,
      };
    }
    default: {
      const exhaustive: never = snapshot.privateSync;
      return exhaustive;
    }
  }
}

export const recoveryKeyConfirmationCopy = {
  prompt:
    'To confirm you saved it, enter the last four characters of your Recovery Key.',
  label: 'Last four characters',
  confirm: 'Confirm Recovery Key',
  mismatch:
    'That does not match the end of your Recovery Key. Check your written copy and try again.',
  failed: 'Your Recovery Key could not be confirmed. Try again.',
} as const;
