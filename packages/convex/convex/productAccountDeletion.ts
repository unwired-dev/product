'use node';

import {
  createPrivateKey,
  createPublicKey,
  randomUUID,
  sign,
  verify,
} from 'node:crypto';

import { productAccountDeletionResponseValidator } from '@private-email/contracts';
import { v } from 'convex/values';
import * as Clock from 'effect/Clock';
import * as Config from 'effect/Config';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Predicate from 'effect/Predicate';
import * as Schema from 'effect/Schema';

import type { Id } from './_generated/dataModel.js';
import type { ActionCtx } from './_generated/server.js';
import type { CallFailed } from './effectRuntime.js';

import { internal } from './_generated/api.js';
import { action, internalAction } from './_generated/server.js';
import { call, runConvexProgram } from './effectRuntime.js';
import { trustedDeviceCredentialArgs } from './productAccountAuth.js';

const appleAudience = 'https://appleid.apple.com';
const appleRevokeUrl = `${appleAudience}/auth/revoke`;
const appleTokenUrl = `${appleAudience}/auth/token`;
const applePublicKeysUrl = `${appleAudience}/auth/keys`;
const deletionBatchLimit = 25;

type RevocationMaterial =
  | Readonly<{ kind: 'authorization-code'; value: string }>
  | Readonly<{ kind: 'access-token'; value: string }>
  | Readonly<{ kind: 'refresh-token'; value: string }>;

type RevocationToken = Exclude<
  RevocationMaterial,
  { kind: 'authorization-code' }
>;

const decodeJson = Schema.decodeUnknownOption(
  Schema.fromJsonString(Schema.Unknown),
);

const isAppleIdentityTokenHeader = Schema.is(
  Schema.Struct({ alg: Schema.Literal('RS256'), kid: Schema.String }),
);

const isAppleIdentityTokenClaims = Schema.is(
  Schema.Struct({
    aud: Schema.String,
    exp: Schema.Finite,
    iss: Schema.Literal(appleAudience),
    sub: Schema.String,
  }),
);

const decodeApplePublicKeySet = Schema.decodeUnknownOption(
  Schema.Struct({ keys: Schema.Array(Schema.Unknown) }),
);

const decodeApplePublicKey = Schema.decodeUnknownOption(
  Schema.Struct({
    e: Schema.String,
    kid: Schema.String,
    kty: Schema.Literal('RSA'),
    n: Schema.String,
  }),
);

const decodeAppleIdentityTokenResponse = Schema.decodeUnknownOption(
  Schema.Struct({ id_token: Schema.String }),
);

const decodeAppleRefreshTokenResponse = Schema.decodeUnknownOption(
  Schema.Struct({ refresh_token: Schema.String }),
);

const decodeAppleErrorResponse = Schema.decodeUnknownOption(
  Schema.Struct({ error: Schema.String }),
);

const appleRequestTimeoutMs = 20_000;

// Apple could not be reached or answered 429 or 5xx; the deletion attempt is kept for retry.
class AppleUnavailable extends Schema.TaggedError<AppleUnavailable>()(
  'AppleUnavailable',
  {},
) {}

// Apple refused the authorization, or its answer failed validation; the attempt ends.
class AppleRejected extends Schema.TaggedError<AppleRejected>()(
  'AppleRejected',
  {
    message: Schema.Literals([
      'Apple authorization exchange failed',
      'Apple authorization revocation failed',
      'Recent authentication must match the Product Account',
    ]),
  },
) {}

// Configuration, signing or Apple's answer could not be processed; handlers rethrow the cause.
class AppleFailed extends Schema.TaggedError<AppleFailed>()('AppleFailed', {
  cause: Schema.Defect(),
}) {}

class DeletionRejected extends Schema.TaggedError<DeletionRejected>()(
  'DeletionRejected',
  {
    message: Schema.Literals([
      'Authentication required',
      'Product Account deletion is already in progress',
      'Recent Sign in with Apple authorization is required',
    ]),
  },
) {}

// Apple revoked the token, but recording that failed; the attempt is released for retry.
class RevocationUnrecorded extends Schema.TaggedError<RevocationUnrecorded>()(
  'RevocationUnrecorded',
  { cause: Schema.Defect() },
) {}

type DeletionFailure =
  | AppleFailed
  | AppleRejected
  | AppleUnavailable
  | CallFailed
  | DeletionRejected;

