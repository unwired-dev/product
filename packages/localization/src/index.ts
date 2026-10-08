import type { TFunction } from 'i18next';

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
  readonly getSettings: () => Promise<LanguageSettings>;
  readonly setLanguage: (language: string | null) => Promise<LanguageSettings>;
}

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

export function createLocalization(
  initial: LanguageSettings,
  storage: LanguageStorage,
) {
  const i18n = createTranslations(initial.language);
  let settings = initial;
  const listeners = new Set<() => void>();
  let pending = Promise.resolve();

  async function apply(next: LanguageSettings) {
    settings = next;
    await i18n.changeLanguage(next.language);
    for (const listener of listeners) {
      listener();
    }
  }

  function enqueue(operation: () => Promise<LanguageSettings>) {
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
