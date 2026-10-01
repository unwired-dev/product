import * as Clock from 'effect/Clock';
import * as ConfigProvider from 'effect/ConfigProvider';
import * as Duration from 'effect/Duration';
import * as Effect from 'effect/Effect';
import * as Predicate from 'effect/Predicate';
import * as Schema from 'effect/Schema';

// A Promise-returning call outside Effect, such as a Convex function, rejected.
// Handlers rethrow the original error, so Convex sees the same failure.
export class CallFailed extends Schema.TaggedError<CallFailed>()('CallFailed', {
  cause: Schema.Defect(),
}) {}

export function call<A>(run: () => Promise<A>): Effect.Effect<A, CallFailed> {
  return Effect.tryPromise({
    try: run,
    catch: (cause) => new CallFailed({ cause }),
  });
}

// Transport codes Node reports for network and HTTP/2 failures.
const errorCodes = new Map(
  [
    'ABORT_ERR',
    'ECONNREFUSED',
    'ECONNRESET',
    'EHOSTUNREACH',
    'ENETUNREACH',
    'ENOTFOUND',
    'EPIPE',
    'ETIMEDOUT',
    'ERR_HTTP2_GOAWAY_SESSION',
    'ERR_HTTP2_INVALID_SESSION',
    'ERR_HTTP2_SESSION_ERROR',
    'ERR_HTTP2_STREAM_CANCEL',
    'ERR_HTTP2_STREAM_ERROR',
  ].map((code) => [code, `code ${code}`]),
);
const errorNames = new Map(
  [
    'AbortError',
    'Error',
    'RangeError',
    'SyntaxError',
    'TimeoutError',
    'TypeError',
  ].map((name) => [name, name]),
);

function allowListed(
  diagnostics: ReadonlyMap<string, string>,
  value: unknown,
  fallback: string,
): string {
  return (
    (Predicate.isString(value) ? diagnostics.get(value) : undefined) ?? fallback
  );
}

// Provider and runtime errors can carry tokens or account data in any field, so
// logs keep only allow-listed codes and error names.
export function failureDiagnostic(cause: unknown): string {
  if (Predicate.hasProperty(cause, 'code')) {
    return allowListed(errorCodes, cause.code, 'unrecognized code');
  }
  return Predicate.isError(cause)
    ? allowListed(errorNames, cause.name, 'unrecognized error')
    : typeof cause;
}

// Resolves after the delay, or early when the waiting fiber is interrupted.
async function delay(milliseconds: number, signal: AbortSignal): Promise<void> {
  // oxlint-disable-next-line promise/avoid-new -- Wraps the callback-based timer once.
  return new Promise((resolve) => {
    const handle = setTimeout(resolve, milliseconds);
    signal.addEventListener('abort', () => {
      clearTimeout(handle);
      resolve();
    });
  });
}

// A sleeping fiber resumes through a Promise continuation, which keeps it in the
// Convex function's async context that Convex calls depend on, even when the timer
// callback runs elsewhere, as with fake timers in tests. Time is still read from
// Date.now, so Date mocks apply.
const convexClock = Effect.clockWith((clock) =>
  Effect.succeed<Clock.Clock>({
    currentTimeMillis: clock.currentTimeMillis,
    currentTimeMillisUnsafe: () => clock.currentTimeMillisUnsafe(),
    currentTimeNanos: clock.currentTimeNanos,
    currentTimeNanosUnsafe: () => clock.currentTimeNanosUnsafe(),
    monotonicTimeNanos: clock.monotonicTimeNanos,
    monotonicTimeNanosUnsafe: () => clock.monotonicTimeNanosUnsafe(),
    sleep: (duration) =>
      Duration.isFinite(duration)
        ? Effect.promise(async (signal) =>
            delay(Duration.toMillis(duration), signal),
          )
        : Effect.never,
  }),
);

// Runs one Convex handler's program and converts its typed failure to the error
// the handler throws. Deployment environment variables are read per invocation.
export async function runConvexProgram<A, E>(
  program: Effect.Effect<A, E>,
  thrownError: (error: E) => unknown,
): Promise<A> {
  return Effect.runPromise(
    convexClock.pipe(
      Effect.flatMap((clock) =>
        program.pipe(
          Effect.mapError(thrownError),
          Effect.provideService(Clock.Clock, clock),
          Effect.provideService(
            ConfigProvider.ConfigProvider,
            ConfigProvider.fromEnv(),
          ),
        ),
      ),
    ),
  );
}
