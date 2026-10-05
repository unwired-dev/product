import { httpRouter } from 'convex/server';
import { ConvexError } from 'convex/values';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type { ActionCtx } from './_generated/server.js';

import { internal } from './_generated/api.js';
import { env, httpAction } from './_generated/server.js';
import { decodeGmailPushEnvelope } from './gmailPushPayload.js';
import {
  trustedDeviceReconnectRequiredErrorCode,
  trustedDeviceRevokedErrorCode,
} from './productAccountAuth.js';
import { signInLinkErrorCodes } from './signInLinks.js';

const http = httpRouter();
const maxMicrosoftGraphNotificationsPerRequest = 100;
const recentAuthenticationMaximumAgeSeconds = 5 * 60;
const recentAuthenticationClockSkewSeconds = 5;

const RecentAuthenticationClaimsSchema = Schema.Struct({
  iat: Schema.Finite,
  iss: Schema.String,
  sub: Schema.String,
});
type RecentAuthenticationClaims = typeof RecentAuthenticationClaimsSchema.Type;
const decodeRecentAuthenticationClaims = Schema.decodeUnknownOption(
  Schema.fromJsonString(RecentAuthenticationClaimsSchema),
);

// Numbers keep the receiving mutation's v.number() domain, which admits non-finite values.
const EncryptedPayloadSchema = Schema.Struct({
  algorithm: Schema.Literal('AES-GCM-256'),
  ciphertextBase64: Schema.String,
  keyVersion: Schema.Number, // oxlint-disable-line effecttsgo/schema-number -- Matches v.number().
  nonceBase64: Schema.String,
  schemaVersion: Schema.Number, // oxlint-disable-line effecttsgo/schema-number -- Matches v.number().
  tagBase64: Schema.String,
});
const decodeRecoveryMaterialRequest = Schema.decodeUnknownOption(
  Schema.Struct({
    encryptedPayload: EncryptedPayloadSchema,
    expectedUpdatedAt: Schema.optionalKey(Schema.Number), // oxlint-disable-line effecttsgo/schema-number -- Matches v.number().
    trustedDeviceCredential: Schema.optionalKey(Schema.String),
    trustedDeviceId: Schema.String,
  }),
);
const decodeTrustedDeviceRevocationRequest = Schema.decodeUnknownOption(
  Schema.Struct({
    encryptedTransition: EncryptedPayloadSchema,
    expectedRecoveryUpdatedAt: Schema.Number, // oxlint-disable-line effecttsgo/schema-number -- Matches v.number().
    recoveryWrappedAccountKey: EncryptedPayloadSchema,
    trustedDeviceCredential: Schema.optionalKey(Schema.String),
    trustedDeviceId: Schema.String,
    trustedDeviceToRevokeId: Schema.String,
  }),
);

const decodeProductAccountDeletionRequest = Schema.decodeUnknownOption(
  Schema.Struct({
    appleClientId: Schema.optionalKey(Schema.String),
    // Required by an account that Sign in with Apple opens, so its authorization is revoked.
    authorizationCode: Schema.optionalKey(Schema.String),
    trustedDeviceCredential: Schema.optionalKey(Schema.String),
    trustedDeviceId: Schema.String,
  }),
);

const signInLinkProof = {
  trustedDeviceCredential: Schema.optionalKey(Schema.String),
  trustedDeviceId: Schema.String,
};
const decodeSignInLinkRequest = Schema.decodeUnknownOption(
  Schema.Struct({
    ...signInLinkProof,
    provider: Schema.Literals(['apple', 'google']),
  }),
);
const decodeSignInLinkCompletion = Schema.decodeUnknownOption(
  Schema.Struct({ ...signInLinkProof, linkTicket: Schema.String }),
);
const isSignInLinkFailure = Schema.is(
  Schema.Struct({ code: Schema.Literals(Object.values(signInLinkErrorCodes)) }),
);

const isTrustedDeviceAccessFailure = Schema.is(
  Schema.Struct({
    code: Schema.Literals([
      trustedDeviceRevokedErrorCode,
      trustedDeviceReconnectRequiredErrorCode,
    ]),
  }),
);

const MicrosoftGraphNotificationSchema = Schema.Struct({
  clientState: Schema.String,
  subscriptionId: Schema.String,
});
type MicrosoftGraphNotification = typeof MicrosoftGraphNotificationSchema.Type;
const decodeMicrosoftGraphNotification = Schema.decodeUnknownOption(
  MicrosoftGraphNotificationSchema,
);
const decodeMicrosoftGraphNotificationBatch = Schema.decodeUnknownOption(
  Schema.Struct({ value: Schema.Array(Schema.Unknown) }),
);

