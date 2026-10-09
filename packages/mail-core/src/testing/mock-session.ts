import * as Schema from 'effect/Schema';

import type { NativeAssistance } from '../assistance.ts';
import type { NativeTranslation } from '../translation.ts';

import { fixtureMessages } from '../index.ts';

const Scenario = Schema.Literals([
  'open-read-relaunch',
  'identity-unavailable',
  'mail-unavailable',
  'assistance-unavailable',
]);

// The fixed summary every available Mock Mail Session returns; native mock builds return the same.
export const syntheticSummary = 'Synthetic summary of local mail.';
// The fixed translation, identified source language and target languages every available Mock
// Mail Session offers; native mock builds return the same.
export const syntheticTranslation = 'Synthetic translation of local mail.';
export const syntheticTranslationLanguages = [
  { code: 'de', name: 'German' },
  { code: 'es', name: 'Spanish' },
];

const unavailable = () =>
  Promise.reject(new Error('Synthetic provider unavailable'));

export function createMockMailSession(selection: unknown) {
  // oxlint-disable-next-line node/no-sync -- Parse the test-only factory's configuration boundary.
  const scenario = Schema.decodeUnknownSync(Scenario)(selection);
  const identity = Object.freeze({
    kind: 'synthetic',
    account: 'mock-product-account',
    address: 'alex@example.invalid',
  });
  const signIn = () =>
    scenario === 'identity-unavailable'
      ? unavailable()
      : Promise.resolve(identity);
  const list = async () => {
    await signIn();
    if (scenario === 'mail-unavailable') {
      throw new Error('Synthetic mail unavailable');
    }
    return fixtureMessages.map((message) => ({ ...message }));
  };
  return Object.freeze({
    scenario,
    identity: Object.freeze({ signIn }),
    mail: Object.freeze({ list }),
    // The native assistance contract with fixed outcomes; it never reads the input it is given.
    assistance: Object.freeze({
      availability: () =>
        Promise.resolve(
          scenario === 'assistance-unavailable'
            ? 'model-not-ready'
            : 'available',
        ),
      summarize: () =>
        scenario === 'assistance-unavailable'
          ? unavailable()
          : Promise.resolve(syntheticSummary),
      cancel: () => Promise.resolve(null),
    }) satisfies NativeAssistance,
    // The native translation contract with fixed outcomes; it never reads the input it is given.
    translation: Object.freeze({
      translationLanguages: () =>
        Promise.resolve(syntheticTranslationLanguages),
      translate: () =>
        scenario === 'assistance-unavailable'
          ? Promise.reject(
              Object.assign(new Error('Synthetic language not installed'), {
                code: 'not-installed',
              }),
            )
          : Promise.resolve({ source: 'en', text: syntheticTranslation }),
      cancel: () => Promise.resolve(null),
    }) satisfies NativeTranslation,
  });
}
