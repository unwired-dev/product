/* oxlint-disable typescript/prefer-readonly-parameter-types -- Tests change the synthetic device's state between steps. */
import type { NativeRegistrationVault } from '../registration-flow.ts';
import type { MailProvider, SignInProvider } from '../registration.ts';
import type { SyntheticProductSync } from './registration-product-sync.ts';
import type {
  Call,
  Identity,
  Presented,
  Receipt,
  SavedRecord,
  SyncVault,
} from './registration-vault-state.ts';

import {
  createSyntheticSyncVault,
  mailboxRecord,
} from './registration-product-sync.ts';
import { syntheticMailboxes } from './registration-session.ts';
import {
  attempt,
  refusal,
  success,
  unavailable,
} from './registration-vault-state.ts';

export { RegistrationRecordSchema } from '../registration-vault.ts';
export type { MailboxDescriptor } from '../registration-vault.ts';

export {
  createSyntheticProductSyncBackend,
  mailboxRecord,
  storeDescriptor,
  storedDescriptor,
} from './registration-product-sync.ts';
export type { SyntheticProductSync } from './registration-product-sync.ts';

// An in-memory native vault with synthetic Google, Apple, Microsoft and Convex behavior, for the TypeScript
// registration flow. It keeps what native code keeps from TypeScript: credentials, tokens and
// provider subjects stay here, and every operation behaves as its native counterpart does.

const gmailScope = 'https://www.googleapis.com/auth/gmail.modify';

const reject = (code: string): Promise<never> =>
  Promise.reject(Object.assign(new Error(`Synthetic ${code}`), { code }));
const opens = (
  record: Readonly<SavedRecord> | undefined,
  signedIn: Readonly<Identity>,
) =>
  record !== undefined &&
  record.provider === signedIn.provider &&
  record.subject === signedIn.subject;

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
      enrollment: undefined as
        | { code: string; notice?: 'renewed' | 'rejected' }
        | undefined,
      unreadable: false,
      // Other devices' requests and Trusted Devices, as this process last listed them.
      requests: [] as Array<{ id: string; device: string; expiresAt: number }>,
      trustedDevices: [] as Array<{
        id: string;
        name: string;
        registeredAt: number;
      }>,
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
  return { device, google, microsoft, apple, backend };
}

