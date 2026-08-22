'use node';

import type { ClientHttp2Session, ClientHttp2Stream } from 'node:http2';

import { createPrivateKey, sign } from 'node:crypto';
import { once } from 'node:events';
import { connect } from 'node:http2';

import { v } from 'convex/values';

import type { Id } from './_generated/dataModel.js';
import type { ActionCtx } from './_generated/server.js';

import { internal } from './_generated/api.js';
import { internalAction } from './_generated/server.js';
import { gmailWakeupPayload } from './gmailPushPayload.js';

const apnsEnvironmentValidator = v.union(
  v.literal('production'),
  v.literal('sandbox'),
);

const apnsRequestTimeoutMs = 10_000;
const permanentApnsFailureStatuses = new Set([400, 403, 404, 405, 410, 413]);

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

type StaleTokenRecipient = Readonly<{
  apnsEnvironment: 'production' | 'sandbox';
  apnsToken: string;
  pushCleanupGeneration?: number;
  trustedDeviceId: Id<'trustedDevices'>;
}>;

type GmailWakeupRecipient = StaleTokenRecipient &
  Readonly<{
    routeId: string;
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
    // oxlint-disable-next-line eslint/no-use-before-define -- Function declarations are hoisted.
    const request = apnsRequest(client, delivery);
    // oxlint-disable-next-line eslint/no-use-before-define -- Function declarations are hoisted.
    const rawHeaders = await apnsResponseHeaders(
      request,
      timeoutController.signal,
    );
    // oxlint-disable-next-line eslint/no-use-before-define -- Function declarations are hoisted.
    const responseBody = await apnsResponseBody(
      request,
      timeoutController.signal,
    );
    // oxlint-disable-next-line eslint/no-use-before-define -- Function declarations are hoisted.
    const status = apnsResponseStatus(rawHeaders);
    if (status !== 200) {
      throw new ApnsRequestError(status, responseBody);
    }
  } finally {
    clearTimeout(timeout);
  }
}

function apnsRequest(
  client: ClientHttp2Session, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- HTTP/2 sessions issue mutable request streams.
  delivery: ApnsDelivery,
): ClientHttp2Stream {
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
  return request;
}

async function apnsResponseArguments(
  request: ClientHttp2Stream, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- HTTP/2 streams are mutable event emitters.
  signal: AbortSignal, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- AbortSignal is observed but not mutated.
): Promise<unknown> {
  try {
    const response: unknown = await once(request, 'response', { signal });
    return response;
  } catch (error) {
    if (signal.aborted) {
      request.close();
      throw new Error('APNs request timed out', { cause: error });
    }
    throw error;
  }
}

function firstApnsResponseArgument(responseArguments: unknown): unknown {
  if (!Array.isArray(responseArguments)) {
    throw new TypeError('APNs response headers required');
  }
  const headers: unknown[] = responseArguments;
  const [rawHeaders] = headers;
  if (rawHeaders === undefined) {
    throw new TypeError('APNs response headers required');
  }
  return rawHeaders;
}

function validateApnsResponseHeaders(rawHeaders: unknown): object {
  if (typeof rawHeaders !== 'object' || rawHeaders === null) {
    throw new TypeError('Invalid APNs response headers');
  }
  return rawHeaders;
}

async function apnsResponseHeaders(
  request: ClientHttp2Stream, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- HTTP/2 streams are mutable event emitters.
  signal: AbortSignal, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- AbortSignal is observed but not mutated.
): Promise<object> {
  const responseArguments = await apnsResponseArguments(request, signal);
  return validateApnsResponseHeaders(
    firstApnsResponseArgument(responseArguments),
  );
}

async function apnsResponseBody(
  request: ClientHttp2Stream, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- HTTP/2 streams are mutable event emitters.
  signal: AbortSignal, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- AbortSignal is observed but not mutated.
): Promise<string> {
  let responseBody = '';
  const onData = (chunk: unknown): void => {
    responseBody += String(chunk);
  };
  request.on('data', onData);
  try {
    await once(request, 'end', { signal });
    return responseBody;
  } catch (error) {
    if (signal.aborted) {
      request.close();
      throw new Error('APNs request timed out', { cause: error });
    }
    throw error;
  } finally {
    request.off('data', onData);
  }
}

function apnsResponseStatus(headers: object): number {
  const rawStatus: unknown = Reflect.get(headers, ':status');
  return typeof rawStatus === 'number' ? rawStatus : 0;
}

function isStaleTokenFailure(
  result: PromiseSettledResult<void>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Promise results are immutable inputs here.
): result is PromiseRejectedResult {
  return (
    result.status === 'rejected' &&
    result.reason instanceof ApnsRequestError &&
    result.reason.status === 410
  );
}

function isPermanentApnsFailure(
  result: PromiseSettledResult<void>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Promise results are immutable inputs here.
): boolean {
  return (
    result.status === 'rejected' &&
    result.reason instanceof ApnsRequestError &&
    permanentApnsFailureStatuses.has(result.reason.status)
  );
}

async function handleDeliveryResult(
  ctx: ActionCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex action context invokes mutations.
  result: PromiseSettledResult<void>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Promise results are immutable inputs here.
  recipient: // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Recipient data is treated as immutable input.
    | Readonly<{
        apnsEnvironment: 'production' | 'sandbox';
        apnsToken: string;
        pushCleanupGeneration?: number;
        trustedDeviceId: Id<'trustedDevices'>;
      }>
    | undefined,
): Promise<void> {
  if (result.status === 'fulfilled') {
    return;
  }
  console.error('APNs wakeup delivery failed', result.reason);
  // oxlint-disable-next-line eslint/no-use-before-define -- Helper extracts the cleanup target from a stale-token failure.
  const staleRecipient = staleTokenRecipient(result, recipient);
  if (staleRecipient === undefined) {
    return;
  }
  await ctx.runMutation(internal.pushRelay.clearStaleDevice, {
    apnsToken: staleRecipient.apnsToken,
    pushCleanupGeneration: staleRecipient.pushCleanupGeneration ?? 0,
    trustedDeviceId: staleRecipient.trustedDeviceId,
  });
}

