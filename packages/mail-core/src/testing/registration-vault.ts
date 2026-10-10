/* oxlint-disable typescript/prefer-readonly-parameter-types -- Tests change the synthetic device's state between steps. */
import type { NativeRegistrationVault } from '../registration-flow.ts';
import type { SignInProvider } from '../registration.ts';

import { syntheticMailboxes } from './registration-session.ts';

// An in-memory native vault with synthetic Google, Apple and Convex behavior, for the TypeScript
// registration flow. It keeps what native code keeps from TypeScript: credentials, tokens and
// provider subjects stay here, and every operation behaves as its native counterpart does.

const gmailScope = 'https://www.googleapis.com/auth/gmail.modify';

interface Identity {
  provider: SignInProvider;
  subject: string;
  email?: string;
  authorizationCode?: string;
}
interface Receipt {
  productAccountId: string;
  trustedDeviceId: string;
  pending?: true;
  signInProviders?: SignInProvider[];
}
interface Connection {
  subject: string;
  address: string;
  // Renewed with each live.authorization, as native credentials are.
  credential: number;
  authorizationNeeded?: true;
  epoch: string;
}
interface SavedRecord {
  clientID: string;
  deviceIdentifier: string;
  provider: SignInProvider;
  subject: string;
  credential: number;
  contactEmail?: string;
  product?: Receipt;
  mailboxSetupReason?: string;
  connections: Connection[];
  removal?: {
    operation: 'signOut' | 'deletion' | 'revoked';
    acknowledged: boolean;
  };
}
type Call = Readonly<{
  endpoint: string;
  path: string;
  args: Readonly<Record<string, unknown>>;
  identity?: true;
  device?: true;
  installation?: true;
  appleAuthorization?: true;
}>;

const reject = (code: string): Promise<never> =>
  Promise.reject(Object.assign(new Error(`Synthetic ${code}`), { code }));
const success = (value: unknown) => ({
  status: 200,
  body: JSON.stringify({ status: 'success', value }),
});
const refusal = (code: string) => ({
  status: 200,
  body: JSON.stringify({ status: 'error', errorData: { code } }),
});

// Runs a native operation, rejecting with whatever it throws.
const attempt = async <A>(operation: () => A) => operation();

// What outlives a relaunch: the device's Keychain, the providers and the backend.
export function createSyntheticDevice() {
  // The device's Keychain record; `clientID` selects which client's record this host reads.
  const device = {
    clientID: 'synthetic-client',
    record: undefined as SavedRecord | undefined,
    // Whether this device's Recovery Key is backed up, so sign-out may discard it.
    recoveryKeyConfirmed: true,
    privateSync: {} as Readonly<Record<string, string>>,
    installations: 0,
    epochs: 0,
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
  };
  return { device, google, apple, backend };
}

