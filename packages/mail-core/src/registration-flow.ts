import type {
  ProductAccountDeletionResponse,
  SignInLinkRequestResponse,
  SignInLinkResponse,
  TrustedDeviceUnregistrationResponse,
} from '@private-email/contracts/productAccount';
import type { ProductSyncEnrollmentStatus } from '@private-email/contracts/productSync';

import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Predicate from 'effect/Predicate';
import * as Schema from 'effect/Schema';

import type {
  BackendCall,
  NativeRegistrationVault,
  RegistrationRecord,
  SetupReason,
} from './registration-vault.ts';
import type {
  RegistrationPrograms,
  RegistrationSnapshot,
  SignInProvider,
} from './registration.ts';

import { decodeDiagnostic, rejectionCode } from './diagnostics.ts';
import {
  BackendReply,
  Identity,
  MailboxIdentity,
  MailboxReceipt,
  RegistrationRecordSchema,
} from './registration-vault.ts';

export type { NativeRegistrationVault } from './registration-vault.ts';

const Provider = Schema.Literals(['google', 'apple']);
// These boundary schemas must remain assignable to the shared Convex validators' inferred types.
const LinkRequest = Schema.Struct({
  linkTicket: Schema.optionalKey(Schema.String),
  signInProviders: Schema.mutable(Schema.Array(Provider)),
}) satisfies Schema.Codec<SignInLinkRequestResponse>;
const LinkResponse = Schema.Struct({
  productAccountId: Schema.String,
  signInProviders: Schema.mutable(Schema.Array(Provider)),
}) satisfies Schema.Codec<SignInLinkResponse>;
const Unregistration = Schema.Struct({
  registered: Schema.Boolean,
}) satisfies Schema.Codec<TrustedDeviceUnregistrationResponse>;
const Deletion = Schema.Struct({
  deleted: Schema.Boolean,
}) satisfies Schema.Codec<ProductAccountDeletionResponse>;
const EnrollmentStatus = Schema.Struct({
  approval: Schema.optionalKey(
    Schema.Struct({
      ciphertextBase64: Schema.String,
      encapsulatedKeyBase64: Schema.String,
      keyVersion: Schema.Finite,
    }),
  ),
  expiresAt: Schema.optionalKey(Schema.Finite),
  state: Schema.Literals(['pending', 'approved', 'cancelled', 'expired']),
}) satisfies Schema.Codec<ProductSyncEnrollmentStatus>;
// What purging after each acknowledged removal tells the person.
const removalNotices = {
  deletion: 'deleted',
  signOut: 'signed-out',
  revoked: 'revoked',
} as const;

// Codes native operations and Convex replies end with; host-facing codes are a subset.
const CodeSchema = Schema.Literals([
  'busy',
  'cancelled',
  'declined',
  'deleted',
  'enrollment-code-invalid',
  'enrollment-unavailable',
  'gmail-unavailable',
  'identity-owned',
  'invalid-identity',
  'locked',
  // A transport failure that permits reading the last verified local state.
  'offline',
  'recovery-key-mismatch',
  'removal-refused',
  'revoked',
  'stale-authentication',
  'unavailable',
  // Distinguished by the flow only; hosts see them as other codes.
  'apple-authorization-required',
  'pending-device-unavailable',
]);
type Code = typeof CodeSchema.Type;

// The flow's own distinctions, as the codes hosts have always received.
const hostCodes: Partial<Record<Code, Code>> = {
  offline: 'unavailable',
  'pending-device-unavailable': 'unavailable',
  revoked: 'unavailable',
  deleted: 'unavailable',
  'apple-authorization-required': 'removal-refused',
};

// The fixed texts hosts have always received with each code.
const messages: Partial<Record<Code, string>> = {
  busy: 'Authorization is already running.',
  cancelled: 'Sign-in was cancelled.',
  'recovery-key-mismatch': 'That does not match the end of your Recovery Key.',
  'enrollment-code-invalid': "That code does not match the new device's code.",
  'enrollment-unavailable': 'That device request is no longer available.',
  locked: 'Unlock your device to open your saved account.',
};

export class RegistrationRejected extends Schema.TaggedError<RegistrationRejected>()(
  'RegistrationRejected',
  { code: CodeSchema, message: Schema.String, cause: Schema.Defect() },
) {}

const rejected = (code: Code, cause?: unknown) =>
  new RegistrationRejected({
    code,
    message:
      messages[code] ??
      'Registration could not finish. Retry with your saved account.',
    cause,
  });
const isCode = Schema.is(CodeSchema);

const gmailScopes = new Set([
  'https://www.googleapis.com/auth/gmail.modify',
  'https://mail.google.com/',
]);

