import * as Arr from 'effect/Array';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import {
  decodeDiagnostic,
  rejectionDiagnostic,
  runLogged,
} from '../diagnostics.ts';

// Spikes #831 (Mac) and #830 (iPhone and iPad), compiled only into the `categorization-spike`
// Mock Mail Session build: the native Core ML runner's wire format and one page session, which
// classifies bundled public and synthetic samples with the frozen DeBERTa candidates. It reads no
// mailbox, changes no assignment and has no server fallback. Its research copy stays English and
// outside the localization catalogs because the page never ships.

const CategoryText = Schema.Struct({
  name: Schema.String,
  description: Schema.String,
});
const CandidateEntry = Schema.Struct({
  run: Schema.String,
  mode: Schema.Literals(['system', 'custom']),
  maxLength: Schema.Finite,
  precisions: Schema.Array(Schema.Literals(['fp16', 'int8'])),
});
const SampleEntry = Schema.Struct({
  id: Schema.String,
  language: Schema.String,
  subject: Schema.String,
});
const CategoryEntry = Schema.Struct({
  id: Schema.String,
  en: CategoryText,
  cs: CategoryText,
});
const Host = Schema.Struct({ model: Schema.String, os: Schema.String });
const AutorunMode = Schema.NullOr(Schema.Literals(['matrix', 'states']));
const Catalog = Schema.fromJsonString(
  Schema.Struct({
    candidates: Schema.Array(CandidateEntry),
    messages: Schema.Array(SampleEntry),
    categories: Schema.Array(CategoryEntry),
    host: Host,
    evidence: Schema.String,
    autorun: AutorunMode,
  }),
);
export type CatalogValue = typeof Catalog.Type;

const Score = Schema.Struct({
  category: Schema.String,
  probability: Schema.Finite,
  threshold: Schema.Finite,
  member: Schema.Boolean,
});
const Classification = Schema.Struct({
  scores: Schema.Array(Score),
  categories: Schema.Array(Schema.String),
  tokens: Schema.Array(Schema.Finite),
  passes: Schema.Finite,
  milliseconds: Schema.Array(Schema.Finite),
});
export type ClassificationValue = typeof Classification.Type;
const Lag = Schema.Struct({ p95: Schema.Finite });
const Process = Schema.Struct({
  peakFootprintMB: Schema.Finite,
  energyMillijoules: Schema.Finite,
  thermalBefore: Schema.String,
  thermalAfter: Schema.String,
  mainThreadLagMs: Lag,
});
const PassTimes = Schema.Struct({ p50: Schema.Finite, p95: Schema.Finite });
const GoldenReport = Schema.Struct({
  checked: Schema.Finite,
  tokenMismatches: Schema.Array(Schema.String),
  maxAbsProbabilityDifference: Schema.Finite,
  decisionChanges: Schema.Array(Schema.String),
});
const Counts = Schema.Record(Schema.String, Schema.Finite);
const Plan = Schema.Struct({ preferred: Counts, withoutNeuralEngine: Counts });
const Result = Schema.fromJsonString(
  Schema.Struct({
    loadMs: Schema.optional(Schema.Finite),
    process: Process,
    input: Schema.optional(Schema.String),
    classification: Schema.optional(Classification),
    messagesPerSecond: Schema.optional(Schema.Finite),
    passMs: Schema.optional(PassTimes),
    golden: Schema.optional(GoldenReport),
    plan: Schema.optional(Plan),
  }),
);
export type ResultValue = typeof Result.Type;
const Progress = Schema.NullOr(
  Schema.Struct({ done: Schema.Finite, total: Schema.Finite }),
);
export type ProgressValue = typeof Progress.Type;
const NativeCode = Schema.Struct({ code: Schema.String });
class SpikeFailure extends Schema.TaggedError<SpikeFailure>()('SpikeFailure', {
  cause: Schema.Defect(),
}) {}
const nativeCall = <A>(run: () => Promise<A>) =>
  Effect.tryPromise({
    try: run,
    catch: (cause) => new SpikeFailure({ cause }),
  });

