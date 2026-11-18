import en from '../../catalogs.bundle/en.json' with { type: 'json' };
import de from './de.json' with { type: 'json' };

// Mock Mail Session builds only: German-length strings for layout checks, never a shipped language.
// Keys it leaves out fall back to English.
export const catalogs = { en, de };
export { default as languages } from './languages.json' with { type: 'json' };
