import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

import {
  healthResponseFixture,
  healthResponseValidator,
} from '../src/health.ts';

describe('health contract', () => {
  it('fixture matches the committed JSON file Swift tests decode', async () => {
    expect.assertions(1);

    const fixturePath = fileURLToPath(
      new URL('../fixtures/health.response.json', import.meta.url),
    );
    const fixtureJson = JSON.parse(await readFile(fixturePath, 'utf8'));

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
