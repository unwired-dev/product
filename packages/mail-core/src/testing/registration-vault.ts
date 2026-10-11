/* oxlint-disable typescript/prefer-readonly-parameter-types -- Tests change the synthetic device's state between steps. */
import type { NativeRegistrationVault } from '../registration-flow.ts';
import type { MailProvider, SignInProvider } from '../registration.ts';
import type {
  Connection,
  Call,
  Identity,
  Presented,
  Receipt,
  SavedRecord,
} from './registration-vault-state.ts';

import { createSyntheticDevice } from './registration-device.ts';
import { admitSyntheticInstallation } from './registration-product-sync-backend.ts';
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

export { createSyntheticDevice } from './registration-device.ts';
export { RegistrationRecordSchema } from '../registration-vault.ts';
export type { MailboxDescriptor } from '../registration-vault.ts';

export {
  createSyntheticProductSyncBackend,
  mailboxRecord,
  removeTrustedDevice,
  storeDescriptor,
  storedDescriptor,
} from './registration-product-sync.ts';
export type { SyntheticProductSync } from './registration-product-sync.ts';

// An in-memory native vault with synthetic Google, Apple, Microsoft and Convex behavior, for the TypeScript
// registration flow. It keeps what native code keeps from TypeScript: credentials, tokens and
// provider subjects stay here, and every operation behaves as its native counterpart does.

const reject = (code: string): Promise<never> =>
  Promise.reject(Object.assign(new Error(`Synthetic ${code}`), { code }));
const opens = (
  record: Readonly<SavedRecord> | undefined,
  signedIn: Readonly<Identity>,
) =>
  record !== undefined &&
  record.provider === signedIn.provider &&
  record.subject === signedIn.subject;

// One process of the host over a synthetic device; a relaunch is another vault over the same one.
type SyntheticDevice = ReturnType<typeof createSyntheticDevice>;