function thrownDeletionError(error: DeletionFailure): unknown {
  if (error._tag === 'AppleFailed' || error._tag === 'CallFailed') {
    return error.cause;
  }
  return new Error(
    error._tag === 'AppleUnavailable'
      ? 'Apple authorization revocation is temporarily unavailable'
      : error.message,
  );
}

function exchangeFailed(): AppleRejected {
  return new AppleRejected({ message: 'Apple authorization exchange failed' });
}

function appleSetting(name: string): Effect.Effect<string, AppleFailed> {
  return Config.NonEmptyString(name).pipe(
    Effect.mapError(
      () =>
        new AppleFailed({ cause: new Error(`Missing ${name} configuration`) }),
    ),
  );
}

function encodeJson(value: Readonly<Record<string, string | number>>): string {
  return Buffer.from(JSON.stringify(value)).toString('base64url');
}

const appleClientSecret = Effect.gen(function* () {
  const now = Math.floor((yield* Clock.currentTimeMillis) / 1000);
  const keyId = yield* appleSetting('APPLE_SIGN_IN_KEY_ID');
  const teamId = yield* appleSetting('APPLE_TEAM_ID');
  const bundleId = yield* appleSetting('APPLE_BUNDLE_ID');
  const privateKey = yield* appleSetting('APPLE_SIGN_IN_PRIVATE_KEY');
  const header = encodeJson({ alg: 'ES256', kid: keyId });
  const payload = encodeJson({
    aud: appleAudience,
    exp: now + 300,
    iat: now,
    iss: teamId,
    sub: bundleId,
  });
  const unsignedToken = `${header}.${payload}`;
  const signature = yield* Effect.try({
    try: () =>
      sign('sha256', Buffer.from(unsignedToken), {
        dsaEncoding: 'ieee-p1363',
        key: createPrivateKey(privateKey.replaceAll(String.raw`\n`, '\n')),
      }).toString('base64url'),
    catch: (cause) => new AppleFailed({ cause }),
  });
  return `${unsignedToken}.${signature}`;
});

function isRetryableAppleStatus(status: number): boolean {
  return status === 429 || status >= 500;
}

// Apple's deadline stays on fetch's abort signal: it also bounds the response body,
// and a body that stalls fails differently from an Apple that cannot be reached.
function requestApple(
  request: (deadline: AbortSignal) => Promise<Response>,
): Effect.Effect<Response, AppleUnavailable> {
  return Effect.tryPromise({
    try: async () => request(AbortSignal.timeout(appleRequestTimeoutMs)),
    catch: () => new AppleUnavailable(),
  });
}

async function postAppleForm(
  url: string,
  values: Readonly<Record<string, string>>,
  signal: AbortSignal,
): Promise<Response> {
  return fetch(url, {
    body: new URLSearchParams(values),
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    method: 'POST',
    signal,
  });
}

async function fetchApplePublicKeys(signal: AbortSignal): Promise<Response> {
  return fetch(applePublicKeysUrl, { signal });
}

function readAppleJson(
  response: Response,
): Effect.Effect<unknown, AppleFailed> {
  return Effect.tryPromise({
    try: async (): Promise<unknown> => response.json(),
    catch: (cause) => new AppleFailed({ cause }),
  });
}

// A token part that is not a JSON object is malformed; a JSON object with the wrong claims does not match.
function decodedJwtPart(encoded: string): Effect.Effect<object, AppleRejected> {
  return decodeJson(Buffer.from(encoded, 'base64url').toString('utf8')).pipe(
    Option.filter(Predicate.isObjectOrArray),
    Effect.fromOption,
    Effect.mapError(exchangeFailed),
  );
}

