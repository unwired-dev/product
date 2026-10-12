import type { ProfileState } from '../registration-vault.ts';
import type { MailProvider, SignInProvider } from '../registration.ts';

export interface Identity {
  provider: SignInProvider;
  subject: string;
  email?: string;
  authorizationCode?: string;
}
export interface Receipt {
  productAccountId: string;
  trustedDeviceId: string;
  pending?: true;
  signInProviders?: SignInProvider[];
  // As the latest connect reported it, where the host has Product Sync.
  materialInitialized?: boolean;
}
export interface Connection {
  provider: MailProvider;
  subject: string;
  address: string;
  // An IMAP connection keeps its endpoint and password; a Gmail one has none.
  imap?: { host: string; port: number; username: string; password: string };
  // Renewed with each live.authorization, as native credentials are.
  credential: number;
  authorizationNeeded?: true;
  epoch?: string;
  published?: true;
  observed?: boolean;
  observedEpoch?: string;
}
// A removed connection whose descriptor is still to be marked removed.
export interface Removal {
  provider: MailProvider;
  subject: string;
  address: string;
  epoch?: string;
}
// A key ring: one lineage of key epochs. Only a ring of the same lineage holding a payload's epoch
// opens it.
export interface Ring {
  id: string;
  epochs: number[];
  current: number;
}
// The device-held Product Sync keys for the account, as native keeps them in the Keychain.
export interface SyncVault {
  ring: Ring;
  published: boolean;
  recoveryKey?: string;
  recoveryKeyConfirmed: boolean;
  readMailboxes?: string[];
  savedMailboxes?: Record<string, string>;
  descriptorEpochs?: Record<string, string>;
  // A prepared removal: what its activation carries and the ring its new epoch seals.
  revocation?: {
    proposal: string;
    device: string;
    recoveryKey: string;
    submitted: boolean;
    request: Record<string, unknown>;
    ring: Ring;
  };
}
export interface Stored {
  payloadIdentifier: string;
  encryptedPayload: Payload;
  updatedAt: number;
}
export interface Payload {
  algorithm: 'AES-GCM-256';
  ciphertextBase64: string;
  keyVersion: number;
  nonceBase64: string;
  schemaVersion: number;
  tagBase64: string;
}
export interface SavedRecord {
  clientID: string;
  deviceIdentifier: string;
  provider: SignInProvider;
  subject: string;
  credential: number;
  contactEmail?: string;
  product?: Receipt;
  profiles?: ProfileState;
  mailboxSetupReason?: string;
  connections: Connection[];
  removal?: {
    operation: 'signOut' | 'deletion' | 'revoked';
    acknowledged: boolean;
  };
  removals?: Removal[];
}
export type Call = Readonly<{
  endpoint: string;
  path: string;
  args: Readonly<Record<string, unknown>>;
  identity?: true;
  session?: true;
  device?: true;
  installation?: true;
  appleAuthorization?: true;
}>;

export type Presented = Readonly<{
  call: Call;
  product?: Readonly<Receipt> | undefined;
  signedIn?: Readonly<Identity> | undefined;
  installation?: string | undefined;
}>;

export const success = (value: unknown) => ({
  status: 200,
  body: JSON.stringify({ status: 'success', value }),
});
export const refusal = (code: string) => ({
  status: 200,
  body: JSON.stringify({ status: 'error', errorData: { code } }),
});

export const unavailable = () =>
  Object.assign(new Error('Synthetic'), { code: 'unavailable' });
// Runs a native operation, rejecting with whatever it throws.
export const attempt = async <A>(operation: () => A) => operation();
