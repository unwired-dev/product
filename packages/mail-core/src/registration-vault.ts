import * as Schema from 'effect/Schema';

import type { StoredPayload } from './registration-replies.ts';
import type { SignInProvider } from './registration.ts';

const Provider = Schema.Literals(['google', 'apple']);
const SetupReasonSchema = Schema.Literals([
  'cancelled',
  'declined',
  'gmail-unavailable',
  'interrupted',
  'unavailable',
]);
export type SetupReason = typeof SetupReasonSchema.Type;

// This device's Product Sync state as native device storage projects it: no key, credential or
// provider subject. The Recovery Key and Enrollment Code are text for display only. `record` is the
// opaque identifier Product Sync stores a mailbox's descriptor under.
const ProductSyncStateSchema = Schema.Struct({
  pending: Schema.Boolean,
  // As the latest connect reported it; absent means unknown, which never permits creating keys.
  materialInitialized: Schema.optionalKey(Schema.Boolean),
  // This installation holds its encryption key for the account.
  deviceKey: Schema.Boolean,
  // This Pending Device's open request.
  enrollment: Schema.optionalKey(
    Schema.Struct({
      code: Schema.NonEmptyString,
      notice: Schema.optionalKey(Schema.Literals(['renewed', 'rejected'])),
    }),
  ),
  // Other devices' requests and the account's other Trusted Devices, as last listed.
  requests: Schema.Array(
    Schema.Struct({
      id: Schema.NonEmptyString,
      device: Schema.NonEmptyString,
      expiresAt: Schema.Finite,
    }),
  ),
  trustedDevices: Schema.Array(
    Schema.Struct({
      id: Schema.NonEmptyString,
      name: Schema.NonEmptyString,
      registeredAt: Schema.Finite,
    }),
  ),
  vault: Schema.optionalKey(
    Schema.Struct({
      keyEpoch: Schema.Finite,
      published: Schema.Boolean,
      recoveryKeyConfirmed: Schema.Boolean,
      // Held by the device that created the keys until its setup is confirmed.
      recoveryKey: Schema.optionalKey(Schema.NonEmptyString),
      revocation: Schema.optionalKey(
        Schema.Struct({
          device: Schema.NonEmptyString,
          recoveryKey: Schema.NonEmptyString,
          // Sent without a definite answer; the account may already have applied it.
          submitted: Schema.Boolean,
        }),
      ),
      readMailboxes: Schema.optionalKey(Schema.Array(Schema.String)),
      // The address confirmed for each of this device's connections, by record identifier.
      savedMailboxes: Schema.optionalKey(
        Schema.Record(Schema.String, Schema.String),
      ),
      mailboxes: Schema.Array(
        Schema.Struct({
          id: Schema.NonEmptyString,
          record: Schema.NonEmptyString,
          // This device has read its descriptor back at the connection's epoch.
          published: Schema.Boolean,
          // Authorized by explicit consent in this process.
          newlyAuthorized: Schema.Boolean,
          // What this device had last read of the descriptor when it authorized the connection.
          observed: Schema.optionalKey(Schema.Boolean),
          observedEpoch: Schema.optionalKey(Schema.String),
        }),
      ),
      // Removed connections whose descriptors are still to be marked removed.
      removals: Schema.Array(
        Schema.Struct({
          id: Schema.NonEmptyString,
          record: Schema.NonEmptyString,
          address: Schema.NonEmptyString,
          epoch: Schema.optionalKey(Schema.NonEmptyString),
        }),
      ),
    }),
  ),
});
export type ProductSyncState = typeof ProductSyncStateSchema.Type;