// Convex error codes the flow distinguishes; others are unavailable.
const backendCodes: Readonly<Record<string, Code>> = {
  SIGN_IN_IDENTITY_OWNED: 'identity-owned',
  SIGN_IN_PROVIDER_ALREADY_LINKED: 'identity-owned',
  SIGN_IN_RECENT_AUTHENTICATION_REQUIRED: 'stale-authentication',
  SIGN_IN_LINK_EXPIRED: 'stale-authentication',
  SIGN_IN_NOT_LINKED: 'invalid-identity',
  ENROLLMENT_REQUEST_UNAVAILABLE: 'enrollment-unavailable',
  PENDING_DEVICE_UNAVAILABLE: 'pending-device-unavailable',
  TRUSTED_DEVICE_REVOKED: 'revoked',
  PRODUCT_ACCOUNT_DELETED: 'deleted',
};
const backendCode = (code: string | undefined) =>
  (code !== undefined && Object.hasOwn(backendCodes, code)
    ? backendCodes[code]
    : undefined) ?? 'unavailable';

const Envelope = Schema.fromJsonString(
  Schema.Struct({
    status: Schema.String,
    value: Schema.optionalKey(Schema.Unknown),
    errorData: Schema.optionalKey(Schema.Struct({ code: Schema.String })),
  }),
);
const decodeEnvelope = Schema.decodeUnknownEffect(Envelope);
const ErrorBody = Schema.fromJsonString(Schema.Struct({ code: Schema.String }));
const decodeErrorBody = Schema.decodeUnknownOption(ErrorBody);

const failWith = (code: Code) => Effect.fail(rejected(code));
const sameIdentity = (value: Readonly<{ matches: boolean }>) =>
  value.matches ? Effect.void : failWith('invalid-identity');
const unreadable = (error: Schema.SchemaError) =>
  Effect.logError(
    'Registration reply unreadable:',
    decodeDiagnostic(error),
  ).pipe(Effect.andThen(Effect.fail(rejected('unavailable', error))));
// Deletion refusals Convex returns before fencing anything.
const refusals: ReadonlySet<Code> = new Set([
  'stale-authentication',
  'removal-refused',
  'apple-authorization-required',
  'pending-device-unavailable',
]);
const endsAccess: ReadonlySet<Code> = new Set(['revoked', 'deleted']);

const mailboxState = (mailbox: RegistrationRecord['mailboxes'][number]) => {
  if (mailbox.authorizationNeeded) {
    return 'authorization' as const;
  }
  return mailbox.access === 'cached'
    ? ('cached' as const)
    : ('connected' as const);
};
// JSON text listing this device's connections in the order they were added.
const mailboxList = (value: RegistrationRecord) =>
  value.product?.pending === true || value.mailboxes.length === 0
    ? undefined
    : JSON.stringify(
        value.mailboxes.map((mailbox) => ({
          address: mailbox.address,
          ...(mailbox.epoch === undefined ? {} : { epoch: mailbox.epoch }),
          id: mailbox.id,
          state: mailboxState(mailbox),
        })),
      );
