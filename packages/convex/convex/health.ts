import { action } from './_generated/server.js';

export const healthPayload = (serverTime: number) => ({
  service: 'private-email-api',
  status: 'ok',
  bootstrapVersion: 1,
  serverTime,
});

export const health = action({
  args: {},
  handler: async () => healthPayload(Date.now()),
});
