import type { SemanticDocument } from '../src/semantic-document.ts';
import type {
  NativeTranslation,
  TranslationInput,
} from '../src/translation.ts';

import {
  displayOf,
  historyOf,
  record,
  replaceSelection,
  selectedText,
  undo,
} from '../src/semantic-document.ts';
import {
  createMockMailSession,
  syntheticTranslation,
} from '../src/testing/mock-session.ts';
import {
  createTranslation,
  draftReplacement,
  draftTranslationInput,
  messageTranslationInput,
  readerText,
  translationInputLimit,
  translationLanguages,
} from '../src/translation.ts';

interface Asked {
  readonly request: string;
  readonly input: string;
  readonly target: string;
  readonly answer: PromiseWithResolvers<unknown>;
}

// A native Translation whose answers the test releases, recording what it was asked.
function scriptedTranslation(languages: unknown = []) {
  const asked: Asked[] = [];
  const cancelled: string[] = [];
  const native: NativeTranslation = {
    translationLanguages: () => Promise.resolve(languages),
    translate: (request, input, target) => {
      const answer = Promise.withResolvers<unknown>();
      asked.push({ request, input, target, answer });
      return answer.promise;
    },
    cancel: (request) => {
      cancelled.push(request);
      return Promise.resolve(null);
    },
  };
  const nth = async (index: number) => {
    await vi.waitFor(() => {
      expect(asked.length).toBeGreaterThan(index);
    });
    const call = asked[index];
    if (call === undefined) {
      throw new Error('Expected a translate call');
    }
    return call;
  };
  return { native, asked, nth, cancelled };
}

const message = (body: string, target = 'es'): TranslationInput => {
  const admitted = messageTranslationInput(readerText(body), target);
  if (admitted === undefined) {
    throw new Error('Expected readable input');
  }
  return admitted;
};

