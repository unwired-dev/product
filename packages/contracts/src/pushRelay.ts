import type { Infer } from 'convex/values';

import { v } from 'convex/values';

export const devicePushRegistrationResponseValidator = v.object({
  registered: v.boolean(),
});

export const gmailPushVerificationResponseValidator = v.object({
  routeId: v.string(),
  verified: v.boolean(),
});

export type DevicePushRegistrationResponse = Infer<
  typeof devicePushRegistrationResponseValidator
>;

export type GmailPushVerificationResponse = Infer<
  typeof gmailPushVerificationResponseValidator
>;

export const devicePushRegistrationResponseFixture: DevicePushRegistrationResponse =
  {
    registered: true,
  };

export const gmailPushVerificationResponseFixture: GmailPushVerificationResponse =
  {
    routeId: 'gmailPushRouteFixtureId',
    verified: true,
  };
