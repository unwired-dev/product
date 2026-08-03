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

import type { Id } from './_generated/dataModel.js';
import type { ActionCtx } from './_generated/server.js';

import { internal } from './_generated/api.js';
import { action, internalAction } from './_generated/server.js';

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

function requiredEnvironmentValue(name: string): string {
  // oxlint-disable-next-line node/no-process-env -- Convex actions read deployment env at runtime.
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing ${name} configuration`);
  }
  return value;
}

function encodeJson(value: Readonly<Record<string, string | number>>): string {
  return Buffer.from(JSON.stringify(value)).toString('base64url');
}

function appleClientSecret(): string {
  const now = Math.floor(Date.now() / 1000);
  const header = encodeJson({
    alg: 'ES256',
    kid: requiredEnvironmentValue('APPLE_SIGN_IN_KEY_ID'),
  });
  const payload = encodeJson({
    aud: appleAudience,
    exp: now + 300,
    iat: now,
    iss: requiredEnvironmentValue('APPLE_TEAM_ID'),
    sub: requiredEnvironmentValue('APPLE_BUNDLE_ID'),
  });
  const unsignedToken = `${header}.${payload}`;
  const signature = sign('sha256', Buffer.from(unsignedToken), {
    dsaEncoding: 'ieee-p1363',
    key: createPrivateKey(
      requiredEnvironmentValue('APPLE_SIGN_IN_PRIVATE_KEY').replaceAll(
        String.raw`\n`,
        '\n',
      ),
    ),
  }).toString('base64url');
  return `${unsignedToken}.${signature}`;
}

function formBody(values: Readonly<Record<string, string>>): URLSearchParams {
  return new URLSearchParams(values);
}

function retryableAppleError(): Error {
  return new Error('Apple authorization revocation is temporarily unavailable');
}

function isRetryableAppleStatus(status: number): boolean {
  return status === 429 || status >= 500;
}

function deletionInProgressError(): Error {
  return new Error('Product Account deletion is already in progress');
}

async function deleteBatches(
  ctx: Pick<ActionCtx, 'runMutation'>,
  requestId: Id<'productAccountDeletionRequests'>,
): Promise<boolean> {
  let complete = false;
  let batchesDeleted = 0;
  while (!complete && batchesDeleted < deletionBatchLimit) {
    const { complete: batchComplete }: Readonly<{ complete: boolean }> =
      await ctx.runMutation(
        internal.productAccountDeletionData.deleteNextBatch,
        { requestId },
      );
    complete = batchComplete;
    batchesDeleted += 1;
  }
  return complete;
}

async function postToApple(
  url: string,
  values: Readonly<Record<string, string>>,
): Promise<Response> {
  try {
    return await fetch(url, {
      body: formBody(values),
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      method: 'POST',
      signal: AbortSignal.timeout(20_000),
    });
  } catch {
    throw retryableAppleError();
  }
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === 'object' && value !== null;
}

function unknownArray(value: unknown): readonly unknown[] {
  return Array.isArray(value) ? value : [];
}

// fallow-ignore-next-line complexity -- Every malformed token shape must fail closed.
function decodedJwtPart(encoded: string): Readonly<Record<string, unknown>> {
  try {
    const decoded: unknown = JSON.parse(
      Buffer.from(encoded, 'base64url').toString('utf8'),
    );
    if (isRecord(decoded)) {
      return decoded;
    }
  } catch {
    // Fall through to the common malformed-token error.
  }
  throw new Error('Apple authorization exchange failed');
}

// fallow-ignore-next-line complexity -- Apple identity tokens must fail closed across signature and claim validation.
async function verifyAppleIdentityToken(
  identityToken: string,
  expectedSubject: string,
): Promise<void> {
  const parts = identityToken.split('.');
  if (parts.length !== 3 || parts.some((part) => part.length === 0)) {
    throw new Error('Apple authorization exchange failed');
  }
  const [encodedHeader, encodedClaims, encodedSignature] = parts;
  if (
    encodedHeader === undefined ||
    encodedClaims === undefined ||
    encodedSignature === undefined
  ) {
    throw new Error('Apple authorization exchange failed');
  }
  const header = decodedJwtPart(encodedHeader);
  const claims = decodedJwtPart(encodedClaims);
  if (
    header.alg !== 'RS256' ||
    typeof header.kid !== 'string' ||
    claims.iss !== appleAudience ||
    claims.aud !== requiredEnvironmentValue('APPLE_BUNDLE_ID') ||
    typeof claims.exp !== 'number' ||
    claims.exp <= Date.now() / 1000 ||
    claims.sub !== expectedSubject
  ) {
    throw new Error('Recent authentication must match the Product Account');
  }
  const response = await fetch(applePublicKeysUrl, {
    signal: AbortSignal.timeout(20_000),
  }).catch(() => {
    throw retryableAppleError();
  });
  if (isRetryableAppleStatus(response.status)) {
    throw retryableAppleError();
  }
  const body: unknown = response.ok ? await response.json() : undefined;
  const keys = isRecord(body) ? unknownArray(body.keys) : [];
  const key = keys.find(
    // fallow-ignore-next-line complexity -- Apple signing-key selection validates every required JWK field.
    (candidate) =>
      isRecord(candidate) &&
      candidate.kid === header.kid &&
      candidate.kty === 'RSA' &&
      typeof candidate.n === 'string' &&
      typeof candidate.e === 'string',
  );
  if (
    !isRecord(key) ||
    typeof key.n !== 'string' ||
    typeof key.e !== 'string'
  ) {
    throw new Error('Apple authorization exchange failed');
  }
  const publicKey = createPublicKey({
    format: 'jwk',
    key: { e: key.e, kty: 'RSA', n: key.n },
  });
  if (
    !verify(
      'RSA-SHA256',
      Buffer.from(`${encodedHeader}.${encodedClaims}`),
      publicKey,
      Buffer.from(encodedSignature, 'base64url'),
    )
  ) {
    throw new Error('Apple authorization exchange failed');
  }
}

// fallow-ignore-next-line complexity -- Apple response validation keeps each failure distinct and fail closed.
async function exchangeAuthorizationCode(
  authorizationCode: string,
  expectedSubject: string,
): Promise<RevocationToken> {
  const response = await postToApple(appleTokenUrl, {
    client_id: requiredEnvironmentValue('APPLE_BUNDLE_ID'),
    client_secret: appleClientSecret(),
    code: authorizationCode,
    grant_type: 'authorization_code',
  });
  if (isRetryableAppleStatus(response.status)) {
    throw retryableAppleError();
  }
  if (!response.ok) {
    throw new Error('Apple authorization exchange failed');
  }
  const body: unknown = await response.json();
  if (!isRecord(body) || typeof body.id_token !== 'string') {
    throw new Error('Apple authorization exchange failed');
  }
  await verifyAppleIdentityToken(body.id_token, expectedSubject);
  if (typeof body.refresh_token === 'string') {
    return { kind: 'refresh-token', value: body.refresh_token };
  }
  throw new Error('Apple authorization exchange failed');
}

async function appleErrorCode(response: Response): Promise<string | undefined> {
  try {
    const body: unknown = await response.json();
    return isRecord(body) && typeof body.error === 'string'
      ? body.error
      : undefined;
  } catch {
    return undefined;
  }
}

// fallow-ignore-next-line complexity -- Retry recovery accepts only Apple's proven refresh-token terminal state.
async function revokeAppleToken(
  token: RevocationToken,
  acceptAlreadyRevoked: boolean,
): Promise<void> {
  const response = await postToApple(appleRevokeUrl, {
    client_id: requiredEnvironmentValue('APPLE_BUNDLE_ID'),
    client_secret: appleClientSecret(),
    token: token.value,
    token_type_hint:
      token.kind === 'refresh-token' ? 'refresh_token' : 'access_token',
  });
  if (isRetryableAppleStatus(response.status)) {
    throw retryableAppleError();
  }
  if (!response.ok) {
    if (
      acceptAlreadyRevoked &&
      token.kind === 'refresh-token' &&
      response.status === 400 &&
      (await appleErrorCode(response)) === 'invalid_grant'
    ) {
      return;
    }
    throw new Error('Apple authorization revocation failed');
  }
}

export const resumeProductAccountRevocation = internalAction({
  args: { requestId: v.id('productAccountDeletionRequests') },
  // fallow-ignore-next-line complexity -- Durable recovery preserves success across every action/mutation boundary.
  handler: async (ctx, args): Promise<void> => {
    const attemptId = randomUUID();
    const recovery: Readonly<{
      revocationPreviouslySucceeded: boolean;
      token: RevocationToken;
    }> | null = await ctx.runMutation(
      internal.productAccountDeletionData.prepareRevocationRecovery,
      { ...args, attemptId },
    );
    if (recovery === null) {
      return;
    }
    let revocationDidSucceed = recovery.revocationPreviouslySucceeded;
    try {
      if (!recovery.revocationPreviouslySucceeded) {
        await revokeAppleToken(recovery.token, true);
        revocationDidSucceed = true;
        await ctx.runMutation(
          internal.productAccountDeletionData.markRecoveredRevocationSucceeded,
          { ...args, attemptId },
        );
      }
    } catch (error) {
      if (revocationDidSucceed) {
        return;
      }
      if (
        error instanceof Error &&
        error.message ===
          'Apple authorization revocation is temporarily unavailable'
      ) {
        return;
      }
      await ctx.runMutation(
        internal.productAccountDeletionData.abortRecoveredRevocation,
        { ...args, attemptId },
      );
      return;
    }
    await ctx.runMutation(
      internal.productAccountDeletionData.completeRecoveredRevocation,
      { ...args, attemptId },
    );
  },
});

export const deleteProductAccount = action({
  args: {
    authorizationCode: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  // fallow-ignore-next-line complexity -- Deletion coordinates fail-closed revocation, durable retries, and bounded cleanup.
  handler: async (ctx, args): Promise<{ deleted: boolean }> => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error('Authentication required');
    }
    const attemptId = randomUUID();
    const prepared: Readonly<
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
    > = await ctx.runMutation(
      internal.productAccountDeletionData.prepareDeletion,
      { ...args, attemptId },
    );
    if (prepared.state === 'already-deleted') {
      return { deleted: true };
    }
    if (prepared.state === 'in-progress') {
      throw deletionInProgressError();
    }

    if (prepared.phase === 'revocation-pending') {
      let revocationDidSucceed = prepared.revocationPreviouslySucceeded;
      try {
        let revocationToken: RevocationToken | undefined = undefined;
        if (
          prepared.revocationMaterial?.kind === 'refresh-token' ||
          prepared.revocationMaterial?.kind === 'access-token'
        ) {
          revocationToken = prepared.revocationMaterial;
        } else if (prepared.revocationMaterial?.kind === 'authorization-code') {
          revocationToken = await exchangeAuthorizationCode(
            prepared.revocationMaterial.value,
            identity.subject,
          );
        }
        if (revocationToken === undefined) {
          throw new Error(
            'Recent Sign in with Apple authorization is required',
          );
        }
        if (prepared.revocationMaterial?.kind === 'authorization-code') {
          await ctx.runMutation(
            internal.productAccountDeletionData.storeRevocationToken,
            {
              attemptId,
              requestId: prepared.requestId,
              token: revocationToken,
            },
          );
        }
        if (!prepared.revocationPreviouslySucceeded) {
          await ctx.runMutation(
            internal.productAccountDeletionData.markRevocationAttemptStarted,
            { attemptId, requestId: prepared.requestId },
          );
          await revokeAppleToken(
            revocationToken,
            prepared.revocationPreviouslyAttempted,
          );
          revocationDidSucceed = true;
          await ctx.runMutation(
            internal.productAccountDeletionData.markRevocationSucceeded,
            { attemptId, requestId: prepared.requestId },
          );
        }
      } catch (error) {
        if (revocationDidSucceed) {
          await ctx.runMutation(
            internal.productAccountDeletionData.releaseDeletionAttempt,
            { attemptId, requestId: prepared.requestId },
          );
          throw retryableAppleError();
        }
        if (
          error instanceof Error &&
          error.message ===
            'Apple authorization revocation is temporarily unavailable'
        ) {
          await ctx.runMutation(
            internal.productAccountDeletionData.releaseDeletionAttempt,
            { attemptId, requestId: prepared.requestId },
          );
          throw error;
        }
        await ctx.runMutation(
          internal.productAccountDeletionData.abortDeletion,
          {
            attemptId,
            requestId: prepared.requestId,
          },
        );
        throw error;
      }
      await ctx.runMutation(
        internal.productAccountDeletionData.markRevocationComplete,
        { attemptId, requestId: prepared.requestId },
      );
    }

    const complete = await deleteBatches(ctx, prepared.requestId);
    if (!complete) {
      await ctx.scheduler.runAfter(
        0,
        internal.productAccountDeletionData.continueProductAccountDeletion,
        { requestId: prepared.requestId },
      );
    }
    return { deleted: complete };
  },
  returns: productAccountDeletionResponseValidator,
});