export const decodeProgress = (value: unknown) =>
  Option.getOrUndefined(Schema.decodeUnknownOption(Progress)(value));

// The native module, UnwiredCategorizationSpike, as both hosts register it.
export interface SpikeModule {
  readonly catalog: () => Promise<string>;
  readonly classify: (request: string, body: string) => Promise<string>;
  readonly benchmark: (request: string, body: string) => Promise<string>;
  readonly golden: (request: string, body: string) => Promise<string>;
  readonly computePlan: (request: string, body: string) => Promise<string>;
  readonly progress: (request: string) => Promise<unknown>;
  readonly cancel: (request: string) => Promise<void>;
  readonly release: () => Promise<unknown>;
}

// The native catalog, or undefined when the build has no exported models or no runner.
export async function loadCatalog(module: SpikeModule | null) {
  if (module === null) {
    return undefined;
  }
  return runLogged(
    Effect.gen(function* () {
      const value = yield* nativeCall(() => module.catalog());
      const decoded = yield* Schema.decodeEffect(Catalog)(value);
      return decoded.candidates.length > 0 ? decoded : undefined;
    }).pipe(
      Effect.catchTags({
        SpikeFailure: (error) =>
          Effect.as(
            Effect.logError(
              'Categorization spike catalog unavailable',
              rejectionDiagnostic(error.cause),
            ),
            undefined,
          ),
        SchemaError: (error) =>
          Effect.as(
            Effect.logError(
              'Invalid categorization spike catalog',
              decodeDiagnostic(error),
            ),
            undefined,
          ),
      }),
    ),
  );
}

export const units = [
  ['all', 'CPU, GPU and Neural Engine'],
  ['cpuAndGPU', 'CPU and GPU'],
  ['cpuAndNeuralEngine', 'CPU and Neural Engine'],
  ['cpuOnly', 'CPU only'],
] as const;
export type Unit = (typeof units)[number][0];
// The six Custom Categories with golden outputs (custom_report.py GOLDEN_CATEGORIES).
const goldenCategories = [
  'online-purchases',
  'flights-booked',
  'statements',
  'kids-school',
  'event-invitations',
  'family-friends',
];
export const categoryCounts = [6, 5, 20, 50] as const;
export type CategoryCount = (typeof categoryCounts)[number];
export const rounds = 3;
// Every window shares this runtime, so identities survive page remounts too.
let requests = 0;

export type Kind = 'classify' | 'benchmark' | 'golden' | 'plan';
export type Busy = Readonly<{ request: string; kind: Kind }>;
export type Selection = Readonly<{
  run: string;
  precision: 'fp16' | 'int8';
  unit: Unit;
  message: string;
  count: CategoryCount;
}>;

export const ms = (value: number) => `${value.toFixed(value < 10 ? 1 : 0)} ms`;
export const probability = (value: number) =>
  value.toFixed(value < 0.01 ? 3 : 2);
export const median = (values: readonly number[]) =>
  Arr.sort(values, Order.Number)[Math.floor(values.length / 2)] ?? 0;
export const categoryName = (
  catalog: CatalogValue,
  language: string,
  id: string,
) => {
  const found = catalog.categories.find((each) => each.id === id);
  if (found === undefined) {
    return id;
  }
  return (language === 'cs' ? found.cs : found.en).name;
};

// The request body for one bridge call: the golden categories when they are selected, otherwise
// the first `count` Custom Categories.
const requestBody = (selection: Selection & Readonly<{ custom: boolean }>) => {
  const categories =
    selection.custom && selection.count === 6
      ? { categories: goldenCategories }
      : { categoryCount: selection.custom ? selection.count : 0 };
  return JSON.stringify({
    run: selection.run,
    precision: selection.precision,
    units: selection.unit,
    message: selection.message,
    rounds,
    ...categories,
  });
};

