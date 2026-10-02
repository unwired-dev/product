'use node';

import type { ClientHttp2Session, ClientHttp2Stream } from 'node:http2';

import { createPrivateKey, sign } from 'node:crypto';
import { once } from 'node:events';
import { connect } from 'node:http2';

import { v } from 'convex/values';
import * as Cause from 'effect/Cause';
import * as Clock from 'effect/Clock';
import * as Config from 'effect/Config';
import * as Effect from 'effect/Effect';
import * as Exit from 'effect/Exit';
import * as Option from 'effect/Option';
import * as Predicate from 'effect/Predicate';
import * as Result from 'effect/Result';
import * as Schema from 'effect/Schema';

import type { Id } from './_generated/dataModel.js';
import type { ActionCtx } from './_generated/server.js';

import { internal } from './_generated/api.js';
import { internalAction } from './_generated/server.js';
import {
  call,
  CallFailed,
  failureDiagnostic,
  runConvexProgram,
} from './effectRuntime.js';
import { gmailWakeupPayload } from './gmailPushPayload.js';

const apnsEnvironmentValidator = v.union(
  v.literal('production'),
  v.literal('sandbox'),
);

const apnsRequestTimeoutMs = 10_000;
const scheduledWakeupDeviceLimit = 100;
const permanentApnsFailureStatuses = new Set([400, 403, 404, 405, 410, 413]);

type ApnsEnvironment = 'production' | 'sandbox';

type ApnsConfiguration = Readonly<{
  keyId: string;
  privateKey: string;
  teamId: string;
  topic: string;
}>;

type ApnsDelivery = Readonly<{
  apnsToken: string;
  authorization: string;
  configuration: ApnsConfiguration;
  payload: string;
}>;

type StaleTokenRecipient = Readonly<{
  apnsEnvironment: ApnsEnvironment;
  apnsToken: string;
  pushCleanupGeneration?: number;
  trustedDeviceId: Id<'trustedDevices'>;
}>;

type GmailWakeupRecipient = StaleTokenRecipient &
  Readonly<{
    routeId: string;
  }>;

type ScheduledSendWakeupRecipient = StaleTokenRecipient &
  Readonly<{
    revision: number;
    scheduleId: string;
  }>;

type ScheduledSendWakeupPage = Readonly<{
  inspectedDeviceCount: number;
  isDone: boolean;
  nextCursor: string | null;
  recipients: readonly ScheduledSendWakeupRecipient[];
}>;

// Apple's documented APNs rejection reasons. Logs carry only these, never the body.
const ApnsRejectionReason = Schema.Literals([
  'BadCollapseId',
  'BadDeviceToken',
  'BadEnvironmentKeyInToken',
  'BadExpirationDate',
  'BadMessageId',
  'BadPath',
  'BadPriority',
  'BadTopic',
  'DeviceTokenNotForTopic',
  'DuplicateHeaders',
  'ExpiredProviderToken',
  'ExpiredToken',
  'Forbidden',
  'IdleTimeout',
  'InternalServerError',
  'InvalidProviderToken',
  'InvalidPushType',
  'MethodNotAllowed',
  'MissingDeviceToken',
  'MissingProviderToken',
  'MissingTopic',
  'PayloadEmpty',
  'PayloadTooLarge',
  'ServiceUnavailable',
  'Shutdown',
  'TooManyProviderTokenUpdates',
  'TooManyRequests',
  'TopicDisallowed',
  'UnrelatedKeyIdInToken',
  'Unregistered',
]);

const decodeApnsRejectionReason = Schema.decodeUnknownOption(
  Schema.fromJsonString(Schema.Struct({ reason: ApnsRejectionReason })),
);

const decodeApnsResponseStatus = Schema.decodeUnknownOption(
  Schema.Struct({ ':status': Schema.Finite }),
);

