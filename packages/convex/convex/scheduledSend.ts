import { v } from 'convex/values';

import type { Doc } from './_generated/dataModel.js';

import { internal } from './_generated/api.js';
import { internalMutation, mutation, query } from './_generated/server.js';
import {
  requireAuthenticatedTrustedDevice,
  trustedDeviceCredentialArgs,
} from './productAccountAuth.js';

const minuteMilliseconds = 60 * 1000;
const dayMilliseconds = 24 * 60 * minuteMilliseconds;
const yearMilliseconds = 365 * dayMilliseconds;

const admissionResponseValidator = v.object({
  dueAt: v.number(),
  encryptedPayloadUpdatedAt: v.number(),
  revision: v.number(),
  scheduleId: v.string(),
});

const statusResponseValidator = v.union(
  v.null(),
  v.object({
    deadlineAt: v.number(),
    dueAt: v.number(),
    encryptedPayloadUpdatedAt: v.number(),
    revision: v.number(),
    scheduleId: v.string(),
    state: v.union(
      v.literal('active'),
      v.literal('cancelled'),
      v.literal('completed'),
      v.literal('needs-attention'),
    ),
  }),
);

function admissionResponse(
  schedule: Readonly<Doc<'scheduledSends'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents contain generated mutable fields but are not mutated here.
) {
  return {
    dueAt: schedule.dueAt,
    encryptedPayloadUpdatedAt: schedule.encryptedPayloadUpdatedAt,
    revision: schedule.revision,
    scheduleId: schedule.scheduleId,
  };
}

export const admit = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    deadlineAt: v.number(),
    dueAt: v.number(),
    encryptedPayloadIdentifier: v.string(),
    encryptedPayloadUpdatedAt: v.number(),
    revision: v.number(),
    scheduleId: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    const now = Date.now();
    if (
      args.dueAt < now + minuteMilliseconds ||
      args.dueAt > now + yearMilliseconds ||
      args.deadlineAt !== args.dueAt + dayMilliseconds ||
      !Number.isSafeInteger(args.revision) ||
      args.revision < 1
    ) {
      throw new Error('Invalid Scheduled Send admission');
    }
    const payload = await ctx.db
      .query('encryptedProductSyncPayloads')
      .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('payloadIdentifier', args.encryptedPayloadIdentifier),
      )
      .unique();
    if (
      payload === null ||
      payload.updatedAt !== args.encryptedPayloadUpdatedAt
    ) {
      throw new Error('Exact encrypted Scheduled Send payload required');
    }
    const existing = await ctx.db
      .query('scheduledSends')
      .withIndex('by_productAccountId_and_scheduleId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('scheduleId', args.scheduleId),
      )
      .unique();
    if (existing !== null) {
      if (
        existing.trustedDeviceId !== args.trustedDeviceId ||
        existing.revision !== args.revision ||
        existing.dueAt !== args.dueAt ||
        existing.deadlineAt !== args.deadlineAt ||
        existing.encryptedPayloadIdentifier !==
          args.encryptedPayloadIdentifier ||
        existing.encryptedPayloadUpdatedAt !== args.encryptedPayloadUpdatedAt
      ) {
        throw new Error('Scheduled Send admission conflicts with its revision');
      }
      return admissionResponse(existing);
    }

    const scheduleDocumentId = await ctx.db.insert('scheduledSends', {
      deadlineAt: args.deadlineAt,
      dueAt: args.dueAt,
      encryptedPayloadIdentifier: args.encryptedPayloadIdentifier,
      encryptedPayloadUpdatedAt: args.encryptedPayloadUpdatedAt,
      productAccountId: account.productAccountId,
      revision: args.revision,
      scheduleId: args.scheduleId,
      state: 'active',
      trustedDeviceId: args.trustedDeviceId,
      updatedAt: now,
    });
    const scheduledFunctionId = await ctx.scheduler.runAt(
      args.dueAt,
      internal.apns.deliverScheduledSendWakeup,
      { revision: args.revision, scheduleDocumentId },
    );
    await ctx.db.patch(scheduleDocumentId, { scheduledFunctionId });
    return {
      dueAt: args.dueAt,
      encryptedPayloadUpdatedAt: args.encryptedPayloadUpdatedAt,
      revision: args.revision,
      scheduleId: args.scheduleId,
    };
  },
  returns: admissionResponseValidator,
});