const call = (module: SpikeModule, kind: Kind) =>
  ({
    classify: module.classify,
    benchmark: module.benchmark,
    golden: module.golden,
    plan: module.computePlan,
  })[kind];

export type SpikeState = Readonly<{
  selection: Selection;
  busy: Busy | undefined;
  result: ResultValue | undefined;
  failure: string | undefined;
}>;

// One page's session with the runner. At most one request runs; a result that arrives after
// Cancel, a newer request or close is never shown. Close stops the running request before its
// next model pass and releases the model. `device` names this host in the failure text.
export function spikeSession({
  module,
  catalog,
  device,
}: Readonly<{
  module: SpikeModule;
  catalog: CatalogValue;
  device: string;
}>) {
  let state: SpikeState = {
    selection: {
      run: catalog.candidates[0]?.run ?? '',
      precision: 'fp16',
      unit: 'all',
      message: catalog.messages[0]?.id ?? '',
      count: 6,
    },
    busy: undefined,
    result: undefined,
    failure: undefined,
  };
  let current: string | undefined = undefined;
  let cancelled: string | undefined = undefined;
  let closed = false;
  const listeners = new Set<() => void>();
  const gate = Semaphore.makeUnsafe(1);
  const unavailable = `The candidate could not run on this ${device}. Categorization stays unavailable; it has no server fallback.`;
  const cancelledText =
    'Cancelled before the next model pass; no partial result is shown.';
  const set = (next: Partial<SpikeState>) => {
    state = { ...state, ...next };
    if (!closed) {
      for (const listener of listeners) {
        listener();
      }
    }
  };
  const cleanup = (request: string | undefined) => {
    const release = nativeCall(() => module.release()).pipe(
      // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
      Effect.catchTag('SpikeFailure', (error) =>
        Effect.logError(
          'Categorization spike release failed',
          rejectionDiagnostic(error.cause),
        ),
      ),
    );
    return runLogged(
      Effect.gen(function* () {
        if (request !== undefined) {
          yield* nativeCall(() => module.cancel(request)).pipe(
            Effect.catchTag('SpikeFailure', (error) =>
              Effect.logError(
                'Categorization spike cancel failed',
                rejectionDiagnostic(error.cause),
              ),
            ),
          );
        }
        yield* release;
      }),
    );
  };
  return {
    getSnapshot: () => state,
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    get closed() {
      return closed;
    },
    // A new selection retires the shown result.
    choose(selection: Selection) {
      if (closed || state.busy !== undefined) {
        return;
      }
      set({ selection, result: undefined, failure: undefined });
    },
    start(kind: Kind, picked: Selection) {
      return runLogged(
        gate.withPermitsIfAvailable(1)(
          Effect.gen(function* () {
            if (closed) {
              return;
            }
            requests += 1;
            const request = `${kind}-${requests}`;
            current = request;
            set({
              selection: picked,
              busy: { request, kind },
              result: undefined,
              failure: undefined,
            });
            const custom =
              catalog.candidates.find((each) => each.run === picked.run)
                ?.mode === 'custom';
            const decoded = yield* nativeCall(() =>
              call(module, kind)(request, requestBody({ ...picked, custom })),
            ).pipe(
              Effect.flatMap(Schema.decodeUnknownEffect(Result)),
              Effect.catchTags({
                SpikeFailure: (error) =>
                  Effect.gen(function* () {
                    const code = Schema.decodeUnknownOption(NativeCode)(
                      error.cause,
                    );
                    if (
                      Option.isSome(code) &&
                      code.value.code === 'cancelled'
                    ) {
                      cancelled = request;
                    } else {
                      yield* Effect.logError(
                        'Categorization spike failed',
                        rejectionDiagnostic(error.cause),
                      );
                    }
                    return undefined;
                  }),
                SchemaError: (error) =>
                  Effect.gen(function* () {
                    yield* Effect.logError(
                      'Invalid categorization spike result',
                      decodeDiagnostic(error),
                    );
                    return undefined;
                  }),
              }),
            );
            if (current !== request) {
              return;
            }
            current = undefined;
            if (cancelled === request) {
              set({ busy: undefined, failure: cancelledText });
              return;
            }
            set(
              decoded === undefined
                ? { busy: undefined, failure: unavailable }
                : { busy: undefined, result: decoded },
            );
          }),
        ),
      );
    },
    cancel() {
      if (current !== undefined) {
        cancelled = current;
        void cleanup(current);
      }
    },
    close() {
      closed = true;
      const request = current;
      current = undefined;
      void cleanup(request);
    },
  };
}
export type SpikeSession = Readonly<ReturnType<typeof spikeSession>>;