// The saved registration as native device storage projects it: no credential, token or provider
// subject. Mailbox access is this process's verification state for each connection.
export const RegistrationRecordSchema = Schema.Struct({
  signInProvider: Provider,
  contactEmail: Schema.optionalKey(Schema.String),
  product: Schema.optionalKey(
    Schema.Struct({
      productAccountId: Schema.NonEmptyString,
      pending: Schema.Boolean,
      signInProviders: Schema.optionalKey(Schema.Array(Provider)),
    }),
  ),
  mailboxSetupReason: Schema.optionalKey(SetupReasonSchema),
  mailboxes: Schema.Array(
    Schema.Struct({
      id: Schema.NonEmptyString,
      address: Schema.NonEmptyString,
      epoch: Schema.optionalKey(Schema.NonEmptyString),
      authorizationNeeded: Schema.Boolean,
      access: Schema.Literals(['verified', 'cached', 'unverified']),
    }),
  ),
  removal: Schema.optionalKey(
    Schema.Struct({
      operation: Schema.Literals(['signOut', 'deletion', 'revoked']),
      acknowledged: Schema.Boolean,
    }),
  ),
  // A removed connection's descriptor or cache still waits for cleanup.
  mailboxRemovalPending: Schema.Boolean,
  // Absent where a host has no Product Sync backend or before a Product Account.
  productSync: Schema.optionalKey(
    Schema.Union([Schema.Literal('unreadable'), ProductSyncStateSchema]),
  ),
  // This process holds a verified Product Sign-In.
  session: Schema.Boolean,
});
export type RegistrationRecord = typeof RegistrationRecordSchema.Type;

export const Identity = Schema.Struct({
  // The identity is the saved record's provider and account.
  matches: Schema.Boolean,
});
export const MailboxIdentity = Schema.Struct({
  scopes: Schema.Array(Schema.String),
});
export const MailboxReceipt = Schema.Struct({
  connection: Schema.NonEmptyString,
  address: Schema.NonEmptyString,
});

// A Convex call this flow names; native attaches the credentials it asks for and never returns
// them. `identity` is the latest Product Sign-In, `session` this process's verified one, `device`
// this device's Trusted or Pending Device proof, `installation` its device identifier, and
// `appleAuthorization` the latest Sign in with Apple authorization code with the client that
// issued it.
export type BackendCall = Readonly<{
  endpoint: 'query' | 'mutation' | 'action';
  path: string;
  args: Readonly<Record<string, unknown>>;
  identity?: true;
  session?: true;
  device?: true;
  installation?: true;
  appleAuthorization?: true;
}>;
export const BackendReply = Schema.Struct({
  status: Schema.Finite,
  body: Schema.String,
});

// The synchronized description of a Mailbox Connection; credentials never enter it. A removed
// connection keeps a descriptor marked removed, so every Trusted Device purges its authorization.
export const MailboxDescriptorSchema = Schema.Struct({
  provider: Schema.String,
  address: Schema.String,
  // Renewed whenever the connection is added after a removal, or first published.
  epoch: Schema.optionalKey(Schema.String),
  removed: Schema.optionalKey(Schema.Boolean),
});
export type MailboxDescriptor = typeof MailboxDescriptorSchema.Type;
// A connection's descriptor epoch, which null clears, and whether it was read back.
export type MailboxChange = Readonly<{
  id: string;
  epoch?: string | null;
  published?: true;
}>;