// APNs answered with a status other than 200. Some statuses end the device token.
class ApnsRejected extends Schema.TaggedError<ApnsRejected>()('ApnsRejected', {
  reason: Schema.optional(ApnsRejectionReason),
  status: Schema.Finite,
}) {}

// The request failed before APNs answered, or the answer was malformed.
class ApnsUnavailable extends Schema.TaggedError<ApnsUnavailable>()(
  'ApnsUnavailable',
  { cause: Schema.Defect() },
) {}

class ApnsTimedOut extends Schema.TaggedError<ApnsTimedOut>()(
  'ApnsTimedOut',
  {},
) {}

// Configuration or the provider token could not be prepared; handlers rethrow the cause.
class ApnsConfigurationFailed extends Schema.TaggedError<ApnsConfigurationFailed>()(
  'ApnsConfigurationFailed',
  { cause: Schema.Defect() },
) {}

type ApnsSendFailure = ApnsRejected | ApnsTimedOut | ApnsUnavailable;
type ApnsBatchFailure = ApnsConfigurationFailed | CallFailed;
type DeliveryResult = Result.Result<void, ApnsSendFailure>;

function requiredSetting(
  name: string,
): Effect.Effect<string, ApnsConfigurationFailed> {
  return Config.NonEmptyString(name).pipe(
    Effect.mapError(
      () =>
        new ApnsConfigurationFailed({
          cause: new Error(`${name} is required`),
        }),
    ),
  );
}

const apnsConfiguration = Effect.gen(function* () {
  const keyId = yield* requiredSetting('APNS_KEY_ID');
  const privateKey = yield* requiredSetting('APNS_PRIVATE_KEY');
  const teamId = yield* requiredSetting('APNS_TEAM_ID');
  const topic = yield* requiredSetting('APNS_TOPIC');
  return {
    keyId,
    privateKey: privateKey.replaceAll(String.raw`\n`, '\n'),
    teamId,
    topic,
  } satisfies ApnsConfiguration;
});

function providerToken(
  configuration: ApnsConfiguration,
  issuedAtSeconds: number,
): string {
  const header = Buffer.from(
    JSON.stringify({ alg: 'ES256', kid: configuration.keyId }),
  ).toString('base64url');
  const claims = Buffer.from(
    JSON.stringify({
      iss: configuration.teamId,
      iat: issuedAtSeconds,
    }),
  ).toString('base64url');
  const unsignedToken = `${header}.${claims}`;
  const signature = sign('sha256', Buffer.from(unsignedToken), {
    dsaEncoding: 'ieee-p1363',
    key: createPrivateKey(configuration.privateKey),
  }).toString('base64url');

  return `${unsignedToken}.${signature}`;
}

function apnsRequest(
  client: ClientHttp2Session,
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
  if (!Predicate.isObjectOrArray(rawHeaders)) {
    throw new TypeError('Invalid APNs response headers');
  }
  return rawHeaders;
}

function apnsResponseStatus(headers: object): number {
  return Option.match(decodeApnsResponseStatus(headers), {
    onNone: () => 0,
    onSome: (decoded) => decoded[':status'],
  });
}

// Waits for one stream event; interruption aborts the wait.
function streamEvent(
  request: ClientHttp2Stream,
  event: 'end' | 'response',
): Effect.Effect<unknown, ApnsUnavailable> {
  return Effect.tryPromise({
    try: async (signal): Promise<unknown> => once(request, event, { signal }),
    catch: (cause) => new ApnsUnavailable({ cause }),
  });
}

