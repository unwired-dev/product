import { createInstance } from 'i18next';

import english from '../catalogs.bundle/en.json' with { type: 'json' };
import languages from '../catalogs.bundle/languages.json' with { type: 'json' };

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
    resources: { translation: typeof english };
    strictKeyChecks: true;
  }
}

export function createLocalization(
  initial: LanguageSettings,
  storage: LanguageStorage,
) {
  const i18n = createInstance();
  void i18n.init({
    lng: initial.language,
    fallbackLng: 'en',
    supportedLngs: languages.map(({ code }) => code),
    resources: { en: { translation: english } },
    initAsync: false,
    interpolation: { escapeValue: false },
  });
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