describe('on-device translation', () => {
  /* oxlint-disable vitest/max-expects -- Each case proves one translation path end to end. */
  it('admits bounded message text and only whole Draft selections', () => {
    expect.hasAssertions();
    expect(messageTranslationInput(readerText(' \n​ '), 'es')).toBeUndefined();
    expect(message(' Lunch at noon? ')).toStrictEqual({
      text: 'Lunch at noon?',
      omitted: false,
      target: 'es',
    });
    const long = message('a'.repeat(translationInputLimit + 10));
    expect(long.text).toHaveLength(translationInputLimit);
    expect(long.omitted).toBe(true);
    // Applying a translation replaces the whole selection, so a Draft selection is never cut.
    expect(
      draftTranslationInput('a'.repeat(translationInputLimit + 1), 'es'),
    ).toBeUndefined();
    expect(draftTranslationInput('Hola', 'en')).toStrictEqual({
      text: 'Hola',
      omitted: false,
      target: 'en',
    });
  });

  it('joins a reader body only until it passes the input limit', () => {
    expect.hasAssertions();
    const paragraph = [{ text: 'Lunch at noon? '.repeat(100) }];
    const paragraphs = Array.from({ length: 10 }, () => paragraph);
    // A paragraph past the limit is never read.
    Object.defineProperty(paragraphs, 9, {
      get: () => {
        throw new Error('Read past the input limit');
      },
    });
    const long = readerText({ paragraphs, hidesImages: false });
    expect(long.cut).toBe(true);
    expect(long.text).toHaveLength(translationInputLimit + 1);
    expect(messageTranslationInput(long, 'es')).toMatchObject({
      omitted: true,
    });
    expect(messageTranslationInput(long, 'es')?.text).toHaveLength(
      translationInputLimit,
    );
    // Leading whitespace does not count against the limit, and a short body is whole.
    expect(
      readerText({
        paragraphs: [[{ text: '  ' }], [{ text: ' Hola' }, { text: ' mundo' }]],
        hidesImages: false,
      }),
    ).toStrictEqual({ text: 'Hola mundo', cut: false });
  });

  it('translates the captured text into the chosen language and discloses a cut', async () => {
    expect.hasAssertions();
    const { native, nth } = scriptedTranslation();
    const translation = createTranslation(native);
    const long = message('Lunch '.repeat(translationInputLimit), 'de');
    const done = translation.start(long);
    expect(translation.getSnapshot(long)).toStrictEqual({
      kind: 'translating',
    });
    const call = await nth(0);
    expect(call.input).toBe(long.text);
    expect(call.target).toBe('de');
    call.answer.resolve({ source: 'en', text: ' Mittagessen ' });
    await done;
    expect(translation.getSnapshot(long)).toStrictEqual({
      kind: 'ready',
      text: 'Mittagessen',
      source: 'en',
      omitted: true,
    });
    // Another language is another input: it reads as idle until translated.
    expect(translation.getSnapshot({ ...long, target: 'es' })).toStrictEqual({
      kind: 'idle',
    });
  });

  it.each([
    'not-installed',
    'unsupported-pair',
    'unidentified-language',
    'same-language',
  ] as const)('reports %s as unavailable without logging', async (reason) => {
    expect.hasAssertions();
    const logged = vi.spyOn(console, 'error').mockReturnValue(undefined);
    const { native, nth } = scriptedTranslation();
    const translation = createTranslation(native);
    const input = message('Lunch at noon?');
    const done = translation.start(input);
    const call = await nth(0);
    call.answer.reject({ code: reason });
    await done;
    expect(translation.getSnapshot(input)).toStrictEqual({
      kind: 'unavailable',
      reason,
    });
    expect(logged).not.toHaveBeenCalled();
  });

  it.each([
    [{ code: 'unavailable', message: 'Lunch at noon?' }, 'reject'],
    [42, 'resolve'],
    [{ source: 'en', text: 'Lunch '.repeat(translationInputLimit) }, 'resolve'],
    [{ source: 'en; Lunch', text: 'Almuerzo' }, 'resolve'],
    [{ source: 'en', text: ' \n ' }, 'resolve'],
  ] as const)(
    'fails closed on %j and logs no mail content',
    async (answer, settle) => {
      expect.hasAssertions();
      const logged = vi.spyOn(console, 'error').mockReturnValue(undefined);
      const { native, nth } = scriptedTranslation();
      const translation = createTranslation(native);
      const input = message('Lunch at noon?');
      const done = translation.start(input);
      const call = await nth(0);
      call.answer[settle](answer);
      await done;
      expect(translation.getSnapshot(input)).toStrictEqual({ kind: 'failed' });
      expect(JSON.stringify(logged.mock.calls)).not.toContain('Lunch');
    },
  );

  it('cancels the native request and drops its late result', async () => {
    expect.hasAssertions();
    const { native, nth, cancelled } = scriptedTranslation();
    const translation = createTranslation(native);
    const input = message('Lunch at noon?');
    const done = translation.start(input);
    const call = await nth(0);
    translation.cancel();
    expect(cancelled).toStrictEqual([call.request]);
    call.answer.resolve({ source: 'en', text: 'Almuerzo' });
    await done;
    expect(translation.getSnapshot(input)).toStrictEqual({
      kind: 'cancelled',
    });

    // Choosing another language replaces the pending request.
    const spanish = translation.start(input);
    const second = await nth(1);
    const german = { ...input, target: 'de' };
    const replaced = translation.start(german);
    expect(cancelled).toContain(second.request);
    const third = await nth(2);
    third.answer.resolve({ source: 'en', text: 'Mittagessen' });
    second.answer.resolve({ source: 'en', text: 'Almuerzo' });
    await Promise.all([spanish, replaced]);
    expect(translation.getSnapshot(german)).toMatchObject({
      kind: 'ready',
      text: 'Mittagessen',
    });
    expect(translation.getSnapshot(input)).toStrictEqual({ kind: 'idle' });
  });

  it('lists target languages by name and fails closed on a malformed list', async () => {
    expect.hasAssertions();
    const logged = vi.spyOn(console, 'error').mockReturnValue(undefined);
    await expect(
      translationLanguages(
        scriptedTranslation([
          { code: 'es', name: 'Spanish' },
          { code: 'zh-Hans', name: 'Chinese' },
        ]).native,
      ),
    ).resolves.toStrictEqual([
      { code: 'zh-Hans', name: 'Chinese' },
      { code: 'es', name: 'Spanish' },
    ]);
    await expect(
      translationLanguages(
        scriptedTranslation([{ code: 'es; rm', name: 'Spanish' }]).native,
      ),
    ).resolves.toBeUndefined();
    expect(logged).toHaveBeenCalledWith(
      expect.any(String),
      'On-device translation failed:',
      expect.any(String),
    );
  });

  it('gives Mock Mail Sessions fixed outcomes', async () => {
    expect.hasAssertions();
    const available = createTranslation(
      createMockMailSession('open-read-relaunch').translation,
    );
    const input = message('Lunch at noon?');
    await available.start(input);
    expect(available.getSnapshot(input)).toStrictEqual({
      kind: 'ready',
      text: syntheticTranslation,
      source: 'en',
      omitted: false,
    });
    const unavailable = createTranslation(
      createMockMailSession('assistance-unavailable').translation,
    );
    await unavailable.start(input);
    expect(unavailable.getSnapshot(input)).toStrictEqual({
      kind: 'unavailable',
      reason: 'not-installed',
    });
  });
});