// The request stream is closed only when the timeout interrupts the exchange.
const sendWakeup = Effect.fnUntraced(
  function* (delivery: ApnsDelivery, client: ClientHttp2Session) {
    const request = yield* Effect.acquireRelease(
      Effect.try({
        try: () => apnsRequest(client, delivery),
        catch: (cause) => new ApnsUnavailable({ cause }),
      }),
      (stream, exit) =>
        Exit.hasInterrupts(exit)
          ? Effect.sync(() => {
              stream.close();
            })
          : Effect.void,
    );
    const responseArguments = yield* streamEvent(request, 'response');
    const headers = yield* Effect.try({
      try: () =>
        validateApnsResponseHeaders(
          firstApnsResponseArgument(responseArguments),
        ),
      catch: (cause) => new ApnsUnavailable({ cause }),
    });
    let responseBody = '';
    const onData = (chunk: unknown): void => {
      responseBody += String(chunk);
    };
    yield* Effect.acquireRelease(
      Effect.sync(() => request.on('data', onData)),
      () => Effect.sync(() => request.off('data', onData)),
    );
    yield* streamEvent(request, 'end');
    const status = apnsResponseStatus(headers);
    if (status !== 200) {
      return yield* new ApnsRejected({
        reason: Option.getOrUndefined(decodeApnsRejectionReason(responseBody))
          ?.reason,
        status,
      });
    }
  },
  Effect.scoped,
  Effect.timeoutOrElse({
    duration: apnsRequestTimeoutMs,
    orElse: () => Effect.fail(new ApnsTimedOut()),
  }),
);

function sendFailureDiagnostic(failure: ApnsSendFailure): string {
  if (failure._tag === 'ApnsRejected') {
    return `status ${failure.status}, ${failure.reason ?? 'unrecognized reason'}`;
  }
  return failure._tag === 'ApnsUnavailable'
    ? failureDiagnostic(failure.cause)
    : failure._tag;
}

function isPermanentApnsFailure(result: DeliveryResult): boolean {
  return (
    Result.isFailure(result) &&
    result.failure._tag === 'ApnsRejected' &&
    permanentApnsFailureStatuses.has(result.failure.status)
  );
}

// APNs answers 410 when the device token is no longer valid for the topic.
function isStaleTokenFailure(failure: ApnsSendFailure): boolean {
  return failure._tag === 'ApnsRejected' && failure.status === 410;
}

const handleDeliveryResult = Effect.fnUntraced(function* (
  ctx: ActionCtx,
  result: DeliveryResult,
  recipient: StaleTokenRecipient | undefined,
) {
  if (Result.isSuccess(result)) {
    return;
  }
  yield* Effect.logError(
    'APNs wakeup delivery failed:',
    sendFailureDiagnostic(result.failure),
  );
  if (recipient === undefined || !isStaleTokenFailure(result.failure)) {
    return;
  }
  yield* call(async () =>
    ctx.runMutation(internal.pushRelay.clearStaleDevice, {
      apnsToken: recipient.apnsToken,
      pushCleanupGeneration: recipient.pushCleanupGeneration ?? 0,
      trustedDeviceId: recipient.trustedDeviceId,
    }),
  );
});

function apnsAuthority(environment: ApnsEnvironment): string {
  return environment === 'production'
    ? 'https://api.push.apple.com'
    : 'https://api.sandbox.push.apple.com';
}

// One HTTP/2 session per APNs environment, closed with the batch scope.
const openApnsSession = Effect.fnUntraced(function* (
  environment: ApnsEnvironment,
) {
  const services = yield* Effect.context();
  const logSessionFailure = Effect.runForkWith(services);
  return yield* Effect.acquireRelease(
    Effect.sync(() => {
      const client = connect(apnsAuthority(environment));
      client.on('error', (error) => {
        logSessionFailure(
          Effect.logError(
            'APNs HTTP/2 session failed:',
            failureDiagnostic(error),
          ),
        );
      });
      return client;
    }),
    (client) =>
      Effect.sync(() => {
        client.close();
      }),
  );
});

