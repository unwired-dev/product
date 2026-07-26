import {
  gmailIdentityBindingDigest,
  gmailRoutingDigest,
  gmailRoutingDigests,
} from '../convex/gmailRouting.js';

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

  it('routes current and previous key versions during rotation', async () => {
    expect.assertions(1);
    vi.stubEnv('GMAIL_ROUTING_KEY', 'gmail-routing-test-key');
    vi.stubEnv('GMAIL_ROUTING_KEY_VERSION', '3');
    vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY', 'gmail-routing-previous-test-key');
    vi.stubEnv('GMAIL_ROUTING_PREVIOUS_KEY_VERSION', '2');

    await expect(
      gmailRoutingDigests('user@example.com'),
    ).resolves.toStrictEqual([
      {
        digest: '3:EDbM2CNsMvy-_5uSWFq3vo9lEXHzxTkzCZ80YrJ92GU',
        keyVersion: 3,
      },
      {
        digest: '2:HBRoR-uKsIDajXPqDwBVsLbfSD9Ss273scQDLTwgZw8',
        keyVersion: 2,
      },
    ]);
    vi.unstubAllEnvs();
  });

  it('keeps identity bindings stable across routing-key rotation', async () => {
    expect.assertions(2);
    vi.stubEnv('GMAIL_IDENTITY_BINDING_KEY', 'gmail-identity-binding-test-key');
    vi.stubEnv('GMAIL_ROUTING_KEY', 'gmail-routing-test-key');
    vi.stubEnv('GMAIL_ROUTING_KEY_VERSION', '1');

    const beforeRotation = await gmailIdentityBindingDigest(
      'product-account-001',
      'gmail-user-001',
    );
    vi.stubEnv('GMAIL_ROUTING_KEY', 'rotated-routing-test-key');
    vi.stubEnv('GMAIL_ROUTING_KEY_VERSION', '2');

    await expect(
      gmailIdentityBindingDigest('product-account-001', 'gmail-user-001'),
    ).resolves.toBe(beforeRotation);
    expect(beforeRotation).toMatch(/^identity:/u);
    vi.unstubAllEnvs();
  });
});
