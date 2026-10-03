import { defineApp } from 'convex/server';
import { v } from 'convex/values';

// Deployment environment variables read through `env` from `_generated/server`.
// Every entry is optional so a deployment without a feature's settings still pushes;
// the code reading each value reports its own missing configuration.
const app = defineApp({
  env: {
    APNS_KEY_ID: v.optional(v.string()),
    APNS_PRIVATE_KEY: v.optional(v.string()),
    APNS_TEAM_ID: v.optional(v.string()),
    APNS_TOPIC: v.optional(v.string()),
    APPLE_BUNDLE_ID: v.optional(v.string()),
    APPLE_PRODUCT_CLIENT_IDS: v.optional(v.string()),
    APPLE_SIGN_IN_KEY_ID: v.optional(v.string()),
    APPLE_SIGN_IN_PRIVATE_KEY: v.optional(v.string()),
    APPLE_TEAM_ID: v.optional(v.string()),
    GMAIL_IDENTITY_BINDING_KEY: v.optional(v.string()),
    GMAIL_OAUTH_CLIENT_ID: v.optional(v.string()),
    GMAIL_PUSH_VERIFICATION_TOKEN: v.optional(v.string()),
    GMAIL_ROUTING_KEY: v.optional(v.string()),
    GMAIL_ROUTING_KEY_VERSION: v.optional(v.string()),
    GMAIL_ROUTING_PREVIOUS_KEY: v.optional(v.string()),
    GMAIL_ROUTING_PREVIOUS_KEY_VERSION: v.optional(v.string()),
    GOOGLE_PRODUCT_CLIENT_IDS: v.optional(v.string()),
  },
});

export default app;