// fallow-ignore-next-line complexity -- Apple identity tokens must fail closed across signature and claim validation.
const verifyAppleIdentityToken = Effect.fnUntraced(function* (
  identityToken: string,
  expectedSubject: string,
) {
  const parts = identityToken.split('.');
  const [encodedHeader, encodedClaims, encodedSignature] = parts;
  if (
    parts.length !== 3 ||
    parts.some((part) => part.length === 0) ||
    encodedHeader === undefined ||
    encodedClaims === undefined ||
    encodedSignature === undefined
  ) {
    return yield* exchangeFailed();
  }
  const header = yield* decodedJwtPart(encodedHeader);
  const claims = yield* decodedJwtPart(encodedClaims);
  const bundleId = yield* appleSetting('APPLE_BUNDLE_ID');
  const now = yield* Clock.currentTimeMillis;
  if (
    !isAppleIdentityTokenHeader(header) ||
    !isAppleIdentityTokenClaims(claims) ||
    claims.aud !== bundleId ||
    claims.exp <= now / 1000 ||
    claims.sub !== expectedSubject
  ) {
    return yield* new AppleRejected({
      message: 'Recent authentication must match the Product Account',
    });
  }
  const response = yield* requestApple(fetchApplePublicKeys);
  if (isRetryableAppleStatus(response.status)) {
    return yield* new AppleUnavailable();
  }
  const body = response.ok ? yield* readAppleJson(response) : undefined;
  const keys = Option.match(decodeApplePublicKeySet(body), {
    onNone: () => [],
    onSome: (keySet) => keySet.keys,
  });
  const key = keys
    .flatMap((candidate) => Option.toArray(decodeApplePublicKey(candidate)))
    .find((candidate) => candidate.kid === header.kid);
  if (key === undefined) {
    return yield* exchangeFailed();
  }
  const verified = yield* Effect.try({
    try: () =>
      verify(
        'RSA-SHA256',
        Buffer.from(`${encodedHeader}.${encodedClaims}`),
        createPublicKey({
          format: 'jwk',
          key: { e: key.e, kty: 'RSA', n: key.n },
        }),
        Buffer.from(encodedSignature, 'base64url'),
      ),
    catch: (cause) => new AppleFailed({ cause }),
  });
  if (!verified) {
    return yield* exchangeFailed();
  }
});

// fallow-ignore-next-line complexity -- Apple response validation keeps each failure distinct and fail closed.
const exchangeAuthorizationCode = Effect.fnUntraced(function* (
  authorizationCode: string,
  expectedSubject: string,
) {
  const bundleId = yield* appleSetting('APPLE_BUNDLE_ID');
  const clientSecret = yield* appleClientSecret;
  const response = yield* requestApple(async (signal) =>
    postAppleForm(
      appleTokenUrl,
      {
        client_id: bundleId,
        client_secret: clientSecret,
        code: authorizationCode,
        grant_type: 'authorization_code',
      },
      signal,
    ),
  );
  if (isRetryableAppleStatus(response.status)) {
    return yield* new AppleUnavailable();
  }
  if (!response.ok) {
    return yield* exchangeFailed();
  }
  const body = yield* readAppleJson(response);
  const { id_token: identityToken } = yield* Effect.fromOption(
    decodeAppleIdentityTokenResponse(body),
  ).pipe(Effect.mapError(exchangeFailed));
  yield* verifyAppleIdentityToken(identityToken, expectedSubject);
  const { refresh_token: refreshToken } = yield* Effect.fromOption(
    decodeAppleRefreshTokenResponse(body),
  ).pipe(Effect.mapError(exchangeFailed));
  const revocationToken: RevocationToken = {
    kind: 'refresh-token',
    value: refreshToken,
  };
  return revocationToken;
});

// An unreadable error body is treated as no error code.
function appleErrorCode(response: Response): Effect.Effect<string | undefined> {
  return Effect.tryPromise(async (): Promise<unknown> => response.json()).pipe(
    Effect.map(
      (body) => Option.getOrUndefined(decodeAppleErrorResponse(body))?.error,
    ),
    Effect.orElseSucceed(() => undefined),
  );
}

// fallow-ignore-next-line complexity -- Retry recovery accepts only Apple's proven refresh-token terminal state.
const revokeAppleToken = Effect.fnUntraced(function* (
  token: RevocationToken,
  acceptAlreadyRevoked: boolean,
) {
  const bundleId = yield* appleSetting('APPLE_BUNDLE_ID');
  const clientSecret = yield* appleClientSecret;
  const response = yield* requestApple(async (signal) =>
    postAppleForm(
      appleRevokeUrl,
      {
        client_id: bundleId,
        client_secret: clientSecret,
        token: token.value,
        token_type_hint:
          token.kind === 'refresh-token' ? 'refresh_token' : 'access_token',
      },
      signal,
    ),
  );
  if (isRetryableAppleStatus(response.status)) {
    return yield* new AppleUnavailable();
  }
  if (!response.ok) {
    if (
      acceptAlreadyRevoked &&
      token.kind === 'refresh-token' &&
      response.status === 400 &&
      (yield* appleErrorCode(response)) === 'invalid_grant'
    ) {
      return;
    }
    return yield* new AppleRejected({
      message: 'Apple authorization revocation failed',
    });
  }
});

