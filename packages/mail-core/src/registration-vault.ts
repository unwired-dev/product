import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';

import type { ImapSetup } from './imap-setup.ts';
import type {
  EncryptedPayload,
  KeyEnvelope,
  PendingEnrollment,
  StoredPayload,
} from './registration-replies.ts';
import type {
  MailGrantProvider,
  SignInProvider,
} from './registration-snapshot.ts';

import {
  ImapEndpointSchema,
  SmtpEndpointSchema,
  endpointMatchesProvider,
} from './imap-setup.ts';
import { MailProviderSchema } from './registration-snapshot.ts';

const Provider = Schema.Literals(['google', 'apple']);
const SetupReasonSchema = Schema.Literals([
  'cancelled',
  'declined',
  'gmail-unavailable',
  'microsoft-unavailable',
  'interrupted',
  'unavailable',
  // An IMAP server refused the user name and password, could not be reached, or offered no
  // verified TLS; or its SMTP server refused them or offered no verified TLS.
  'imap-refused',
  'imap-offline',
  'imap-insecure',
  'smtp-refused',
  'smtp-insecure',
]);
export type SetupReason = typeof SetupReasonSchema.Type;

const Version = Schema.Int.check(Schema.isGreaterThanOrEqualTo(1));
// A Mail Profile definition, a connection's ownership or its New Mail Notification policy as native
// code seals and opens it.
export const ProfileRecordSchema = Schema.Union([
  Schema.Struct({
    kind: Schema.Literal('profile'),
    id: Schema.NonEmptyString,
    // The record's write count, sealed with it so an older write is never served as newer.
    version: Version,
    // Absent once the Profile is removed.
    name: Schema.optionalKey(Schema.NonEmptyString),
  }),
  Schema.Struct({
    kind: Schema.Literal('mailbox'),
    // The connection's descriptor record, and the epoch of the incarnation this owns.
    record: Schema.NonEmptyString,
    epoch: Schema.NonEmptyString,
    version: Version,
    profile: Schema.NonEmptyString,
  }),
  // Whether one incarnation of a connection notifies for new Inbox mail; a Mail Workflow
  // Preference of the Profile that owns it.
  Schema.Struct({
    kind: Schema.Literal('notifications'),
    record: Schema.NonEmptyString,
    epoch: Schema.NonEmptyString,
    version: Version,
    enabled: Schema.Boolean,
  }),
]);
export type ProfileRecord = typeof ProfileRecordSchema.Type;
// Mail Profile definitions and connection ownership as this device last read them, and the
// Profiles it named while offline. Native code keeps it in the account's device-only vault.
export const ProfileStateSchema = Schema.Struct({
  profiles: Schema.Array(
    Schema.Struct({
      id: Schema.NonEmptyString,
      // The stored record: its name, absent once removed, its write count and Convex revision.
      // All absent until the Profile is first published.
      name: Schema.optionalKey(Schema.NonEmptyString),
      version: Schema.optionalKey(Version),
      updatedAt: Schema.optionalKey(Schema.Finite),
      // A name this device chose that Product Sync does not hold yet.
      pending: Schema.optionalKey(Schema.NonEmptyString),
      // A fenced removal retained until its tombstone can publish.
      pendingRemoval: Schema.optionalKey(Schema.Literal(true)),
    }),
  ),
  owners: Schema.Array(
    Schema.Struct({
      record: Schema.NonEmptyString,
      epoch: Schema.NonEmptyString,
      profile: Schema.NonEmptyString,
      version: Version,
      updatedAt: Schema.Finite,
    }),
  ),
  // Each connection's synchronized notification policy, by its descriptor record.
  notifications: Schema.optionalKey(
    Schema.Array(
      Schema.Struct({
        record: Schema.NonEmptyString,
        epoch: Schema.NonEmptyString,
        enabled: Schema.Boolean,
        version: Version,
        updatedAt: Schema.Finite,
        // The record's opaque Product Sync identifier, so a later unreadable read can turn it off.
        identifier: Schema.optionalKey(Schema.NonEmptyString),
      }),
    ),
  ),
});
export type ProfileState = typeof ProfileStateSchema.Type;

