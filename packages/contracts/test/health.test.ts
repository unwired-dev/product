import healthResponseJson from '../fixtures/health.response.json' with { type: 'json' };
import {
  healthResponseFixture,
  healthResponseValidator,
} from '../src/health.ts';

describe('health contract', () => {
  it('fixture matches the committed JSON file Swift tests decode', () => {
    expect.assertions(1);

    expect(healthResponseJson).toStrictEqual(healthResponseFixture);
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
