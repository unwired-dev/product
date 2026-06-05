import { healthResponseValidator } from '@private-email/contracts/health';

import { action } from './_generated/server.js';

export const health = action({
  args: {},
  returns: healthResponseValidator,
  handler: async () => ({
    bootstrapVersion: 1,
    serverTime: Date.now(),
    service: 'private-email-api',
    status: 'ok' as const,
  }),
});