const sendBatch = Effect.fnUntraced(function* <
  Recipient extends StaleTokenRecipient,
>(
  recipients: readonly Recipient[],
  delivery: (recipient: Recipient) => ApnsDelivery,
) {
  const sessions = new Map<ApnsEnvironment, ClientHttp2Session>();
  for (const recipient of recipients) {
    if (!sessions.has(recipient.apnsEnvironment)) {
      sessions.set(
        recipient.apnsEnvironment,
        yield* openApnsSession(recipient.apnsEnvironment),
      );
    }
  }
  return yield* Effect.forEach(
    recipients,
    (recipient) =>
      Effect.fromNullishOr(sessions.get(recipient.apnsEnvironment)).pipe(
        Effect.mapError((cause) => new ApnsUnavailable({ cause })),
        Effect.flatMap((client) => sendWakeup(delivery(recipient), client)),
        Effect.result,
      ),
    { concurrency: 'unbounded' },
  );
}, Effect.scoped);

const deliverWakeupBatch = Effect.fnUntraced(function* <
  Recipient extends StaleTokenRecipient,
>(
  ctx: ActionCtx,
  recipients: readonly Recipient[],
  payload: (recipient: Recipient) => string,
) {
  const configuration = yield* apnsConfiguration;
  const issuedAt = yield* Clock.currentTimeMillis;
  const authorization = yield* Effect.try({
    try: () => providerToken(configuration, Math.floor(issuedAt / 1000)),
    catch: (cause) => new ApnsConfigurationFailed({ cause }),
  });
  const results = yield* sendBatch(recipients, (recipient) => ({
    apnsToken: recipient.apnsToken,
    authorization,
    configuration,
    payload: payload(recipient),
  }));
  yield* Effect.forEach(
    results,
    (result, index) => handleDeliveryResult(ctx, result, recipients[index]),
    { concurrency: 'unbounded', discard: true },
  );
  return results;
});

// Any batch failure is logged and reported as no delivery results.
function attemptWakeupDelivery<Recipient extends StaleTokenRecipient>(
  options: Readonly<{
    ctx: ActionCtx;
    failureMessage: string;
    payload: (recipient: Recipient) => string;
    recipients: readonly Recipient[];
  }>,
): Effect.Effect<Option.Option<readonly DeliveryResult[]>> {
  return deliverWakeupBatch(
    options.ctx,
    options.recipients,
    options.payload,
  ).pipe(
    Effect.asSome,
    Effect.catchCause((cause) => {
      const failure = Cause.squash(cause);
      const diagnostic =
        failure instanceof ApnsConfigurationFailed ||
        failure instanceof CallFailed
          ? failureDiagnostic(failure.cause)
          : failureDiagnostic(failure);
      return Effect.logError(`${options.failureMessage}:`, diagnostic).pipe(
        Effect.as(Option.none()),
      );
    }),
  );
}

function thrownBatchError(error: ApnsBatchFailure): unknown {
  return error.cause;
}

function backgroundWakeupPayload(
  provider: 'microsoft-graph' | 'scheduled-send',
  fields: Readonly<Record<string, number | string>>,
): string {
  return JSON.stringify({
    aps: { 'content-available': 1 },
    provider,
    ...fields,
  });
}

function microsoftGraphWakeupPayload(routeId: string): string {
  return backgroundWakeupPayload('microsoft-graph', { routeId });
}

function scheduledSendWakeupPayload(
  revision: number,
  scheduleId: string,
): string {
  return backgroundWakeupPayload('scheduled-send', { revision, scheduleId });
}

function deliverGmailWakeupBatch(
  ctx: ActionCtx,
  args: Readonly<{
    historyId: string;
    recipients: readonly GmailWakeupRecipient[];
  }>,
): Effect.Effect<null, ApnsBatchFailure> {
  return deliverWakeupBatch(ctx, args.recipients, (recipient) =>
    JSON.stringify(gmailWakeupPayload(args.historyId, recipient.routeId)),
  ).pipe(Effect.as(null));
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
  handler: async (ctx, args): Promise<null> =>
    runConvexProgram(deliverGmailWakeupBatch(ctx, args), thrownBatchError),
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
  handler: async (ctx, args): Promise<null> =>
    runConvexProgram(
      Effect.gen(function* () {
        const recipients = yield* call(
          async (): Promise<readonly GmailWakeupRecipient[]> =>
            ctx.runQuery(internal.pushRelay.revalidateGmailRecipients, {
              recipients: args.recipients,
            }),
        );
        if (recipients.length > 0) {
          yield* deliverGmailWakeupBatch(ctx, {
            historyId: args.historyId,
            recipients,
          });
        }
        return null;
      }),
      thrownBatchError,
    ),
  returns: v.null(),
});

