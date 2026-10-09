import * as Arr from 'effect/Array';
import * as Effect from 'effect/Effect';
import * as Order from 'effect/Order';
import * as Schema from 'effect/Schema';

import type { SummaryInput } from './assistance.ts';
import type { ReadableBody } from './readable-text.ts';

import {
  boundedInput,
  createAssistanceRequest,
  malformedFields,
  rejectionFields,
  summaryInputLimit,
} from './assistance.ts';
import { runLogged } from './diagnostics.ts';
import { hasVisibleText } from './readable-text.ts';

// The host's on-device Apple Translation. It translates only the text it is given, with
// languages already installed on the device, and has no remote fallback.
export interface NativeTranslation {
  readonly translationLanguages: () => Promise<unknown>;
  readonly translate: (
    request: string,
    input: string,
    target: string,
  ) => Promise<unknown>;
  readonly cancel: (request: string) => Promise<unknown>;
}

// Why a translation cannot run. Mail and the Draft stay unchanged in every case.
const Unavailable = Schema.Literals([
  // The pair is supported, but its languages are not downloaded on this device.
  'not-installed',
  'unsupported-pair',
  'unidentified-language',
  'same-language',
]);
export type TranslationUnavailable = typeof Unavailable.Type;

const LanguageCode = Schema.String.check(
  Schema.isPattern(/^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8}){0,4}$/u),
);
const Language = Schema.Struct({
  code: LanguageCode,
  name: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(100)),
});
export type TranslationLanguage = typeof Language.Type;

const decodeLanguages = Schema.decodeUnknownEffect(
  Schema.Array(Language).check(Schema.isMaxLength(500)),
);
const decodeTranslation = Schema.decodeUnknownEffect(
  Schema.Struct({
    source: LanguageCode,
    // Translated text can be longer than its source, but not without bound.
    text: Schema.String.check(Schema.isMaxLength(summaryInputLimit * 4)),
  }),
);
const decodeOutcome = Schema.decodeUnknownOption(
  Schema.Struct({
    code: Schema.Union([Unavailable, Schema.Literal('cancelled')]),
  }),
);

export type TranslationInput = Readonly<
  SummaryInput & {
    // The explicitly selected target language.
    target: string;
  }
>;

export { summaryInputLimit as translationInputLimit } from './assistance.ts';
// Whether a text has anything to translate.
export { hasVisibleText as hasTranslatableText } from './readable-text.ts';

export type ReaderText = Readonly<{ text: string; cut: boolean }>;

// The readable text of an opened message without leading whitespace, joined only until it passes
// the input limit, so a long body is never traversed or copied whole.
export function readerText(body: ReadableBody | string): ReaderText {
  const paragraphs =
    typeof body === 'string' ? [[{ text: body }]] : body.paragraphs;
  let text = '';
  for (const spans of paragraphs) {
    if (text !== '') {
      text += '\n\n'.slice(0, summaryInputLimit + 1 - text.length);
      if (text.length > summaryInputLimit) {
        return { text, cut: true };
      }
    }
    for (const { text: part } of spans) {
      const budget = Math.max(0, summaryInputLimit + 1 - text.length);
      text += (text === '' ? part.trimStart() : part).slice(0, budget);
      if (text.length > summaryInputLimit) {
        return { text, cut: true };
      }
    }
  }
  return { text, cut: false };
}

// The already-local readable text of an opened message, cut at the input limit.
export const messageTranslationInput = (
  { text, cut }: ReaderText,
  target: string,
): TranslationInput | undefined => {
  if (!hasVisibleText(text)) {
    return undefined;
  }
  const bounded = boundedInput(text.trimEnd());
  return { ...bounded, omitted: bounded.omitted || cut, target };
};

// Selected Draft text is never cut: accepting a translation replaces the whole selection.
export const draftTranslationInput = (
  text: string,
  target: string,
): TranslationInput | undefined =>
  hasVisibleText(text) && text.length <= summaryInputLimit
    ? { text, omitted: false, target }
    : undefined;

// The text that replaces a Draft selection: its translation, trimmed for the preview, between the
// selection's own leading and trailing whitespace so neighbouring words stay separated.
export const draftReplacement = (selected: string, translated: string) =>
  `${/^\s*/u.exec(selected)?.[0] ?? ''}${translated.trim()}${/\s*$/u.exec(selected)?.[0] ?? ''}`;