const deleteBatches = Effect.fnUntraced(function* (
  ctx: Pick<ActionCtx, 'runMutation'>,
  requestId: Id<'productAccountDeletionRequests'>,
) {
  let complete = false;
  let batchesDeleted = 0;
  while (!complete && batchesDeleted < deletionBatchLimit) {
    const batch = yield* call(
      async (): Promise<Readonly<{ complete: boolean }>> =>
        ctx.runMutation(internal.productAccountDeletionData.deleteNextBatch, {
          requestId,
        }),
    );
    ({ complete } = batch);
    batchesDeleted += 1;
  }
  return complete;
});

type RevocationRecovery = Readonly<{
  revocationPreviouslySucceeded: boolean;
  token: RevocationToken;
}>;

// fallow-ignore-next-line complexity -- Durable recovery preserves success across every action/mutation boundary.
const resumeRevocation = Effect.fnUntraced(function* (
  ctx: ActionCtx,
  args: Readonly<{ requestId: Id<'productAccountDeletionRequests'> }>,
  attemptId: string,
) {
  const recovery = yield* call(async (): Promise<RevocationRecovery | null> =>
    ctx.runMutation(
      internal.productAccountDeletionData.prepareRevocationRecovery,
      { ...args, attemptId },
    ),
  );
  if (recovery === null) {
    return;
  }
  const abortRecovery = call(async () =>
    ctx.runMutation(
      internal.productAccountDeletionData.abortRecoveredRevocation,
      { ...args, attemptId },
    ),
  ).pipe(Effect.as(false));
  const revocation: Effect.Effect<
    void,
    AppleFailed | AppleRejected | AppleUnavailable | RevocationUnrecorded
  > = recovery.revocationPreviouslySucceeded
    ? Effect.void
    : Effect.gen(function* () {
        yield* revokeAppleToken(recovery.token, true);
        yield* call(async () =>
          ctx.runMutation(
            internal.productAccountDeletionData
              .markRecoveredRevocationSucceeded,
            { ...args, attemptId },
          ),
        ).pipe(Effect.mapError((cause) => new RevocationUnrecorded({ cause })));
      });
  // A retryable or unrecorded revocation leaves recovery for its next run.
  const completed = yield* revocation.pipe(
    Effect.as(true),
    Effect.catchTags({
      AppleFailed: () => abortRecovery,
      AppleRejected: () => abortRecovery,
      AppleUnavailable: () => Effect.succeed(false),
      RevocationUnrecorded: () => Effect.succeed(false),
    }),
    // An unexpected defect aborts recovery, like a terminal failure.
    Effect.catchDefect(() => abortRecovery),
  );
  if (completed) {
    yield* call(async () =>
      ctx.runMutation(
        internal.productAccountDeletionData.completeRecoveredRevocation,
        { ...args, attemptId },
      ),
    );
  }
});

export const resumeProductAccountRevocation = internalAction({
  args: { requestId: v.id('productAccountDeletionRequests') },
  handler: async (ctx, args): Promise<void> =>
    runConvexProgram(
      resumeRevocation(ctx, args, randomUUID()),
      thrownDeletionError,
    ),
});

type PreparedDeletion = Readonly<
  | { state: 'already-deleted' }
  | { state: 'in-progress' }
  | {
      phase: 'deleting-data' | 'revocation-pending';
      requestId: Id<'productAccountDeletionRequests'>;
      revocationPreviouslyAttempted: boolean;
      revocationPreviouslySucceeded: boolean;
      revocationMaterial?: RevocationMaterial;
      state: 'pending';
    }
>;

type PendingDeletion = Extract<PreparedDeletion, { state: 'pending' }>;

