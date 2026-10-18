import type { Infer } from 'convex/values';

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

interface ControlArgs {
  installationId: string;
  credentialDigest: string;
  generation: number;
  operation: Infer<typeof operation>;
}
type Installation = Doc<'errorReportingInstallations'>;
interface ControlResult {
  status: number;
  state: Installation['state'];
  leaseId?: Id<'errorReportingDeliveries'>;
}
interface ControlContext {
  ctx: MutationCtx;
  record: Installation;
  args: ControlArgs;
}
const deleting = (record: Installation) =>
  !['enabled', 'disabled'].includes(record.state.kind);

async function createInstallation(ctx: MutationCtx, args: ControlArgs) {
  if (args.operation === 'capture' || args.operation === 'status') {
    return null;
  }
  const id = await ctx.db.insert('errorReportingInstallations', {
    installationId: args.installationId,
    credentialDigest: args.credentialDigest,
    generation: args.generation,
    deliveryAttempted: false,
    state: initialState(args.operation),
  });
  return ctx.db.get('errorReportingInstallations', id);
}

function enableRefused(record: Installation, generation: number) {
  return (
    deleting(record) ||
    (record.state.kind === 'disabled' && generation === record.generation)
  );
}

async function enable({
  ctx,
  record,
  args,
}: ControlContext): Promise<ControlResult> {
  if (enableRefused(record, args.generation)) {
    return { status: 409, state: record.state };
  }
  await ctx.db.patch('errorReportingInstallations', record._id, {
    state: { kind: 'enabled' },
    generation: args.generation,
  });
  return { status: 200, state: { kind: 'enabled' } };
}

async function revoke({
  ctx,
  record,
  args,
}: ControlContext): Promise<ControlResult> {
  if (deleting(record)) {
    return { status: 200, state: record.state };
  }
  await ctx.db.patch('errorReportingInstallations', record._id, {
    generation: args.generation,
    state: { kind: 'disabled' },
  });
  return { status: 200, state: { kind: 'disabled' } };
}

async function deleteReports({
  ctx,
  record,
  args,
}: ControlContext): Promise<ControlResult> {
  if (deleting(record)) {
    return { status: 200, state: record.state };
  }
  const state = record.deliveryAttempted
    ? { kind: 'pending' as const }
    : { kind: 'complete' as const };
  await ctx.db.patch('errorReportingInstallations', record._id, {
    generation: args.generation,
    state,
  });
  if (state.kind === 'pending') {
    await ctx.scheduler.runAfter(5000, internal.errorReporting.pollDeletion, {
      installationId: args.installationId,
    });
  }
  return { status: 200, state };
}

const commands = {
  enable,
  revoke,
  delete: deleteReports,
  capture: ({ ctx, record, args }: ControlContext) =>
    claimCapture(ctx, record, args.generation),
  status: ({ record }: ControlContext): ControlResult => ({
    status: 200,
    state: record.state,
  }),
};

function authenticated(
  record: Installation | null,
  digest: string,
): record is Installation {
  return record !== null && sameDigest(record.credentialDigest, digest);
}

export const control = internalMutation({
  args: { ...proof, operation },
  handler: async (ctx, args): Promise<ControlResult> => {
    const record =
      (await installation(ctx, args.installationId)) ??
      (await createInstallation(ctx, args));
    if (!authenticated(record, args.credentialDigest)) {
      return { status: 403, state: { kind: 'disabled' } };
    }
    if (args.generation < record.generation) {
      return { status: 409, state: record.state };
    }
    return commands[args.operation]({ ctx, record, args });
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

interface DeletionUpdate {
  personUuid?: string;
  complete?: boolean;
}
const deletionTransitions: Partial<
  Record<
    Installation['state']['kind'],
    (update: DeletionUpdate) => Installation['state'] | undefined
  >
> = {
  verifying: (update) =>
    update.complete === true ? { kind: 'complete' } : undefined,
  pending: (update) =>
    update.personUuid === undefined
      ? undefined
      : { kind: 'verifying', personUuid: update.personUuid },
};

export const advanceDeletion = internalMutation({
  args: {
    installationId: v.string(),
    personUuid: v.optional(v.string()),
    complete: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const record = await installation(ctx, args.installationId);
    if (record === null) {
      return;
    }
    const state = deletionTransitions[record.state.kind]?.(args);
    if (state !== undefined) {
      await ctx.db.patch('errorReportingInstallations', record._id, { state });
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
