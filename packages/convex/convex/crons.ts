import { cronJobs } from 'convex/server';

import { internal } from './_generated/api.js';

const crons = cronJobs();

crons.interval(
  'reconcile stale device push routes',
  { hours: 24 },
  internal.pushRelay.reconcileStaleDevicePushRoutes,
  {},
);

export default crons;
