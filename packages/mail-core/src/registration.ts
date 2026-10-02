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

const Account = Schema.Struct({
  productAccountId: Schema.NonEmptyString,
  signInProvider: SignInProviderSchema,
  // The other Sign-In Provider explicitly linked to the same Product Account.
  alternateSignIn: Schema.optionalKey(SignInProviderSchema),
  // Display and contact information only; it never links identities or selects a mailbox.
  contactEmail: Schema.optionalKey(Schema.NonEmptyString),
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

export interface NativeRegistration {
  readonly restore: () => Promise<unknown>;
  readonly signIn: (provider: SignInProvider) => Promise<unknown>;
  readonly authorizeGmail: (reselect: boolean) => Promise<unknown>;
  // Verifies the current Product Account and the identity being linked, interactively.
  readonly link: (provider: SignInProvider) => Promise<unknown>;
}

type RegistrationState = Readonly<{
  snapshot: RegistrationSnapshot;
  busy: boolean;
  failed: boolean;
  // A failed link leaves the Product Account and its sign-ins unchanged.
  linkFailure?: LinkFailure;
}>;

// A connected status is only valid while its verification succeeds.
const pending = (snapshot: RegistrationSnapshot): RegistrationSnapshot =>
  snapshot.kind === 'connected'
    ? {
        kind: 'mailbox-needed',
        productAccountId: snapshot.productAccountId,
        signInProvider: snapshot.signInProvider,
        ...(snapshot.alternateSignIn === undefined
          ? {}
          : { alternateSignIn: snapshot.alternateSignIn }),
        ...(snapshot.contactEmail === undefined
          ? {}
          : { contactEmail: snapshot.contactEmail }),
      }
    : snapshot;

const settled = (snapshot: RegistrationSnapshot): RegistrationState => ({
  snapshot,
  busy: false,
  failed: false,
});

class RegistrationCancelled extends Schema.TaggedError<RegistrationCancelled>()(
  'RegistrationCancelled',
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
    catch: (cause) =>
      isCancelled(cause)
        ? new RegistrationCancelled()
        : new RegistrationFailed({
            cause,
            diagnostic: rejectionDiagnostic(cause),
          }),
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

export function createRegistration(native: NativeRegistration) {
  let state: RegistrationState = {
    snapshot: { kind: 'signed-out' },
    busy: true,
    failed: false,
  };
  let restored = false;
  // One registration operation runs at a time; overlapping requests are ignored.
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
      RegistrationCancelled | RegistrationFailed
    >,
    onFailure: (
      snapshot: RegistrationSnapshot,
      cause: unknown,
    ) => RegistrationState = (snapshot) => ({
      ...settled(snapshot),
      failed: true,
    }),
  ) =>
    runLogged(
      Effect.sync(() => {
        publish({ snapshot: state.snapshot, busy: true, failed: false });
      }).pipe(
        Effect.andThen(operation),
        Effect.map(settled),
        Effect.catchTags({
          RegistrationCancelled: () =>
            Effect.sync(() => settled(state.snapshot)),
          RegistrationFailed: (error) =>
            Effect.logError('Registration failed:', error.diagnostic).pipe(
              Effect.andThen(
                Effect.sync(() => onFailure(state.snapshot, error.cause)),
              ),
            ),
        }),
        Effect.flatMap((next) =>
          Effect.sync(() => {
            publish(next);
          }),
        ),
        Semaphore.withPermitsIfAvailable(semaphore, 1),
        Effect.asVoid,
      ),
    );
  const restore = () =>
    execute(request(native.restore), (snapshot) => ({
      ...settled(pending(snapshot)),
      failed: true,
    }));
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