// One process of the host over a synthetic device; a relaunch is another vault over the same one.
export function createSyntheticVault(
  shared: Readonly<
    ReturnType<typeof createSyntheticDevice>
  > = createSyntheticDevice(),
) {
  const { device, google, apple, backend } = shared;
  // This process's latest sign-in, verified sign-in and Gmail live.authorization.
  const live = {
    identity: undefined as Identity | undefined,
    session: undefined as Identity | undefined,
    authorization: undefined as
      | {
          subject: string;
          scopes: readonly string[];
          receipt?: { address: string };
        }
      | undefined,
  };
  const verified = new Set<string>();
  const cached = new Set<string>();

  // Opaque like native connection IDs; the known synthetic mailboxes keep their host IDs.
  const connectionId = (subject: string, address?: string) => {
    const known = Object.entries(syntheticMailboxes).find(
      ([mailbox]) => mailbox === address,
    )?.[1];
    if (known !== undefined) {
      return known;
    }
    const id =
      device.connectionIds.get(subject) ??
      `synthetic-connection-${device.connectionIds.size + 1}`;
    device.connectionIds.set(subject, id);
    return id;
  };
  const load = () =>
    device.record?.clientID === device.clientID ? device.record : undefined;
  const saved = () => {
    const record = load();
    if (record === undefined) {
      throw Object.assign(new Error('Synthetic unavailable'), {
        code: 'unavailable',
      });
    }
    return record;
  };
  const latestIdentity = () => {
    if (live.identity === undefined) {
      throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
    }
    return live.identity;
  };
  const opens = (
    record: Readonly<SavedRecord> | undefined,
    signedIn: Readonly<Identity>,
  ) =>
    record !== undefined &&
    record.provider === signedIn.provider &&
    record.subject === signedIn.subject;
  const productIdentity = (provider: SignInProvider, hint?: string) => {
    if (provider === 'google') {
      google.hints.push(hint);
      return google.outcome === undefined
        ? Promise.resolve<Identity>({ provider, subject: google.subject })
        : reject(google.outcome);
    }
    apple.signIns += 1;
    if (apple.outcome !== undefined) {
      return reject(apple.outcome);
    }
    const signedIn: Identity = {
      provider,
      subject: apple.subject,
      authorizationCode: `synthetic-apple-code-${apple.signIns}`,
      ...(apple.email === undefined ? {} : { email: apple.email }),
    };
    apple.email = undefined;
    return Promise.resolve(signedIn);
  };
  const connect = (
    signedIn: Readonly<Identity>,
    previous?: Readonly<Receipt>,
  ): Receipt => {
    const existing = backend.owners.get(signedIn.subject);
    if (previous !== undefined && existing !== previous.productAccountId) {
      throw Object.assign(new Error('Synthetic refusal'), {
        code: 'invalid-identity',
      });
    }
    if (backend.connectFailure !== undefined) {
      throw Object.assign(new Error('Synthetic failure'), {
        code: backend.connectFailure,
      });
    }
    const account = existing ?? `account-${signedIn.subject}`;
    if (backend.deleted.has(account)) {
      throw Object.assign(new Error('Synthetic deletion'), { code: 'deleted' });
    }
    backend.owners.set(signedIn.subject, account);
    if (!backend.linked.has(account)) {
      backend.linked.set(account, [signedIn.provider]);
    }
    backend.connected.push(signedIn);
    return {
      productAccountId: account,
      trustedDeviceId: `synthetic-device-${(backend.devices += 1)}`,
      ...(backend.pendingDevices ? { pending: true as const } : {}),
      signInProviders: [...(backend.linked.get(account) ?? [])],
    };
  };

  // What Convex answers for each call, given the credentials native code attached.
  type Presented = Readonly<{
    call: Call;
    product?: Readonly<Receipt> | undefined;
    signedIn?: Readonly<Identity> | undefined;
    installation?: string | undefined;
  }>;
  const registered = () => {
    const record = saved();
    if (record.product === undefined) {
      throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
    }
    return record;
  };
  const present = (call: Call): Presented => {
    if (call.path === 'productAccount:connect') {
      throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
    }
    return {
      call,
      product: call.device === true ? registered().product : undefined,
      signedIn: call.identity === true ? latestIdentity() : undefined,
      installation:
        call.installation === true ? registered().deviceIdentifier : undefined,
    };
  };
  const unregister = ({ signedIn, installation }: Presented) => {
    if (backend.unregisterFailure !== undefined) {
      throw Object.assign(new Error('Synthetic failure'), {
        code: backend.unregisterFailure,
      });
    }
    if (signedIn !== undefined && installation !== undefined) {
      backend.unregistered.push({ identity: signedIn, installation });
    }
    return success({ registered: false });
  };
  const handlers: Readonly<
    Record<
      string,
      (presented: Presented) => Readonly<{ status: number; body: string }>
    >
  > = {
    'productAccount:isTrustedDeviceRevoked': () => {
      if (backend.revocationOffline) {
        throw Object.assign(new Error('Synthetic failure'), {
          code: 'offline',
        });
      }
      return success(backend.revoked);
    },
    '/sign-in-links/request': ({ call, product, signedIn }) => {
      if (backend.stale) {
        return refusal('SIGN_IN_RECENT_AUTHENTICATION_REQUIRED');
      }
      if (
        product === undefined ||
        signedIn === undefined ||
        backend.owners.get(signedIn.subject) !== product.productAccountId
      ) {
        return refusal('SIGN_IN_NOT_LINKED');
      }
      backend.verified.push(signedIn.subject);
      const providers = backend.linked.get(product.productAccountId) ?? [];
      const provider: SignInProvider =
        call.args.provider === 'apple' ? 'apple' : 'google';
      if (providers.includes(provider)) {
        return success({ signInProviders: providers });
      }
      const ticket = `synthetic-ticket-${backend.tickets.size}`;
      backend.tickets.set(ticket, {
        account: product.productAccountId,
        provider,
      });
      return success({ linkTicket: ticket, signInProviders: providers });
    },
    '/sign-in-links/complete': ({ call, product, signedIn }) => {
      const ticket = String(call.args.linkTicket);
      const request = backend.tickets.get(ticket);
      backend.tickets.delete(ticket);
      if (
        request === undefined ||
        signedIn === undefined ||
        request.account !== product?.productAccountId ||
        request.provider !== signedIn.provider
      ) {
        return refusal('SIGN_IN_LINK_EXPIRED');
      }
      if (backend.owners.has(signedIn.subject)) {
        return refusal('SIGN_IN_IDENTITY_OWNED');
      }
      backend.verified.push(signedIn.subject);
      backend.owners.set(signedIn.subject, request.account);
      const providers = [
        ...(backend.linked.get(request.account) ?? []),
        signedIn.provider,
      ];
      backend.linked.set(request.account, providers);
      return success({
        productAccountId: request.account,
        signInProviders: providers,
      });
    },
    'productAccount:unregisterTrustedDevice': unregister,
    'productAccount:unregisterPendingDevice': unregister,
    'productSyncEnrollment:status': () =>
      backend.pendingExpired
        ? refusal('PENDING_DEVICE_UNAVAILABLE')
        : success({ state: 'pending' }),
    '/product-account/delete': ({ product, signedIn }) => {
      if (backend.deletionStatus !== 200) {
        return {
          status: backend.deletionStatus,
          body: JSON.stringify({ code: backend.deletionCode ?? 'REFUSED' }),
        };
      }
      if (signedIn !== undefined) {
        backend.deletions.push(signedIn);
      }
      if (product !== undefined) {
        backend.deleted.add(product.productAccountId);
      }
      return { status: 200, body: JSON.stringify({ deleted: true }) };
    },
  };

  const accessOf = (id: string) => {
    if (verified.has(id)) {
      return 'verified';
    }
    return cached.has(id) ? 'cached' : 'unverified';
  };

  const vault: NativeRegistrationVault = {
    registration: () =>
      attempt(() => {
        const record = load();
        if (record === undefined) {
          return null;
        }
        return {
          signInProvider: record.provider,
          ...(record.contactEmail === undefined
            ? {}
            : { contactEmail: record.contactEmail }),
          ...(record.product === undefined
            ? {}
            : {
                product: {
                  productAccountId: record.product.productAccountId,
                  pending: record.product.pending === true,
                  ...(record.product.signInProviders === undefined
                    ? {}
                    : { signInProviders: record.product.signInProviders }),
                },
              }),
          ...(record.mailboxSetupReason === undefined
            ? {}
            : { mailboxSetupReason: record.mailboxSetupReason }),
          ...(record.removal === undefined ? {} : { removal: record.removal }),
          mailboxes: record.connections.map((connection) => {
            const id = connectionId(connection.subject, connection.address);
            return {
              id,
              address: connection.address,
              epoch: connection.epoch,
              authorizationNeeded: connection.authorizationNeeded === true,
              access: accessOf(id),
            };
          }),
          mailboxRemovalPending: false,
          privateSync: record.product === undefined ? {} : device.privateSync,
          session: live.session !== undefined,
        };
      }),
    signInIdentity: async (provider, hint) => {
      const record = load();
      const signedIn = await productIdentity(
        provider,
        hint && record?.provider === 'google' ? record.subject : undefined,
      );
      live.identity = signedIn;
      return { matches: opens(record, signedIn) };
    },
    renewIdentity: () =>
      attempt(() => {
        const record = saved();
        if (record.provider !== 'google') {
          throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
        }
        google.refreshes += 1;
        if (google.refreshFailure !== undefined) {
          throw Object.assign(new Error('Synthetic'), {
            code: google.refreshFailure,
          });
        }
        live.identity = { provider: 'google', subject: record.subject };
        return { matches: true };
      }),
    appleCredentialState: () =>
      attempt(() => {
        saved();
        return apple.state;
      }),
    reuseSession: () =>
      attempt(() => {
        if (live.session === undefined) {
          throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
        }
        live.identity = live.session;
        return null;
      }),
    saveIdentity: (replacing) =>
      attempt(() => {
        const signedIn = latestIdentity();
        const existing = load();
        if (
          replacing
            ? existing?.product !== undefined
            : existing !== undefined && !opens(existing, signedIn)
        ) {
          throw Object.assign(new Error('Synthetic'), {
            code: 'invalid-identity',
          });
        }
        const retained = replacing ? undefined : existing;
        if (retained === undefined) {
          device.installations += 1;
        }
        const next: SavedRecord = retained ?? {
          clientID: device.clientID,
          deviceIdentifier: `synthetic-installation-${device.installations}`,
          provider: signedIn.provider,
          subject: signedIn.subject,
          credential: 0,
          connections: [],
        };
        next.credential += 1;
        if (signedIn.email !== undefined) {
          next.contactEmail = signedIn.email;
        }
        device.record = next;
        return null;
      }),
    connect: (mode) =>
      attempt(() => {
        const record = saved();
        const signedIn = latestIdentity();
        if (mode === 'establish' && !opens(record, signedIn)) {
          throw Object.assign(new Error('Synthetic'), {
            code: 'invalid-identity',
          });
        }
        if (mode !== 'establish' && record.product === undefined) {
          throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
        }
        if (backend.offline) {
          throw Object.assign(new Error('Synthetic'), { code: 'offline' });
        }
        const product = connect(signedIn, record.product);
        if (mode === 'switch') {
          record.provider = signedIn.provider;
          record.subject = signedIn.subject;
          if (signedIn.email !== undefined) {
            record.contactEmail = signedIn.email;
          }
        }
        record.product = product;
        if (mode !== 'renew') {
          live.session = signedIn;
        }
        return null;
      }),
    synchronize: () =>
      attempt(() => {
        saved();
        return null;
      }),
    forgetMailboxAccess: () =>
      attempt(() => {
        verified.clear();
        cached.clear();
        return null;
      }),
    retryMailboxCleanup: () =>
      attempt(() => {
        saved();
        return null;
      }),
    refreshMailbox: (id) =>
      attempt(() => {
        const connection = saved().connections.find(
          ({ subject, address }) => connectionId(subject, address) === id,
        );
        if (connection === undefined) {
          throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
        }
        if (google.refreshFailure !== undefined) {
          throw Object.assign(new Error('Synthetic'), {
            code: google.refreshFailure,
          });
        }
        live.authorization = {
          subject: connection.subject,
          scopes: google.scopes,
        };
        return { scopes: google.scopes };
      }),
    signInMailbox: async (id, suggest) => {
      const record = saved();
      const hint =
        record.connections.find(
          ({ subject, address }) => connectionId(subject, address) === id,
        )?.subject ??
        (suggest && record.provider === 'google' ? record.subject : undefined);
      google.hints.push(hint);
      if (google.outcome !== undefined) {
        return reject(google.outcome);
      }
      live.authorization = { subject: google.subject, scopes: google.scopes };
      return { scopes: google.scopes };
    },
    verifyGmail: () =>
      attempt(() => {
        if (live.authorization === undefined) {
          throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
        }
        if (
          !google.gmailAvailable ||
          google.refused.has(live.authorization.subject)
        ) {
          throw Object.assign(new Error('Synthetic'), {
            code: 'gmail-unavailable',
          });
        }
        const address =
          google.addresses[live.authorization.subject] ?? google.address;
        live.authorization.receipt = { address };
        return {
          connection: connectionId(live.authorization.subject, address),
          address,
        };
      }),
    confirmMailbox: (id) =>
      attempt(() => {
        const record = saved();
        const receipt = live.authorization?.receipt;
        const connection = record.connections.find(
          ({ subject, address }) => connectionId(subject, address) === id,
        );
        if (
          receipt === undefined ||
          connection === undefined ||
          live.authorization?.subject !== connection.subject
        ) {
          throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
        }
        live.authorization = undefined;
        connection.credential += 1;
        connection.address = receipt.address;
        delete connection.authorizationNeeded;
        delete record.mailboxSetupReason;
        verified.add(id);
        cached.delete(id);
        return null;
      }),
    storeMailbox: () =>
      attempt(() => {
        const record = saved();
        const pending = live.authorization;
        if (
          pending?.receipt === undefined ||
          record.product === undefined ||
          record.product.pending === true
        ) {
          throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
        }
        live.authorization = undefined;
        const id = connectionId(pending.subject, pending.receipt.address);
        const existing = record.connections.find(
          ({ subject }) => subject === pending.subject,
        );
        if (existing === undefined) {
          device.epochs += 1;
          record.connections.push({
            subject: pending.subject,
            address: pending.receipt.address,
            credential: 1,
            epoch: `synthetic-epoch-${device.epochs}`,
          });
        } else {
          existing.credential += 1;
          existing.address = pending.receipt.address;
          delete existing.authorizationNeeded;
        }
        delete record.mailboxSetupReason;
        verified.add(id);
        cached.delete(id);
        return null;
      }),
    markMailbox: (id, access) =>
      attempt(() => {
        verified.delete(id);
        if (access === 'cached') {
          cached.add(id);
        } else if (access === 'authorization') {
          cached.delete(id);
          const connection = saved().connections.find(
            ({ subject, address }) => connectionId(subject, address) === id,
          );
          if (connection !== undefined) {
            connection.authorizationNeeded = true;
          }
        }
        return null;
      }),
    recordMailboxSetup: (reason) =>
      attempt(() => {
        saved().mailboxSetupReason = reason;
        return null;
      }),
    saveSignInProviders: (providers) =>
      attempt(() => {
        const { product } = saved();
        if (product === undefined) {
          throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
        }
        product.signInProviders = [...providers];
        return null;
      }),
    recordRemoval: (operation) =>
      attempt(() => {
        const record = saved();
        if (operation === null) {
          delete record.removal;
        } else {
          record.removal = { operation, acknowledged: false };
        }
        return null;
      }),
    prepareSignOut: () =>
      attempt(() => {
        const record = saved();
        if (live.identity === undefined || !opens(record, live.identity)) {
          throw Object.assign(new Error('Synthetic'), {
            code: 'invalid-identity',
          });
        }
        live.session = live.identity;
        return device.recoveryKeyConfirmed;
      }),
    endSession: () =>
      attempt(() => {
        live.session = undefined;
        return null;
      }),
    purge: () =>
      attempt(() => {
        verified.clear();
        cached.clear();
        live.session = undefined;
        live.identity = undefined;
        live.authorization = undefined;
        device.record = undefined;
        device.privateSync = {};
        return null;
      }),
    call: async (call) => {
      backend.calls.push(call);
      const presented = present(call);
      if (backend.offline) {
        return reject('offline');
      }
      const reply = (handlers[call.path] ?? (() => refusal('UNAVAILABLE')))(
        presented,
      );
      if (backend.loseReply) {
        return reject('offline');
      }
      return reply;
    },
    removeMailbox: (id) =>
      attempt(() => {
        const record = saved();
        record.connections = record.connections.filter(
          ({ subject, address }) => connectionId(subject, address) !== id,
        );
        verified.delete(id);
        cached.delete(id);
        return null;
      }),
    confirmRecoveryKey: () =>
      attempt(() => {
        device.recoveryKeyConfirmed = true;
        return null;
      }),
    readsAsRecoveryKey: (entry) => Promise.resolve(entry.length > 0),
    recoverWithRecoveryKey: () => Promise.resolve({ rejected: true }),
    approveEnrollment: () => reject('enrollment-unavailable'),
    declineEnrollment: () => reject('enrollment-unavailable'),
    revokeTrustedDevice: () => reject('unavailable'),
  };
  return { vault, device, google, apple, backend };
}

export type SyntheticVault = ReturnType<typeof createSyntheticVault>;