// fallow-ignore-next-line complexity -- Revocation keeps exchange, storage, and Apple revocation ordered and durable.
const revokeForDeletion = Effect.fnUntraced(function* (
  ctx: ActionCtx,
  prepared: PendingDeletion,
  attempt: Readonly<{ attemptId: string; subject: string }>,
) {
  const { attemptId, subject } = attempt;
  const { requestId, revocationMaterial: material } = prepared;
  let token: RevocationToken | undefined = undefined;
  if (material?.kind === 'refresh-token' || material?.kind === 'access-token') {
    token = material;
  } else if (material?.kind === 'authorization-code') {
    token = yield* exchangeAuthorizationCode(material.value, subject);
  }
  if (token === undefined) {
    return yield* new DeletionRejected({
      message: 'Recent Sign in with Apple authorization is required',
    });
  }
  const revocationToken = token;
  if (material?.kind === 'authorization-code') {
    yield* call(async () =>
      ctx.runMutation(
        internal.productAccountDeletionData.storeRevocationToken,
        {
          attemptId,
          requestId,
          token: revocationToken,
        },
      ),
    );
  }
  yield* call(async () =>
    ctx.runMutation(
      internal.productAccountDeletionData.markRevocationAttemptStarted,
      { attemptId, requestId },
    ),
  );
  yield* revokeAppleToken(
    revocationToken,
    prepared.revocationPreviouslyAttempted,
  );
  yield* call(async () =>
    ctx.runMutation(
      internal.productAccountDeletionData.markRevocationSucceeded,
      {
        attemptId,
        requestId,
      },
    ),
  ).pipe(Effect.mapError((cause) => new RevocationUnrecorded({ cause })));
});

// fallow-ignore-next-line complexity -- Deletion coordinates fail-closed revocation, durable retries, and bounded cleanup.
const deleteAccount = Effect.fnUntraced(function* (
  ctx: ActionCtx,
  args: Readonly<{
    authorizationCode: string;
    trustedDeviceCredential?: string;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
  attemptId: string,
) {
  const identity = yield* call(async () => ctx.auth.getUserIdentity());
  if (!identity) {
    return yield* new DeletionRejected({ message: 'Authentication required' });
  }
  const prepared = yield* call(async (): Promise<PreparedDeletion> =>
    ctx.runMutation(internal.productAccountDeletionData.prepareDeletion, {
      ...args,
      attemptId,
    }),
  );
  if (prepared.state === 'already-deleted') {
    return { deleted: true };
  }
  if (prepared.state === 'in-progress') {
    return yield* new DeletionRejected({
      message: 'Product Account deletion is already in progress',
    });
  }
  const { requestId } = prepared;
  if (prepared.phase === 'revocation-pending') {
    const settleAttempt = (
      mutation:
        | typeof internal.productAccountDeletionData.abortDeletion
        | typeof internal.productAccountDeletionData.releaseDeletionAttempt,
    ) => call(async () => ctx.runMutation(mutation, { attemptId, requestId }));
    const revocation: Effect.Effect<
      void,
      DeletionFailure | RevocationUnrecorded
    > = prepared.revocationPreviouslySucceeded
      ? Effect.void
      : revokeForDeletion(ctx, prepared, {
          attemptId,
          subject: identity.subject,
        });
    // Retryable failures release the deletion attempt; terminal ones abort it. A
    // revocation that succeeded but was not recorded is retried like an unavailable Apple.
    yield* revocation.pipe(
      Effect.catch((error): Effect.Effect<never, DeletionFailure> =>
        error._tag === 'AppleUnavailable' ||
        error._tag === 'RevocationUnrecorded'
          ? settleAttempt(
              internal.productAccountDeletionData.releaseDeletionAttempt,
            ).pipe(Effect.andThen(Effect.fail(new AppleUnavailable())))
          : settleAttempt(
              internal.productAccountDeletionData.abortDeletion,
            ).pipe(Effect.andThen(Effect.fail(error))),
      ),
      // An unexpected defect aborts the attempt and still surfaces, as before.
      Effect.catchDefect((defect) =>
        settleAttempt(internal.productAccountDeletionData.abortDeletion).pipe(
          Effect.andThen(Effect.die(defect)),
        ),
      ),
    );
    yield* call(async () =>
      ctx.runMutation(
        internal.productAccountDeletionData.markRevocationComplete,
        { attemptId, requestId },
      ),
    );
  }
  const complete = yield* deleteBatches(ctx, requestId);
  if (!complete) {
    yield* call(async () =>
      ctx.scheduler.runAfter(
        0,
        internal.productAccountDeletionData.continueProductAccountDeletion,
        { requestId },
      ),
    );
  }
  return { deleted: complete };
});

export const deleteProductAccount = action({
  args: {
    ...trustedDeviceCredentialArgs,
    authorizationCode: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args): Promise<{ deleted: boolean }> =>
    runConvexProgram(
      deleteAccount(ctx, args, randomUUID()),
      thrownDeletionError,
    ),
  returns: productAccountDeletionResponseValidator,
});