function decodeBase64Url(value: string): string | null {
  try {
    const encoded = value.replaceAll('-', '+').replaceAll('_', '/');
    const padded = encoded.padEnd(
      encoded.length + ((4 - (encoded.length % 4)) % 4),
      '=',
    );
    const bytes = Uint8Array.from(
      atob(padded),
      (character) => character.codePointAt(0) ?? 0,
    );
    return new TextDecoder().decode(bytes);
  } catch {
    return null;
  }
}

// fallow-ignore-next-line complexity -- Authentication parsing keeps every malformed form fail-closed.
function bearerToken(request: Request): string | null {
  const authorization = request.headers.get('authorization');
  if (authorization === null) {
    return null;
  }
  const [scheme, token, ...remainder] = authorization.split(' ');
  return scheme?.toLowerCase() === 'bearer' && token && remainder.length === 0
    ? token
    : null;
}

function identityTokenClaims(
  identityToken: string,
): RecentAuthenticationClaims | null {
  const segments = identityToken.split('.');
  const claimsSegment = segments.length === 3 ? segments[1] : undefined;
  const claimsJSON =
    claimsSegment === undefined ? null : decodeBase64Url(claimsSegment);
  return claimsJSON === null
    ? null
    : Option.getOrNull(decodeRecentAuthenticationClaims(claimsJSON));
}

function recentlyIssuedForIdentity(
  claims: RecentAuthenticationClaims,
  identity: Readonly<{ issuer: string; subject: string }>,
): boolean {
  if (claims.iss !== identity.issuer || claims.sub !== identity.subject) {
    return false;
  }
  const now = Math.floor(Date.now() / 1000);
  return (
    claims.iat <= now + recentAuthenticationClockSkewSeconds &&
    now - claims.iat <= recentAuthenticationMaximumAgeSeconds
  );
}

// fallow-ignore-next-line complexity -- Each Trusted Device access failure keeps its distinct client response.
function trustedDeviceFailureResponse(error: unknown): Response | null {
  const failure: unknown =
    error instanceof ConvexError ? error.data : undefined;
  if (isTrustedDeviceAccessFailure(failure)) {
    return Response.json({ code: failure.code }, { status: 403 });
  }
  if (
    error instanceof Error &&
    error.message.includes('Trusted device required')
  ) {
    return new Response('Trusted device required', { status: 403 });
  }
  return null;
}

// fallow-ignore-next-line complexity -- Authentication and payload failures intentionally remain distinct responses.
async function replaceRecoveryMaterialResponse(
  ctx: ActionCtx,
  request: Request,
): Promise<Response> {
  if (!(await recentlyAuthenticatedRequest(ctx, request))) {
    return new Response('Recent authentication required', { status: 401 });
  }

  const body: unknown = await request.json().catch(() => null);
  const decoded = decodeRecoveryMaterialRequest(body);
  if (Option.isNone(decoded)) {
    return new Response('Invalid Recovery Key material', { status: 400 });
  }
  const args = decoded.value;

  try {
    const payload = await ctx.runMutation(
      internal.productSync.replaceRecoveryMaterialIfUnchanged,
      args,
    );
    return Response.json(payload);
  } catch (error) {
    const trustedDeviceFailure = trustedDeviceFailureResponse(error);
    if (trustedDeviceFailure !== null) {
      return trustedDeviceFailure;
    }
    if (
      error instanceof Error &&
      error.message.includes('Product Sync key material already exists')
    ) {
      return new Response('Product Sync key material already exists', {
        status: 409,
      });
    }
    throw error;
  }
}

// fallow-ignore-next-line complexity -- Authentication, payload and Trusted Device failures intentionally remain distinct responses.
async function revokeTrustedDeviceResponse(
  ctx: ActionCtx,
  request: Request,
): Promise<Response> {
  if (!(await recentlyAuthenticatedRequest(ctx, request))) {
    return new Response('Recent authentication required', { status: 401 });
  }
  const body: unknown = await request.json().catch(() => null);
  const decoded = decodeTrustedDeviceRevocationRequest(body);
  if (Option.isNone(decoded)) {
    return new Response('Invalid Trusted Device revocation', { status: 400 });
  }
  try {
    return Response.json(
      await ctx.runMutation(
        internal.productAccount.revokeTrustedDevice,
        decoded.value,
      ),
    );
  } catch (error) {
    const trustedDeviceFailure = trustedDeviceFailureResponse(error);
    if (trustedDeviceFailure !== null) {
      return trustedDeviceFailure;
    }
    throw error;
  }
}

