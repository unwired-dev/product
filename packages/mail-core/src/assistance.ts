import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type { ReadableBody } from './readable-text.ts';

import {
  decodeDiagnostic,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';
import { hasVisibleText } from './readable-text.ts';

// The host's on-device Apple model. It reads only the text it is given and has no cloud fallback.
export interface NativeAssistance {
  readonly availability: () => Promise<unknown>;
  readonly summarize: (request: string, input: string) => Promise<unknown>;
  readonly cancel: (request: string) => Promise<unknown>;
}

// Why the system model cannot run now. Mail stays readable in every case.
const Unavailable = Schema.Literals([
  'device-ineligible',
  'assistance-disabled',
  'model-not-ready',
  'unsupported-locale',
]);
export type AssistanceUnavailable = typeof Unavailable.Type;

const decodeAvailability = Schema.decodeUnknownEffect(
  Schema.Union([Schema.Literal('available'), Unavailable]),
);
const decodeSummary = Schema.decodeUnknownEffect(
  Schema.String.check(Schema.isMaxLength(4000)),
);
const decodeOutcome = Schema.decodeUnknownOption(
  Schema.Struct({
    code: Schema.Union([
      Unavailable,
      Schema.Literals(['refused', 'cancelled']),
    ]),
  }),
);

// The most message text one summary reads.
// ponytail: a character bound well inside the system model's context window; count tokens if
// long messages are refused for their size.
export const summaryInputLimit = 6000;

export type SummaryInput = Readonly<{ text: string; omitted: boolean }>;

export const readableBodyText = (body: ReadableBody) =>
  body.paragraphs
    .map((spans) => spans.map(({ text }) => text).join(''))
    .join('\n\n');

// The already-local text one summary admits: the subject and the readable body, cut at the limit.
// No readable body means nothing to summarize.
export function summaryInput({
  subject,
  body,
}: Readonly<{ subject?: string | undefined; body: string }>):
  | SummaryInput
  | undefined {
  if (!hasVisibleText(body)) {
    return undefined;
  }
  const text = `${subject === undefined ? '' : `Subject: ${subject}\n\n`}${body.trim()}`;
  if (text.length <= summaryInputLimit) {
    return { text, omitted: false };
  }
  const cut = text.slice(0, summaryInputLimit);
  return {
    // Never end on half of a surrogate pair.
    text: /[\uD800-\uDBFF]$/u.test(cut) ? cut.slice(0, -1) : cut,
    omitted: true,
  };
}

export type SummaryState =
  | { readonly kind: 'idle' }
  | { readonly kind: 'summarizing' }
  | { readonly kind: 'refused' | 'failed' | 'cancelled' }
  | { readonly kind: 'unavailable'; readonly reason: AssistanceUnavailable }
  | {
      readonly kind: 'ready';
      readonly summary: string;
      // Part of the message was beyond the input limit and not read.
      readonly omitted: boolean;
    };

class AssistanceFailure extends Schema.TaggedError<AssistanceFailure>()(
  'AssistanceFailure',
  {
    outcome: Schema.Union([
      Unavailable,
      Schema.Literals(['refused', 'cancelled', 'failed']),
    ]),
    cause: Schema.Defect(),
    // Logged instead of the cause; see rejectionDiagnostic.
    diagnostic: Schema.String,
  },
) {}

const call = (operation: () => Promise<unknown>) =>
  Effect.tryPromise({
    try: operation,
    catch: (cause) =>
      new AssistanceFailure({
        outcome: Option.match(decodeOutcome(cause), {
          onNone: () => 'failed' as const,
          onSome: ({ code }) => code,
        }),
        cause,
        diagnostic: rejectionDiagnostic(cause),
      }),
  });

const malformed = (error: Schema.SchemaError) =>
  new AssistanceFailure({
    outcome: 'failed',
    cause: error,
    diagnostic: decodeDiagnostic(error),
  });

const isUnavailable = Schema.is(Unavailable);

const failedState = (outcome: AssistanceFailure['outcome']): SummaryState =>
  isUnavailable(outcome)
    ? { kind: 'unavailable', reason: outcome }
    : { kind: outcome };

const summarizeLocal = Effect.fnUntraced(
  function* (
    native: NativeAssistance,
    { request, input }: Readonly<{ request: string; input: SummaryInput }>,
    isCurrent: () => boolean,
  ) {
    const availability = yield* call(() => native.availability()).pipe(
      Effect.flatMap((value) =>
        decodeAvailability(value).pipe(Effect.mapError(malformed)),
      ),
    );
    if (availability !== 'available') {
      return { kind: 'unavailable', reason: availability } as const;
    }
    // Cancellation may have happened while availability was pending. There is no asynchronous
    // suspension between this ownership check and the native call.
    if (!isCurrent()) {
      return { kind: 'cancelled' } as const;
    }
    const summary = yield* call(() =>
      native.summarize(request, input.text),
    ).pipe(
      Effect.flatMap((value) =>
        decodeSummary(value).pipe(Effect.mapError(malformed)),
      ),
    );
    if (!hasVisibleText(summary)) {
      return { kind: 'failed' } as const;
    }
    return {
      kind: 'ready',
      summary: summary.trim(),
      omitted: input.omitted,
    } as const;
  },
  // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
  Effect.catchTag('AssistanceFailure', (error) =>
    (error.outcome === 'failed'
      ? Effect.logError('On-device assistance failed:', error.diagnostic)
      : Effect.void
    ).pipe(Effect.as(failedState(error.outcome))),
  ),
);

let requests = 0;
const idle: SummaryState = { kind: 'idle' };

// One reader's explicitly requested summary of one message. A result belongs to the input it was
// requested for: any other input reads as idle, and a cancelled or discarded request's late
// result is dropped. Nothing is stored or written to mail.
export function createMessageSummary(native: NativeAssistance) {
  let shown:
    | Readonly<{ input: SummaryInput; state: SummaryState }>
    | undefined = undefined;
  let running: Readonly<{ input: SummaryInput; request: string }> | undefined =
    undefined;
  const listeners = new Set<() => void>();
  const publish = (input: SummaryInput | undefined, state: SummaryState) => {
    shown = input === undefined ? undefined : { input, state };
    for (const listener of listeners) {
      listener();
    }
  };
  const same = (left: SummaryInput, right: SummaryInput) =>
    left.text === right.text && left.omitted === right.omitted;
  const stop = () => {
    if (running === undefined) {
      return undefined;
    }
    const { input, request } = running;
    running = undefined;
    void runLogged(call(() => native.cancel(request)).pipe(Effect.ignore));
    return input;
  };
  return {
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    // The state for the reader's current input.
    getSnapshot: (input: SummaryInput) =>
      shown !== undefined && same(shown.input, input) ? shown.state : idle,
    summarize: async (input: SummaryInput) => {
      if (running !== undefined && same(running.input, input)) {
        return;
      }
      stop();
      requests += 1;
      const request = `summary-${requests}`;
      running = { input, request };
      publish(input, { kind: 'summarizing' });
      const state = await runLogged(
        summarizeLocal(
          native,
          { request, input },
          () => running?.request === request,
        ),
      );
      if (running?.request === request) {
        running = undefined;
        publish(input, state);
      }
    },
    cancel: () => {
      const input = stop();
      if (input !== undefined) {
        publish(input, { kind: 'cancelled' });
      }
    },
    // Dismissal, or a reader whose message or account changed: forget the preview.
    discard: () => {
      stop();
      publish(undefined, idle);
    },
  };
}

export type MessageSummary = ReturnType<typeof createMessageSummary>;

// Retrying cannot help an ineligible device or a refused message.
export const canRetrySummary = (state: SummaryState) =>
  state.kind !== 'refused' &&
  !(state.kind === 'unavailable' && state.reason === 'device-ineligible');
