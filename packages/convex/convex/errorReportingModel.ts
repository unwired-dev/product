import { v } from 'convex/values';

export const reportingStateValidator = v.union(
  v.object({ kind: v.literal('enabled') }),
  v.object({ kind: v.literal('disabled') }),
  v.object({ kind: v.literal('pending') }),
  v.object({ kind: v.literal('verifying'), personUuid: v.string() }),
  v.object({ kind: v.literal('complete') }),
);
