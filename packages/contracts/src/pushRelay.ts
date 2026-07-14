import type { Infer } from 'convex/values';

import { v } from 'convex/values';

export const devicePushRegistrationResponseValidator = v.object({
  registered: v.boolean(),
});

export type DevicePushRegistrationResponse = Infer<
  typeof devicePushRegistrationResponseValidator
>;

export const devicePushRegistrationResponseFixture: DevicePushRegistrationResponse =
  {
    registered: true,
  };
