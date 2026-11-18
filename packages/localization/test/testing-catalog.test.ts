import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';
import * as Predicate from 'effect/Predicate';

import { createLocalization, languages } from '../src/index.ts';
import { catalogs } from '../src/testing/catalogs.ts';

// What a Mac Mock Mail Session build bundles in place of the shipped catalogs. A string path:
// an import() of this internal module would break tests-through-entrypoints.
vi.mock(
  // oxlint-disable-next-line vitest/prefer-import-in-mock
  '../src/shipped-catalogs.ts',
  () => import('../src/testing/catalogs.ts'),
);

const entries = (value: object, prefix = ''): Array<[string, string]> =>
  Object.entries(value).flatMap(([key, child]) =>
    Predicate.isObject(child)
      ? entries(child, `${prefix}${key}.`)
      : [[`${prefix}${key}`, String(child)]],
  );
// Each key's sorted interpolation names.
const shape = (catalog: object) =>
  Object.fromEntries(
    entries(catalog).map(([key, text]) => [
      key,
      Arr.sort(
        Array.from(text.matchAll(/(?<=\{\{)\w+/gu), ([name]) => name),
        Order.String,
      ),
    ]),
  );

describe('german test catalog', () => {
  it('translates English keys with their interpolation names', () => {
    expect.hasAssertions();
    const english = shape(catalogs.en);
    const german = shape(catalogs.de);
    expect(german).toStrictEqual(
      Object.fromEntries(Object.keys(german).map((key) => [key, english[key]])),
    );
  });

  it('is offered after the shipped languages and falls back to English', () => {
    expect.hasAssertions();
    const app = createLocalization(
      { preference: 'de', language: 'de', locale: 'de' },
      { getSettings: async () => null, setLanguage: async () => null },
    );
    expect(app.i18n.t('drafts.send')).toBe('Senden');
    expect(app.i18n.t('drafts.discardDraft')).toBe('Discard Draft');
    expect(languages.at(-1)).toStrictEqual({ code: 'de', name: 'Deutsch' });
  });
});
