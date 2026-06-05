import { healthPayload } from '../convex/health.ts';

describe('backend health response', () => {
  it('exposes only bootstrap operational data', () => {
    expect.assertions(1);

    expect(healthPayload(123)).toStrictEqual({
      service: 'private-email-api',
      status: 'ok',
      bootstrapVersion: 1,
      serverTime: 123,
    });
  });
});
