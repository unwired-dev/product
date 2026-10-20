import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type { ImapSetup } from './imap-setup.ts';
import type { RevocationReply } from './product-sync-devices.ts';
import type { ListedDevices } from './product-sync.ts';
import type { Code, RegistrationRejected } from './registration-rejection.ts';
import type {
  MailGrantProvider,
  RegistrationSnapshot,
  SignInProvider,
} from './registration-snapshot.ts';
import type {
  NativeRegistrationVault,
  RegistrationRecord,
  SetupReason,
} from './registration-vault.ts';

import { imapFallback } from './imap-setup.ts';
import {
  notifyingConnections,
  profileList,
  profileOwners,
} from './mail-profiles.ts';
import {
  createMailboxVerification,
  setupReason,
  suggestsSignIn,
  unavailableReason,
} from './mailbox-authorization.ts';
import { createProductSyncProgram, privateSyncState } from './product-sync.ts';
import {
  backendCode,
  backendCodes,
  endsAccess,
  failWith,
  nativeSteps,
  unreadable,
} from './registration-native.ts';
import { hostCodes, rejected } from './registration-rejection.ts';
import {
  Deletion,
  EnrollmentStatus,
  LinkRequest,
  LinkResponse,
  Unregistration,
} from './registration-replies.ts';
import {
  BackendReply,
  Identity,
  MailboxIdentity,
  MailboxReceipt,
} from './registration-vault.ts';

export { RegistrationRejected } from './registration-rejection.ts';
export type { NativeRegistrationVault } from './registration-vault.ts';

// What purging after each acknowledged removal tells the person.
const removalNotices = {
  deletion: 'deleted',
  signOut: 'signed-out',
  revoked: 'revoked',
} as const;

const ErrorBody = Schema.fromJsonString(Schema.Struct({ code: Schema.String }));
const decodeErrorBody = Schema.decodeUnknownOption(ErrorBody);

// A settled removal reports "removed" only while its Recovery Key belongs to the epoch this device
// holds after synchronizing, which may adopt a later rotation. Unreadable state reports nothing.
const settledNotice = (
  value: RegistrationRecord,
  settlement: NonNullable<RevocationReply['settlement']>,
) => {
  const sync =
    value.productSync === 'unreadable' ? undefined : value.productSync;
  const epoch =
    sync?.vault?.keyEpoch ??
    (sync?.pending === true ? settlement.settledEpoch : undefined);
  if (epoch === undefined) {
    return undefined;
  }
  return settlement.recoveryKeyCurrent && settlement.keyEpoch === epoch
    ? ('removed' as const)
    : ('superseded' as const);
};
const sameIdentity = (value: Readonly<{ matches: boolean }>) =>
  value.matches ? Effect.void : failWith('invalid-identity');
// Deletion refusals Convex returns before fencing anything.
const refusals: ReadonlySet<Code> = new Set([
  'stale-authentication',
  'removal-refused',
  'apple-authorization-required',
  'pending-device-unavailable',
]);
// Why an IMAP connection could not be added, as the setup reason a relaunch resumes with.
const imapSetupReasons: Partial<Record<Code, SetupReason>> = {
  'imap-refused': 'imap-refused',
  'imap-insecure': 'imap-insecure',
  'smtp-refused': 'smtp-refused',
  'smtp-insecure': 'smtp-insecure',
};

