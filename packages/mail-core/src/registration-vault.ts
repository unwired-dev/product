import * as Schema from 'effect/Schema';

import type { MailProvider, SignInProvider } from './registration.ts';

import { MailProviderSchema, PrivateSyncStateSchema } from './registration.ts';

const Provider = Schema.Literals(['google', 'apple']);
const SetupReasonSchema = Schema.Literals([
  'cancelled',
  'declined',
  'gmail-unavailable',
  'microsoft-unavailable',
  'interrupted',
  'unavailable',
]);
export type SetupReason = typeof SetupReasonSchema.Type;

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
      provider: MailProviderSchema,
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
  privateSync: PrivateSyncStateSchema,
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
// them. `identity` is the latest Product Sign-In, `device` this device's Trusted or Pending Device
// proof, `installation` its device identifier, and `appleAuthorization` the latest Sign in with
// Apple authorization code with the client that issued it.
export type BackendCall = Readonly<{
  endpoint: 'query' | 'mutation' | 'action';
  path: string;
  args: Readonly<Record<string, unknown>>;
  identity?: true;
  device?: true;
  installation?: true;
  appleAuthorization?: true;
}>;
export const BackendReply = Schema.Struct({
  status: Schema.Finite,
  body: Schema.String,
});

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
  // Temporary until #757 moves Product Sync: initialization, admission and descriptors.
  readonly synchronize: () => Promise<unknown>;
  readonly forgetMailboxAccess: () => Promise<unknown>;
  readonly retryMailboxCleanup: () => Promise<unknown>;
  readonly refreshMailbox: (connection: string) => Promise<unknown>;
  // An interactive authorization with the provider, for a connection or a new mailbox; `suggest`
  // offers the Google Product Sign-In's account to Gmail.
  readonly signInMailbox: (
    connection: string | null,
    suggest: boolean,
    provider: MailProvider,
  ) => Promise<unknown>;
  // Reads the authorized mailbox's address from its provider, which proves the mail grant.
  readonly verifyMailbox: () => Promise<unknown>;
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
