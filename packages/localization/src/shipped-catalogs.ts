import en from '../catalogs.bundle/en.json' with { type: 'json' };

// The languages a build offers, each with its catalog. Mock Mail Session builds substitute
// `testing/catalogs.ts`, which adds the German test catalog.
export const catalogs: Readonly<Record<string, object>> = { en };
export { default as languages } from '../catalogs.bundle/languages.json' with { type: 'json' };