const mailboxState = (mailbox: RegistrationRecord['mailboxes'][number]) => {
  if (mailbox.authorizationNeeded) {
    return 'authorization' as const;
  }
  return mailbox.access === 'cached'
    ? ('cached' as const)
    : ('connected' as const);
};
// JSON text listing this device's connections in the order they were added. A connection listed
// without a Profile belongs to the Default Profile.
const mailboxList = (value: RegistrationRecord) => {
  if (value.product?.pending === true || value.mailboxes.length === 0) {
    return undefined;
  }
  const owners = profileOwners(value);
  const notifying = notifyingConnections(value);
  return JSON.stringify(
    value.mailboxes.map((mailbox) => {
      const profile = owners.get(mailbox.id);
      return {
        provider: mailbox.provider,
        address: mailbox.address,
        ...(mailbox.epoch === undefined ? {} : { epoch: mailbox.epoch }),
        id: mailbox.id,
        ...(mailbox.imap === undefined ? {} : { imap: mailbox.imap }),
        ...(mailbox.smtp === undefined ? {} : { smtp: mailbox.smtp }),
        state: mailboxState(mailbox),
        ...(profile === undefined ? {} : { profile }),
        ...(notifying.has(mailbox.id) ? { notifications: true } : {}),
      };
    }),
  );
};
const account = (
  value: RegistrationRecord,
  listed: ListedDevices | undefined,
) => {
  const { product } = value;
  if (product === undefined) {
    return Effect.fail(rejected('unavailable'));
  }
  const alternate = product.signInProviders?.find(
    (provider) => provider !== value.signInProvider,
  );
  const profiles = profileList(value);
  return Effect.succeed({
    productAccountId: product.productAccountId,
    signInProvider: value.signInProvider,
    ...(value.contactEmail === undefined || value.contactEmail === ''
      ? {}
      : { contactEmail: value.contactEmail }),
    ...(alternate === undefined ? {} : { alternateSignIn: alternate }),
    ...privateSyncState(value, listed),
    ...(value.mailboxRemovalPending
      ? { privateSyncPending: 'mailbox' as const }
      : {}),
    ...(profiles === undefined ? {} : { profiles }),
  });
};
const pending = Effect.fnUntraced(function* (
  value: RegistrationRecord,
  listed: ListedDevices | undefined,
) {
  const fields = yield* account(value, listed);
  // A device the account has not admitted shows only its enrollment gate.
  if (value.product?.pending === true) {
    return { kind: 'device-pending', ...fields } satisfies RegistrationSnapshot;
  }
  // Saved mailboxes that all need authorization again read as the first one's provider being
  // unavailable.
  const [first] = value.mailboxes;
  const reason =
    value.mailboxSetupReason ??
    (first === undefined ? undefined : unavailableReason(first.provider));
  // Without a verified Product Account no connection's state is known, so none is listed.
  const mailboxes =
    reason === 'unavailable' || reason === 'interrupted'
      ? undefined
      : mailboxList(value);
  return {
    kind: 'mailbox-needed',
    ...fields,
    ...(reason === undefined ? {} : { reason }),
    ...(mailboxes === undefined ? {} : { mailboxes }),
  } satisfies RegistrationSnapshot;
});
// Connected while any mailbox verified or saw no failure, saved-Inbox-only while every usable one
// is open from its cache, and otherwise waiting for a mailbox.
const status = Effect.fnUntraced(function* (
  value: RegistrationRecord,
  listed: ListedDevices | undefined,
) {
  const states = value.mailboxes
    .filter((mailbox) => !mailbox.authorizationNeeded)
    .map(mailboxState);
  const mailboxes = mailboxList(value);
  if (
    value.product?.pending === true ||
    states.length === 0 ||
    mailboxes === undefined
  ) {
    return yield* pending(value, listed);
  }
  const fields = yield* account(value, listed);
  return {
    kind: states.includes('connected') ? 'connected' : 'cached',
    ...fields,
    mailboxes,
  } satisfies RegistrationSnapshot;
});