describe('applying a translation to selected Draft text', () => {
  it('keeps the selection boundary whitespace around the trimmed translation', () => {
    expect.hasAssertions();
    expect(draftReplacement('Hola ', 'Hello')).toBe('Hello ');
    expect(draftReplacement(' \nHola\n', ' Hello ')).toBe(' \nHello\n');
    expect(draftReplacement('Hola', 'Hello ')).toBe('Hello');
  });

  const draft: SemanticDocument = [
    { kind: 'paragraph', spans: [{ text: 'Hello ', marks: ['bold'] }] },
    { kind: 'bulleted', spans: [{ text: 'first item' }] },
    { kind: 'bulleted', spans: [{ text: 'second item' }] },
  ];

  it('captures the selected text without list markers', () => {
    expect.hasAssertions();
    const { text } = displayOf(draft);
    expect(text).toBe('Hello \n• first item\n• second item');
    // From inside the first item's marker to the end of the second item.
    const selection = { start: 7, end: text.length };
    expect(selectedText(draft, selection)).toBe('first item\nsecond item');
    expect(selectedText(draft, { start: 2, end: 2 })).toBe('');
    const long: SemanticDocument = [
      { kind: 'paragraph', spans: [{ text: 'a'.repeat(2_000_000) }] },
    ];
    expect(
      selectedText(
        long,
        { start: 0, end: 2_000_000 },
        translationInputLimit + 1,
      ),
    ).toHaveLength(translationInputLimit + 1);
    expect(selectedText(long, { start: 1_000_000, end: 1_000_000 })).toBe('');
    expect(selectedText(draft, { start: 2, end: 15 }, 8)).toBe('llo \nfir');
  });

  it('replaces exactly the selection as one undoable edit and keeps the list', () => {
    expect.hasAssertions();
    const { text } = displayOf(draft);
    const selection = { start: 7, end: text.length };
    const edit = replaceSelection(
      draft,
      selection,
      'primer elemento\nsegundo elemento',
    );
    expect(displayOf(edit.document).text).toBe(
      'Hello \n• primer elemento\n• segundo elemento',
    );
    expect(edit.selection).toStrictEqual({
      start: displayOf(edit.document).text.length,
      end: displayOf(edit.document).text.length,
    });
    const mixed: SemanticDocument = [
      { kind: 'bulleted', spans: [{ text: 'First old' }] },
      { kind: 'numbered', spans: [{ text: 'Second tail', marks: ['bold'] }] },
      { kind: 'quote', spans: [{ text: 'Unselected quote' }] },
    ];
    const replaced = replaceSelection(
      mixed,
      { start: 2, end: 22 },
      'Erstes\nZweites',
    );
    expect(replaced.document.map(({ kind }) => kind)).toStrictEqual([
      'bulleted',
      'numbered',
      'quote',
    ]);
    expect(displayOf(replaced.document).text).toBe(
      '• Erstes\n1. Zweitestail\nUnselected quote',
    );
    expect(replaced.document[1]?.spans.at(-1)).toStrictEqual({
      text: 'Zweitestail',
      marks: ['bold'],
    });
    expect(replaced.document[2]).toBe(mixed[2]);
    // Text inserted after formatted text takes its marks.
    const word = replaceSelection(draft, { start: 0, end: 5 }, 'Hola');
    expect(word.document[0]).toStrictEqual({
      kind: 'paragraph',
      spans: [{ text: 'Hola ', marks: ['bold'] }],
    });
    const history = record(historyOf(draft), edit.document);
    expect(undo(history).present).toBe(draft);
  });
});
