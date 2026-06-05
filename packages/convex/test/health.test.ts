import { healthResponseFixture } from '@private-email/contracts/health';

describe('backend health action contract', () => {
  it('uses the shared health response fixture shape', () => {
    expect.assertions(1);

    expect(healthResponseFixture).toStrictEqual({
      bootstrapVersion: 1,
      serverTime: 1_781_200_000_000,
      service: 'private-email-api',
      status: 'ok',
    });
  });
});
