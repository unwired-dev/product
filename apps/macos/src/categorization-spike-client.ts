import * as Arr from 'effect/Array';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Schema from 'effect/Schema';

// Native wire decoding for the Mac-only research build. No mailbox or assignment logic.
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

export const unavailable =
  'The candidate could not run on this Mac. Categorization stays unavailable; it has no server fallback.';

export const failureText = (error: unknown) => {
  const code = Schema.decodeUnknownOption(NativeCode)(error);
  return Option.isSome(code) && code.value.code === 'cancelled'
    ? 'Cancelled before the next model pass; no partial result is shown.'
    : unavailable;
};

export const decodeCatalog = (value: unknown) =>
  Option.getOrUndefined(Schema.decodeUnknownOption(Catalog)(value));
export const decodeResult = (value: unknown) =>
  Option.getOrUndefined(Schema.decodeUnknownOption(Result)(value));
export const decodeProgress = (value: unknown) =>
  Option.getOrUndefined(Schema.decodeUnknownOption(Progress)(value));
export type ClassificationValue = typeof Classification.Type;

export const median = (values: readonly number[]) =>
  Arr.sort(values, Order.Number)[Math.floor(values.length / 2)] ?? 0;