function staleTokenRecipient(
  result: PromiseSettledResult<void>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Promise results are immutable inputs here.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Recipient data is immutable input.
  recipient: StaleTokenRecipient | undefined,
): StaleTokenRecipient | undefined {
  return recipient !== undefined && isStaleTokenFailure(result)
    ? recipient
    : undefined;
}

function apnsAuthority(environment: ApnsDelivery['apnsEnvironment']): string {
  return environment === 'production'
    ? 'https://api.push.apple.com'
    : 'https://api.sandbox.push.apple.com';
}

function microsoftGraphWakeupPayload(routeId: string): string {
  return JSON.stringify({
    aps: { 'content-available': 1 },
    provider: 'microsoft-graph',
    routeId,
  });
}

function scheduledSendWakeupPayload(
  revision: number,
  scheduleId: string,
): string {
  return JSON.stringify({
    aps: { 'content-available': 1 },
    provider: 'scheduled-send',
    revision,
    scheduleId,
  });
}

async function deliverWakeupBatch<Recipient extends StaleTokenRecipient>(
  ctx: ActionCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex action context invokes mutations.
  recipients: readonly Recipient[],
  payload: (recipient: Recipient) => string,
): Promise<ReadonlyArray<PromiseSettledResult<void>>> {
  const configuration = apnsConfiguration();
  const authorization = providerToken(configuration);
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
    recipients.map(async (recipient) =>
      sendWakeup(
        {
          apnsEnvironment: recipient.apnsEnvironment,
          apnsToken: recipient.apnsToken,
          authorization,
          configuration,
          payload: payload(recipient),
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
    results.map(async (result, index) =>
      handleDeliveryResult(ctx, result, recipients[index]),
    ),
  );
  return results;
}

async function deliverGmailWakeupBatch(
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex supplies its mutable action context.
  ctx: ActionCtx,
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex validates and owns the generated action arguments.
  args: Readonly<{
    historyId: string;
    recipients: readonly GmailWakeupRecipient[];
  }>,
): Promise<null> {
  await deliverWakeupBatch(ctx, args.recipients, (recipient) =>
    JSON.stringify(gmailWakeupPayload(args.historyId, recipient.routeId)),
  );
  return null;
}

export const deliverGmailWakeups = internalAction({
  args: {
    historyId: v.string(),
    recipients: v.array(
      v.object({
        apnsEnvironment: apnsEnvironmentValidator,
        apnsToken: v.string(),
        pushCleanupGeneration: v.optional(v.number()),
        routeId: v.string(),
        trustedDeviceId: v.id('trustedDevices'),
      }),
    ),
  },
  handler: deliverGmailWakeupBatch,
  returns: v.null(),
});

export const deliverQueuedGmailWakeups = internalAction({
  args: {
    historyId: v.string(),
    recipients: v.array(
      v.object({
        apnsEnvironment: apnsEnvironmentValidator,
        apnsToken: v.string(),
        pushCleanupGeneration: v.number(),
        routeId: v.string(),
        trustedDeviceId: v.id('trustedDevices'),
      }),
    ),
  },
  handler: async (ctx, args) => {
    const recipients = await ctx.runQuery(
      internal.pushRelay.revalidateGmailRecipients,
      { recipients: args.recipients },
    );
    if (recipients.length > 0) {
      await deliverGmailWakeupBatch(ctx, {
        historyId: args.historyId,
        recipients,
      });
    }
    return null;
  },
  returns: v.null(),
});

export const deliverMicrosoftGraphWakeup = internalAction({
  args: {
    routeId: v.id('mailProviderConnections'),
    scheduledAt: v.number(),
  },
  handler: async (ctx, args) => {
    const recipient = await ctx.runMutation(
      internal.pushRelay.claimMicrosoftGraphWakeup,
      args,
    );
    if (recipient === null) {
      return null;
    }
    let delivered = false;
    let terminalFailure = false;
    try {
      const result = await deliverWakeupBatch(ctx, [recipient], (target) =>
        microsoftGraphWakeupPayload(target.routeId),
      );
      const deliveryResult = result[0];
      if (deliveryResult === undefined) {
        throw new Error('APNs delivery produced no result');
      }
      delivered = deliveryResult.status === 'fulfilled';
      terminalFailure = isPermanentApnsFailure(deliveryResult);
    } catch (error) {
      console.error('APNs wakeup delivery failed', error);
    }
    await ctx.runMutation(internal.pushRelay.completeMicrosoftGraphWakeup, {
      delivered,
      routeId: args.routeId,
      scheduledAt: args.scheduledAt,
      terminalFailure,
    });
    return null;
  },
  returns: v.null(),
});

export const deliverScheduledSendWakeup = internalAction({
  args: {
    revision: v.number(),
    scheduleDocumentId: v.id('scheduledSends'),
  },
  handler: async (ctx, args) => {
    const recipients = await ctx.runMutation(
      internal.scheduledSend.claimWakeup,
      args,
    );
    if (recipients.length === 0) {
      return null;
    }
    try {
      await deliverWakeupBatch(ctx, recipients, (recipient) =>
        scheduledSendWakeupPayload(recipient.revision, recipient.scheduleId),
      );
    } catch (error) {
      console.error('Scheduled Send APNs wakeup delivery failed', error);
    }
    return null;
  },
  returns: v.null(),
});
