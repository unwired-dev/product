import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

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
export const gmailResponse = (
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
export const httpFailure = (status: number, body: string) =>
  new SyncFailure({
    kind:
      status === 401 || (status === 403 && Option.isNone(rateLimited(body)))
        ? 'authentication'
        : 'retry',
    cause: status,
    diagnostic: `status ${status}`,
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