// fallow-ignore-next-line complexity -- Authentication, payload and Trusted Device failures intentionally remain distinct responses.
async function deleteProductAccountResponse(
  ctx: ActionCtx,
  request: Request,
): Promise<Response> {
  if (!(await recentlyAuthenticatedRequest(ctx, request))) {
    return new Response('Recent authentication required', { status: 401 });
  }
  const body: unknown = await request.json().catch(() => null);
  const decoded = decodeProductAccountDeletionRequest(body);
  if (Option.isNone(decoded)) {
    return new Response('Invalid Product Account deletion', { status: 400 });
  }
  try {
    return Response.json(
      await ctx.runAction(
        internal.productAccountDeletion
          .deleteRecentlyAuthenticatedProductAccount,
        decoded.value,
      ),
    );
  } catch (error) {
    const trustedDeviceFailure = trustedDeviceFailureResponse(error);
    if (trustedDeviceFailure !== null) {
      return trustedDeviceFailure;
    }
    if (
      error instanceof Error &&
      error.message.includes(
        'Recent Sign in with Apple authorization is required',
      )
    ) {
      return new Response(
        'Recent Sign in with Apple authorization is required',
        { status: 409 },
      );
    }
    throw error;
  }
}

function signInLinkFailure(code: string, status: number): Response {
  return Response.json({ status: 'error', errorData: { code } }, { status });
}

async function recentlyAuthenticatedRequest(
  ctx: ActionCtx,
  request: Request,
): Promise<boolean> {
  // Convex validates this exact bearer token's signature, issuer and audience.
  // Reserved OIDC claims such as iat are not exposed on getUserIdentity().
  // HTTP actions throw, rather than return null, for a missing or invalid token.
  const identity = await ctx.auth.getUserIdentity().catch(() => null);
  const token = bearerToken(request);
  const claims = token === null ? null : identityTokenClaims(token);
  return (
    identity !== null &&
    claims !== null &&
    recentlyIssuedForIdentity(claims, identity)
  );
}

async function signInLinkMutationResponse(
  ctx: ActionCtx,
  body: unknown,
  operation: 'request' | 'complete',
): Promise<Response> {
  if (operation === 'request') {
    const decoded = decodeSignInLinkRequest(body);
    if (Option.isNone(decoded)) {
      return new Response('Invalid sign-in link request', { status: 400 });
    }
    const value = await ctx.runMutation(
      internal.signInLinks.request,
      decoded.value,
    );
    return Response.json({ status: 'success', value });
  }
  const decoded = decodeSignInLinkCompletion(body);
  if (Option.isNone(decoded)) {
    return new Response('Invalid sign-in link completion', { status: 400 });
  }
  const value = await ctx.runMutation(
    internal.signInLinks.complete,
    decoded.value,
  );
  return Response.json({ status: 'success', value });
}

function signInLinkErrorResponse(error: unknown): Response {
  const failure: unknown =
    error instanceof ConvexError ? error.data : undefined;
  if (isSignInLinkFailure(failure)) {
    return signInLinkFailure(failure.code, 409);
  }
  if (isTrustedDeviceAccessFailure(failure)) {
    return signInLinkFailure(failure.code, 403);
  }
  throw error;
}

async function signInLinkResponse(
  ctx: ActionCtx,
  request: Request,
  operation: 'request' | 'complete',
): Promise<Response> {
  if (!(await recentlyAuthenticatedRequest(ctx, request))) {
    return signInLinkFailure(signInLinkErrorCodes.recentAuthentication, 401);
  }
  const body: unknown = await request.json().catch(() => null);
  try {
    return await signInLinkMutationResponse(ctx, body, operation);
  } catch (error) {
    return signInLinkErrorResponse(error);
  }
}

function decodeRequestEnvelope(
  envelope: unknown,
): ReturnType<typeof decodeGmailPushEnvelope> | null {
  try {
    return decodeGmailPushEnvelope(envelope ?? {});
  } catch {
    return null;
  }
}