export interface NativeRegistrationVault {
  // The saved registration's projection, or null without one usable here.
  readonly registration: () => Promise<unknown>;
  // An interactive Product Sign-In; `hint` suggests the saved Google account.
  readonly signInIdentity: (
    provider: SignInProvider,
    hint: boolean,
  ) => Promise<unknown>;
  // Renews the saved Google Product Sign-In without a prompt.
  readonly renewIdentity: () => Promise<unknown>;
  readonly appleCredentialState: () => Promise<unknown>;
  // Makes this process's verified Product Sign-In the latest one again.
  readonly reuseSession: () => Promise<unknown>;
  // Saves the latest sign-in to the record, or to a new one for this device when `replacing`.
  readonly saveIdentity: (replacing: boolean) => Promise<unknown>;
  // Connects the latest sign-in to the Product Account and stores the issued device credential.
  readonly connect: (
    mode: 'establish' | 'switch' | 'renew',
  ) => Promise<unknown>;
  // Product Sync's native steps, which the flow sequences. Creates the key ring and Recovery Key
  // once, stored before anything is published, and returns what initialization sends.
  readonly createKeyRing: () => Promise<unknown>;
  // Convex's answer to initialization; unpublished keys never replace other key material.
  readonly recordInitialization: (initialized: boolean) => Promise<unknown>;
  // A Trusted Device that lost its encryption key connects again as a new Pending Device.
  readonly reenroll: () => Promise<unknown>;
  // Temporary until #758: this Pending Device's admission, adoption of the newest key ring, and
  // the other devices' requests and Trusted Devices kept for approval and removal.
  readonly admitPendingDevice: () => Promise<unknown>;
  readonly adoptRotation: () => Promise<unknown>;
  readonly refreshDevices: () => Promise<unknown>;
  // Ends the consent window in which a new connection may adopt a removed descriptor.
  readonly finishSynchronization: () => Promise<unknown>;
  readonly sealMailboxDescriptor: (
    record: string,
    descriptor: MailboxDescriptor,
  ) => Promise<unknown>;
  // Each stored record's descriptor, or null when it does not open under its own identifier.
  readonly openMailboxDescriptors: (
    records: ReadonlyArray<typeof StoredPayload.Type>,
  ) => Promise<unknown>;
  // Saves each connection's changed descriptor epoch or read-back, and drops settled removals.
  readonly recordMailboxChanges: (
    connections: readonly MailboxChange[],
    settledRemovals: readonly string[],
  ) => Promise<unknown>;
  // A connection another device removed or added again leaves this device.
  readonly purgeMailbox: (connection: string) => Promise<unknown>;
  // Relay routes of removed connections whose removals Product Sync records.
  readonly removeQueuedPushRoutes: () => Promise<unknown>;
  readonly recordMailboxReadback: (
    addresses: readonly string[],
    confirmed: Readonly<Record<string, string>>,
    epochs: Readonly<Record<string, string>>,
  ) => Promise<unknown>;
  readonly forgetMailboxAccess: () => Promise<unknown>;
  readonly retryMailboxCleanup: () => Promise<unknown>;
  readonly refreshMailbox: (connection: string) => Promise<unknown>;
  // An interactive Gmail authorization, for a connection or a new mailbox.
  readonly signInMailbox: (
    connection: string | null,
    suggest: boolean,
  ) => Promise<unknown>;
  readonly verifyGmail: () => Promise<unknown>;
  // Saves the verified authorization to its existing connection.
  readonly confirmMailbox: (connection: string) => Promise<unknown>;
  // Adds the verified authorization as a connection, or repairs the existing one.
  readonly storeMailbox: () => Promise<unknown>;
  readonly markMailbox: (
    connection: string,
    access: 'cached' | 'authorization' | 'unverified',
  ) => Promise<unknown>;
  readonly recordMailboxSetup: (reason: SetupReason) => Promise<unknown>;
  readonly saveSignInProviders: (
    providers: readonly SignInProvider[],
  ) => Promise<unknown>;
  readonly recordRemoval: (
    operation: 'signOut' | 'deletion' | null,
  ) => Promise<unknown>;
  // Whether this device may sign out without losing a Recovery Key nobody backed up.
  readonly prepareSignOut: () => Promise<unknown>;
  readonly endSession: () => Promise<unknown>;
  readonly purge: (
    notice: 'revoked' | 'deleted' | 'signed-out',
  ) => Promise<unknown>;
  readonly call: (request: BackendCall) => Promise<unknown>;
  // Stops a connection's Gmail watch and removes its push route before its credential leaves.
  readonly removeMailbox: (connection: string) => Promise<unknown>;
  // Registers this device for content-free Gmail wakes and renews each verified connection's
  // watch and route. Only the end of this device's access fails it.
  readonly routeMailboxes: () => Promise<unknown>;
  // Stops each connection's Gmail watch that no other device's route needs.
  readonly stopMailboxWatches: () => Promise<unknown>;
  readonly confirmRecoveryKey: (entry: string) => Promise<unknown>;
  readonly readsAsRecoveryKey: (entry: string) => Promise<unknown>;
  // Temporary until #758: unlocks with the Recovery Key after the flow renewed the sign-in.
  readonly recoverWithRecoveryKey: (entry: string) => Promise<unknown>;
  readonly approveEnrollment: (
    requestId: string,
    code: string,
  ) => Promise<unknown>;
  readonly declineEnrollment: (requestId: string) => Promise<unknown>;
  // Temporary until #758: prepares removing another Trusted Device with the latest sign-in.
  readonly revokeTrustedDevice: (trustedDeviceId: string) => Promise<unknown>;
  // Temporary until #758: activates the prepared removal once its replacement Recovery Key's final
  // group matches; a sign-in that is no longer recent rejects as stale authentication.
  readonly confirmRevocation: (entry: string) => Promise<unknown>;
  // Temporary until #758: discards the prepared removal, settling an unanswered one first.
  readonly cancelRevocation: () => Promise<unknown>;
}
