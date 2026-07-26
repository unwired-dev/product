import { httpRouter } from 'convex/server';

import { internal } from './_generated/api.js';
import { httpAction } from './_generated/server.js';
import { decodeGmailPushEnvelope } from './gmailPushPayload.js';

const http = httpRouter();

type MicrosoftGraphNotification = Readonly<{
  clientState: string;
  subscriptionId: string;
}>;

function isUnknownRecord(
  value: unknown,
): value is Readonly<Record<string, unknown>> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
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
  const candidates: unknown[] = value.value;
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
  path: '/microsoft-graph/push',
  method: 'POST',
  handler: httpAction(async (ctx, request) => {
    const url = new URL(request.url);
    const validationToken = url.searchParams.get('validationToken');
    if (validationToken !== null) {
      return new Response(validationToken, {
        headers: { 'content-type': 'text/plain' },
        status: 200,
      });
    }

    const routeId = url.searchParams.get('routeId');
    if (routeId === null || routeId.length === 0) {
      return new Response('Microsoft Graph route required', { status: 400 });
    }
    const payload: unknown = await request.json().catch(() => null);
    const notifications = microsoftGraphNotifications(payload);
    if (notifications.length === 0) {
      return new Response('Invalid Microsoft Graph push', { status: 400 });
    }
    await Promise.all(
      notifications.map(async (notification) =>
        ctx.runMutation(internal.pushRelay.enqueueMicrosoftGraphWakeup, {
          clientStateDigest: await sha256Hex(notification.clientState),
          routeId,
          subscriptionId: notification.subscriptionId,
        }),
      ),
    );
    return new Response(null, { status: 202 });
  }),
});

export default http;