function hasValidVerificationToken(request: Request): boolean {
  const verificationToken = env.GMAIL_PUSH_VERIFICATION_TOKEN;
  const requestToken = new URL(request.url).searchParams.get('token');
  return (
    verificationToken !== undefined &&
    verificationToken.length > 0 &&
    requestToken === verificationToken
  );
}

function microsoftGraphNotifications(
  value: unknown,
): MicrosoftGraphNotification[] {
  const candidates = Option.match(
    decodeMicrosoftGraphNotificationBatch(value),
    {
      onNone: () => [],
      onSome: (batch) =>
        batch.value.slice(0, maxMicrosoftGraphNotificationsPerRequest),
    },
  );
  return candidates.flatMap((candidate) =>
    Option.toArray(decodeMicrosoftGraphNotification(candidate)),
  );
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

function microsoftGraphValidationResponse(url: URL): Response | null {
  const validationToken = url.searchParams.get('validationToken');
  if (validationToken === null) {
    return null;
  }
  return new Response(validationToken, {
    headers: { 'content-type': 'text/plain' },
    status: 200,
  });
}

function microsoftGraphRouteId(url: URL): string | null {
  const routeId = url.searchParams.get('routeId');
  return routeId?.length === 0 ? null : routeId;
}

async function enqueueMicrosoftGraphNotifications(
  ctx: ActionCtx,
  routeId: string,
  notifications: readonly MicrosoftGraphNotification[],
): Promise<void> {
  const uniqueNotifications = new Map<
    string,
    { clientStateDigest: string; subscriptionId: string }
  >();
  for (const notification of notifications) {
    const digest = await sha256Hex(notification.clientState);
    uniqueNotifications.set(`${notification.subscriptionId}:${digest}`, {
      clientStateDigest: digest,
      subscriptionId: notification.subscriptionId,
    });
  }
  for (const notification of uniqueNotifications.values()) {
    await ctx.runMutation(internal.pushRelay.enqueueMicrosoftGraphWakeup, {
      clientStateDigest: notification.clientStateDigest,
      routeId,
      subscriptionId: notification.subscriptionId,
    });
  }
}

async function microsoftGraphPushResponse(
  ctx: ActionCtx,
  request: Request,
): Promise<Response> {
  const url = new URL(request.url);
  const validationResponse = microsoftGraphValidationResponse(url);
  if (validationResponse !== null) {
    return validationResponse;
  }
  const routeId = microsoftGraphRouteId(url);
  if (routeId === null) {
    return new Response('Microsoft Graph route required', { status: 400 });
  }
  const payload: unknown = await request.json().catch(() => null);
  const notifications = microsoftGraphNotifications(payload);
  if (notifications.length === 0) {
    return new Response('Invalid Microsoft Graph push', { status: 400 });
  }
  await enqueueMicrosoftGraphNotifications(ctx, routeId, notifications);
  return new Response(null, { status: 202 });
}

http.route({
  path: '/gmail/push',
  method: 'POST',
  handler: httpAction(async (ctx, request) => {
    if (!hasValidVerificationToken(request)) {
      return new Response('Unauthorized', { status: 401 });
    }

    const envelope: unknown = await request.json().catch(() => null);
    const metadata = decodeRequestEnvelope(envelope);
    if (metadata === null) {
      return new Response('Invalid Gmail push', { status: 400 });
    }

    await ctx.runAction(
      internal.pushRelay.enqueueGmailWakeupsFromMetadata,
      metadata,
    );
    return new Response(null, { status: 204 });
  }),
});

http.route({
  path: '/sign-in-links/request',
  method: 'POST',
  handler: httpAction((ctx, request) =>
    signInLinkResponse(ctx, request, 'request'),
  ),
});
http.route({
  path: '/sign-in-links/complete',
  method: 'POST',
  handler: httpAction((ctx, request) =>
    signInLinkResponse(ctx, request, 'complete'),
  ),
});

http.route({
  path: '/product-sync/recovery-material',
  method: 'POST',
  handler: httpAction(replaceRecoveryMaterialResponse),
});

http.route({
  path: '/trusted-devices/revoke',
  method: 'POST',
  handler: httpAction(revokeTrustedDeviceResponse),
});

http.route({
  path: '/product-account/delete',
  method: 'POST',
  handler: httpAction(deleteProductAccountResponse),
});

http.route({
  path: '/microsoft-graph/push',
  method: 'POST',
  handler: httpAction(microsoftGraphPushResponse),
});

export default http;
