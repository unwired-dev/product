import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type { Draft, Recipient } from './drafts.ts';
import type { ReadableBody } from './readable-text.ts';
import type { Selection, SemanticDocument } from './semantic-document.ts';

import {
  decodeDiagnostic,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';
import { hasVisibleText } from './readable-text.ts';
import {
  displayOf,
  imageCharacter,
  selectedText,
} from './semantic-document.ts';

// The host's on-device Apple model. It reads only the text it is given and has no cloud fallback.
export interface NativeAssistance {
  readonly availability: () => Promise<unknown>;
  readonly summarize: (request: string, input: string) => Promise<unknown>;
  // A meaning-preserving rewrite of authored Draft text.
  readonly rewrite: (request: string, input: string) => Promise<unknown>;
  // One full reply from a reply Draft's authored text, recipient names and quoted message.
  readonly suggestReply: (request: string, input: string) => Promise<unknown>;
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
// Rewritten text can be longer than its source, but not without bound: twice the input limit.
// Applying text drops image placeholders, so a result containing one could delete authored text.
const decodeDraftText = Schema.decodeUnknownEffect(
  Schema.String.check(
    Schema.isMaxLength(12_000),
    Schema.makeFilter((text) => !text.includes(imageCharacter)),
  ),
);
const decodeOutcome = Schema.decodeUnknownOption(
  Schema.Struct({
    code: Schema.Union([
      Unavailable,
      Schema.Literals(['refused', 'cancelled']),
    ]),
  }),
);

// The most message text one summary or translation reads.
// ponytail: a character bound well inside the system model's context window; count tokens if
// long messages are refused for their size.
export const summaryInputLimit = 6000;

// The most To and Cc recipients a reply suggestion inspects for display names, so a Draft with
// very many address-only recipients is never walked whole.
const recipientLimit = 100;

export type SummaryInput = Readonly<{ text: string; omitted: boolean }>;

const ModelRequest = Schema.Union([
  Schema.Struct({
    operation: Schema.Literal('summary'),
    subject: Schema.String,
    body: Schema.String,
  }),
  Schema.Struct({
    operation: Schema.Literal('rewrite'),
    authoredText: Schema.String,
  }),
  Schema.Struct({
    operation: Schema.Literal('reply'),
    recipientNames: Schema.String,
    authoredText: Schema.String,
    quotedText: Schema.String,
  }),
]);
// oxlint-disable-next-line node/no-sync -- Pure JSON serialization of locally constructed string fields, not synchronous I/O.
const encodeModelRequest = Schema.encodeSync(
  Schema.fromJsonString(ModelRequest),
);
// oxlint-disable-next-line node/no-sync -- Pure string escaping for the model input budget, not synchronous I/O.
const encodeString = Schema.encodeSync(Schema.fromJsonString(Schema.String));

// Fit the escaped string, not its raw length, without cutting a surrogate pair.
function jsonBoundedInput(text: string, limit: number): SummaryInput {
  let low = 0;
  let high = Math.min(text.length, limit);
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    if (encodeString(boundedInput(text, middle).text).length - 2 <= limit) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return boundedInput(text, low);
}

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
  const empty = { operation: 'summary', subject: '', body: '' } as const;
  const budget = summaryInputLimit - encodeModelRequest(empty).length;
  const title = jsonBoundedInput(subject ?? '', budget);
  const text = jsonBoundedInput(
    body.trim(),
    budget - (encodeString(title.text).length - 2),
  );
  return {
    text: encodeModelRequest({
      ...empty,
      subject: title.text,
      body: text.text,
    }),
    omitted: title.omitted || text.omitted,
  };
}

// At most `limit` code units of `text`, and whether the rest was left out.
export function boundedInput(
  text: string,
  limit = summaryInputLimit,
): SummaryInput {
  if (text.length <= limit) {
    return { text, omitted: false };
  }
  const cut = text.slice(0, limit);
  return {
    // Never end on half of a surrogate pair.
    text: /[\uD800-\uDBFF]$/u.test(cut) ? cut.slice(0, -1) : cut,
    omitted: true,
  };
}

// One generated preview's state, with `Pending` while the model works.
export type AssistanceState<Pending extends string> =
  | { readonly kind: 'idle' }
  | { readonly kind: Pending }
  | { readonly kind: 'refused' | 'failed' | 'cancelled' }
  | { readonly kind: 'unavailable'; readonly reason: AssistanceUnavailable }
  | {
      readonly kind: 'ready';
      readonly text: string;
      // Part of the input was beyond the input limit and not read.
      readonly omitted: boolean;
    };

export type SummaryState = AssistanceState<'summarizing'>;

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

// A native rejection's fields for an assistance failure: its allow-listed code as the outcome,
// or `failed` for anything else.
export const rejectionFields =
  <Code extends string>(
    decode: (cause: unknown) => Option.Option<Readonly<{ code: Code }>>,
  ) =>
  (cause: unknown) => ({
    outcome: Option.match(decode(cause), {
      onNone: () => 'failed' as const,
      onSome: ({ code }) => code,
    }),
    cause,
    diagnostic: rejectionDiagnostic(cause),
  });

// A malformed native result's fields for an assistance failure.
export const malformedFields = (error: Schema.SchemaError) => ({
  outcome: 'failed' as const,
  cause: error,
  diagnostic: decodeDiagnostic(error),
});

const rejection = rejectionFields(decodeOutcome);

const call = (operation: () => Promise<unknown>) =>
  Effect.tryPromise({
    try: operation,
    catch: (cause) => new AssistanceFailure(rejection(cause)),
  });

const malformed = (error: Schema.SchemaError) =>
  new AssistanceFailure(malformedFields(error));

const isUnavailable = Schema.is(Unavailable);

const failedState = (outcome: AssistanceFailure['outcome']) =>
  isUnavailable(outcome)
    ? ({ kind: 'unavailable', reason: outcome } as const)
    : ({ kind: outcome } as const);

// One model operation on captured input, once the system model is available.
const generateLocal = Effect.fnUntraced(
  function* (
    native: NativeAssistance,
    {
      request,
      input,
      generate,
      decode,
    }: Readonly<{
      request: string;
      input: SummaryInput;
      generate: (request: string, input: string) => Promise<unknown>;
      decode: typeof decodeSummary;
    }>,
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
    const text = yield* call(() => generate(request, input.text)).pipe(
      Effect.flatMap((value) => decode(value).pipe(Effect.mapError(malformed))),
    );
    if (!hasVisibleText(text)) {
      return { kind: 'failed' } as const;
    }
    return {
      kind: 'ready',
      text: text.trim(),
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

// One explicitly requested on-device operation on captured local input. A result belongs to the
// input it was requested for: any other input reads as idle, and a cancelled or discarded
// request's late result is dropped. Nothing is stored or written to mail.
export function createAssistanceRequest<Input, State extends { kind: string }>({
  run,
  cancel,
  same,
  idle,
  pending,
  cancelled,
}: Readonly<{
  run: (
    request: string,
    input: Input,
    isCurrent: () => boolean,
  ) => Promise<State>;
  cancel: (request: string) => Promise<unknown>;
  same: (left: Input, right: Input) => boolean;
  idle: State;
  pending: State;
  cancelled: State;
}>) {
  let shown: Readonly<{ input: Input; state: State }> | undefined = undefined;
  let running: Readonly<{ input: Input; request: string }> | undefined =
    undefined;
  const listeners = new Set<() => void>();
  const publish = (input: Input | undefined, state: State) => {
    shown = input === undefined ? undefined : { input, state };
    for (const listener of listeners) {
      listener();
    }
  };
  const stop = () => {
    if (running === undefined) {
      return undefined;
    }
    const { input, request } = running;
    running = undefined;
    void runLogged(call(() => cancel(request)).pipe(Effect.ignore));
    return input;
  };
  return {
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    // The state for the caller's current input.
    getSnapshot: (input: Input) =>
      shown !== undefined && same(shown.input, input) ? shown.state : idle,
    start: async (input: Input) => {
      if (running !== undefined && same(running.input, input)) {
        return;
      }
      stop();
      requests += 1;
      const request = `assistance-${requests}`;
      running = { input, request };
      publish(input, pending);
      const state = await run(
        request,
        input,
        () => running?.request === request,
      );
      if (running?.request === request) {
        running = undefined;
        publish(input, state);
      }
    },
    cancel: () => {
      const input = stop();
      if (input !== undefined) {
        publish(input, cancelled);
      }
    },
    // Dismissal, or a caller whose message, account or input changed: forget the preview.
    discard: () => {
      stop();
      publish(undefined, idle);
    },
  };
}

// One reader's explicitly requested summary of one message.
export function createMessageSummary(native: NativeAssistance) {
  const { start, ...summary } = createAssistanceRequest<
    SummaryInput,
    SummaryState
  >({
    run: (request, input, isCurrent) =>
      runLogged(
        generateLocal(
          native,
          {
            request,
            input,
            generate: (id, text) => native.summarize(id, text),
            decode: decodeSummary,
          },
          isCurrent,
        ),
      ),
    cancel: (request) => native.cancel(request),
    same: (left, right) =>
      left.text === right.text && left.omitted === right.omitted,
    idle: { kind: 'idle' },
    pending: { kind: 'summarizing' },
    cancelled: { kind: 'cancelled' },
  });
  return { ...summary, summarize: start };
}

export type MessageSummary = ReturnType<typeof createMessageSummary>;

// Retrying cannot help an ineligible device or refused input.
export const canRetryAssistance = (state: AssistanceState<string>) =>
  state.kind !== 'refused' &&
  !('reason' in state && state.reason === 'device-ineligible');

// Draft text --------------------------------------------------------------------------------------

// Why captured Draft text cannot go to assistance. Accepting a result replaces all of it, so it is
// never cut, and a text result cannot retain selected semantic image spans.
export const draftTextIssue = (
  text: string,
  purpose: 'translate' | 'rewrite' | 'reply' = 'translate',
) => {
  if (text.length > summaryInputLimit) {
    return 'too-long';
  }
  if (text.includes(imageCharacter)) {
    return 'inline-image';
  }
  if (
    purpose === 'rewrite' &&
    encodeModelRequest({ operation: 'rewrite', authoredText: text }).length >
      summaryInputLimit
  ) {
    return 'too-long';
  }
  return undefined;
};

// The text that replaces captured Draft text: the result, trimmed for the preview, between the
// capture's own leading and trailing whitespace so neighbouring words stay separated.
export const draftReplacement = (selected: string, replacement: string) =>
  `${/^\s*/u.exec(selected)?.[0] ?? ''}${replacement.trim()}${/\s*$/u.exec(selected)?.[0] ?? ''}`;

export type DraftAssistanceInput = Readonly<
  SummaryInput & { purpose: 'rewrite' | 'reply' }
>;
export type DraftAssistanceState = AssistanceState<'generating'>;

export type CapturedDraftText = Readonly<{
  purpose: 'translate' | 'rewrite' | 'reply';
  draft: Draft;
  selection: Selection;
  text: string;
  // Translation chooses its own language; a refused model input cannot run.
  input: DraftAssistanceInput | undefined;
  // Why a rewrite or reply input was refused, when the person can act on it.
  issue: 'too-long' | 'inline-image' | undefined;
}>;

// Whether Rewrite has text: the selection's, or with a collapsed caret any authored text.
// The whole-body check stops at the first visible span without projecting document ranges.
export const canRewrite = (body: Draft['body'], at: Selection) =>
  at.start === at.end
    ? body.some(({ spans }) =>
        spans.some((span) => !('image' in span) && hasVisibleText(span.text)),
      )
    : hasVisibleText(selectedText(body, at, summaryInputLimit + 1));

// Only Reply and Reply All Drafts with local quoted correspondence admit a reply suggestion.
export const canSuggestReply = ({ quoted, response }: Draft) =>
  quoted !== undefined && response !== undefined && response.kind !== 'forward';

// Selected authored text, or the whole authored body, to rewrite.
export const rewriteInput = (text: string): DraftAssistanceInput | undefined =>
  hasVisibleText(text) && draftTextIssue(text, 'rewrite') === undefined
    ? {
        purpose: 'rewrite',
        text: encodeModelRequest({ operation: 'rewrite', authoredText: text }),
        omitted: false,
      }
    : undefined;

// Captured text belongs to its body revision; replies also capture their admitted context.
export const sameDraftAssistanceSource = (
  captured: Draft,
  current: Draft,
  purpose: 'translate' | 'rewrite' | 'reply',
) =>
  captured.body === current.body &&
  (purpose !== 'reply' ||
    (captured.to === current.to &&
      captured.cc === current.cc &&
      captured.quoted === current.quoted));

// Response Assistance never admits raw addresses, such as the one in a quoted attribution line:
// every word containing "@" is dropped. Linear in the bounded text it is given.
const withoutAddresses = (text: string) =>
  text
    .split(/(?<space>\s+)/u)
    .filter((word) => !word.includes('@'))
    .join('');

// Drop a cut word regardless of length: it may contain an address whose "@" was left out.
function redactedBoundedInput(text: string, limit: number): SummaryInput {
  const bounded = boundedInput(text, limit);
  const cut = bounded.text.length;
  let start = cut;
  if (bounded.omitted && /\S/u.test(text[cut] ?? '')) {
    while (start > 0 && /\S/u.test(bounded.text[start - 1] ?? '')) {
      start -= 1;
    }
  }
  return {
    text: withoutAddresses(bounded.text.slice(0, start)),
    omitted: bounded.omitted,
  };
}

// Read only the quoted prefix plus one lookahead character, excluding semantic images.
function quotedInput(quoted: SemanticDocument, limit: number): SummaryInput {
  const pieces = function* () {
    for (const [index, { spans }] of quoted.entries()) {
      yield index === 0 ? '' : '\n';
      for (const span of spans) {
        if (!('image' in span)) {
          yield span.text;
        }
      }
    }
  };
  let text = '';
  for (const piece of pieces()) {
    text += piece.slice(0, limit + 1 - text.length);
    if (text.length > limit) {
      break;
    }
  }
  return {
    text: redactedBoundedInput(text, limit).text.trim(),
    omitted: text.length > limit,
  };
}

// A reply Draft's admitted context: its authored text, the display names of its To and Cc
// recipients (never addresses or Bcc) and its already-local quoted message, which is cut so the
// whole input stays within the limit. Only the authored text is replaced by the result.
function captureReplyInput({
  authored,
  recipients,
  quoted,
}: Readonly<{
  authored: string;
  recipients: readonly Recipient[];
  quoted: SemanticDocument;
}>): Pick<CapturedDraftText, 'input' | 'issue'> {
  const issue = draftTextIssue(authored);
  if (issue !== undefined) {
    return { input: undefined, issue };
  }
  let names = '';
  for (const { name } of recipients.slice(0, recipientLimit)) {
    if (name !== undefined) {
      names += names === '' ? '' : ', '.slice(0, 501 - names.length);
      names += name.slice(0, 501 - names.length);
      if (names.length === 501) {
        break;
      }
    }
  }
  // Bound the raw prefix before redaction; removed addresses never refill its budget.
  const shown = redactedBoundedInput(names, 500).text.trim();
  const request = {
    operation: 'reply',
    recipientNames: shown,
    authoredText: authored.trim(),
    quotedText: '',
  } as const;
  const budget = summaryInputLimit - encodeModelRequest(request).length;
  if (budget <= 0) {
    return { input: undefined, issue: 'too-long' };
  }
  const raw = quotedInput(quoted, budget);
  const bounded = jsonBoundedInput(raw.text, budget);
  const context = redactedBoundedInput(raw.text, bounded.text.length);
  if (!hasVisibleText(context.text)) {
    return { input: undefined, issue: undefined };
  }
  return {
    input: {
      purpose: 'reply',
      text: encodeModelRequest({ ...request, quotedText: context.text.trim() }),
      omitted: raw.omitted || context.omitted,
    },
    issue: undefined,
  };
}

export const replyInput = (
  source: Parameters<typeof captureReplyInput>[0],
): DraftAssistanceInput | undefined => captureReplyInput(source).input;

// Capture policy is shared by both editors; hosts retain ownership and apply the reviewed edit.
export function captureDraftText(
  purpose: CapturedDraftText['purpose'],
  draft: Draft,
  at: Selection,
): CapturedDraftText {
  // Rewrite defaults to the whole body; a reply suggestion always replaces the whole body.
  const selection =
    purpose === 'reply' || (purpose === 'rewrite' && at.start === at.end)
      ? { start: 0, end: displayOf(draft.body).text.length }
      : at;
  const text = selectedText(draft.body, selection, summaryInputLimit + 1);
  let input: DraftAssistanceInput | undefined = undefined;
  let issue: CapturedDraftText['issue'] = undefined;
  if (purpose === 'rewrite') {
    input = rewriteInput(text);
    issue = input === undefined ? draftTextIssue(text, purpose) : undefined;
  } else if (purpose === 'reply' && draft.quoted !== undefined) {
    ({ input, issue } = captureReplyInput({
      authored: text,
      recipients: [
        ...draft.to.slice(0, recipientLimit),
        ...draft.cc.slice(0, recipientLimit),
      ],
      quoted: draft.quoted,
    }));
  }
  return { purpose, draft, selection, text, input, issue };
}

// One composer's explicitly requested rewrite or reply suggestion. The preview is never stored or
// synchronized; the Draft changes only when its owner applies it.
export const createDraftAssistance = (native: NativeAssistance) =>
  createAssistanceRequest<DraftAssistanceInput, DraftAssistanceState>({
    run: (request, input, isCurrent) =>
      runLogged(
        generateLocal(
          native,
          {
            request,
            input,
            generate: (id, text) =>
              input.purpose === 'rewrite'
                ? native.rewrite(id, text)
                : native.suggestReply(id, text),
            decode: decodeDraftText,
          },
          isCurrent,
        ),
      ),
    cancel: (request) => native.cancel(request),
    same: (left, right) =>
      left.purpose === right.purpose &&
      left.text === right.text &&
      left.omitted === right.omitted,
    idle: { kind: 'idle' },
    pending: { kind: 'generating' },
    cancelled: { kind: 'cancelled' },
  });

export type DraftAssistance = ReturnType<typeof createDraftAssistance>;