export type TranslationState =
  | { readonly kind: 'idle' }
  | { readonly kind: 'translating' }
  | { readonly kind: 'failed' | 'cancelled' }
  | { readonly kind: 'unavailable'; readonly reason: TranslationUnavailable }
  | {
      readonly kind: 'ready';
      readonly text: string;
      // The language the device identified in the input.
      readonly source: string;
      // Part of the input was beyond the input limit and not translated.
      readonly omitted: boolean;
    };

class TranslationFailure extends Schema.TaggedError<TranslationFailure>()(
  'TranslationFailure',
  {
    outcome: Schema.Union([
      Unavailable,
      Schema.Literals(['cancelled', 'failed']),
    ]),
    cause: Schema.Defect(),
    // Logged instead of the cause; see rejectionDiagnostic.
    diagnostic: Schema.String,
  },
) {}

const rejection = rejectionFields(decodeOutcome);

const call = (operation: () => Promise<unknown>) =>
  Effect.tryPromise({
    try: operation,
    catch: (cause) => new TranslationFailure(rejection(cause)),
  });

const malformed = (error: Schema.SchemaError) =>
  new TranslationFailure(malformedFields(error));

const isUnavailable = Schema.is(Unavailable);

const logFailure = ({
  outcome,
  diagnostic,
}: Readonly<Pick<TranslationFailure, 'outcome' | 'diagnostic'>>) =>
  outcome === 'failed'
    ? Effect.logError('On-device translation failed:', diagnostic)
    : Effect.void;

const translateLocal = Effect.fnUntraced(
  function* (
    native: NativeTranslation,
    { request, input }: Readonly<{ request: string; input: TranslationInput }>,
    isCurrent: () => boolean,
  ) {
    // A request cancelled before it reached the host never starts there. There is no
    // asynchronous suspension between this ownership check and the native call.
    if (!isCurrent()) {
      return { kind: 'cancelled' } as const;
    }
    const { source, text } = yield* call(() =>
      native.translate(request, input.text, input.target),
    ).pipe(
      Effect.flatMap((value) =>
        decodeTranslation(value).pipe(Effect.mapError(malformed)),
      ),
    );
    if (!hasVisibleText(text)) {
      return { kind: 'failed' } as const;
    }
    return {
      kind: 'ready',
      text: text.trim(),
      source,
      omitted: input.omitted,
    } as const;
  },
  // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
  Effect.catchTag('TranslationFailure', (error) =>
    logFailure(error).pipe(
      Effect.as<TranslationState>(
        isUnavailable(error.outcome)
          ? { kind: 'unavailable', reason: error.outcome }
          : { kind: error.outcome },
      ),
    ),
  ),
);

// The target languages this device's Translation offers, by name, or undefined when it cannot
// report them. Listing languages reads no mail.
export const translationLanguages = (native: NativeTranslation) =>
  runLogged(
    call(() => native.translationLanguages()).pipe(
      Effect.flatMap((value) =>
        decodeLanguages(value).pipe(Effect.mapError(malformed)),
      ),
      Effect.map((languages) =>
        Arr.sort(
          languages,
          Order.mapInput(Order.String, ({ name }: TranslationLanguage) => name),
        ),
      ),
      // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
      Effect.catchTag('TranslationFailure', (error) =>
        logFailure(error).pipe(Effect.as(undefined)),
      ),
    ),
  );

// One explicitly requested translation of captured local text into one target language. Nothing
// is stored, synchronized or written to mail; a Draft changes only when its owner applies it.
export const createTranslation = (native: NativeTranslation) =>
  createAssistanceRequest<TranslationInput, TranslationState>({
    run: (request, input, isCurrent) =>
      runLogged(translateLocal(native, { request, input }, isCurrent)),
    cancel: (request) => native.cancel(request),
    same: (left, right) =>
      left.text === right.text &&
      left.omitted === right.omitted &&
      left.target === right.target,
    idle: { kind: 'idle' },
    pending: { kind: 'translating' },
    cancelled: { kind: 'cancelled' },
  });

export type Translation = ReturnType<typeof createTranslation>;

// Retrying cannot help a pair the device does not support or text in the target language.
export const canRetryTranslation = (state: TranslationState) =>
  !(
    state.kind === 'unavailable' &&
    (state.reason === 'unsupported-pair' || state.reason === 'same-language')
  );
