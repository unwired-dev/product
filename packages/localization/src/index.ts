import type { TFunction } from 'i18next';

import * as Result from 'effect/Result';
import * as Schema from 'effect/Schema';
import { createInstance } from 'i18next';

import catalog from '../catalogs.bundle/en.json' with { type: 'json' };
import languages from '../catalogs.bundle/languages.json' with { type: 'json' };

export { createMessageDateFormat } from './message-date-format.ts';

export { default as languages } from '../catalogs.bundle/languages.json' with { type: 'json' };

export interface LanguageSettings {
  readonly preference: string | null;
  readonly language: string;
  readonly locale: string;
}

export interface LanguageStorage {
  readonly getSettings: () => Promise<unknown>;
  readonly setLanguage: (language: string | null) => Promise<unknown>;
}

const languageCode = Schema.NonEmptyString.check(
  Schema.makeFilter((code) =>
    languages.some((language) => language.code === code),
  ),
);
const locale = Schema.NonEmptyString.check(
  Schema.makeFilter((value) => {
    try {
      return (
        new Intl.DateTimeFormat(value).resolvedOptions().locale !== '' &&
        new Intl.NumberFormat(value).resolvedOptions().locale !== ''
      );
    } catch {
      return false;
    }
  }),
);
const settingsSchema = Schema.Struct({
  preference: Schema.NullOr(languageCode),
  language: languageCode,
  locale,
});
class InvalidLanguageSettings extends Schema.TaggedError<InvalidLanguageSettings>()(
  'InvalidLanguageSettings',
  { cause: Schema.Defect(), message: Schema.String },
) {}
const decodeSettings = (input: unknown): LanguageSettings => {
  const decoded = Schema.decodeUnknownResult(settingsSchema)(input);
  if (Result.isFailure(decoded)) {
    throw new InvalidLanguageSettings({
      cause: decoded.failure,
      message: 'Invalid native language settings.',
    });
  }
  return decoded.success;
};

declare module 'i18next' {
  interface CustomTypeOptions {
    defaultNS: 'translation';
    resources: { translation: typeof catalog };
    strictKeyChecks: true;
  }
}

// Shared copy builders receive the host's translation function, so they stay free of React.
export type Translate = TFunction;

function createTranslations(language: string) {
  const i18n = createInstance();
  void i18n.init({
    lng: language,
    fallbackLng: 'en',
    supportedLngs: languages.map(({ code }) => code),
    resources: { en: { translation: catalog } },
    initAsync: false,
    interpolation: { escapeValue: false },
  });
  return i18n;
}

// The shipped English catalog, for tests and code that runs before a host chooses a language.
export const english: Translate = createTranslations('en').getFixedT('en');

export function createLocalization(initial: unknown, storage: LanguageStorage) {
  let settings = decodeSettings(initial);
  const i18n = createTranslations(settings.language);
  const listeners = new Set<() => void>();
  let pending = Promise.resolve();

  async function apply(input: unknown) {
    const next = decodeSettings(input);
    const { language } = i18n;
    try {
      await i18n.changeLanguage(next.language);
    } catch (error) {
      // Keep the rendered language and the settings snapshot in agreement.
      await i18n.changeLanguage(language);
      throw error;
    }
    settings = next;
    for (const listener of listeners) {
      listener();
    }
  }

  function enqueue(operation: () => Promise<unknown>) {
    const previous = pending;
    async function run() {
      try {
        await previous;
      } catch {
        // The previous caller receives its failure; later choices can still succeed.
      }
      await apply(await operation());
    }
    pending = run();
    return pending;
  }

  return {
    i18n,
    getSnapshot: () => settings,
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    refresh: () => enqueue(storage.getSettings),
    setLanguage(language: string | null) {
      if (
        language !== null &&
        !languages.some(({ code }) => code === language)
      ) {
        return Promise.reject(
          new RangeError('Unsupported interface language.'),
        );
      }
      return enqueue(() => storage.setLanguage(language));
    },
  };
}
