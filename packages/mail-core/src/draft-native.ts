import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import { decodeDiagnostic, rejectionDiagnostic } from './diagnostics.ts';

export class DraftStorageFailure extends Schema.TaggedError<DraftStorageFailure>()(
  'DraftStorageFailure',
  {
    kind: Schema.Literals(['locked', 'conflict', 'failed']),
    cause: Schema.Defect(),
    // Logged instead of the cause; see rejectionDiagnostic.
    diagnostic: Schema.String,
  },
) {}

const storageCode = Schema.decodeUnknownOption(
  Schema.Struct({ code: Schema.Literals(['locked', 'conflict']) }),
);
export const failureOf = (cause: unknown) =>
  new DraftStorageFailure({
    kind: Option.match(storageCode(cause), {
      onNone: () => 'failed' as const,
      onSome: ({ code }) => code,
    }),
    cause,
    diagnostic: rejectionDiagnostic(cause),
  });
export const malformed = (error: Schema.SchemaError) =>
  new DraftStorageFailure({
    kind: 'failed',
    cause: error,
    diagnostic: decodeDiagnostic(error),
  });
export const ownerMismatch = () =>
  new DraftStorageFailure({
    kind: 'failed',
    cause: undefined,
    diagnostic: 'owner mismatch',
  });

export const native = Effect.fnUntraced(function* <S extends Schema.Top>(
  operation: () => Promise<unknown>,
  schema: S,
) {
  const value = yield* Effect.tryPromise({ try: operation, catch: failureOf });
  return yield* Schema.decodeUnknownEffect(schema)(value).pipe(
    Effect.mapError(malformed),
  );
});

// Locked storage is expected while the device is locked; any other failure is logged.
export const report = (
  error: Readonly<Pick<DraftStorageFailure, 'kind' | 'diagnostic'>>,
) =>
  error.kind === 'locked'
    ? Effect.void
    : Effect.logError('Draft storage failed:', error.diagnostic);
