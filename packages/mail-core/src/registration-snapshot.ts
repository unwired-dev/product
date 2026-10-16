import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import {
  ImapEndpointSchema,
  SmtpEndpointSchema,
  endpointMatchesProvider,
} from './imap-setup.ts';

// The registration status hosts read: Sign-In and Mail Providers, Mailbox Connections and the
// Product Account snapshot. The registration flow and the store share it.

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

// The Mail Profiles besides the Default Profile: each one's identifier and name, and whether that
// name, chosen on this device, is not yet synchronized.
const ProfilesSchema = Schema.fromJsonString(
  Schema.Array(
    Schema.Struct({
      id: Schema.NonEmptyString,
      name: Schema.NonEmptyString,
      pending: Schema.optionalKey(Schema.Literal(true)),
    }),
  ),
);
const decodeProfiles = Schema.decodeOption(ProfilesSchema);
const profilesText = Schema.NonEmptyString.check(
  Schema.makeFilter((value) => Option.isSome(decodeProfiles(value))),
);
export type MailProfile = (typeof ProfilesSchema.Type)[number];

// The Mail Provider a Mailbox Connection reads: Gmail, Outlook.com and Microsoft 365 mail through
// Microsoft Graph, or a Standards-Based Mailbox Connection over IMAP.
export const MailProviderSchema = Schema.Literals([
  'gmail',
  'microsoft-graph',
  'imap',
]);
export type MailProvider = typeof MailProviderSchema.Type;
// A Mail Provider whose mailbox is authorized through the provider's own sign-in.
export type MailGrantProvider = Exclude<MailProvider, 'imap'>;

// The lossless migrated Mail Profile. It owns every Mailbox Connection recorded before Profiles,
// and its Profile Record Scope is the Product Account's existing Product Sync namespace, so no
// connection, Draft, Outbox or encrypted-record identity changes. Unique within a Product Account.
export const defaultProfile = 'default';
// The owner of a connection whose Mail Profile this device cannot determine; no window reads it.
export const unavailableProfile = 'unavailable';

// This device's Mailbox Connections in the order they were added. 'cached' opens only the saved
// Inbox until its provider verifies again; 'authorization' needs it authorized again first.
const MailboxesSchema = Schema.fromJsonString(
  Schema.Array(
    Schema.Struct({
      id: Schema.NonEmptyString,
      // Connections listed before Microsoft mail are Gmail.
      provider: MailProviderSchema.pipe(
        Schema.withDecodingDefaultKey(Effect.succeed('gmail')),
      ),
      address: Schema.NonEmptyString,
      // The reviewed IMAP endpoint, shown again when its password is entered again.
      imap: Schema.optionalKey(ImapEndpointSchema),
      // The verified SMTP endpoint; an IMAP connection without one receives only.
      smtp: Schema.optionalKey(SmtpEndpointSchema),
      state: Schema.Literals(['connected', 'cached', 'authorization']),
      // A removal/recreation changes this owner lifetime; ordinary verification does not.
      epoch: Schema.optionalKey(Schema.NonEmptyString),
      // The owning Mail Profile. Entries written before Profiles carry none and belong to the
      // Default Profile.
      profile: Schema.NonEmptyString.pipe(
        Schema.withDecodingDefaultKey(Effect.succeed(defaultProfile)),
      ),
    }).check(Schema.makeFilter(endpointMatchesProvider)),
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
  // Action-only receipt metadata, removed before publishing the snapshot to hosts.
  imapConnected: Schema.optionalKey(Schema.NonEmptyString),
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
  // JSON text listing the Mail Profiles besides the Default Profile; absent without any.
  profiles: Schema.optionalKey(profilesText),
  // A prepared removal of this listed Trusted Device waits for its replacement Recovery Key to be
  // confirmed, or for the outcome of its activation, which may already have committed.
  revocationDevice: Schema.optionalKey(Schema.NonEmptyString),
  // That proposal's replacement Recovery Key; it becomes current only when the removal activates.
  revocationRecoveryKey: Schema.optionalKey(Schema.NonEmptyString),
  // Only in the reply to a removal call: 'renewed' replaced the proposal and its key after the
  // account changed, 'unconfirmed' kept the proposal after a lost reply, and 'superseded'
  // discarded a key that never activated or was replaced by a later removal.
  revocationNotice: Schema.optionalKey(
    Schema.Literals(['removed', 'renewed', 'unconfirmed', 'superseded']),
  ),
});
// The account's Product Sync status values, from this device's Product Sync state.
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
  revocationDevice: Account.fields.revocationDevice,
  revocationRecoveryKey: Account.fields.revocationRecoveryKey,
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
        'microsoft-unavailable',
        'interrupted',
        'unavailable',
        'imap-refused',
        'imap-offline',
        'imap-insecure',
        'smtp-refused',
        'smtp-insecure',
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
export const profilesOf = (
  snapshot: RegistrationSnapshot,
): readonly MailProfile[] =>
  !('profiles' in snapshot) || snapshot.profiles === undefined
    ? []
    : Option.getOrThrow(decodeProfiles(snapshot.profiles));

// The native snapshot boundary has already validated this JSON text.
export const mailboxesOf = (
  snapshot: RegistrationSnapshot | Readonly<{ mailboxes?: string }>,
): readonly MailboxConnection[] =>
  !('mailboxes' in snapshot) || snapshot.mailboxes === undefined
    ? []
    : Option.getOrThrow(decodeMailboxes(snapshot.mailboxes));
