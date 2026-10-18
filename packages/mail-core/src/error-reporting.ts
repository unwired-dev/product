import type { ErrorReport } from '@private-email/contracts/errorReporting';
import type {
  ReportingBreadcrumb,
  ReportingCode,
} from '@private-email/contracts/errorReporting';

import {
  ErrorReportSchema,
  ReportingBreadcrumbSchema,
  ReportingMessageSchema,
  ReportingMetadataSchema,
  ReportingNameSchema,
} from '@private-email/contracts/errorReportingSchema';
import * as Arr from 'effect/Array';
import * as Clock from 'effect/Clock';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Predicate from 'effect/Predicate';
import * as Random from 'effect/Random';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import { rejectionCode, runLogged } from './diagnostics.ts';

export type ErrorReportingSnapshot =
  | Readonly<{ kind: 'loading' }>
  | Readonly<{ kind: 'unavailable' }>
  | Readonly<{
      kind: 'ready' | 'saving';
      enabled: boolean;
      deletion: 'idle' | 'complete' | 'missing';
    }>
  | Readonly<{
      kind: 'deleting';
      phase: 'pending' | 'offline' | 'failed';
    }>;

export interface ErrorReporting {
  readonly getSnapshot: () => ErrorReportingSnapshot;
  readonly subscribe: (listener: () => void) => () => void;
  readonly load: () => Promise<void>;
  readonly refresh: () => Promise<void>;
  readonly setEnabled: (enabled: boolean) => Promise<void>;
  readonly deleteReports: () => Promise<void>;
  readonly retryDeletion: () => Promise<void>;
  readonly capture: (error: unknown, code?: ReportingCode) => void;
  readonly breadcrumb: (breadcrumb: ReportingBreadcrumb) => void;
  readonly dispose: () => void;
}

export interface NativeErrorReporting {
  readonly errorReportingRead: () => Promise<unknown>;
  readonly errorReportingConsent: (
    enabled: boolean,
    renewIdentity: boolean,
    generation: number,
  ) => Promise<unknown>;
  readonly errorReportingSave: (
    generation: number,
    document: string,
  ) => Promise<unknown>;
  readonly errorReportingRequest: (
    operation: 'enable' | 'capture' | 'revoke' | 'delete' | 'status',
    body: string,
    generation: number,
  ) => Promise<unknown>;
  readonly errorReportingTakeNative: () => Promise<unknown>;
}

const strict = { onExcessProperty: 'error' } as const;
const Deletion = Schema.Literals([
  'idle',
  'pending',
  'offline',
  'failed',
  'complete',
  'missing',
]);
const Document = Schema.Struct({
  version: Schema.Literal(1),
  queue: Schema.Array(ErrorReportSchema).check(Schema.isMaxLength(100)),
  deletion: Deletion,
});
const BridgeState = Schema.Struct({
  enabled: Schema.Boolean,
  generation: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  document: Schema.NullOr(Schema.String),
  available: Schema.Boolean,
  nativeAvailable: Schema.Boolean,
  identityAvailable: Schema.Boolean,
  metadata: ReportingMetadataSchema,
});
const Reply = Schema.Struct({
  status: Schema.Literals([
    'enabled',
    'disabled',
    'accepted',
    'pending',
    'complete',
    'retry',
  ]),
  retryAfterMs: Schema.optionalKey(
    Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 86_400_000 })),
  ),
});
const decodeState = Schema.decodeUnknownEffect(BridgeState, strict);
const decodeDocument = Schema.decodeUnknownOption(
  Schema.fromJsonString(Document),
  strict,
);
const decodeReply = Schema.decodeUnknownEffect(Reply, strict);
const encodeDocument = Schema.encodeEffect(Schema.fromJsonString(Document));
const encodeCapture = Schema.encodeEffect(
  Schema.fromJsonString(
    Schema.Struct({
      reports: Schema.Array(ErrorReportSchema),
      metadata: ReportingMetadataSchema,
    }),
  ),
);
const isName = Schema.is(ReportingNameSchema);
const isMessage = Schema.is(ReportingMessageSchema);
const maxAge = 86_400_000;
const deleting = (
  phase: typeof Deletion.Type,
): phase is 'pending' | 'offline' | 'failed' =>
  ['pending', 'offline', 'failed'].includes(phase);
