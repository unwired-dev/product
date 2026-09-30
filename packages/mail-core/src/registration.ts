import * as Schema from 'effect/Schema';

const Account = Schema.Struct({
  productAccountId: Schema.NonEmptyString,
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

export interface NativeRegistration {
  readonly restore: () => Promise<unknown>;
  readonly signIn: () => Promise<unknown>;
  readonly authorizeGmail: (reselect: boolean) => Promise<unknown>;
}

type RegistrationState = Readonly<{
  snapshot: RegistrationSnapshot;
  busy: boolean;
  failed: boolean;
}>;

// A connected status is only valid while its verification succeeds.
const pending = (snapshot: RegistrationSnapshot): RegistrationSnapshot =>
  snapshot.kind === 'connected'
    ? { kind: 'mailbox-needed', productAccountId: snapshot.productAccountId }
    : snapshot;

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
    onFailure: (snapshot: RegistrationSnapshot) => RegistrationSnapshot = (
      snapshot,
    ) => snapshot,
  ) => {
    if (running) {
      return;
    }
    running = true;
    publish({ ...state, busy: true, failed: false });
    try {
      publish({ snapshot: await operation(), busy: false, failed: false });
    } catch (error) {
      if (isCancelled(error)) {
        publish({ ...state, busy: false, failed: false });
      } else {
        console.error('Registration failed', error);
        publish({
          snapshot: onFailure(state.snapshot),
          busy: false,
          failed: true,
        });
      }
    } finally {
      running = false;
    }
  };
  const restore = () =>
    execute(async () => decode(await native.restore()), pending);
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
    register: () =>
      execute(async () => {
        // Commit Product Sign-In before starting the separate consent session.
        const snapshot = decode(await native.signIn());
        publish({ snapshot, busy: true, failed: false });
        return snapshot.kind === 'mailbox-needed'
          ? decode(await native.authorizeGmail(false))
          : snapshot;
      }),
    authorizeGmail: (reselect: boolean) =>
      execute(async () => decode(await native.authorizeGmail(reselect))),
  };
}

export type Registration = ReturnType<typeof createRegistration>;

const mailboxReasons = {
  cancelled:
    'Gmail authorization was cancelled. Your Product Account is retained. Retry or choose another Google mailbox.',
  declined:
    'Gmail access was not granted. Your Product Account is retained. Retry or choose another Google mailbox.',
  'gmail-unavailable':
    'Gmail is unavailable for this authorization. Your Product Account is retained. Retry or choose another Google mailbox.',
  interrupted:
    'Gmail authorization was interrupted. Your Product Account is retained. Retry to finish setup.',
  unavailable:
    'Your saved Product Account could not be verified. It is retained on this device. Retry when you are online, or sign in again with Google.',
} as const;

export function registrationCopy(snapshot: RegistrationSnapshot) {
  switch (snapshot.kind) {
    case 'signed-out': {
      return {
        title: 'Welcome to Unwired Mail',
        description:
          'Create your Product Account with Google, then choose whether to grant Gmail access.',
      };
    }
    case 'mailbox-needed': {
      return {
        title: 'Connect your Gmail',
        description: snapshot.reason
          ? mailboxReasons[snapshot.reason]
          : 'Your Product Account is ready. Grant Gmail access to finish setup. You can use another Google account for your mailbox.',
      };
    }
    case 'connected': {
      return {
        title: 'Gmail connected',
        description: `${snapshot.address} is connected on this device.`,
      };
    }
    default: {
      const exhaustive: never = snapshot;
      return exhaustive;
    }
  }
}