const account = (value: RegistrationRecord) => {
  const { product } = value;
  if (product === undefined) {
    return Effect.fail(rejected('unavailable'));
  }
  const alternate = product.signInProviders?.find(
    (provider) => provider !== value.signInProvider,
  );
  return Effect.succeed({
    productAccountId: product.productAccountId,
    signInProvider: value.signInProvider,
    ...(value.contactEmail === undefined || value.contactEmail === ''
      ? {}
      : { contactEmail: value.contactEmail }),
    ...(alternate === undefined ? {} : { alternateSignIn: alternate }),
    ...value.privateSync,
    ...(value.mailboxRemovalPending
      ? { privateSyncPending: 'mailbox' as const }
      : {}),
  });
};
const pending = Effect.fnUntraced(function* (value: RegistrationRecord) {
  const fields = yield* account(value);
  // A device the account has not admitted shows only its enrollment gate.
  if (value.product?.pending === true) {
    return { kind: 'device-pending', ...fields } satisfies RegistrationSnapshot;
  }
  // Saved mailboxes that all need authorization again read as Gmail being unavailable.
  const reason =
    value.mailboxSetupReason ??
    (value.mailboxes.length === 0 ? undefined : 'gmail-unavailable');
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
const status = Effect.fnUntraced(function* (value: RegistrationRecord) {
  const states = value.mailboxes
    .filter((mailbox) => !mailbox.authorizationNeeded)
    .map(mailboxState);
  const mailboxes = mailboxList(value);
  if (
    value.product?.pending === true ||
    states.length === 0 ||
    mailboxes === undefined
  ) {
    return yield* pending(value);
  }
  const fields = yield* account(value);
  return {
    kind: states.includes('connected') ? 'connected' : 'cached',
    ...fields,
    mailboxes,
  } satisfies RegistrationSnapshot;
});

export function createRegistrationFlow(vault: NativeRegistrationVault) {
  const native = Effect.fnUntraced(function* <S extends Schema.Top>(
    operation: () => Promise<unknown>,
    schema: S,
  ) {
    const value = yield* Effect.tryPromise({
      try: operation,
      catch: (cause) => {
        const code = rejectionCode(cause);
        return rejected(isCode(code) ? code : 'unavailable', cause);
      },
    });
    return yield* Schema.decodeUnknownEffect(schema)(value).pipe(
      Effect.catch(unreadable),
    );
  });
  const step = (operation: () => Promise<unknown>) =>
    native(operation, Schema.Null).pipe(Effect.asVoid);
  const record = native(
    vault.registration,
    Schema.NullOr(RegistrationRecordSchema),
  );
  const saved = record.pipe(
    Effect.filterOrFail(Predicate.isNotNull, () => rejected('unavailable')),
  );
  // A Convex function result; application errors carry a code whatever the HTTP status.
  const convex = Effect.fnUntraced(function* <S extends Schema.Top>(
    request: BackendCall,
    schema: S,
  ) {
    const reply = yield* native(() => vault.call(request), BackendReply);
    const envelope = yield* decodeEnvelope(reply.body).pipe(
      Effect.catch(unreadable),
    );
    if (envelope.status !== 'success' || reply.status !== 200) {
      return yield* failWith(backendCode(envelope.errorData?.code));
    }
    return yield* Schema.decodeUnknownEffect(schema)(envelope.value).pipe(
      Effect.catch(unreadable),
    );
  });

  const current = saved.pipe(Effect.flatMap(status));
  const failure = (reason: SetupReason) =>
    step(() => vault.recordMailboxSetup(reason)).pipe(
      Effect.andThen(saved),
      Effect.flatMap(pending),
    );

  const purge = (notice: 'revoked' | 'deleted' | 'signed-out') =>
    step(() => vault.purge(notice)).pipe(
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
  // Saves the latest matching sign-in even if the backend is interrupted, then connects it.
  const establish = (replacing = false) =>
    step(() => vault.saveIdentity(replacing)).pipe(
      Effect.andThen(step(() => vault.connect('establish'))),
      Effect.andThen(step(vault.synchronize)),
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

  const checkedGmail = Effect.fnUntraced(function* (scopes: readonly string[]) {
    if (!scopes.some((scope) => gmailScopes.has(scope))) {
      return yield* failWith('declined');
    }
    return yield* native(vault.verifyGmail, MailboxReceipt);
  });

  // Reports each retained connection as connected only after its Gmail access verifies again,
  // including one Gmail refused before. One connection's failure never changes another's state.
  const mailboxStatus = Effect.gen(function* () {
    const value = yield* saved;
    if (value.product?.pending === true || value.mailboxes.length === 0) {
      return yield* pending(value);
    }
    for (const mailbox of value.mailboxes) {
      yield* native(
        () => vault.refreshMailbox(mailbox.id),
        MailboxIdentity,
      ).pipe(
        Effect.flatMap(({ scopes }) => checkedGmail(scopes)),
        Effect.andThen(step(() => vault.confirmMailbox(mailbox.id))),
        // Cached consent is never proof of usable Gmail access; a refused grant never opens its
        // saved mail.
        Effect.catchIf(
          (error) => !endsAccess.has(error.code),
          ({ code }) => {
            // Offline keeps the saved Inbox open unless Gmail already refused this grant.
            const offline = mailbox.authorizationNeeded
              ? 'unverified'
              : 'cached';
            return step(() =>
              vault.markMailbox(
                mailbox.id,
                code === 'offline' ? offline : 'authorization',
              ),
            );
          },
        ),
      );
    }
    const verified = (yield* saved).mailboxes.some(
      (mailbox) =>
        !mailbox.authorizationNeeded && mailbox.access === 'verified',
    );
    if (verified) {
      yield* step(vault.synchronize);
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
      Effect.andThen(step(vault.synchronize)),
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

  // Authorizes Gmail for the named connection again, or adds a mailbox when none is named. Adding
  // a mailbox that is already connected repairs that connection instead of duplicating it. The
  // first mailbox suggests the Google sign-in unless the person chooses another account.
  const authorizeGmail = Effect.fnUntraced(function* (
    connection: string | null,
    chooseAccount: boolean,
  ) {
    const value = yield* saved;
    // Gmail authorization follows admission; a Pending Device holds no mailbox.
    if (value.product === undefined || value.product.pending) {
      return yield* failWith('unavailable');
    }
    const existing = value.mailboxes.find(({ id }) => id === connection);
    // A connection removed meanwhile is not added back by reauthorizing it.
    if (connection !== null && existing === undefined) {
      return yield* failWith('unavailable');
    }
    // A failure leaves other usable mailboxes as they are; the host reports it.
    const keepsMailboxes = value.mailboxes.some(
      ({ id, authorizationNeeded }) =>
        !authorizationNeeded && id !== connection,
    );
    // Confirm the retained Product Sign-In independently of the mailbox selection.
    const confirmed = yield* reconfirm(value).pipe(
      Effect.as(true),
      Effect.catchIf(
        (error) => !endsAccess.has(error.code),
        () => Effect.succeed(false),
      ),
    );
    if (!confirmed) {
      return yield* failure(
        value.signInProvider === 'apple' ? 'unavailable' : 'interrupted',
      );
    }
    // An Apple identity or its relay address is never a Google account hint. Another mailbox is
    // chosen without one.
    const suggest =
      !chooseAccount &&
      value.mailboxes.length === 0 &&
      value.signInProvider === 'google';
    return yield* Effect.gen(function* () {
      const { scopes } = yield* native(
        () => vault.signInMailbox(connection, suggest),
        MailboxIdentity,
      );
      const receipt = yield* checkedGmail(scopes);
      // Reauthorization repairs this connection; another Google account is added separately.
      if (existing !== undefined && existing.id !== receipt.connection) {
        return yield* failWith('gmail-unavailable');
      }
      yield* step(vault.retryMailboxCleanup);
      yield* step(vault.storeMailbox);
      yield* step(vault.synchronize);
      return yield* current;
    }).pipe(
      Effect.catchIf(
        (error) => !endsAccess.has(error.code) && !keepsMailboxes,
        ({ code }) =>
          failure(
            code === 'cancelled' ||
              code === 'declined' ||
              code === 'gmail-unavailable'
              ? code
              : 'interrupted',
          ),
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
        // Never discard a published or unanswered Recovery Key the person has not backed up.
        const ready = yield* native(vault.prepareSignOut, Schema.Boolean);
        if (!ready) {
          return yield* current;
        }
      }
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
      const value = yield* record.pipe(Effect.orElseSucceed(() => null));
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
    signIn: (provider) => program(signIn(provider)),
    addMailbox: (chooseAccount) => program(authorizeGmail(null, chooseAccount)),
    authorizeGmail: (connection) => program(authorizeGmail(connection, false)),
    removeMailbox: (connection) =>
      program(thenStatus(() => vault.removeMailbox(connection))),
    link: (provider) => program(link(provider)),
    confirmRecoveryKey: (entry) =>
      program(thenStatus(() => vault.confirmRecoveryKey(entry))),
    recoverWithRecoveryKey: (entry) =>
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
          const outcome = readable
            ? yield* native(
                () => vault.recoverWithRecoveryKey(entry),
                Schema.Struct({ rejected: Schema.Boolean }),
              )
            : { rejected: true };
          const snapshot = yield* current;
          return outcome.rejected
            ? { ...snapshot, recoveryNotice: 'rejected' as const }
            : snapshot;
        }),
      ),
    approveEnrollment: (requestId, code) =>
      program(thenStatus(() => vault.approveEnrollment(requestId, code))),
    declineEnrollment: (requestId) =>
      program(thenStatus(() => vault.declineEnrollment(requestId))),
    // Removes another Trusted Device after a fresh interactive Product Sign-In.
    revokeTrustedDevice: (trustedDeviceId) =>
      program(
        Effect.gen(function* () {
          const value = yield* saved;
          yield* sameIdentity(
            yield* identity(
              value.signInProvider,
              value.signInProvider === 'google',
            ),
          );
          const { notice } = yield* native(
            () => vault.revokeTrustedDevice(trustedDeviceId),
            Schema.Struct({
              notice: Schema.optionalKey(
                Schema.Literals(['removed', 'unconfirmed']),
              ),
            }),
          );
          const snapshot = yield* current;
          return notice === undefined
            ? snapshot
            : { ...snapshot, revocationNotice: notice };
        }),
      ),
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
            yield* step(vault.synchronize);
          }
          return yield* current;
        }),
      ),
    signOut: () => program(signOut, 'signOut'),
    deleteProductAccount: () => program(deleteAccount, 'deletion'),
  } satisfies RegistrationPrograms;
}