export const deliverMicrosoftGraphWakeup = internalAction({
  args: {
    routeId: v.id('mailProviderConnections'),
    scheduledAt: v.number(),
  },
  handler: async (ctx, args): Promise<null> =>
    runConvexProgram(
      Effect.gen(function* () {
        const recipient = yield* call(
          async (): Promise<GmailWakeupRecipient | null> =>
            ctx.runMutation(internal.pushRelay.claimMicrosoftGraphWakeup, args),
        );
        if (recipient === null) {
          return null;
        }
        const deliveryResult = Option.flatMapNullishOr(
          yield* attemptWakeupDelivery({
            ctx,
            failureMessage: 'APNs wakeup delivery failed',
            payload: (target) => microsoftGraphWakeupPayload(target.routeId),
            recipients: [recipient],
          }),
          (results) => results[0],
        );
        // A failed batch is neither delivered nor terminal, so the wakeup is retried.
        yield* call(async () =>
          ctx.runMutation(internal.pushRelay.completeMicrosoftGraphWakeup, {
            delivered: Option.exists(deliveryResult, Result.isSuccess),
            routeId: args.routeId,
            scheduledAt: args.scheduledAt,
            terminalFailure: Option.exists(
              deliveryResult,
              isPermanentApnsFailure,
            ),
          }),
        );
        return null;
      }),
      thrownBatchError,
    ),
  returns: v.null(),
});

export const deliverScheduledSendWakeup = internalAction({
  args: {
    revision: v.number(),
    scheduleDocumentId: v.id('scheduledSends'),
  },
  handler: async (ctx, args): Promise<null> =>
    runConvexProgram(
      // fallow-ignore-next-line complexity -- Delivery pages must preserve bounded reads, ordered APNs batches, and retry persistence.
      Effect.gen(function* () {
        const retryWakeup = call(async (): Promise<unknown> =>
          ctx.runMutation(internal.scheduledSend.retryWakeup, args),
        );
        let cursor: string | null = null;
        let delivered = false;
        let attemptedDelivery = false;
        let remainingDeviceCount = scheduledWakeupDeviceLimit;
        while (remainingDeviceCount > 0) {
          const pageCursor = cursor;
          const pageDeviceCount = remainingDeviceCount;
          const page = yield* call(async (): Promise<ScheduledSendWakeupPage> =>
            ctx.runMutation(internal.scheduledSend.claimWakeup, {
              ...args,
              cursor: pageCursor,
              remainingDeviceCount: pageDeviceCount,
            }),
          );
          remainingDeviceCount -= page.inspectedDeviceCount;
          if (page.recipients.length > 0) {
            attemptedDelivery = true;
            const deliveryResults = yield* attemptWakeupDelivery({
              ctx,
              failureMessage: 'Scheduled Send APNs wakeup delivery failed',
              payload: (recipient) =>
                scheduledSendWakeupPayload(
                  recipient.revision,
                  recipient.scheduleId,
                ),
              recipients: page.recipients,
            });
            if (Option.isNone(deliveryResults)) {
              yield* retryWakeup;
              return null;
            }
            delivered ||= deliveryResults.value.some(Result.isSuccess);
          }
          if (page.isDone || page.nextCursor === null) {
            break;
          }
          cursor = page.nextCursor;
        }
        if (attemptedDelivery && !delivered) {
          yield* retryWakeup;
        }
        return null;
      }),
      thrownBatchError,
    ),
  returns: v.null(),
});
