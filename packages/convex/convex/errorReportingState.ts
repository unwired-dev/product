import { v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx } from './_generated/server.js';

import { internal } from './_generated/api.js';
import { internalMutation, internalQuery } from './_generated/server.js';

const proof = {
  installationId: v.string(),
  credentialDigest: v.string(),
  generation: v.number(),
};
const operation = v.union(
  v.literal('enable'),
  v.literal('revoke'),
  v.literal('delete'),
  v.literal('status'),
  v.literal('capture'),
);

// Both digests have a fixed length; do not return early for a differing byte.
function sameDigest(left: string, right: string): boolean {
  let difference = Math.abs(left.length - right.length);
  for (let index = 0; index < 64; index += 1) {
    difference += Math.abs(
      (left.codePointAt(index) ?? 0) - (right.codePointAt(index) ?? 0),
    );
  }
  return difference === 0;
}

async function installation(ctx: MutationCtx, installationId: string) {
  return ctx.db
    .query('errorReportingInstallations')
    .withIndex('by_installationId', (q) =>
      q.eq('installationId', installationId),
    )
    .unique();
}

async function claimCapture(
  ctx: MutationCtx,
  record: Doc<'errorReportingInstallations'>,
  generation: number,
) {
  if (record.state.kind !== 'enabled' || generation !== record.generation) {
    return { status: 409, state: record.state };
  }
  const active = await ctx.db
    .query('errorReportingDeliveries')
    .withIndex('by_installationId', (q) =>
      q.eq('installationId', record.installationId),
    )
    .first();
  if (active !== null) {
    return { status: 429, state: record.state };
  }
  const leaseId = await ctx.db.insert('errorReportingDeliveries', {
    installationId: record.installationId,
  });
  await ctx.db.patch('errorReportingInstallations', record._id, {
    deliveryAttempted: true,
  });
  return { status: 200, state: record.state, leaseId };
}

function initialState(command: 'enable' | 'revoke' | 'delete') {
  if (command === 'enable') {
    return { kind: 'enabled' as const };
  }
  return command === 'delete'
    ? { kind: 'complete' as const }
    : { kind: 'disabled' as const };
}

export const control = internalMutation({
  args: { ...proof, operation },
  handler: async (
    ctx,
    args,
  ): Promise<{
    status: number;
    state: Doc<'errorReportingInstallations'>['state'];
    leaseId?: Id<'errorReportingDeliveries'>;
  }> => {
    let record = await installation(ctx, args.installationId);
    if (record === null) {
      if (args.operation === 'capture' || args.operation === 'status') {
        return { status: 403, state: { kind: 'disabled' } };
      }
      const state = initialState(args.operation);
      const id = await ctx.db.insert('errorReportingInstallations', {
        installationId: args.installationId,
        credentialDigest: args.credentialDigest,
        generation: args.generation,
        deliveryAttempted: false,
        state,
      });
      record = await ctx.db.get('errorReportingInstallations', id);
    }
    if (
      record === null ||
      !sameDigest(record.credentialDigest, args.credentialDigest)
    ) {
      return { status: 403, state: { kind: 'disabled' } };
    }
    if (args.generation < record.generation) {
      return { status: 409, state: record.state };
    }
    const deleting = !['enabled', 'disabled'].includes(record.state.kind);
    if (args.operation === 'enable') {
      if (
        deleting ||
        (record.state.kind === 'disabled' &&
          args.generation === record.generation)
      ) {
        return { status: 409, state: record.state };
      }
      await ctx.db.patch('errorReportingInstallations', record._id, {
        state: { kind: 'enabled' },
        generation: args.generation,
      });
      return { status: 200, state: { kind: 'enabled' } };
    }
    if (args.operation === 'capture') {
      return claimCapture(ctx, record, args.generation);
    }
    if (args.operation === 'revoke') {
      if (deleting) {
        return { status: 200, state: record.state };
      }
      await ctx.db.patch('errorReportingInstallations', record._id, {
        generation: args.generation,
        state: { kind: 'disabled' },
      });
      return { status: 200, state: { kind: 'disabled' } };
    }
    if (args.operation === 'delete' && !deleting) {
      const state = record.deliveryAttempted
        ? { kind: 'pending' as const }
        : { kind: 'complete' as const };
      await ctx.db.patch('errorReportingInstallations', record._id, {
        generation: args.generation,
        state,
      });
      if (state.kind === 'pending') {
        await ctx.scheduler.runAfter(
          5000,
          internal.errorReporting.pollDeletion,
          { installationId: args.installationId },
        );
      }
      return { status: 200, state };
    }
    return { status: 200, state: record.state };
  },
});

export const releaseDelivery = internalMutation({
  args: { leaseId: v.id('errorReportingDeliveries') },
  handler: async (ctx, args) => {
    await ctx.db.delete('errorReportingDeliveries', args.leaseId);
  },
});

export const deletionState = internalQuery({
  args: { installationId: v.string() },
  handler: async (ctx, args) => {
    const record = await ctx.db
      .query('errorReportingInstallations')
      .withIndex('by_installationId', (q) =>
        q.eq('installationId', args.installationId),
      )
      .unique();
    const active = await ctx.db
      .query('errorReportingDeliveries')
      .withIndex('by_installationId', (q) =>
        q.eq('installationId', args.installationId),
      )
      .first();
    return {
      state: record?.state ?? { kind: 'disabled' as const },
      active: active !== null,
    };
  },
});

export const advanceDeletion = internalMutation({
  args: {
    installationId: v.string(),
    personUuid: v.optional(v.string()),
    complete: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const record = await installation(ctx, args.installationId);
    if (
      record === null ||
      (record.state.kind !== 'pending' && record.state.kind !== 'verifying')
    ) {
      return;
    }
    if (args.complete === true && record.state.kind === 'verifying') {
      await ctx.db.patch('errorReportingInstallations', record._id, {
        state: { kind: 'complete' },
      });
    } else if (
      args.personUuid !== undefined &&
      record.state.kind === 'pending'
    ) {
      await ctx.db.patch('errorReportingInstallations', record._id, {
        state: { kind: 'verifying', personUuid: args.personUuid },
      });
    }
  },
});

export const rescheduleDeletion = internalMutation({
  args: { installationId: v.string() },
  handler: async (ctx, args) => {
    const record = await installation(ctx, args.installationId);
    if (
      record?.state.kind === 'pending' ||
      record?.state.kind === 'verifying'
    ) {
      await ctx.scheduler.runAfter(
        60_000,
        internal.errorReporting.pollDeletion,
        args,
      );
    }
  },
});