export function createRegistrationFlow(vault: NativeRegistrationVault) {
  const { native, step, record, saved, convex } = nativeSteps(vault);
  const productSyncFlow = createProductSyncProgram(vault);
  const { synchronize, listedFor } = productSyncFlow;

  const current = saved.pipe(
    Effect.flatMap((value) => status(value, listedFor(value))),
  );
  const pendingStatus = (value: RegistrationRecord) =>
    pending(value, listedFor(value));
  const failure = (reason: SetupReason) =>
    step(() => vault.recordMailboxSetup(reason)).pipe(
      Effect.andThen(saved),
      Effect.flatMap(pendingStatus),
    );

  const purge = (notice: 'revoked' | 'deleted' | 'signed-out') =>
    productSyncFlow.forgetDevices.pipe(
      Effect.andThen(step(() => vault.purge(notice))),
      Effect.as<RegistrationSnapshot>(
        notice === 'signed-out'
          ? { kind: 'signed-out' }
          : { kind: 'signed-out', notice },
      ),
    );

  // An unanswered request must not reconnect a device that may already have unregistered.
  // Acknowledged cleanup resumes without any provider credential or interactive prompt.
  const removalStatus = Effect.fnUntraced(function* (
    value: RegistrationRecord,
  ) {
    const { removal, product } = value;
    if (removal === undefined) {
      return undefined;
    }
    if (removal.acknowledged) {
      return yield* purge(removalNotices[removal.operation]);
    }
    yield* step(vault.endSession);
    yield* productSyncFlow.forgetDevices;
    if (product === undefined) {
      return yield* failWith('unavailable');
    }
    return {
      kind: 'mailbox-needed',
      productAccountId: product.productAccountId,
      signInProvider: value.signInProvider,
      reason: 'unavailable',
      privateSync: 'unavailable',
      removalPending: removal.operation === 'signOut' ? 'sign-out' : 'deletion',
    } satisfies RegistrationSnapshot;
  });

  const identity = (provider: SignInProvider, hint: boolean) =>
    native(() => vault.signInIdentity(provider, hint), Identity);
  // A fresh interactive sign-in of this registration's own identity.
  const renewSignIn = saved.pipe(
    Effect.flatMap((value) =>
      identity(value.signInProvider, value.signInProvider === 'google'),
    ),
    Effect.flatMap(sameIdentity),
  );
  // A removal step's notice, shown with the status the step leaves.
  const noticed = (
    operation: Effect.Effect<RevocationReply, RegistrationRejected>,
  ) =>
    Effect.gen(function* () {
      const reply = yield* operation;
      if (reply.synchronize === true) {
        yield* synchronize;
      }
      const snapshot = yield* current;
      const notice =
        reply.settlement === undefined
          ? reply.notice
          : (settledNotice(yield* saved, reply.settlement) ?? reply.notice);
      return notice === undefined
        ? snapshot
        : { ...snapshot, revocationNotice: notice };
    });
  // Saves the latest matching sign-in even if the backend is interrupted, then connects it.
  const establish = (replacing = false) =>
    step(() => vault.saveIdentity(replacing)).pipe(
      Effect.andThen(step(() => vault.connect('establish'))),
      Effect.andThen(synchronize),
    );

  // Confirms the retained Product Sign-In without an interactive session.
  const reconfirm = Effect.fnUntraced(function* (value: RegistrationRecord) {
    if (value.signInProvider === 'google') {
      yield* sameIdentity(yield* native(vault.renewIdentity, Identity));
      return yield* establish();
    }
    // Native Sign in with Apple cannot renew an identity token silently; check the grant instead.
    if (value.product === undefined) {
      return yield* failWith('unavailable');
    }
    const state = yield* native(
      vault.appleCredentialState,
      Schema.Literals(['authorized', 'revoked', 'unavailable']),
    );
    if (state !== 'authorized') {
      return yield* failWith('unavailable');
    }
  });

  // Push wakes are an opportunity: routing waits for a later verification unless access ended.
  const pushStep = (operation: () => Promise<unknown>) =>
    step(operation).pipe(
      Effect.catchIf(
        (error) => !endsAccess.has(error.code),
        () => Effect.void,
      ),
    );

  const { checkedMailbox, verify } = createMailboxVerification(vault);

  // Reports each retained connection as connected only after its provider access verifies again,
  // including one its provider refused before. One connection's failure never changes another's
  // state.
  const mailboxStatus = Effect.gen(function* () {
    const value = yield* saved;
    if (value.product?.pending === true || value.mailboxes.length === 0) {
      return yield* pendingStatus(value);
    }
    for (const mailbox of value.mailboxes) {
      yield* verify(mailbox);
    }
    const verified = (yield* saved).mailboxes.some(
      (mailbox) =>
        !mailbox.authorizationNeeded && mailbox.access === 'verified',
    );
    if (verified) {
      yield* synchronize;
      yield* pushStep(vault.routeMailboxes);
    }
    return yield* current;
  });

  // Every usable connection opens from its cache only, until registration verifies again.
  const cachedMailbox = Effect.fnUntraced(function* (
    value: RegistrationRecord,
  ) {
    const usable = value.mailboxes.filter(
      (mailbox) => !mailbox.authorizationNeeded,
    );
    if (
      value.product === undefined ||
      value.removal !== undefined ||
      usable.length === 0
    ) {
      return undefined;
    }
    for (const mailbox of usable) {
      yield* step(() => vault.markMailbox(mailbox.id, 'cached'));
    }
    return yield* current;
  });

  const restore = Effect.gen(function* () {
    yield* step(vault.forgetMailboxAccess);
    const retained = yield* record;
    if (retained === null) {
      return { kind: 'signed-out' } satisfies RegistrationSnapshot;
    }
    const removal = yield* removalStatus(retained);
    if (removal !== undefined) {
      return removal;
    }
    yield* step(vault.retryMailboxCleanup);
    const value = yield* saved;
    // Apple Product Sign-In finishes interactively; an uncommitted one starts again.
    if (value.signInProvider === 'apple' && value.product === undefined) {
      return { kind: 'signed-out' } satisfies RegistrationSnapshot;
    }
    const unconfirmed = yield* reconfirm(value).pipe(
      Effect.as(undefined),
      Effect.catchIf(
        (error) => !endsAccess.has(error.code),
        (error) =>
          Effect.gen(function* () {
            // Keep any identity credential the flow saved before the backend failed.
            const latest =
              (yield* record.pipe(Effect.orElseSucceed(() => null))) ?? value;
            const cached =
              error.code === 'offline'
                ? yield* cachedMailbox(latest)
                : undefined;
            if (cached !== undefined) {
              return cached;
            }
            if (value.product !== undefined) {
              return yield* failure('unavailable');
            }
            return yield* error;
          }),
      ),
    );
    return unconfirmed ?? (yield* mailboxStatus);
  });

  // Moves this device to a Linked Sign-In once the backend confirms it opens the same account.
  // The linked identity is chosen explicitly; no mailbox or contact address hints it.
  const switchSignIn = (provider: SignInProvider) =>
    identity(provider, false).pipe(
      Effect.andThen(step(() => vault.connect('switch'))),
      Effect.andThen(synchronize),
    );

  const signIn = Effect.fnUntraced(function* (provider: SignInProvider) {
    const value = yield* record;
    // Explicit linking is required before another provider can reach a committed Product Account.
    // The backend decides: the cached provider list may predate a link made on another device.
    if (value?.product !== undefined && value.signInProvider !== provider) {
      // Switching sign-ins keeps the mailbox; recheck it rather than restarting Gmail consent.
      yield* switchSignIn(provider);
      return yield* mailboxStatus;
    }
    const signedIn = yield* identity(
      provider,
      value?.signInProvider === 'google',
    );
    // Only a sign-in that never received a Product Account may be replaced by another identity.
    yield* establish(
      value === null || (value.product === undefined && !signedIn.matches),
    );
    // Signing in again keeps a saved mailbox; recheck it rather than restarting Gmail consent.
    return yield* mailboxStatus;
  });

  // Verifies the current Product Account and then the identity being linked, both interactively.
  const link = Effect.fnUntraced(function* (other: SignInProvider) {
    const value = yield* saved;
    const { product } = value;
    if (product === undefined) {
      return yield* failWith('unavailable');
    }
    if (other === value.signInProvider) {
      return yield* failWith('invalid-identity');
    }
    yield* sameIdentity(
      yield* identity(value.signInProvider, value.signInProvider === 'google'),
    );
    const request = yield* convex(
      {
        endpoint: 'action',
        path: '/sign-in-links/request',
        args: { provider: other },
        identity: true,
        device: true,
      },
      LinkRequest,
    );
    let providers = request.signInProviders;
    if (request.linkTicket !== undefined) {
      // Nothing is stored until the backend commits the link; an interruption changes nothing.
      yield* identity(other, false);
      const completed = yield* convex(
        {
          endpoint: 'action',
          path: '/sign-in-links/complete',
          args: { linkTicket: request.linkTicket },
          identity: true,
          device: true,
        },
        LinkResponse,
      );
      if (completed.productAccountId !== product.productAccountId) {
        return yield* failWith('invalid-identity');
      }
      providers = completed.signInProviders;
    }
    yield* step(() => vault.saveSignInProviders(providers));
    return yield* current;
  });

  // Why the retained Product Sign-In did not verify before a mailbox is set up, or undefined once
  // it does; one that cannot keeps the Product Account and resumable mailbox setup.
  const signInRefusal = (value: RegistrationRecord) =>
    reconfirm(value).pipe(
      Effect.as(undefined),
      Effect.catchIf(
        (error) => !endsAccess.has(error.code),
        ({ code }) => Effect.succeed(code),
      ),
    );
  // An unconfirmed sign-in records why mailbox setup paused. Offline with other usable mailboxes,
  // adding another reports the failure and changes nothing, so their Inboxes stay open.
  const unconfirmed = (
    value: RegistrationRecord,
    code: Code,
    keepsMailboxes: boolean,
  ) =>
    code === 'offline' && keepsMailboxes
      ? failWith('offline')
      : failure(
          value.signInProvider === 'apple' ? 'unavailable' : 'interrupted',
        );

  // Authorizes the named connection's provider again, or adds a mailbox of `added` when none is
  // named. Adding a mailbox that is already connected repairs that connection instead of
  // duplicating it. The first Gmail mailbox suggests the Google sign-in unless the person chooses
  // another account.
  const authorizeMailbox = Effect.fnUntraced(function* (
    connection: string | null,
    added: MailGrantProvider,
    chooseAccount: boolean,
  ) {
    const value = yield* saved;
    // Mailbox authorization follows admission; a Pending Device holds no mailbox.
    if (value.product === undefined || value.product.pending) {
      return yield* failWith('unavailable');
    }
    const existing = value.mailboxes.find(({ id }) => id === connection);
    // A connection removed meanwhile is not added back by reauthorizing it.
    if (connection !== null && existing === undefined) {
      return yield* failWith('unavailable');
    }
    const provider = existing?.provider ?? added;
    // An IMAP password is entered again in its own setup, never through a provider's sign-in.
    if (provider === 'imap') {
      return yield* failWith('unavailable');
    }
    // A failure leaves other usable mailboxes as they are; the host reports it.
    const keepsMailboxes = value.mailboxes.some(
      ({ id, authorizationNeeded }) =>
        !authorizationNeeded && id !== connection,
    );
    // Confirm the retained Product Sign-In independently of the mailbox selection.
    const refusal = yield* signInRefusal(value);
    if (refusal !== undefined) {
      return yield* unconfirmed(value, refusal, keepsMailboxes);
    }
    const suggest = suggestsSignIn(value, provider, chooseAccount);
    return yield* Effect.gen(function* () {
      const { scopes } = yield* native(
        () => vault.signInMailbox(connection, suggest, provider),
        MailboxIdentity,
      );
      const receipt = yield* checkedMailbox(provider, scopes);
      // Reauthorization repairs this connection; another account is added separately.
      if (existing !== undefined && existing.id !== receipt.connection) {
        return yield* failWith('gmail-unavailable');
      }
      yield* step(vault.retryMailboxCleanup);
      yield* step(vault.storeMailbox);
      yield* synchronize;
      yield* pushStep(vault.routeMailboxes);
      return yield* current;
    }).pipe(
      Effect.catchIf(
        (error) => !endsAccess.has(error.code) && !keepsMailboxes,
        ({ code }) => failure(setupReason(provider, code)),
      ),
    );
  });

  // Connects an IMAP mailbox after its login verifies, or repairs the connection for the same
  // account. Choosing IMAP never starts Gmail authorization. A failed first mailbox keeps the
  // Product Account and records why, so setup resumes after relaunch; with other usable mailboxes
  // the failure is reported and nothing changes.
  const connectImap = Effect.fnUntraced(function* (setup: ImapSetup) {
    const value = yield* saved;
    // Mailbox setup follows admission; a Pending Device holds no mailbox.
    if (value.product === undefined || value.product.pending) {
      return yield* failWith('unavailable');
    }
    const keepsMailboxes = value.mailboxes.some(
      ({ authorizationNeeded }) => !authorizationNeeded,
    );
    const refusal = yield* signInRefusal(value);
    if (refusal !== undefined) {
      return yield* unconfirmed(value, refusal, keepsMailboxes);
    }
    const fallback = imapFallback(setup);
    return yield* Effect.gen(function* () {
      const receipt = yield* native(
        () => vault.connectImap(setup),
        MailboxReceipt,
      ).pipe(
        Effect.catchIf(
          (error) => error.code === 'imap-refused' && fallback !== undefined,
          () =>
            native(() => vault.connectImap(fallback ?? setup), MailboxReceipt),
        ),
      );
      yield* step(vault.retryMailboxCleanup);
      yield* synchronize;
      return { ...(yield* current), imapConnected: receipt.connection };
    }).pipe(
      Effect.catchIf(
        (error) => !endsAccess.has(error.code) && !keepsMailboxes,
        ({ code }) => failure(imapSetupReasons[code] ?? 'imap-offline'),
      ),
    );
  });

  const requestedRemoval = Effect.fnUntraced(function* (
    value: RegistrationRecord,
    operation: 'signOut' | 'deletion',
  ) {
    if (value.removal?.acknowledged === true) {
      return (
        (yield* removalStatus(value)) ??
        ({ kind: 'signed-out' } satisfies RegistrationSnapshot)
      );
    }
    if (value.removal !== undefined && value.removal.operation !== operation) {
      return yield* failWith('unavailable');
    }
    return undefined;
  });

  // Sign-out adopts the latest key epoch first, which settles an unanswered removal.
  const adoptBeforeSignOut = (value: RegistrationRecord) =>
    value.productSync !== undefined &&
    value.productSync !== 'unreadable' &&
    value.productSync.vault?.published === true
      ? step(vault.adoptIdentity).pipe(
          Effect.andThen(productSyncFlow.adoptRotation),
        )
      : Effect.void;

  // Convex forgets this Trusted Device and its push routes first; then the device keeps nothing of
  // the Product Account. Cancelled authentication changes nothing; unanswered backend work is
  // retained for retry and cannot silently reconnect this device.
  const signOut = Effect.gen(function* () {
    const value = yield* saved;
    const completed = yield* requestedRemoval(value, 'signOut');
    if (completed !== undefined) {
      return completed;
    }
    const { product } = value;
    if (product !== undefined) {
      // Google renews silently; Sign in with Apple cannot, so it asks again.
      yield* sameIdentity(
        yield* value.signInProvider === 'google'
          ? native(vault.renewIdentity, Identity)
          : identity('apple', false),
      );
      // A Pending Device holds no published keys or Recovery Key of its own to protect.
      if (value.removal === undefined && !product.pending) {
        yield* adoptBeforeSignOut(value);
        // Never discard a published or unanswered Recovery Key the person has not backed up.
        const ready = yield* native(vault.prepareSignOut, Schema.Boolean);
        if (!ready) {
          return yield* current;
        }
      }
      // The backend removes this device's routes; watches no other device needs stop first. A
      // Pending Device holds no mailbox to stop.
      yield* pushStep(vault.stopMailboxWatches);
      yield* step(() => vault.recordRemoval('signOut'));
      yield* convex(
        {
          endpoint: 'mutation',
          path: product.pending
            ? 'productAccount:unregisterPendingDevice'
            : 'productAccount:unregisterTrustedDevice',
          args: {},
          identity: true,
          device: true,
          installation: true,
        },
        Unregistration,
      );
    }
    return yield* purge('signed-out');
  });

  // Refusals arrive as HTTP statuses; a 403 names its Convex code.
  const deletion = Effect.gen(function* () {
    const reply = yield* native(
      () =>
        vault.call({
          endpoint: 'action',
          path: '/product-account/delete',
          args: {},
          // The fresh token is the recent-authentication proof.
          identity: true,
          device: true,
          appleAuthorization: true,
        }),
      BackendReply,
    );
    const refusal = Option.getOrUndefined(decodeErrorBody(reply.body))?.code;
    switch (reply.status) {
      // Complete, or continuing on the backend; the account is fenced either way.
      case 200: {
        yield* Schema.decodeEffect(Schema.fromJsonString(Deletion))(
          reply.body,
        ).pipe(Effect.catch(unreadable));
        return;
      }
      case 401: {
        return yield* failWith('stale-authentication');
      }
      // Refusals Convex returns before fencing the account.
      case 400: {
        return yield* failWith('removal-refused');
      }
      case 403: {
        return yield* failWith(
          refusal !== undefined && Object.hasOwn(backendCodes, refusal)
            ? backendCode(refusal)
            : 'removal-refused',
        );
      }
      case 409: {
        return yield* failWith('apple-authorization-required');
      }
      // Repeating the deletion after a lost reply reports it as complete.
      default: {
        return yield* failWith('unavailable');
      }
    }
  });

  // Permanently deletes the Product Account after a fresh interactive Product Sign-In. An account
  // that Sign in with Apple opens is deleted through Apple, so Convex can revoke that authorization.
  // Convex decides whether the identity opens this account; an unanswered request stays pending
  // here, and repeating the deletion after a lost reply reports it as complete.
  const deleteAccount = Effect.gen(function* () {
    const value = yield* saved;
    const { product } = value;
    if (product === undefined) {
      return yield* failWith('unavailable');
    }
    const completed = yield* requestedRemoval(value, 'deletion');
    if (completed !== undefined) {
      return completed;
    }
    const provider =
      value.signInProvider === 'apple' ||
      product.signInProviders?.includes('apple') === true
        ? 'apple'
        : 'google';
    const signedIn = yield* identity(
      provider,
      value.signInProvider === 'google',
    );
    // Another identity of the same provider cannot open this account; Convex would refuse it.
    if (provider === value.signInProvider) {
      yield* sameIdentity(signedIn);
    }
    // An expired Pending Device may have been cleaned up. Renew its proof before recording
    // deletion intent; a retry of an unanswered deletion must not reconnect the account.
    if (value.removal === undefined && product.pending) {
      const needsProof = yield* convex(
        {
          endpoint: 'mutation',
          path: 'productSyncEnrollment:status',
          args: {},
          identity: true,
          device: true,
        },
        EnrollmentStatus,
      ).pipe(
        Effect.as(false),
        Effect.catchIf(
          ({ code }) => code === 'pending-device-unavailable',
          () => Effect.succeed(true),
        ),
      );
      if (needsProof) {
        yield* step(() => vault.connect('renew'));
      }
    }
    const wasPending = value.removal !== undefined;
    yield* pushStep(vault.stopMailboxWatches);
    yield* step(() => vault.recordRemoval('deletion'));
    yield* deletion.pipe(
      // This attempt was refused before fencing anything. A refusal cannot settle an earlier
      // unanswered deletion; keep its intent and report uncertainty until cleanup is acknowledged.
      Effect.catchIf(
        ({ code }) => refusals.has(code),
        (error) =>
          Effect.gen(function* () {
            if (!wasPending) {
              yield* step(() => vault.recordRemoval(null));
            }
            if (error.code === 'apple-authorization-required') {
              const providers = product.signInProviders ?? [
                value.signInProvider,
              ];
              yield* step(() =>
                vault.saveSignInProviders(
                  providers.includes('apple')
                    ? providers
                    : [...providers, 'apple'],
                ),
              );
            }
            return yield* failWith(wasPending ? 'unavailable' : error.code);
          }),
      ),
    );
    return yield* purge('deleted');
  });
  // Whether the account revoked this device, answered for its credential without a Product Sign-In.
  // Offline, the check is skipped and the saved account stays usable. Convex only revokes Trusted
  // Devices, so a Pending Device is never asked.
  const requireNotRevoked = (value: RegistrationRecord) =>
    value.product === undefined || value.product.pending
      ? Effect.void
      : convex(
          {
            endpoint: 'query',
            path: 'productAccount:isTrustedDeviceRevoked',
            args: { productAccountId: value.product.productAccountId },
            device: true,
          },
          Schema.Boolean,
        ).pipe(
          Effect.orElseSucceed(() => false),
          Effect.flatMap((revoked) =>
            revoked ? failWith('revoked') : Effect.void,
          ),
        );

  // Every operation runs through this, so whichever request learns of a revocation purges. A saved
  // account is checked first: an operation may open a provider prompt before any backend request,
  // and cancelling that prompt must not keep a removed device's keys and credentials.
  const guarded = (
    operation: Effect.Effect<RegistrationSnapshot, RegistrationRejected>,
    removing?: 'signOut' | 'deletion',
  ) =>
    Effect.gen(function* () {
      // An unreadable record skips the check; the operation reports that failure itself.
      const value = yield* record.pipe(
        Effect.catchIf(
          (error) => !endsAccess.has(error.code),
          () => Effect.succeed(null),
        ),
      );
      if (
        value?.removal !== undefined &&
        (value.removal.acknowledged || value.removal.operation !== removing)
      ) {
        const removal = yield* removalStatus(value);
        if (removal !== undefined) {
          return removal;
        }
      }
      if (value !== null) {
        yield* requireNotRevoked(value);
      }
      return yield* operation;
    }).pipe(
      Effect.catchIf(
        ({ code }) => code === 'revoked' || code === 'deleted',
        ({ code }) => purge(code === 'revoked' ? 'revoked' : 'deleted'),
      ),
    );

  // Hosts keep their fixed rejection codes; the flow's own distinctions map onto them.
  const program = (
    operation: Effect.Effect<RegistrationSnapshot, RegistrationRejected>,
    removing?: 'signOut' | 'deletion',
  ) =>
    guarded(operation, removing).pipe(
      Effect.mapError((rejection) => {
        const code = hostCodes[rejection.code];
        return code === undefined ? rejection : rejected(code, rejection);
      }),
    );

  const thenStatus = (operation: () => Promise<unknown>) =>
    step(operation).pipe(Effect.andThen(current));

  return {
    restore: () => program(restore),
    signIn: (provider: SignInProvider) => program(signIn(provider)),
    // Adds a mailbox of the provider; the first Gmail one suggests the Google sign-in unless
    // `chooseAccount`. Adding a mailbox that is already connected authorizes it again instead.
    addMailbox: (provider: MailGrantProvider, chooseAccount: boolean) =>
      program(authorizeMailbox(null, provider, chooseAccount)),
    // Authorizes one Mailbox Connection's provider again, with the same account.
    authorizeMailbox: (connection: string) =>
      program(authorizeMailbox(connection, 'gmail', false)),
    // Connects an IMAP mailbox at a reviewed endpoint, or repairs the connection for its account.
    connectImap: (setup: ImapSetup) => program(connectImap(setup)),
    // The removal then reaches Product Sync and every Trusted Device.
    removeMailbox: (connection: string) =>
      program(
        step(() => vault.removeMailbox(connection)).pipe(
          Effect.andThen(synchronize),
          Effect.andThen(current),
        ),
      ),
    // A Profile is named on this device first and published when Product Sync is reachable.
    createProfile: (name: string) =>
      program(
        productSyncFlow
          .createProfile(name)
          .pipe(Effect.andThen(synchronize), Effect.andThen(current)),
      ),
    renameProfile: (id: string, name: string) =>
      program(
        productSyncFlow
          .renameProfile(id, name)
          .pipe(Effect.andThen(synchronize), Effect.andThen(current)),
      ),
    // Removing a Profile and moving a connection need Product Sync.
    removeProfile: (id: string) =>
      program(productSyncFlow.removeProfile(id).pipe(Effect.andThen(current))),
    moveMailbox: (connection: string, profile: string) =>
      program(
        saved.pipe(
          Effect.flatMap((value) =>
            productSyncFlow.moveMailbox(value, connection, profile),
          ),
          Effect.andThen(current),
        ),
      ),
    // Turning a connection's New Mail Notifications on or off needs Product Sync.
    notifyMailbox: (connection: string, enabled: boolean) =>
      program(
        saved.pipe(
          Effect.flatMap((value) =>
            productSyncFlow.notifyMailbox(value, connection, enabled),
          ),
          Effect.andThen(current),
        ),
      ),
    // Verifies the current Product Account and the identity being linked, interactively.
    link: (provider: SignInProvider) => program(link(provider)),
    // Confirms Recovery Key setup with the final group the person wrote down.
    confirmRecoveryKey: (entry: string) =>
      program(thenStatus(() => vault.confirmRecoveryKey(entry))),
    // Unlocks this device's private data with the Recovery Key when no trusted device can.
    recoverWithRecoveryKey: (entry: string) =>
      program(
        Effect.gen(function* () {
          const value = yield* saved;
          if (value.product === undefined) {
            return yield* failWith('unavailable');
          }
          // A malformed key is rejected before any sign-in renewal.
          const readable = yield* native(
            () => vault.readsAsRecoveryKey(entry),
            Schema.Boolean,
          );
          if (readable) {
            // Refresh authentication for every attempt, including a form left open beyond token
            // expiry. Google renews silently; Apple cannot refresh without interactive sign-in.
            yield* value.signInProvider === 'google'
              ? reconfirm(value)
              : signIn('apple');
          }
          const refused = readable
            ? yield* productSyncFlow.recover(entry)
            : true;
          // Unlocked keys then initialize, admit and read back through Product Sync.
          if (!refused) {
            yield* synchronize;
          }
          const snapshot = yield* current;
          return refused
            ? { ...snapshot, recoveryNotice: 'rejected' as const }
            : snapshot;
        }),
      ),
    // Seals this device's keys to another device, unlocked by the code that device shows.
    approveEnrollment: (requestId: string, code: string) =>
      program(
        productSyncFlow
          .approveEnrollment(requestId, code)
          .pipe(Effect.andThen(current)),
      ),
    declineEnrollment: (requestId: string) =>
      program(
        productSyncFlow
          .declineEnrollment(requestId)
          .pipe(Effect.andThen(current)),
      ),
    // Prepares the removal of another Trusted Device after a fresh interactive Product Sign-In.
    revokeTrustedDevice: (trustedDeviceId: string) =>
      program(
        renewSignIn.pipe(
          Effect.andThen(noticed(productSyncFlow.revoke(trustedDeviceId))),
        ),
      ),
    // Activation needs a recent sign-in; one that aged while the key was saved is renewed once.
    confirmRevocation: (entry: string) =>
      program(
        noticed(productSyncFlow.confirmRevocation(entry)).pipe(
          Effect.catchIf(
            ({ code }) => code === 'stale-authentication',
            () =>
              renewSignIn.pipe(
                Effect.andThen(
                  noticed(productSyncFlow.confirmRevocation(entry)),
                ),
              ),
          ),
        ),
      ),
    // Discards an unsent proposal; an unanswered activation must be reconciled first.
    cancelRevocation: () => program(noticed(productSyncFlow.cancelRevocation)),
    // Checks for an approval of this device, or for another device waiting for one.
    refreshPrivateSync: () =>
      program(
        Effect.gen(function* () {
          const value = yield* saved;
          if (value.product === undefined) {
            return yield* failWith('unavailable');
          }
          // Google renews its Product Sign-In silently.
          if (value.signInProvider === 'google') {
            yield* reconfirm(value);
            return yield* current;
          }
          // Apple cannot renew silently; without this process's sign-in it asks interactively.
          if (!value.session) {
            return yield* signIn('apple');
          }
          // A Pending Device reconnects, which renews a record that ended with its Enrollment Code.
          if (value.product.pending) {
            yield* step(vault.reuseSession);
            yield* establish();
          } else {
            yield* synchronize;
          }
          return yield* current;
        }),
      ),
    // Adopts the newest key epoch after a removal refused a Product Sync write, so the next write is
    // sealed at it.
    adoptKeyRotation: () =>
      program(
        Effect.gen(function* () {
          const value = yield* saved;
          const sync = value.productSync;
          // Only a Trusted Device holding its keys and a session synchronizes Drafts.
          if (
            value.session &&
            sync !== undefined &&
            sync !== 'unreadable' &&
            !sync.pending &&
            sync.deviceKey &&
            sync.vault?.published === true
          ) {
            yield* productSyncFlow.adoptRotation;
          }
          return yield* current;
        }),
      ),
    // Unregisters this Trusted Device, then removes the Product Account's data from this device.
    signOut: () => program(signOut, 'signOut'),
    // Permanently deletes the Product Account after an interactive Product Sign-In.
    deleteProductAccount: () => program(deleteAccount, 'deletion'),
  };
}
