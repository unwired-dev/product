import { convexTest } from 'convex-test';

import { internal } from './convex/_generated/api.js';
import schema from './convex/schema.js';

// The HTTP journeys use the real database/router; only vendor HTTP is replaced.
export function createReportingTest(
  modules: Record<string, () => Promise<unknown>>,
) {
  const backend = convexTest(schema, modules);
  return {
    backend,
    scheduleServiceHealth: () =>
      backend.mutation(internal.errorReportingState.scheduleServiceHealth, {}),
    captureServiceHealth: () =>
      backend.action(internal.errorReporting.captureServiceHealth, {}),
  };
}