// Microsoft mail and the controlled IMAP server are optional for journeys that share only the
// other providers.
export function createSyntheticVault(
  // Devices shared without Microsoft get their own.
  shared: Readonly<
    Omit<SyntheticDevice, 'microsoft' | 'imap'> &
      Partial<Pick<SyntheticDevice, 'microsoft' | 'imap'>>
  > = createSyntheticDevice(),
) {
  const { device, google, apple, backend } = shared;
  const microsoft = shared.microsoft ?? createSyntheticDevice().microsoft;
  const imap = shared.imap ?? createSyntheticDevice().imap;
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
          : provider === 'microsoft-graph' &&
            mailbox === 'casey@example.invalid'),
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
    const admitted = admitSyntheticInstallation(backend, account, installation);
    const sync = admitted?.sync;
    return {
      productAccountId: account,
      trustedDeviceId:
        admitted?.id ?? `synthetic-device-${(backend.devices += 1)}`,
      ...(backend.pendingDevices || admitted?.pending === true
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
  // The latest Product Sign-In, or else this process's verified one, becomes the session later
  // steps present; it must open the saved registration.
  const adoptIdentity = () => {
    const signedIn = live.identity ?? live.session;
    if (signedIn === undefined) {
      throw Object.assign(new Error('Synthetic'), {
        code: 'stale-authentication',
      });
    }
    if (!opens(load(), signedIn)) {
      throw Object.assign(new Error('Synthetic'), {
        code: 'invalid-identity',
      });
    }
    live.identity = signedIn;
    live.session = signedIn;
  };
  const syncAdapter = createSyntheticSyncVault(
    { ...shared, microsoft, imap },
    {
      saved,
      connectionId,
      newlyAuthorized,
      live,
      connect,
      adoptIdentity,
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
    'productAccount:isTrustedDeviceRevoked': ({ product }) => {
      if (backend.revocationOffline) {
        throw Object.assign(new Error('Synthetic failure'), {
          code: 'offline',
        });
      }
      const sync = backend.productSync;
      return success(
        backend.revoked ||
          sync?.revoked.has(product?.trustedDeviceId ?? '') === true,
      );
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

  // Adds a connection as native code does, observing the descriptors this device last read;
  // they are absent before it ever read them.
  const addConnection = (
    record: SavedRecord,
    connection: Pick<Connection, 'provider' | 'subject' | 'address'> &
      Partial<Pick<Connection, 'imap'>>,
  ) => {
    const { vault } = device.productSync;
    const sync = backend.productSync;
    const observedEpoch =
      vault === undefined || sync === undefined
        ? undefined
        : vault.descriptorEpochs?.[
            mailboxRecord(
              sync,
              vault.ring.id,
              `${connection.provider}:${connection.subject}`,
            )
          ];
    record.connections.push({
      ...connection,
      credential: 1,
      epoch: `synthetic-epoch-${(backend.epochs += 1)}`,
      ...(vault?.descriptorEpochs === undefined ? {} : { observed: true }),
      ...(observedEpoch === undefined ? {} : { observedEpoch }),
    });
  };
  // A login at the controlled IMAP server, which accepts only its current password.
  const loginImap = (password: string) => {
    imap.logins += 1;
    if (imap.outcome !== undefined) {
      throw Object.assign(new Error('Synthetic'), { code: imap.outcome });
    }
    if (password !== imap.password) {
      throw Object.assign(new Error('Synthetic'), { code: 'imap-refused' });
    }
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
              ...(connection.imap === undefined
                ? {}
                : {
                    imap: {
                      host: connection.imap.host,
                      port: connection.imap.port,
                      username: connection.imap.username,
                    },
                  }),
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
        // An IMAP password is never a provider grant.
        if (connection === undefined || connection.provider === 'imap') {
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
    connectImap: (setup) =>
      attempt(() => {
        const record = saved();
        if (record.product === undefined || record.product.pending === true) {
          throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
        }
        loginImap(setup.password);
        const host = setup.host.toLowerCase();
        const subject = `${host}:${setup.port}:${setup.username}`;
        const id = connectionId('imap', subject, setup.address);
        const existing = record.connections.find(
          (connection) =>
            connection.provider === 'imap' && connection.subject === subject,
        );
        const endpoint = {
          host,
          port: setup.port,
          username: setup.username,
          password: setup.password,
        };
        if (existing === undefined) {
          addConnection(record, {
            provider: 'imap',
            subject,
            address: setup.address,
            imap: endpoint,
          });
        } else {
          existing.imap = endpoint;
          existing.address = setup.address;
          delete existing.authorizationNeeded;
        }
        delete record.mailboxSetupReason;
        verified.add(id);
        cached.delete(id);
        newlyAuthorized.add(id);
        return { connection: id, address: setup.address };
      }),
    verifyImap: (id) =>
      attempt(() => {
        const connection = saved().connections.find(
          ({ provider, subject, address }) =>
            connectionId(provider, subject, address) === id,
        );
        if (connection?.imap === undefined) {
          throw Object.assign(new Error('Synthetic'), { code: 'unavailable' });
        }
        loginImap(connection.imap.password);
        delete connection.authorizationNeeded;
        verified.add(id);
        cached.delete(id);
        return null;
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
          addConnection(record, {
            provider: pending.provider,
            subject: pending.subject,
            address: pending.receipt.address,
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
        // An unanswered removal stays until it is settled.
        return (
          device.recoveryKeyConfirmed &&
          device.productSync.vault?.revocation?.submitted !== true
        );
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
        device.productSync.deviceKeyName = undefined;
        device.productSync.enrollment = undefined;
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
    adoptIdentity: () =>
      attempt(() => {
        adoptIdentity();
        return null;
      }),
  };
  return { vault: operations, device, google, microsoft, imap, apple, backend };
}

export type SyntheticVault = ReturnType<typeof createSyntheticVault>;
