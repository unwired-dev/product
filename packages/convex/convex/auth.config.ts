import type { AuthConfig } from 'convex/server';

// Must match the unwired-mail bundle identifier in Xcode (or APPLE_BUNDLE_ID in Convex env).
// oxlint-disable-next-line node/no-process-env -- Convex auth config reads deployment env at runtime.
const appleBundleId = process.env.APPLE_BUNDLE_ID ?? 'dev.unwired.mail';
// oxlint-disable-next-line node/no-process-env -- Public native OAuth audiences, configured on the deployment.
const googleClientIds = (process.env.GOOGLE_PRODUCT_CLIENT_IDS ?? '')
  .split(',')
  .map((id) => id.trim())
  .filter(Boolean);

export default {
  providers: [
    ...googleClientIds.map((applicationID) => ({
      applicationID,
      domain: 'https://accounts.google.com',
    })),
    {
      applicationID: appleBundleId,
      domain: 'https://appleid.apple.com',
    },
  ],
} satisfies AuthConfig;
