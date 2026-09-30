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

export function createRegistration(native: NativeRegistration) {
  let state: RegistrationState = {
    snapshot: { kind: 'signed-out' },
    busy: true,
    failed: false,
  };
  let running = false;
  const listeners = new Set<() => void>();
  const publish = (next: RegistrationState) => {
    state = next;
    for (const listener of listeners) {
      listener();
    }
  };
  const execute = async (operation: () => Promise<unknown>) => {
    if (running) {
      return;
    }
    running = true;
    publish({ ...state, busy: true, failed: false });
    try {
      const value = await operation();
      // oxlint-disable-next-line node/no-sync -- Decode the native response boundary.
      const snapshot = Schema.decodeUnknownSync(RegistrationSnapshotSchema)(
        value,
      );
      publish({ snapshot, busy: false, failed: false });
    } catch {
      publish({ ...state, busy: false, failed: true });
    } finally {
      running = false;
    }
  };
  return {
    getSnapshot: () => state,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    restore: () => {
      if (running) {
        return Promise.resolve();
      }
      if (state.snapshot.kind === 'connected') {
        publish({
          ...state,
          snapshot: {
            kind: 'mailbox-needed',
            productAccountId: state.snapshot.productAccountId,
          },
        });
      }
      return execute(native.restore);
    },
    register: () =>
      execute(async () => {
        // Commit Product Sign-In before starting the separate consent session.
        const value = await native.signIn();
        // oxlint-disable-next-line node/no-sync -- Decode the native response boundary.
        const snapshot = Schema.decodeUnknownSync(RegistrationSnapshotSchema)(
          value,
        );
        publish({ snapshot, busy: true, failed: false });
        return snapshot.kind === 'mailbox-needed'
          ? native.authorizeGmail(false)
          : snapshot;
      }),
    authorizeGmail: (reselect: boolean) =>
      execute(() => native.authorizeGmail(reselect)),
  };
}

export type Registration = ReturnType<typeof createRegistration>;

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
          ? {
              cancelled:
                'Gmail authorization was cancelled. Your Product Account is retained. Retry or choose another Google mailbox.',
              declined:
                'Gmail access was not granted. Your Product Account is retained. Retry or choose another Google mailbox.',
              'gmail-unavailable':
                'Gmail is unavailable for this authorization. Your Product Account is retained. Retry or choose another Google mailbox.',
              interrupted:
                'Gmail authorization was interrupted. Your Product Account is retained. Retry to finish setup.',
            }[snapshot.reason]
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
