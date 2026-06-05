import type { Infer } from 'convex/values';

import { v } from 'convex/values';

export const healthResponseValidator = v.object({
  bootstrapVersion: v.number(),
  serverTime: v.number(),
  service: v.string(),
  status: v.literal('ok'),
});

export type HealthResponse = Infer<typeof healthResponseValidator>;

export const healthResponseFixture: HealthResponse = {
  bootstrapVersion: 1,
  serverTime: 1_781_200_000_000,
  service: 'private-email-api',
  status: 'ok',
};
