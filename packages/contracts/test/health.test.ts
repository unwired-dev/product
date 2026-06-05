import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import {
  healthResponseFixture,
  healthResponseValidator,
} from '../src/health.ts';

describe('health contract', () => {
  it('fixture matches the committed JSON file Swift tests decode', () => {
    expect.assertions(1);

    const fixturePath = fileURLToPath(
      new URL('../fixtures/health.response.json', import.meta.url),
    );
    const fixtureJson = JSON.parse(readFileSync(fixturePath, 'utf8'));

    expect(fixtureJson).toStrictEqual(healthResponseFixture);
  });

  it('exposes only bootstrap operational fields', () => {
    expect.assertions(1);

    expect(healthResponseValidator.fields).toStrictEqual({
      bootstrapVersion: expect.anything(),
      serverTime: expect.anything(),
      service: expect.anything(),
      status: expect.anything(),
    });
  });
});