const pause = (seconds: number) =>
  // oxlint-disable-next-line promise/avoid-new -- Hold each state long enough to capture it.
  new Promise<void>((resolve) => {
    setTimeout(resolve, seconds * 1000);
  });

const systemSmall = 'deberta-xsmall-body256';
const systemBase = 'deberta-mdeberta-body512';
const customSmall = 'xsmall-zs-adapted-body256-description';
const customBase = 'mdeberta-nli-adapted-body256-description';

// The design states in order: a System result, an Uncategorized Custom result, a benchmark that
// Cancel stops, and a benchmark that dismissal stops.
async function autorunStates(
  catalog: CatalogValue,
  session: SpikeSession,
  dismiss: () => void,
) {
  const message =
    catalog.messages.find((each) => each.subject === 'Your change fee receipt')
      ?.id ?? '';
  const base: Selection = {
    run: systemSmall,
    precision: 'fp16',
    unit: 'all',
    message,
    count: 6,
  };
  await session.start('classify', base);
  await pause(15);
  await session.start('classify', {
    ...base,
    run: customSmall,
    precision: 'int8',
    unit: 'cpuAndNeuralEngine',
  });
  await pause(15);
  const cancelled = session.start('benchmark', {
    ...base,
    run: customBase,
    count: 20,
  });
  await pause(20);
  session.cancel();
  await cancelled;
  await pause(15);
  void session.start('benchmark', { ...base, run: customBase, count: 50 });
  await pause(20);
  if (!session.closed) {
    dismiss();
  }
}

// Every candidate and precision: golden outputs, a classification and benchmarks (Custom
// Category counts 5, 20 and 50), compute plans, then the compute-unit comparison.
async function autorunMatrix(catalog: CatalogValue, session: SpikeSession) {
  const base: Selection = {
    run: systemSmall,
    precision: 'fp16',
    unit: 'all',
    message: catalog.messages[0]?.id ?? '',
    count: 6,
  };
  for (const run of [systemSmall, systemBase, customSmall, customBase]) {
    const counts: CategoryCount[] = run.includes('adapted') ? [5, 20, 50] : [6];
    for (const precision of ['fp16', 'int8'] as const) {
      const picked = { ...base, run, precision };
      await session.start('golden', picked);
      await session.start('classify', picked);
      for (const count of counts) {
        await session.start('benchmark', { ...picked, count });
      }
    }
    for (const unit of ['all', 'cpuAndNeuralEngine'] as const) {
      await session.start('plan', { ...base, run, unit });
    }
  }
  for (const unit of ['cpuOnly', 'cpuAndGPU', 'cpuAndNeuralEngine'] as const) {
    await session.start('benchmark', { ...base, unit });
  }
}

// An unattended run, selected at launch for hosts without UI automation, through the same actions
// as the page's buttons. `dismiss` unmounts the page as closing it would.
export function autorun(
  catalog: CatalogValue,
  session: SpikeSession,
  dismiss: () => void,
) {
  if (catalog.autorun === 'states') {
    void autorunStates(catalog, session, dismiss);
  } else if (catalog.autorun === 'matrix') {
    void autorunMatrix(catalog, session);
  }
}