// One process of the host over a synthetic device; a relaunch is another vault over the same one.
type SyntheticDevice = ReturnType<typeof createSyntheticDevice>;
export function createSyntheticVault(
  // Devices shared without Microsoft get their own.
  shared: Readonly<
    Omit<SyntheticDevice, 'microsoft'> &
      Partial<Pick<SyntheticDevice, 'microsoft'>>
  > = createSyntheticDevice(),
) {
  const { device, google, apple, backend } = shared;
  const microsoft = shared.microsoft ?? createSyntheticDevice().microsoft;
  // This process's latest sign-in, verified sign-in and Gmail live.authorization.
  const live = {
    identity: undefined as Identity | undefined,
    session: undefined as Identity | undefined,
    authorization: undefined as
      | {
          provider: MailProvider;
          subject: string;
          scopes: readonly string[];
          receipt?: { address: string };
        }
      | undefined,
  };
  const verified = new Set<string>();
  const cached = new Set<string>();
  // Connections explicit consent stored in this process, until synchronization ends.
  const newlyAuthorized = new Set<string>();

  // Opaque like native connection IDs; the known synthetic mailboxes keep their host IDs.
  const connectionId = (
    provider: MailProvider,
    subject: string,
    address: string,
  ) => {
    const known = Object.entries(syntheticMailboxes).find(
      ([mailbox]) =>
        mailbox === address &&
        (provider === 'gmail'
          ? mailbox !== 'casey@example.invalid'
          : mailbox === 'casey@example.invalid'),
    )?.[1];
    if (known !== undefined) {
      return known;
    }
    const id =
      device.connectionIds.get(`${provider}:${subject}`) ??
      `synthetic-connection-${device.connectionIds.size + 1}`;
    device.connectionIds.set(`${provider}:${subject}`, id);
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
  // With Product Sync, an installation of an account that holds keys waits for admission.
  const admission = (account: string, installation: string) => {
    const sync = backend.productSync;
    const keys = sync?.accounts.get(account);
    const admitted =
      keys === undefined ||
      keys.admitted.has(installation) ||
      (keys.admitted.size === 0 && keys.recovery === undefined);
    if (sync !== undefined && admitted && !backend.pendingDevices) {
      const entry = keys ?? { records: new Map(), admitted: new Set<string>() };
      entry.admitted.add(installation);
      sync.accounts.set(account, entry);
    }
    return { sync, admitted };
  };
  // fallow-ignore-next-line complexity -- Mirrors Convex's ownership, deletion and admission refusals.
  const connect = (
    signedIn: Readonly<Identity>,
    installation: string,
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
    const { sync, admitted } = admission(account, installation);
    return {
      productAccountId: account,
      trustedDeviceId: `synthetic-device-${(backend.devices += 1)}`,
      ...(backend.pendingDevices || !admitted
        ? { pending: true as const }
        : {}),
      signInProviders: [...(backend.linked.get(account) ?? [])],
      ...(sync === undefined || sync.legacyReceipts
        ? {}
        : {
            materialInitialized:
              sync.accounts.get(account)?.recovery !== undefined,
          }),
    };
  };

  const registered = () => {
    const record = saved();
    if (record.product === undefined) {
      throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
    }
    return record;
  };
  const presentedIdentity = (call: Call) =>
    call.identity === true ? latestIdentity() : undefined;
  const present = (call: Call): Presented => {
    if (call.path === 'productAccount:connect') {
      throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
    }
    if (call.session === true && live.session === undefined) {
      throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
    }
    return {
      call,
      product: call.device === true ? registered().product : undefined,
      signedIn: call.session === true ? live.session : presentedIdentity(call),
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
  const syncAdapter = createSyntheticSyncVault(
    { ...shared, microsoft },
    {
      saved,
      connectionId,
      newlyAuthorized,
      live,
      connect,
      verified,
      cached,
    },
  );

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
    ...syncAdapter.handlers,
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

  const operations: NativeRegistrationVault = {
    registration: () =>
      // fallow-ignore-next-line complexity -- Each optional field mirrors the native projection.
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
            const id = connectionId(
              connection.provider,
              connection.subject,
              connection.address,
            );
            return {
              id,
              provider: connection.provider,
              address: connection.address,
              ...(connection.epoch === undefined
                ? {}
                : { epoch: connection.epoch }),
              authorizationNeeded: connection.authorizationNeeded === true,
              access: accessOf(id),
            };
          }),
          mailboxRemovalPending: (record.removals?.length ?? 0) > 0,
          ...(backend.productSync === undefined || record.product === undefined
            ? {}
            : { productSync: syncAdapter.project(record) }),
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
        const next: SavedRecord = retained ?? {
          clientID: device.clientID,
          deviceIdentifier: `synthetic-installation-${(backend.installations += 1)}`,
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
        const product = connect(
          signedIn,
          record.deviceIdentifier,
          record.product,
        );
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
    ...syncAdapter.operations,
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
          ({ provider, subject, address }) =>
            connectionId(provider, subject, address) === id,
        );
        if (connection === undefined) {
          throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
        }
        const source = connection.provider === 'gmail' ? google : microsoft;
        if (source.refreshFailure !== undefined) {
          throw Object.assign(new Error('Synthetic'), {
            code: source.refreshFailure,
          });
        }
        live.authorization = {
          provider: connection.provider,
          subject: connection.subject,
          scopes: source.scopes,
        };
        return { scopes: source.scopes };
      }),
    signInMailbox: async (id, suggest, provider) => {
      const record = saved();
      const existing = record.connections.find(
        (connection) =>
          connectionId(
            connection.provider,
            connection.subject,
            connection.address,
          ) === id,
      );
      const source = provider === 'gmail' ? google : microsoft;
      // As native code hints: Gmail by Google account, Microsoft by the connection's address.
      source.hints.push(
        provider === 'gmail'
          ? (existing?.subject ??
              (suggest && record.provider === 'google'
                ? record.subject
                : undefined))
          : existing?.address,
      );
      if (source.outcome !== undefined) {
        return reject(source.outcome);
      }
      live.authorization = {
        provider,
        subject: source.subject,
        scopes: source.scopes,
      };
      return { scopes: source.scopes };
    },
    verifyMailbox: () =>
      attempt(() => {
        if (live.authorization === undefined) {
          throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
        }
        const gmail = live.authorization.provider === 'gmail';
        if (
          gmail
            ? !google.gmailAvailable ||
              google.refused.has(live.authorization.subject)
            : !microsoft.mailboxAvailable
        ) {
          // Native code reports any provider refusing the mailbox with this code.
          throw Object.assign(new Error('Synthetic'), {
            code: 'gmail-unavailable',
          });
        }
        const address = gmail
          ? (google.addresses[live.authorization.subject] ?? google.address)
          : microsoft.address;
        live.authorization.receipt = { address };
        return {
          connection: connectionId(
            live.authorization.provider,
            live.authorization.subject,
            address,
          ),
          address,
        };
      }),
    confirmMailbox: (id) =>
      attempt(() => {
        const record = saved();
        const receipt = live.authorization?.receipt;
        const connection = record.connections.find(
          ({ provider, subject, address }) =>
            connectionId(provider, subject, address) === id,
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
      // fallow-ignore-next-line complexity -- Mirrors native consent, repair and observation bookkeeping.
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
        const id = connectionId(
          pending.provider,
          pending.subject,
          pending.receipt.address,
        );
        // Native code keys a connection by its provider account.
        const existing = record.connections.find(
          (connection) =>
            connection.provider === pending.provider &&
            connection.subject === pending.subject,
        );
        if (existing === undefined) {
          // The descriptors this device last read; absent before it ever read them.
          const { vault } = device.productSync;
          const sync = backend.productSync;
          const observedEpoch =
            vault === undefined || sync === undefined
              ? undefined
              : vault.descriptorEpochs?.[
                  mailboxRecord(
                    sync,
                    vault.ring.id,
                    `${pending.provider}:${pending.subject}`,
                  )
                ];
          record.connections.push({
            provider: pending.provider,
            subject: pending.subject,
            address: pending.receipt.address,
            credential: 1,
            epoch: `synthetic-epoch-${(backend.epochs += 1)}`,
            ...(vault?.descriptorEpochs === undefined
              ? {}
              : { observed: true }),
            ...(observedEpoch === undefined ? {} : { observedEpoch }),
          });
        } else {
          existing.credential += 1;
          existing.address = pending.receipt.address;
          delete existing.authorizationNeeded;
        }
        delete record.mailboxSetupReason;
        verified.add(id);
        cached.delete(id);
        newlyAuthorized.add(id);
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
            ({ provider, subject, address }) =>
              connectionId(provider, subject, address) === id,
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
        device.productSync.vault = undefined;
        device.productSync.deviceKey = false;
        device.productSync.enrollment = undefined;
        device.productSync.requests = [];
        device.productSync.trustedDevices = [];
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
    routeMailboxes: () =>
      attempt(() => {
        backend.push.push('route');
        return null;
      }),
    stopMailboxWatches: () =>
      attempt(() => {
        backend.push.push('stop');
        return null;
      }),
    removeMailbox: (id) =>
      attempt(() => {
        const record = saved();
        const removed = record.connections.find(
          ({ provider, subject, address }) =>
            connectionId(provider, subject, address) === id,
        );
        if (removed === undefined) {
          throw unavailable();
        }
        record.connections = record.connections.filter(
          (connection) => connection !== removed,
        );
        // Its descriptor is then marked removed through Product Sync.
        if (backend.productSync !== undefined) {
          record.removals = [
            ...(record.removals ?? []).filter(
              ({ subject, provider }) =>
                subject !== removed.subject || provider !== removed.provider,
            ),
            {
              provider: removed.provider,
              subject: removed.subject,
              address: removed.address,
              ...(removed.epoch === undefined ? {} : { epoch: removed.epoch }),
            },
          ];
        }
        verified.delete(id);
        cached.delete(id);
        return null;
      }),
    confirmRecoveryKey: (entry) =>
      attempt(() => {
        const { vault } = device.productSync;
        if (backend.productSync !== undefined) {
          if (vault?.published !== true) {
            throw unavailable();
          }
          // The entry matches the end of the Recovery Key shown for setup.
          if (!vault.recoveryKeyConfirmed) {
            if (
              vault.recoveryKey === undefined ||
              entry.length === 0 ||
              !vault.recoveryKey.toLowerCase().endsWith(entry.toLowerCase())
            ) {
              throw Object.assign(new Error('Synthetic'), {
                code: 'recovery-key-mismatch',
              });
            }
            vault.recoveryKeyConfirmed = true;
          }
        }
        device.recoveryKeyConfirmed = true;
        return null;
      }),
    readsAsRecoveryKey: (entry) => Promise.resolve(entry.length > 0),
    recoverWithRecoveryKey: () => Promise.resolve({ rejected: true }),
    approveEnrollment: () => reject('enrollment-unavailable'),
    declineEnrollment: () => reject('enrollment-unavailable'),
    revokeTrustedDevice: () => reject('unavailable'),
    confirmRevocation: () => reject('unavailable'),
    cancelRevocation: () => reject('unavailable'),
  };
  return { vault: operations, device, google, microsoft, apple, backend };
}

export type SyntheticVault = ReturnType<typeof createSyntheticVault>;
