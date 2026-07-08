import type { AuthConfig } from 'convex/server';

// Must match the unwired-mail bundle identifier in Xcode.
const appleBundleId = 'dev.unwired.mail';

export default {
  providers: [
    {
      algorithm: 'RS256',
      applicationID: appleBundleId,
      issuer: 'https://appleid.apple.com',
      jwks: 'https://appleid.apple.com/auth/keys',
      type: 'customJwt',
    },
  ],
} satisfies AuthConfig;
