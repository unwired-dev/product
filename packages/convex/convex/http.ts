import { httpRouter } from 'convex/server';
import { ConvexError } from 'convex/values';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type { ActionCtx } from './_generated/server.js';

import { internal } from './_generated/api.js';
import { httpAction } from './_generated/server.js';
import { decodeGmailPushEnvelope } from './gmailPushPayload.js';
import {
  trustedDeviceReconnectRequiredErrorCode,
  trustedDeviceRevokedErrorCode,
} from './productAccountAuth.js';

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
const decodeRecoveryMaterialRequest = Schema.decodeUnknownOption(
  Schema.Struct({
    encryptedPayload: Schema.Struct({
      algorithm: Schema.Literal('AES-GCM-256'),
      ciphertextBase64: Schema.String,
      keyVersion: Schema.Number, // oxlint-disable-line effecttsgo/schema-number -- Matches v.number().
      nonceBase64: Schema.String,
      schemaVersion: Schema.Number, // oxlint-disable-line effecttsgo/schema-number -- Matches v.number().
      tagBase64: Schema.String,
    }),
    expectedUpdatedAt: Schema.optionalKey(Schema.Number), // oxlint-disable-line effecttsgo/schema-number -- Matches v.number().
    trustedDeviceCredential: Schema.optionalKey(Schema.String),
    trustedDeviceId: Schema.String,
  }),
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
function bearerToken(
  request: Request, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Request is inspected but not mutated.
): string | null {
  const authorization = request.headers.get('authorization');
  if (authorization === null) {
    return null;
  }
  const [scheme, token, ...remainder] = authorization.split(' ');
  return scheme?.toLowerCase() === 'bearer' && token && remainder.length === 0
    ? token
    : null;
}

function appleIdentityTokenClaims(
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

// fallow-ignore-next-line complexity -- Authentication and payload failures intentionally remain distinct responses.
async function replaceRecoveryMaterialResponse(
  ctx: ActionCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  request: Request, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Request is inspected but not mutated.
): Promise<Response> {
  const identity = await ctx.auth.getUserIdentity();
  const token = bearerToken(request);
  const claims = token === null ? null : appleIdentityTokenClaims(token);
  if (
    identity === null ||
    claims === null ||
    !recentlyIssuedForIdentity(claims, identity)
  ) {
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
    throw error;
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

function hasValidVerificationToken(
  request: Request, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Request is inspected but not mutated.
): boolean {
  // oxlint-disable-next-line node/no-process-env -- Convex HTTP actions read deployment env at runtime.
  const verificationToken = process.env.GMAIL_PUSH_VERIFICATION_TOKEN;
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

function microsoftGraphValidationResponse(
  url: URL, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- URL is inspected but not mutated.
): Response | null {
  const validationToken = url.searchParams.get('validationToken');
  if (validationToken === null) {
    return null;
  }
  return new Response(validationToken, {
    headers: { 'content-type': 'text/plain' },
    status: 200,
  });
}

function microsoftGraphRouteId(
  url: URL, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- URL is inspected but not mutated.
): string | null {
  const routeId = url.searchParams.get('routeId');
  return routeId?.length === 0 ? null : routeId;
}

async function enqueueMicrosoftGraphNotifications(
  ctx: ActionCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
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
  ctx: ActionCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  request: Request, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Request is inspected but not mutated.
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
  path: '/product-sync/recovery-material',
  method: 'POST',
  handler: httpAction(replaceRecoveryMaterialResponse),
});

http.route({
  path: '/microsoft-graph/push',
  method: 'POST',
  handler: httpAction(microsoftGraphPushResponse),
});

export default http;
