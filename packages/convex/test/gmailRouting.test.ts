import { gmailRoutingDigest } from '../convex/gmailRouting.js';

describe('gmail routing digest', () => {
  it.each([
    ['user@example.com', '1:YkM5c4uR-TLWiEaddOnJZ7jf4GBjPSFvCijT-86h-wk'],
    ['first.last@example.com', '1:21RScr46dozf-XRfsRF98wZxoGlbPQzzFLa-l0jdE3s'],
    ['user+tag@example.com', '1:-X3-cBOpLE6xh5D6RgDXYMWNHHIiqQpFQh36Oyf_dS8'],
    ['user@googlemail.com', '1:HfF1mdKc2A2U65XCdawoMHL5WAFOaT0JKaMgOXuX98Y'],
  ])(
    'keeps the verified address variant distinct for %s',
    async (email, expected) => {
      expect.assertions(1);
      vi.stubEnv('GMAIL_ROUTING_KEY', 'gmail-routing-test-key');

      await expect(gmailRoutingDigest(email)).resolves.toStrictEqual({
        digest: expected,
        keyVersion: 1,
      });
      vi.unstubAllEnvs();
    },
  );

  it('requires the backend-only routing key', async () => {
    expect.assertions(1);
    vi.stubEnv('GMAIL_ROUTING_KEY', '');

    await expect(gmailRoutingDigest('user@example.com')).rejects.toThrow(
      'Gmail routing is not configured',
    );
    vi.unstubAllEnvs();
  });
});
