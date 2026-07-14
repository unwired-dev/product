import { httpRouter } from 'convex/server';

import { internal } from './_generated/api.js';
import { httpAction } from './_generated/server.js';
import { decodeGmailPushEnvelope } from './gmailPushPayload.js';

const http = httpRouter();

function decodeRequestEnvelope(
  envelope: unknown,
): ReturnType<typeof decodeGmailPushEnvelope> | null {
  try {
    return decodeGmailPushEnvelope(envelope ?? {});
  } catch {
    return null;
  }
}

http.route({
  path: '/gmail/push',
  method: 'POST',
  handler: httpAction(async (ctx, request) => {
    // oxlint-disable-next-line node/no-process-env -- Convex HTTP actions read deployment env at runtime.
    const verificationToken = process.env.GMAIL_PUSH_VERIFICATION_TOKEN;
    const requestToken = new URL(request.url).searchParams.get('token');
    if (
      verificationToken === undefined ||
      verificationToken.length === 0 ||
      requestToken !== verificationToken
    ) {
      return new Response('Unauthorized', { status: 401 });
    }

    const envelope: unknown = await request.json().catch(() => null);
    const metadata = decodeRequestEnvelope(envelope);
    if (metadata === null) {
      return new Response('Invalid Gmail push', { status: 400 });
    }

    await ctx.runMutation(internal.pushRelay.enqueueGmailWakeups, metadata);
    return new Response(null, { status: 204 });
  }),
});

export default http;
