import type { LanguageSettings } from '@private-email/localization';

// The native preference store at the Jest boundary: System default until a test chooses.
let settings: LanguageSettings = {
  preference: null,
  language: 'en',
  locale: 'en',
};

export const languageStorage = {
  initial: settings,
  getSettings: async () => settings,
  async setLanguage(preference: string | null) {
    settings = { preference, language: preference ?? 'en', locale: 'en' };
    return settings;
  },
  subscribe() {
    // Locale notifications come from the device.
  },
};
