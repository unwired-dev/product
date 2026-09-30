import * as Schema from 'effect/Schema';

import { fixtureMessages } from '../index.ts';

const Scenario = Schema.Literals([
  'open-read-relaunch',
  'identity-unavailable',
  'mail-unavailable',
  'assistance-unavailable',
]);

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
    assistance: Object.freeze({
      summarize: () =>
        scenario === 'assistance-unavailable'
          ? unavailable()
          : Promise.resolve(
              'Synthetic summary: a studio review and a weekend walk.',
            ),
    }),
  });
}
