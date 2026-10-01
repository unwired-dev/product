import type { AuthConfig } from 'convex/server';

// Public native audiences, configured on the deployment as comma-separated lists.
const audiences = (value: string | undefined) =>
  (value ?? '')
    .split(',')
    .map((id) => id.trim())
    .filter(Boolean);

// Must match the unwired-mail bundle identifier in Xcode (or APPLE_BUNDLE_ID in Convex env).
// oxlint-disable-next-line node/no-process-env -- Convex auth config reads deployment env at runtime.
const appleBundleId = process.env.APPLE_BUNDLE_ID ?? 'dev.unwired.mail';
// Sign in with Apple uses each native host's bundle identifier as the token audience.
const appleAudiences = new Set([
  appleBundleId,
  // oxlint-disable-next-line node/no-process-env -- Public native bundle identifiers.
  ...audiences(process.env.APPLE_PRODUCT_CLIENT_IDS),
]);
// oxlint-disable-next-line node/no-process-env -- Public native OAuth audiences, configured on the deployment.
const googleClientIds = audiences(process.env.GOOGLE_PRODUCT_CLIENT_IDS);

export default {
  providers: [
    ...googleClientIds.map((applicationID) => ({
      applicationID,
      domain: 'https://accounts.google.com',
    })),
    ...[...appleAudiences].map((applicationID) => ({
      applicationID,
      domain: 'https://appleid.apple.com',
    })),
  ],
} satisfies AuthConfig;