const recentReports = <Report extends { readonly createdAt: number }>(
  reports: readonly Report[],
  now: number,
) =>
  reports.filter(
    (report) =>
      report.createdAt <= now + 60_000 && now - report.createdAt <= maxAge,
  );
class ReportingFailure extends Schema.TaggedError<ReportingFailure>()(
  'ReportingFailure',
  { cause: Schema.Defect() },
) {}
const call = (request: () => Promise<unknown>) =>
  Effect.tryPromise({
    try: request,
    catch: (cause) => new ReportingFailure({ cause }),
  });

// Only known constants and bundle coordinates cross this boundary. Stack URLs,
// arbitrary function names and exception text can contain mail or credentials.
function exception(error: unknown) {
  const name =
    Predicate.hasProperty(error, 'name') && isName(error.name)
      ? error.name
      : 'Error';
  const message =
    Predicate.hasProperty(error, 'message') && isMessage(error.message)
      ? error.message
      : undefined;
  return { name, ...(message === undefined ? {} : { message }) };
}
function frames(error: unknown) {
  if (
    !Predicate.hasProperty(error, 'stack') ||
    !Predicate.isString(error.stack)
  ) {
    return [];
  }
  return Arr.reverse(
    [
      ...error.stack
        .slice(0, 32_768)
        .matchAll(
          /(?:index(?:\.ios|\.macos)?\.bundle|main\.jsbundle|[a-f0-9-]{8,}\.hbc|app:\/\/\/(?:index\.bundle|(?:ios|macos)\/[\d.]+\/[\d.]+\/index\.bundle)):(?<line>\d{1,8}):(?<column>\d{1,8})(?:\)|\s|$)/gu,
        ),
    ].slice(0, 64),
  ).map((match) => ({
    kind: 'javascript' as const,
    line: Number(match[1]),
    column: Number(match[2]),
  }));
}
function exceptionCauses(error: unknown) {
  const causes: Array<ReturnType<typeof exception>> = [];
  let cause = error;
  for (let i = 0; i < 8 && Predicate.hasProperty(cause, 'cause'); i += 1) {
    const { cause: nextCause } = cause;
    cause = nextCause;
    causes.push(exception(cause));
  }
  return causes;
}
const uuid = Effect.gen(function* () {
  const bytes: number[] = [];
  for (let i = 0; i < 16; i += 1) {
    bytes.push(yield* Random.nextIntBetween(0, 255));
  }
  bytes[6] = ((bytes[6] ?? 0) % 16) + 64;
  bytes[8] = ((bytes[8] ?? 0) % 64) + 128;
  const hex = bytes.map((byte) => byte.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
});

const consentEnabled = (value: typeof BridgeState.Type) =>
  value.available && value.enabled;

export function createErrorReporting(
  native: NativeErrorReporting,
  initialState?: unknown,
): ErrorReporting {
  const operations = Semaphore.makeUnsafe(1);
  const listeners = new Set<() => void>();
  const lifetime = new AbortController();
  let snapshot: ErrorReportingSnapshot = { kind: 'loading' };
  const initial = Schema.decodeUnknownOption(BridgeState, strict)(initialState);
  let state = Option.getOrUndefined(initial);
  const initialDocument = Option.flatMap(initial, (value) =>
    value.document === null ? Option.none() : decodeDocument(value.document),
  );
  let document: {
    version: 1;
    queue: typeof Document.Type.queue;
    deletion: typeof Deletion.Type;
  } = Option.getOrElse(initialDocument, () => ({
    version: 1 as const,
    queue: [],
    deletion: 'idle' as const,
  }));
  let breadcrumbs: ReportingBreadcrumb[] = [];
  const captured = new WeakSet<object>();
  let collecting =
    state !== undefined &&
    consentEnabled(state) &&
    (state.document === null || Option.isSome(initialDocument)) &&
    document.deletion === 'idle';
  if (!collecting) {
    document.queue = [];
  }
  let revision = 0;
  let retryAt = 0;
  let loaded = false;
  let disposed = false;
  let consentPending = false;
  const publish = () => {
    if (disposed) {
      return;
    }
    if (state === undefined || !state.available) {
      snapshot = { kind: 'unavailable' };
    } else if (deleting(document.deletion)) {
      snapshot = { kind: 'deleting', phase: document.deletion };
    } else {
      snapshot = {
        kind: consentPending ? 'saving' : 'ready',
        enabled: collecting,
        deletion: document.deletion,
      };
    }
    for (const listener of listeners) {
      listener();
    }
  };
  const save = Effect.fn('ErrorReporting.save')(function* () {
    if (state === undefined) {
      return false;
    }
    const { generation } = state;
    const encoded = yield* encodeDocument(document);
    const result = yield* call(() =>
      native.errorReportingSave(generation, encoded),
    );
    const accepted = yield* Schema.decodeUnknownEffect(
      Schema.Struct({ saved: Schema.Boolean }),
      strict,
    )(result);
    if (!accepted.saved) {
      retryAt = 0;
      collecting = false;
      document.queue = [];
    }
    return accepted.saved;
  });
  const request = Effect.fn('ErrorReporting.request')(function* (
    operation: Parameters<NativeErrorReporting['errorReportingRequest']>[0],
    body?: string,
  ) {
    if (state === undefined) {
      return yield* new ReportingFailure({ cause: 'unavailable' });
    }
    const { generation } = state;
    return yield* call(() =>
      native.errorReportingRequest(operation, body ?? '{}', generation),
    ).pipe(Effect.flatMap(decodeReply));
  });
  const isCurrent = (expected: number) => expected === revision && !disposed;
  const reconcileRetry = (next: typeof BridgeState.Type) => {
    if (state?.generation !== next.generation) {
      retryAt = 0;
    }
  };
  const deletionAllowed = (expected: number) =>
    isCurrent(expected) &&
    !consentPending &&
    !collecting &&
    deleting(document.deletion);
  const deletion = Effect.fn('ErrorReporting.delete')(function* () {
    const expected = revision;
    if (!deletionAllowed(expected)) {
      return;
    }
    if (state === undefined || !state.identityAvailable) {
      document.deletion = 'missing';
      yield* save();
      return;
    }
    const phase = yield* request('delete').pipe(
      Effect.map((reply) => {
        if (reply.status === 'complete' || reply.status === 'pending') {
          return reply.status;
        }
        return 'failed' as const;
      }),
      Effect.catchTag('ReportingFailure', (error) =>
        Effect.succeed(
          rejectionCode(error.cause) === 'offline'
            ? ('offline' as const)
            : ('failed' as const),
        ),
      ),
      Effect.orElseSucceed(() => 'failed' as const),
    );
    if (!deletionAllowed(expected)) {
      return;
    }
    document.deletion = phase;
    yield* save();
  });
  const stillCollecting = (expected: number) =>
    collecting && expected === revision;
  const captureBatch = Effect.fn('ErrorReporting.captureBatch')(function* (
    metadata: typeof ReportingMetadataSchema.Type,
  ) {
    let reports = document.queue.slice(0, 10);
    let body = yield* encodeCapture({ reports, metadata });
    // All admitted fields are ASCII. Leave room for the native capability proof.
    while (body.length > 60_000 && reports.length > 1) {
      reports = reports.slice(0, -1);
      body = yield* encodeCapture({ reports, metadata });
    }
    return { reports, body };
  });
  const deliverQueue = Effect.fn('ErrorReporting.deliverQueue')(function* (
    metadata: typeof ReportingMetadataSchema.Type,
    expected: number,
  ) {
    while (document.queue.length > 0) {
      const { reports, body } = yield* captureBatch(metadata);
      const reply = yield* request('capture', body).pipe(
        Effect.catchTag('SchemaError', () =>
          Effect.succeed({ status: 'retry' as const, retryAfterMs: 30_000 }),
        ),
      );
      const now = yield* Clock.currentTimeMillis;
      if (!stillCollecting(expected)) {
        break;
      }
      if (reply.status !== 'accepted') {
        if (reply.status === 'retry') {
          const delay = reply.retryAfterMs ?? 30_000;
          retryAt = now + (delay === 0 ? 30_000 : delay);
        }
        break;
      }
      retryAt = 0;
      document.queue = document.queue.slice(reports.length);
      yield* save();
    }
  });
  const flush = Effect.fn('ErrorReporting.flush')(function* () {
    if (!collecting || state === undefined) {
      return;
    }
    const expected = revision;
    const now = yield* Clock.currentTimeMillis;
    document.queue = recentReports(document.queue, now).slice(-32);
    const nativeReports = yield* call(() =>
      native.errorReportingTakeNative(),
    ).pipe(
      Effect.flatMap(
        Schema.decodeUnknownEffect(
          Schema.Struct({
            reports: Schema.Array(ErrorReportSchema).check(
              Schema.isMaxLength(100),
            ),
          }),
          strict,
        ),
      ),
      Effect.orElseSucceed(() => ({ reports: [] })),
    );
    if (!stillCollecting(expected)) {
      return;
    }
    document.queue = [
      ...document.queue,
      ...recentReports(nativeReports.reports, now),
    ].slice(-32);
    yield* save();
    if (!stillCollecting(expected) || document.queue.length === 0) {
      return;
    }
    if ((yield* Clock.currentTimeMillis) < retryAt) {
      return;
    }
    const enabled = yield* request('enable');
    if (enabled.status !== 'enabled' || !stillCollecting(expected)) {
      return;
    }
    yield* deliverQueue(state.metadata, expected);
  });
  const guarded = (program: Effect.Effect<void, unknown>) =>
    runLogged(
      operations
        .withPermit(program)
        .pipe(Effect.ignore, Effect.andThen(Effect.sync(publish))),
    );
  const read = Effect.gen(function* () {
    const expected = revision;
    const result = yield* call(() => native.errorReportingRead()).pipe(
      Effect.flatMap(decodeState),
      Effect.option,
    );
    if (!isCurrent(expected) || consentPending) {
      return;
    }
    if (Option.isNone(result)) {
      retryAt = 0;
      state = undefined;
      collecting = false;
      loaded = true;
      return;
    }
    const next = result.value;
    reconcileRetry(next);
    state = next;
    const stored =
      next.document === null
        ? Option.some({
            version: 1 as const,
            queue: [],
            deletion: 'idle' as const,
          })
        : decodeDocument(next.document);
    if (Option.isNone(stored)) {
      retryAt = 0;
      collecting = false;
      document = { version: 1, queue: [], deletion: 'idle' };
      state = yield* call(() =>
        native.errorReportingConsent(false, false, next.generation),
      ).pipe(Effect.flatMap(decodeState));
      loaded = true;
      yield* save();
      return;
    }
    document = stored.value;
    collecting = consentEnabled(next) && document.deletion === 'idle';
    if (!collecting) {
      retryAt = 0;
      document.queue = [];
      breadcrumbs = [];
    }
    loaded = true;
    yield* deleting(document.deletion) ? deletion() : flush();
  }).pipe(Effect.ignore);
  let polling = false;
  const refresh = async () => {
    await guarded(read);
    if (!polling && !disposed && state?.available === true) {
      polling = true;
      void poll();
    }
  };
  const canChangeConsent = (enabled: boolean) =>
    !disposed &&
    (loaded || !enabled) &&
    state?.available === true &&
    (!enabled ||
      (!consentPending && !collecting && !deleting(document.deletion)));
  const persistDeletionIntent = Effect.fn(
    'ErrorReporting.persistDeletionIntent',
  )(function* (expected: number) {
    while (isCurrent(expected)) {
      if (yield* save()) {
        return;
      }
      const latest = yield* call(() => native.errorReportingRead()).pipe(
        Effect.flatMap(decodeState),
      );
      if (
        expected !== revision ||
        !latest.available ||
        latest.generation <= (state?.generation ?? -1)
      ) {
        return;
      }
      state = latest;
    }
  });
  const applyConsent = async ({
    next,
    expected,
    enabled,
    renew,
  }: {
    next: Option.Option<typeof BridgeState.Type>;
    expected: number;
    enabled: boolean;
    renew: boolean;
  }) => {
    if (!isCurrent(expected)) {
      return;
    }
    consentPending = false;
    if (Option.isNone(next)) {
      publish();
      return;
    }
    state = next.value;
    collecting = enabled && consentEnabled(state);
    if (renew) {
      document.deletion = 'idle';
    }
    publish();
    await guarded(
      Effect.gen(function* () {
        if (expected !== revision) {
          return;
        }
        yield* save();
        yield* collecting ? flush() : request('revoke').pipe(Effect.asVoid);
      }),
    );
  };
  const setEnabled = async (enabled: boolean) => {
    if (!canChangeConsent(enabled) || state === undefined) {
      return;
    }
    revision += 1;
    retryAt = 0;
    consentPending = true;
    const expected = revision;
    collecting = false;
    breadcrumbs = [];
    document.queue = [];
    publish();
    const renew = enabled && document.deletion === 'complete';
    const { generation } = state;
    if (!enabled && deleting(document.deletion)) {
      // Native withdrawal must carry durable deletion intent through interruption.
      await runLogged(persistDeletionIntent(expected).pipe(Effect.ignore));
      if (expected !== revision && !disposed) {
        return;
      }
    }
    // Revocation reaches native before waiting for an in-flight network action.
    const consent = call(() =>
      native.errorReportingConsent(enabled, renew, generation),
    ).pipe(Effect.flatMap(decodeState));
    const next = await runLogged(consent.pipe(Effect.option));
    await applyConsent({ next, expected, enabled, renew });
  };
  const deleteReports = async () => {
    if (disposed || state?.available !== true) {
      return;
    }
    document = { version: 1, queue: [], deletion: 'pending' };
    const withdrawal = setEnabled(false);
    const expected = revision;
    await withdrawal;
    if (expected !== revision || disposed) {
      return;
    }
    publish();
    await guarded(
      Effect.gen(function* () {
        if (expected !== revision || disposed) {
          return;
        }
        yield* save();
        yield* deletion();
      }),
    );
  };
  const capture = (error: unknown, code: ReportingCode = 'unhandled-js') => {
    if (!collecting || disposed) {
      return;
    }
    if (Predicate.isObject(error)) {
      if (captured.has(error)) {
        return;
      }
      captured.add(error);
    }
    const expected = revision;
    // Read foreign error properties before scheduling; no arbitrary error is retained.
    let detail: ReturnType<typeof exception> = { name: 'Error' };
    let stack: ReturnType<typeof frames> = [];
    let causes: ReturnType<typeof exceptionCauses> = [];
    try {
      if (['offline', 'cancelled'].includes(rejectionCode(error) ?? '')) {
        return;
      }
      detail = exception(error);
      stack = frames(error);
      causes = exceptionCauses(error);
    } catch {
      return;
    }
    const trail = [...breadcrumbs];
    void guarded(
      Effect.gen(function* () {
        if (!stillCollecting(expected)) {
          return;
        }
        const report: ErrorReport = {
          id: yield* uuid,
          createdAt: yield* Clock.currentTimeMillis,
          code,
          ...detail,
          frames: stack,
          causes,
          breadcrumbs: trail,
        };
        document.queue = [...document.queue, report].slice(-32);
        yield* save();
        yield* flush();
      }),
    );
  };
  async function poll() {
    for (;;) {
      if (disposed) {
        return;
      }
      try {
        await runLogged(Effect.sleep('30 seconds'), {
          signal: lifetime.signal,
        });
      } catch {
        return;
      }
      if (!disposed && loaded) {
        await refresh();
      }
    }
  }
  return {
    getSnapshot: () => snapshot,
    subscribe: (listener) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    load: () => (loaded ? Promise.resolve() : refresh()),
    refresh,
    setEnabled,
    deleteReports,
    retryDeletion: () => guarded(deletion()),
    capture,
    breadcrumb: (breadcrumb) => {
      if (
        collecting &&
        Option.isSome(
          Schema.decodeOption(ReportingBreadcrumbSchema, strict)(breadcrumb),
        )
      ) {
        breadcrumbs = [...breadcrumbs, breadcrumb].slice(-50);
      }
    },
    dispose: () => {
      disposed = true;
      retryAt = 0;
      collecting = false;
      revision += 1;
      lifetime.abort();
      listeners.clear();
      breadcrumbs = [];
      document.queue = [];
    },
  };
}
