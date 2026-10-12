import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type { GraphChange } from './microsoft-graph.ts';
import type { MessageSegment } from './outgoing-message.ts';

import {
  decodeDiagnostic,
  rejectionCode,
  rejectionDiagnostic,
} from './diagnostics.ts';

export interface NativeGraphMailbox {
  // Resolves `{ status, body }` for a Microsoft Graph read of the signed-in person's own mail at
  // `url`; native code refuses any other URL.
  readonly graphRequest: (
    url: string,
    mailbox: Readonly<{
      address: string;
      generation: string;
      signal?: Readonly<AbortSignal>;
    }>,
  ) => Promise<unknown>;
  // Applies one change to one of the signed-in person's own messages: its read state, or a move
  // to a well-known folder name or a folder ID. Native code writes the request, so only these
  // values cross. Resolves `{ status, body }`, the body Graph's view of the message afterwards.
  readonly graphModify: (
    change: Readonly<{ message: string } & GraphChange>,
    mailbox: Readonly<{ address: string; generation: string }>,
  ) => Promise<unknown>;
  // Sends one message through Graph's sendMail as MIME, inserting each asset segment's verified
  // bytes. Resolves `{ status, body }` once Graph answers. Rejects with 'delivery-unknown' when the
  // request may have reached Graph without an answer; any other rejection means it never left
  // this device.
  readonly graphSend: (
    message: Readonly<{ segments: readonly MessageSegment[] }>,
    mailbox: Readonly<{ address: string; generation: string }>,
  ) => Promise<unknown>;
}

export const decodeResponse = Schema.decodeUnknownEffect(
  Schema.Struct({ status: Schema.Int, body: Schema.String }),
);
// Gmail's documented 403 usage limits; authorizing Gmail again cannot resolve them.
export const rateLimited = Schema.decodeUnknownOption(
  Schema.fromJsonString(
    Schema.Struct({
      error: Schema.Struct({
        errors: Schema.Array(
          Schema.Struct({
            reason: Schema.Literals([
              'dailyLimitExceeded',
              'rateLimitExceeded',
              'userRateLimitExceeded',
            ]),
          }),
        ),
      }),
    }),
  ),
);

// 'authentication' needs Gmail authorized again; 'retry' may succeed on a later synchronization.
export class SyncFailure extends Schema.TaggedError<SyncFailure>()(
  'SyncFailure',
  {
    kind: Schema.Literals([
      'authentication',
      'retry',
      'locked',
      'conflict',
      // Native work started before a registration change; a new synchronization opens the cache again.
      'invalidated',
      'revoked',
      'failed',
    ]),
    cause: Schema.Defect(),
    // Logged instead of the cause; see rejectionDiagnostic.
    diagnostic: Schema.String,
  },
) {}

// A message or history that Gmail no longer has.
export class GmailNotFound extends Schema.TaggedError<GmailNotFound>()(
  'GmailNotFound',
  {},
) {}

// Gmail refused the mailbox's grant; authorizing Gmail again is the only remedy.
export const rejectedGrant = (error: unknown) =>
  error instanceof SyncFailure && error.kind === 'authentication';

export class GmailInvalidPage extends Schema.TaggedError<GmailInvalidPage>()(
  'GmailInvalidPage',
  {},
) {}

export const rejected = (
  cause: unknown,
  otherwise: 'retry' | 'failed',
): SyncFailure => {
  const code = rejectionCode(cause);
  let kind: SyncFailure['kind'] = otherwise;
  if (code === 'gmail-unavailable') {
    kind = 'authentication';
  } else if (code === 'locked' || code === 'conflict') {
    kind = code;
  } else if (code === 'mailbox-revoked') {
    kind = 'revoked';
  } else if (code === 'mailbox-invalidated') {
    kind = 'invalidated';
  }
  return new SyncFailure({
    kind,
    cause,
    diagnostic: rejectionDiagnostic(cause),
  });
};

export const malformed = (
  error: Schema.SchemaError,
  kind: 'retry' | 'failed',
) =>
  new SyncFailure({ kind, cause: error, diagnostic: decodeDiagnostic(error) });

// One Gmail request's `{ status, body }`; a rejected or malformed reply may pass on a later try.
const gmailResponse = (
  request: (signal: Readonly<AbortSignal>) => Promise<unknown>,
) =>
  Effect.tryPromise({
    try: request,
    catch: (cause) => rejected(cause, 'retry'),
  }).pipe(
    Effect.flatMap(decodeResponse),
    Effect.mapError((failure) =>
      Schema.isSchemaError(failure) ? malformed(failure, 'retry') : failure,
    ),
  );

// Gmail refusing the grant needs authorization again; other HTTP failures may pass on a later try.
const httpFailure = (status: number, body: string) =>
  new SyncFailure({
    kind:
      status === 401 || (status === 403 && Option.isNone(rateLimited(body)))
        ? 'authentication'
        : 'retry',
    cause: status,
    diagnostic: `status ${status}`,
  });

// One provider write's reply: none when the provider refuses it for good because the message or
// its target no longer exists, the decoded body when `accepted` reads its status as success, and
// other HTTP failures classified.
export const providerWrite = Effect.fnUntraced(function* <A>(
  request: () => Promise<unknown>,
  accepted: (status: number) => boolean,
  decode: (body: unknown) => Effect.Effect<A, Schema.SchemaError>,
) {
  const { status, body } = yield* gmailResponse(request);
  if (status === 400 || status === 404) {
    return Option.none<A>();
  }
  if (!accepted(status)) {
    return yield* httpFailure(status, body);
  }
  return Option.some(
    yield* decode(body).pipe(
      Effect.mapError((error) => malformed(error, 'retry')),
    ),
  );
});

// One provider read. A missing resource is GmailNotFound, a continuation the provider no longer
// accepts is GmailInvalidPage, and other HTTP failures are classified.
export const providerRead = Effect.fnUntraced(function* <A>(
  request: (signal: Readonly<AbortSignal>) => Promise<unknown>,
  expired: (status: number) => boolean,
  decode: (body: unknown) => Effect.Effect<A, Schema.SchemaError>,
) {
  const { status, body } = yield* gmailResponse(request);
  if (status === 404) {
    return yield* new GmailNotFound();
  }
  if (expired(status)) {
    return yield* new GmailInvalidPage();
  }
  if (status !== 200) {
    return yield* httpFailure(status, body);
  }
  return yield* decode(body).pipe(
    Effect.mapError((error) => malformed(error, 'retry')),
  );
});