export const status = query({
  args: {
    ...trustedDeviceCredentialArgs,
    scheduleId: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    const schedule = await ctx.db
      .query('scheduledSends')
      .withIndex('by_productAccountId_and_scheduleId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('scheduleId', args.scheduleId),
      )
      .unique();
    if (
      schedule === null ||
      schedule.trustedDeviceId !== args.trustedDeviceId
    ) {
      return null;
    }
    return {
      deadlineAt: schedule.deadlineAt,
      dueAt: schedule.dueAt,
      encryptedPayloadUpdatedAt: schedule.encryptedPayloadUpdatedAt,
      revision: schedule.revision,
      scheduleId: schedule.scheduleId,
      state: schedule.state,
    };
  },
  returns: statusResponseValidator,
});

export const cancel = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    revision: v.number(),
    scheduleId: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    const schedule = await ctx.db
      .query('scheduledSends')
      .withIndex('by_productAccountId_and_scheduleId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('scheduleId', args.scheduleId),
      )
      .unique();
    if (
      schedule === null ||
      schedule.trustedDeviceId !== args.trustedDeviceId ||
      schedule.revision !== args.revision ||
      schedule.state !== 'active'
    ) {
      return false;
    }
    if (schedule.scheduledFunctionId !== undefined) {
      await ctx.scheduler.cancel(schedule.scheduledFunctionId);
    }
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.patch(schedule._id, {
      scheduledFunctionId: undefined,
      state: 'cancelled',
      updatedAt: Date.now(),
    });
    return true;
  },
  returns: v.boolean(),
});

export const complete = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    revision: v.number(),
    scheduleId: v.string(),
    state: v.union(v.literal('completed'), v.literal('needs-attention')),
    trustedDeviceId: v.id('trustedDevices'),
  },
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    const schedule = await ctx.db
      .query('scheduledSends')
      .withIndex('by_productAccountId_and_scheduleId', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('scheduleId', args.scheduleId),
      )
      .unique();
    if (
      schedule === null ||
      schedule.trustedDeviceId !== args.trustedDeviceId ||
      schedule.revision !== args.revision ||
      schedule.state !== 'active'
    ) {
      return false;
    }
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.patch(schedule._id, {
      scheduledFunctionId: undefined,
      state: args.state,
      updatedAt: Date.now(),
    });
    return true;
  },
  returns: v.boolean(),
});

export const claimWakeup = internalMutation({
  args: {
    revision: v.number(),
    scheduleDocumentId: v.id('scheduledSends'),
  },
  handler: async (ctx, args) => {
    const schedule = await ctx.db.get(args.scheduleDocumentId);
    if (
      schedule === null ||
      schedule.state !== 'active' ||
      schedule.revision !== args.revision
    ) {
      return null;
    }
    const now = Date.now();
    if (now < schedule.dueAt) {
      return null;
    }
    if (now > schedule.deadlineAt) {
      await ctx.db.patch(args.scheduleDocumentId, {
        scheduledFunctionId: undefined,
        state: 'needs-attention',
        updatedAt: now,
      });
      return null;
    }
    const device = await ctx.db.get(schedule.trustedDeviceId);
    await ctx.db.patch(args.scheduleDocumentId, {
      scheduledFunctionId: undefined,
      updatedAt: now,
      wakeAttemptedAt: now,
    });
    if (
      device?.apnsEnvironment === undefined ||
      device.apnsToken === undefined
    ) {
      return null;
    }
    return {
      apnsEnvironment: device.apnsEnvironment,
      apnsToken: device.apnsToken,
      pushCleanupGeneration: device.pushCleanupGeneration,
      revision: schedule.revision,
      scheduleId: schedule.scheduleId,
      trustedDeviceId: schedule.trustedDeviceId,
    };
  },
  returns: v.union(
    v.null(),
    v.object({
      apnsEnvironment: v.union(v.literal('production'), v.literal('sandbox')),
      apnsToken: v.string(),
      pushCleanupGeneration: v.optional(v.number()),
      revision: v.number(),
      scheduleId: v.string(),
      trustedDeviceId: v.id('trustedDevices'),
    }),
  ),
});
