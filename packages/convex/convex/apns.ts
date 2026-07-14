'use node';

import type { ClientHttp2Session } from 'node:http2';

import { createPrivateKey, sign } from 'node:crypto';
import { once } from 'node:events';
import { connect } from 'node:http2';

import { v } from 'convex/values';

import { internal } from './_generated/api.js';
import { internalAction } from './_generated/server.js';
import { gmailWakeupPayload } from './gmailPushPayload.js';

const apnsEnvironmentValidator = v.union(
  v.literal('production'),
  v.literal('sandbox'),
);

const apnsRequestTimeoutMs = 10_000;

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

class ApnsRequestError extends Error {
  public readonly status: number;

  public constructor(status: number, responseBody: string) {
    super(`APNs request failed (${status}): ${responseBody}`);
    this.name = 'ApnsRequestError';
    this.status = status;
  }
}

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

async function sendWakeup(
  delivery: ApnsDelivery,
  client: ClientHttp2Session, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- HTTP/2 sessions issue mutable request streams.
): Promise<void> {
  const timeoutController = new AbortController();
  const timeout = setTimeout(() => {
    timeoutController.abort();
  }, apnsRequestTimeoutMs);
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
    const responseArguments: unknown = await (async () => {
      try {
        const response: unknown = await once(request, 'response', {
          signal: timeoutController.signal,
        });
        return response;
      } catch (error) {
        if (timeoutController.signal.aborted) {
          request.close();
          throw new Error('APNs request timed out', { cause: error });
        }
        throw error;
      }
    })();
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
      throw new ApnsRequestError(status, responseBody);
    }
  } finally {
    clearTimeout(timeout);
  }
}

function apnsAuthority(environment: ApnsDelivery['apnsEnvironment']): string {
  return environment === 'production'
    ? 'https://api.push.apple.com'
    : 'https://api.sandbox.push.apple.com';
}

export const deliverGmailWakeups = internalAction({
  args: {
    historyId: v.string(),
    recipients: v.array(
      v.object({
        apnsEnvironment: apnsEnvironmentValidator,
        apnsToken: v.string(),
        trustedDeviceId: v.id('trustedDevices'),
      }),
    ),
  },
  handler: async (ctx, args) => {
    const configuration = apnsConfiguration();
    const authorization = providerToken(configuration);
    const payload = JSON.stringify(gmailWakeupPayload(args.historyId));
    const clients = new Map<
      ApnsDelivery['apnsEnvironment'],
      ClientHttp2Session
    >();
    const clientFor = (
      environment: ApnsDelivery['apnsEnvironment'],
    ): ClientHttp2Session => {
      const existing = clients.get(environment);
      if (existing !== undefined) {
        return existing;
      }
      const client = connect(apnsAuthority(environment));
      client.on('error', (error) => {
        console.error('APNs HTTP/2 session failed', error);
      });
      clients.set(environment, client);
      return client;
    };

    const results = await Promise.allSettled(
      args.recipients.map(async (recipient) =>
        sendWakeup(
          {
            apnsEnvironment: recipient.apnsEnvironment,
            apnsToken: recipient.apnsToken,
            authorization,
            configuration,
            payload,
          },
          clientFor(recipient.apnsEnvironment),
        ),
      ),
    ).finally(() => {
      for (const client of clients.values()) {
        client.close();
      }
    });

    await Promise.all(
      results.map(async (result, index) => {
        if (result.status === 'fulfilled') {
          return;
        }
        console.error('APNs wakeup delivery failed', result.reason);
        const recipient = args.recipients[index];
        if (
          recipient !== undefined &&
          result.reason instanceof ApnsRequestError &&
          result.reason.status === 410
        ) {
          await ctx.runMutation(internal.pushRelay.clearStaleDevice, {
            apnsToken: recipient.apnsToken,
            trustedDeviceId: recipient.trustedDeviceId,
          });
        }
      }),
    );

    return null;
  },
  returns: v.null(),
});
