'use node';

import { createPrivateKey, sign } from 'node:crypto';
import { once } from 'node:events';
import { connect } from 'node:http2';

import { v } from 'convex/values';

import { internalAction } from './_generated/server.js';
import { gmailWakeupPayload } from './gmailPushPayload.js';

const apnsEnvironmentValidator = v.union(
  v.literal('production'),
  v.literal('sandbox'),
);

type ApnsConfiguration = Readonly<{
  keyId: string;
  privateKey: string;
  teamId: string;
  topic: string;
}>;

type ApnsDelivery = Readonly<{
  apnsEnvironment: 'production' | 'sandbox';
  apnsToken: string;
  authorization: string;
  configuration: ApnsConfiguration;
  payload: string;
}>;

function requiredEnvironmentValue(name: string): string {
  // oxlint-disable-next-line node/no-process-env -- Convex actions read deployment env at runtime.
  const value = process.env[name];
  if (value === undefined || value.length === 0) {
    throw new Error(`${name} is required`);
  }
  return value;
}

function apnsConfiguration(): ApnsConfiguration {
  return {
    keyId: requiredEnvironmentValue('APNS_KEY_ID'),
    privateKey: requiredEnvironmentValue('APNS_PRIVATE_KEY').replaceAll(
      String.raw`\n`,
      '\n',
    ),
    teamId: requiredEnvironmentValue('APNS_TEAM_ID'),
    topic: requiredEnvironmentValue('APNS_TOPIC'),
  };
}

function providerToken(configuration: ApnsConfiguration): string {
  const header = Buffer.from(
    JSON.stringify({ alg: 'ES256', kid: configuration.keyId }),
  ).toString('base64url');
  const claims = Buffer.from(
    JSON.stringify({
      iss: configuration.teamId,
      iat: Math.floor(Date.now() / 1000),
    }),
  ).toString('base64url');
  const unsignedToken = `${header}.${claims}`;
  const signature = sign('sha256', Buffer.from(unsignedToken), {
    dsaEncoding: 'ieee-p1363',
    key: createPrivateKey(configuration.privateKey),
  }).toString('base64url');

  return `${unsignedToken}.${signature}`;
}

async function sendWakeup(delivery: ApnsDelivery): Promise<void> {
  const authority =
    delivery.apnsEnvironment === 'production'
      ? 'https://api.push.apple.com'
      : 'https://api.sandbox.push.apple.com';
  const client = connect(authority);

  try {
    let responseBody = '';
    const request = client.request({
      ':method': 'POST',
      ':path': `/3/device/${delivery.apnsToken}`,
      authorization: `bearer ${delivery.authorization}`,
      'apns-priority': '5',
      'apns-push-type': 'background',
      'apns-topic': delivery.configuration.topic,
      'content-type': 'application/json',
    });

    request.setEncoding('utf8');
    request.end(delivery.payload);
    const responseArguments: unknown = await once(request, 'response');
    if (!Array.isArray(responseArguments) || responseArguments.length === 0) {
      throw new TypeError('APNs response headers required');
    }
    // oxlint-disable-next-line eslint/prefer-destructuring -- Event arguments are validated from unknown below.
    const rawHeaders: unknown = responseArguments[0];
    if (typeof rawHeaders !== 'object' || rawHeaders === null) {
      throw new TypeError('Invalid APNs response headers');
    }
    for await (const chunk of request) {
      responseBody += String(chunk);
    }
    const rawStatus: unknown = Reflect.get(rawHeaders, ':status');
    const status = typeof rawStatus === 'number' ? rawStatus : 0;
    if (status !== 200) {
      throw new Error(`APNs request failed (${status}): ${responseBody}`);
    }
  } finally {
    client.close();
  }
}

export const deliverGmailWakeups = internalAction({
  args: {
    historyId: v.string(),
    recipients: v.array(
      v.object({
        apnsEnvironment: apnsEnvironmentValidator,
        apnsToken: v.string(),
      }),
    ),
  },
  handler: async (_ctx, args) => {
    const configuration = apnsConfiguration();
    const authorization = providerToken(configuration);
    const payload = JSON.stringify(gmailWakeupPayload(args.historyId));

    await Promise.all(
      args.recipients.map(async (recipient) =>
        sendWakeup({
          apnsEnvironment: recipient.apnsEnvironment,
          apnsToken: recipient.apnsToken,
          authorization,
          configuration,
          payload,
        }),
      ),
    );

    return null;
  },
  returns: v.null(),
});
