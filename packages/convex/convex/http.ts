import type { EncryptedProductSyncPayloadBody } from '@private-email/contracts/productSync';

import { httpRouter } from 'convex/server';

import type { ActionCtx } from './_generated/server.js';

import { internal } from './_generated/api.js';
import { httpAction } from './_generated/server.js';
import { decodeGmailPushEnvelope } from './gmailPushPayload.js';

const http = httpRouter();
const maxMicrosoftGraphNotificationsPerRequest = 100;
const recentAuthenticationMaximumAgeSeconds = 5 * 60;

type RecoveryMaterialRequest = Readonly<{
  encryptedPayload: EncryptedProductSyncPayloadBody;
  expectedUpdatedAt?: number;
  trustedDeviceId: string;
}>;

type MicrosoftGraphNotification = Readonly<{
  clientState: string;
  subscriptionId: string;
}>;

function isUnknownRecord(
  value: unknown,
): value is Readonly<Record<string, unknown>> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

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
): Readonly<Record<string, unknown>> | null {
  const segments = identityToken.split('.');
  const claimsSegment = segments.length === 3 ? segments[1] : undefined;
  if (claimsSegment === undefined) {
    return null;
  }
  const claimsJSON = decodeBase64Url(claimsSegment);
  if (claimsJSON === null) {
    return null;
  }
  try {
    const claims: unknown = JSON.parse(claimsJSON);
    return isUnknownRecord(claims) ? claims : null;
  } catch {
    return null;
  }
}

function recentlyIssuedForIdentity(
  claims: Readonly<Record<string, unknown>>,
  identity: Readonly<{ issuer: string; subject: string }>,
): boolean {
  if (
    claims.iss !== identity.issuer ||
    claims.sub !== identity.subject ||
    typeof claims.iat !== 'number' ||
    !Number.isFinite(claims.iat)
  ) {
    return false;
  }
  const now = Math.floor(Date.now() / 1000);
  return (
    claims.iat <= now &&
    now - claims.iat <= recentAuthenticationMaximumAgeSeconds
  );
}

function decodeRecoveryMaterialRequest(
  value: unknown,
): RecoveryMaterialRequest | null {
  if (!isUnknownRecord(value) || !isUnknownRecord(value.encryptedPayload)) {
    return null;
  }
  const { encryptedPayload } = value;
  if (
    encryptedPayload.algorithm !== 'AES-GCM-256' ||
    typeof encryptedPayload.ciphertextBase64 !== 'string' ||
    typeof encryptedPayload.keyVersion !== 'number' ||
    typeof encryptedPayload.nonceBase64 !== 'string' ||
    typeof encryptedPayload.schemaVersion !== 'number' ||
    typeof encryptedPayload.tagBase64 !== 'string' ||
    typeof value.trustedDeviceId !== 'string' ||
    (value.expectedUpdatedAt !== undefined &&
      typeof value.expectedUpdatedAt !== 'number')
  ) {
    return null;
  }
  return {
    encryptedPayload: {
      algorithm: encryptedPayload.algorithm,
      ciphertextBase64: encryptedPayload.ciphertextBase64,
      keyVersion: encryptedPayload.keyVersion,
      nonceBase64: encryptedPayload.nonceBase64,
      schemaVersion: encryptedPayload.schemaVersion,
      tagBase64: encryptedPayload.tagBase64,
    },
    expectedUpdatedAt: value.expectedUpdatedAt,
    trustedDeviceId: value.trustedDeviceId,
  };
}

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
  const args = decodeRecoveryMaterialRequest(body);
  if (args === null) {
    return new Response('Invalid Recovery Key material', { status: 400 });
  }

  const payload = await ctx.runMutation(
    internal.productSync.replaceRecoveryMaterialIfUnchanged,
    args,
  );
  return Response.json(payload);
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
  if (!isUnknownRecord(value) || !Array.isArray(value.value)) {
    return [];
  }
  const candidates: unknown[] = value.value.slice(
    0,
    maxMicrosoftGraphNotificationsPerRequest,
  );
  return candidates.flatMap((candidate) => {
    if (
      !isUnknownRecord(candidate) ||
      typeof candidate.clientState !== 'string' ||
      typeof candidate.subscriptionId !== 'string'
    ) {
      return [];
    }
    return [
      {
        clientState: candidate.clientState,
        subscriptionId: candidate.subscriptionId,
      },
    ];
  });
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
