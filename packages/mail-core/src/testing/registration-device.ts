import type { SignInProvider } from '../registration.ts';
import type { SyntheticProductSync } from './registration-product-sync-state.ts';
import type {
  Call,
  Identity,
  SavedRecord,
  SyncVault,
} from './registration-vault-state.ts';

const gmailScope = 'https://www.googleapis.com/auth/gmail.modify';

// What outlives a relaunch: the device's Keychain, the providers and the backend.
export function createSyntheticDevice() {
  // The device's Keychain record; `clientID` selects which client's record this host reads.
  const device = {
    clientID: 'synthetic-client',
    record: undefined as SavedRecord | undefined,
    // Whether this device's Recovery Key is backed up, so sign-out may discard it.
    recoveryKeyConfirmed: true,
    // The Keychain's Product Sync items: the key ring, this installation's encryption key and an
    // open enrollment request. `unreadable` makes them fail to read.
    productSync: {
      vault: undefined as SyncVault | undefined,
      deviceKey: false,
      // The public half of this installation's encryption key, while it holds one.
      deviceKeyName: undefined as string | undefined,
      enrollment: undefined as
        | {
            pendingDeviceId: string;
            key: string;
            code: string;
            notice?: 'renewed' | 'rejected';
          }
        | undefined,
      unreadable: false,
    },
    connectionIds: new Map<string, string>(),
  };
  // The Google Sign-In SDK and Gmail profile, for Product Sign-In and Gmail alike.
  const google = {
    subject: 'synthetic-product-subject',
    outcome: undefined as string | undefined,
    scopes: [gmailScope] as string[],
    gmailAvailable: true,
    address: 'alex@example.invalid',
    addresses: {} as Record<string, string>,
    refused: new Set<string>(),
    refreshFailure: undefined as string | undefined,
    hints: [] as Array<string | undefined>,
    refreshes: 0,
  };
  // Microsoft's sign-in and Graph mailbox, for Microsoft mail only.
  const microsoft = {
    subject: 'synthetic-microsoft-subject',
    outcome: undefined as string | undefined,
    scopes: ['Mail.Read', 'User.Read', 'offline_access'] as string[],
    // Graph serves no mailbox, as for an account without Exchange Online or a refusing tenant.
    mailboxAvailable: true,
    address: 'casey@example.invalid',
    refreshFailure: undefined as string | undefined,
    hints: [] as Array<string | undefined>,
  };
  // A controlled IMAP server: the password it accepts, the user names it refuses, or the failure
  // every login meets.
  const imap = {
    password: 'synthetic-app-password',
    refusedUsernames: [] as string[],
    outcome: undefined as string | undefined,
    logins: 0,
  };
  const apple = {
    subject: 'synthetic-apple-subject',
    outcome: undefined as string | undefined,
    // Apple returns the address on first live.authorization only.
    email: 'relay@privaterelay.example.invalid' as string | undefined,
    state: 'authorized' as 'authorized' | 'revoked' | 'unavailable',
    signIns: 0,
  };
  // Convex's ownership, linking and removal rules: one owner per subject, never by email.
  const backend = {
    offline: false,
    owners: new Map<string, string>(),
    linked: new Map<string, SignInProvider[]>(),
    tickets: new Map<string, { account: string; provider: SignInProvider }>(),
    stale: false,
    pendingDevices: false,
    // Another connection's cleanup removed this Pending Device's expired record.
    pendingExpired: false,
    revoked: false,
    // The revocation query cannot reach Convex.
    revocationOffline: false,
    connectFailure: undefined as string | undefined,
    devices: 0,
    // Installation identifiers and connection epochs, unique across devices like native UUIDs.
    installations: 0,
    epochs: 0,
    deleted: new Set<string>(),
    // An unanswered request: the backend applies it, and the reply is lost.
    loseReply: false,
    unregisterFailure: undefined as string | undefined,
    deletionStatus: 200,
    deletionCode: undefined as string | undefined,
    // Identities that each link step verified, in order.
    verified: [] as string[],
    connected: [] as Identity[],
    unregistered: [] as Array<{ identity: Identity; installation: string }>,
    deletions: [] as Identity[],
    calls: [] as Call[],
    // Native push steps, in order with `calls`: each verified mailbox's routing and every watch
    // stopped before this device's routes leave the backend.
    push: [] as Array<'route' | 'stop'>,
    // Convex's Product Sync, absent where the host has none.
    productSync: undefined as SyntheticProductSync | undefined,
  };
  return { device, google, microsoft, imap, apple, backend };
}