// This device's Product Sync state as native device storage projects it: no key, credential or
// provider subject. The Recovery Key and Enrollment Code are text for display only. `record` is the
// opaque identifier Product Sync stores a mailbox's descriptor under.
const ProductSyncStateSchema = Schema.Struct({
  pending: Schema.Boolean,
  // As the latest connect reported it; absent means unknown, which never permits creating keys.
  materialInitialized: Schema.optionalKey(Schema.Boolean),
  // This installation holds its encryption key for the account.
  deviceKey: Schema.Boolean,
  // This installation's Trusted or Pending Device identifier, an opaque name other devices list.
  deviceId: Schema.NonEmptyString,
  // This Pending Device's open request.
  enrollment: Schema.optionalKey(
    Schema.Struct({
      code: Schema.NonEmptyString,
      notice: Schema.optionalKey(Schema.Literals(['renewed', 'rejected'])),
    }),
  ),
  vault: Schema.optionalKey(
    Schema.Struct({
      keyEpoch: Schema.Finite,
      published: Schema.Boolean,
      recoveryKeyConfirmed: Schema.Boolean,
      // Shown by the device that created the keys only until its setup is confirmed.
      recoveryKey: Schema.optionalKey(Schema.NonEmptyString),
      revocation: Schema.optionalKey(
        Schema.Struct({
          // The opaque identifier its activation and receipt carry.
          proposal: Schema.NonEmptyString,
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
          // Removals recorded before Microsoft mail are Gmail.
          provider: MailProviderSchema.pipe(
            Schema.withDecodingDefaultKey(Effect.succeed('gmail')),
          ),
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
      provider: MailProviderSchema,
      address: Schema.NonEmptyString,
      // An IMAP connection's reviewed endpoint; its password never leaves native storage.
      imap: Schema.optionalKey(ImapEndpointSchema),
      smtp: Schema.optionalKey(SmtpEndpointSchema),
      epoch: Schema.optionalKey(Schema.NonEmptyString),
      authorizationNeeded: Schema.Boolean,
      access: Schema.Literals(['verified', 'cached', 'unverified']),
    }).check(Schema.makeFilter(endpointMatchesProvider)),
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
  // Mail Profile state, saved apart from the Product Sync keys; absent before any Profile.
  profiles: Schema.optionalKey(
    Schema.Union([Schema.Literal('unreadable'), ProfileStateSchema]),
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
  // Creates and stores this Pending Device's one-time key pair and Enrollment Code, replacing an
  // earlier request's, and returns the public keys its request names. `notice` says why the
  // previous request ended without unlocking this device.
  readonly beginEnrollment: (
    notice: 'renewed' | 'rejected' | null,
  ) => Promise<unknown>;
  // Opens an approval with this Pending Device's one-time key and code and stores the key ring;
  // `{ opened: false }` when it does not open here, which changes nothing.
  readonly openEnrollment: (
    approval: Readonly<{
      keyVersion: number;
      encapsulatedKeyBase64: string;
      ciphertextBase64: string;
    }>,
  ) => Promise<unknown>;
  // Confirms the keys this Pending Device stored. Convex admits it as a Trusted Device, whose
  // receipt is saved before this resolves `{ admitted: true }`; a void authorization discards the
  // keys and leaves it pending.
  readonly confirmAdmission: () => Promise<unknown>;
  // This Pending Device proves the entered Recovery Key with a value derived from it, opens the
  // recovery envelope Convex returns and stores the key ring. Resolves `{ rejected }`.
  readonly recoverPendingDevice: (entry: string) => Promise<unknown>;
  // Opens the account's recovery envelope with the entered Recovery Key, binds this Trusted
  // Device's encryption key with the key's proof and stores the key ring. Resolves `{ rejected }`.
  readonly recoverTrustedDevice: (
    entry: string,
    envelope: typeof EncryptedPayload.Type,
  ) => Promise<unknown>;
  readonly readsAsEnrollmentCode: (entry: string) => Promise<unknown>;
  // Seals this device's key ring for another device's request, unlocked by the code it shows, and
  // returns the approval Convex stores.
  readonly sealEnrollment: (
    code: string,
    request: Pick<
      typeof PendingEnrollment.Type,
      'pendingDeviceId' | 'enrollmentPublicKey' | 'deviceEncryptionPublicKey'
    >,
  ) => Promise<unknown>;
  // Adopts the newest key ring a removal sealed to this device's encryption key; one it already
  // holds changes nothing.
  readonly adoptRotation: (
    envelope: typeof KeyEnvelope.Type,
  ) => Promise<unknown>;
  // Settles this device's submitted removal, which the account committed at `keyEpoch`.
  readonly settleRevocation: (keyEpoch: number) => Promise<unknown>;
  // Makes the latest Product Sign-In, or else this process's verified one, the session later steps
  // present; it must open the saved registration.
  readonly adoptIdentity: () => Promise<unknown>;
  // Prepares removing another Trusted Device: a new key epoch sealed to each remaining device's
  // encryption key and to a replacement Recovery Key, stored before this resolves. Replaces an
  // earlier proposal that was never sent.
  readonly prepareRevocation: (
    proposal: Readonly<{
      trustedDeviceId: string;
      expectedRecoveryUpdatedAt: number;
      devices: ReadonlyArray<
        Readonly<{ id: string; deviceEncryptionPublicKey?: string }>
      >;
    }>,
  ) => Promise<unknown>;
  // Once `entry` matches the end of the replacement Recovery Key, records that the prepared removal
  // is submitted, before it is sent, and returns what its activation carries.
  readonly submitRevocation: (entry: string) => Promise<unknown>;
  // A definite refusal: the prepared removal stays, with no submission outstanding.
  readonly withdrawRevocation: () => Promise<unknown>;
  readonly discardRevocation: () => Promise<unknown>;
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
  // Seals a Profile definition or connection ownership under the identifier native code derives
  // from its Profile or connection; resolves `{ payloadIdentifier, encryptedPayload }`.
  readonly sealProfileRecord: (record: ProfileRecord) => Promise<unknown>;
  // Each stored record's Profile definition or ownership, or null when it does not open under the
  // identifier its own content determines.
  readonly openProfileRecords: (
    records: ReadonlyArray<typeof StoredPayload.Type>,
  ) => Promise<unknown>;
  // Saves the Profile state in the account's device-only vault.
  readonly recordProfiles: (state: ProfileState) => Promise<unknown>;
  readonly forgetMailboxAccess: () => Promise<unknown>;
  readonly retryMailboxCleanup: () => Promise<unknown>;
  readonly refreshMailbox: (connection: string) => Promise<unknown>;
  // An interactive authorization with the provider, for a connection or a new mailbox; `suggest`
  // offers the Google Product Sign-In's account to Gmail.
  readonly signInMailbox: (
    connection: string | null,
    suggest: boolean,
    provider: MailGrantProvider,
  ) => Promise<unknown>;
  // Reads the authorized mailbox's address from its provider, which proves the mail grant.
  readonly verifyMailbox: () => Promise<unknown>;
  // Verifies an IMAP login and adds it as a connection, or repairs the one for the same account.
  // Resolves `{ connection, address }`; the password stays in native device storage.
  readonly connectImap: (setup: ImapSetup) => Promise<unknown>;
  // Logs in to a saved IMAP connection again, which verifies it for this process.
  readonly verifyImap: (connection: string) => Promise<unknown>;
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
}
