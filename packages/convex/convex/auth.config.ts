import type { AuthConfig } from 'convex/server';

// Must match the unwired-mail bundle identifier in Xcode (or APPLE_BUNDLE_ID in Convex env).
// oxlint-disable-next-line node/no-process-env -- Convex auth config reads deployment env at runtime.
const appleBundleId = process.env.APPLE_BUNDLE_ID ?? 'dev.unwired.mail';

export default {
  providers: [
    {
      applicationID: appleBundleId,
      domain: 'https://appleid.apple.com',
    },
  ],
} satisfies AuthConfig;
