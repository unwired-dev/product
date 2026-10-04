import type { AuthConfig } from 'convex/server';

import { env } from './_generated/server.js';

// Public native audiences, configured on the deployment as comma-separated lists.
const audiences = (value: string | undefined) =>
  (value ?? '')
    .split(',')
    .map((id) => id.trim())
    .filter(Boolean);

// Sign in with Apple uses each native host's bundle identifier as the token audience.
// Without configured bundle IDs, no Apple token is accepted.
const appleAudiences = new Set([
  ...audiences(env.APPLE_BUNDLE_ID),
  ...audiences(env.APPLE_PRODUCT_CLIENT_IDS),
]);
const googleClientIds = audiences(env.GOOGLE_PRODUCT_CLIENT_IDS);

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
