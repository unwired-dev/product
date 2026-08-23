import { v } from 'convex/values';

import type { Doc, Id } from './_generated/dataModel.js';
import type { MutationCtx, QueryCtx } from './_generated/server.js';

import { internal } from './_generated/api.js';
import { internalMutation, mutation, query } from './_generated/server.js';
import {
  requireAuthenticatedTrustedDevice,
  trustedDeviceCredentialArgs,
} from './productAccountAuth.js';

const minuteMilliseconds = 60 * 1000;
const dayMilliseconds = 24 * 60 * minuteMilliseconds;
const yearMilliseconds = 365 * dayMilliseconds;
const claimDurationMilliseconds = 15 * minuteMilliseconds;
const scheduledDeliveryCapabilityVersion = 1;
const authorizationByteCount = 32;

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
    claimPhase: v.optional(
      v.union(v.literal('pre-handoff'), v.literal('handing-off')),
    ),
    state: v.union(
      v.literal('active'),
      v.literal('cancelled'),
      v.literal('completed'),
      v.literal('needs-attention'),
    ),
  }),
);

const authorizationResponseValidator = v.object({
  authorization: v.string(),
  capabilityVersion: v.number(),
  generation: v.number(),
});

const claimResponseValidator = v.union(
  v.object({ status: v.literal('unavailable') }),
  v.object({
    authorizationGeneration: v.number(),
    expiresAt: v.optional(v.number()),
    generation: v.number(),
    phase: v.union(v.literal('pre-handoff'), v.literal('handing-off')),
    status: v.literal('claimed'),
  }),
);

const scheduledDeliveryAuthorizationArgs = {
  scheduledDeliveryAuthorization: v.string(),
  trustedDeviceId: v.id('trustedDevices'),
};

const wakeupArgs = {
  revision: v.number(),
  scheduleDocumentId: v.id('scheduledSends'),
};

// fallow-ignore-next-line code-duplication -- Scheduled Delivery Authorization keeps its private digest encoding local to this capability boundary.
function bytesToHex(bytes: Readonly<Uint8Array>): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

function issueScheduledDeliveryAuthorization(): string {
  return bytesToHex(
    crypto.getRandomValues(new Uint8Array(authorizationByteCount)),
  );
}

async function authorizationDigest(authorization: string): Promise<string> {
  return bytesToHex(
    new Uint8Array(
      await crypto.subtle.digest(
        'SHA-256',
        new TextEncoder().encode(authorization),
      ),
    ),
  );
}

// fallow-ignore-next-line complexity -- This boundary validates every credential and capability invariant before returning a narrowed device.
async function requireScheduledDeliveryAuthorization(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Convex generated IDs are mutable types.
  args: Readonly<{
    scheduledDeliveryAuthorization: string;
    trustedDeviceId: Id<'trustedDevices'>;
  }>,
) {
  const device = await ctx.db.get(args.trustedDeviceId);
  if (
    device === null ||
    device.scheduledDeliveryAuthorizationDigest === undefined ||
    device.scheduledDeliveryAuthorizationGeneration === undefined ||
    device.scheduledDeliveryCapabilityVersion !==
      scheduledDeliveryCapabilityVersion ||
    !/^[0-9a-f]{64}$/u.test(args.scheduledDeliveryAuthorization) ||
    (await authorizationDigest(args.scheduledDeliveryAuthorization)) !==
      device.scheduledDeliveryAuthorizationDigest
  ) {
    throw new Error('Scheduled Delivery Authorization required');
  }
  return {
    ...device,
    scheduledDeliveryAuthorizationDigest:
      device.scheduledDeliveryAuthorizationDigest,
    scheduledDeliveryAuthorizationGeneration:
      device.scheduledDeliveryAuthorizationGeneration,
    scheduledDeliveryCapabilityVersion,
  };
}

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

interface AdmissionArguments {
  readonly deadlineAt: number;
  readonly dueAt: number;
  readonly encryptedPayloadIdentifier: string;
  readonly encryptedPayloadUpdatedAt: number;
  readonly revision: number;
  readonly scheduleId: string;
  readonly trustedDeviceId: Doc<'trustedDevices'>['_id'];
}

function assertValidAdmission(
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- AdmissionArguments fields are explicitly readonly but the generated trusted-device ID is not inferred as readonly.
  args: Readonly<AdmissionArguments>,
  now: number,
) {
  const isValid = [
    args.dueAt >= now + minuteMilliseconds,
    args.dueAt <= now + yearMilliseconds,
    args.deadlineAt === args.dueAt + dayMilliseconds,
    Number.isSafeInteger(args.revision),
    args.revision >= 1,
  ].every(Boolean);
  if (!isValid) {
    throw new Error('Invalid Scheduled Send admission');
  }
}

function admissionConflicts(
  existing: Readonly<Doc<'scheduledSends'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents contain generated mutable fields but are not mutated here.
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- AdmissionArguments fields are explicitly readonly but the generated trusted-device ID is not inferred as readonly.
  args: Readonly<AdmissionArguments>,
) {
  return [
    existing.trustedDeviceId === args.trustedDeviceId,
    existing.revision === args.revision,
    existing.dueAt === args.dueAt,
    existing.deadlineAt === args.deadlineAt,
    existing.encryptedPayloadIdentifier === args.encryptedPayloadIdentifier,
    existing.encryptedPayloadUpdatedAt === args.encryptedPayloadUpdatedAt,
  ].some((matches) => !matches);
}

function isCurrentActiveSchedule(
  schedule: Readonly<Doc<'scheduledSends'>> | null, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents contain generated mutable fields but are not mutated here.
  revision: number,
): schedule is Doc<'scheduledSends'> {
  return (
    schedule !== null &&
    schedule.state === 'active' &&
    schedule.revision === revision
  );
}

async function currentActiveSchedule(
  ctx: MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex mutation contexts expose mutable database methods.
  args: Readonly<{
    revision: number;
    scheduleDocumentId: Id<'scheduledSends'>;
  }>,
): Promise<Doc<'scheduledSends'> | null> {
  const schedule = await ctx.db.get(args.scheduleDocumentId);
  return isCurrentActiveSchedule(schedule, args.revision) ? schedule : null;
}

function hasPushRecipient(
  device: Readonly<Doc<'trustedDevices'>> | null, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents contain generated mutable fields but are not mutated here.
): device is Doc<'trustedDevices'> & {
  apnsEnvironment: 'production' | 'sandbox';
  apnsToken: string;
} {
  return (
    device?.apnsEnvironment !== undefined && device.apnsToken !== undefined
  );
}

function claimedResponse(
  schedule: Readonly<Doc<'scheduledSends'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents contain generated mutable fields but are not mutated here.
) {
  if (
    schedule.claimAuthorizationGeneration === undefined ||
    schedule.claimGeneration === undefined ||
    schedule.claimPhase === undefined
  ) {
    throw new Error('Scheduled Send claim is incomplete');
  }
  return {
    authorizationGeneration: schedule.claimAuthorizationGeneration,
    expiresAt: schedule.claimExpiresAt,
    generation: schedule.claimGeneration,
    phase: schedule.claimPhase,
    status: 'claimed' as const,
  };
}

// fallow-ignore-next-line complexity -- Claim replacement must keep expiry, ownership, authorization generation, and capability checks atomic.
async function preHandoffClaimCanBeReplaced(
  ctx: QueryCtx | MutationCtx, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex context is mutated by design.
  schedule: Readonly<Doc<'scheduledSends'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents contain generated mutable fields but are not mutated here.
  now: number,
) {
  if (schedule.claimPhase === undefined) {
    return true;
  }
  if (schedule.claimPhase === 'handing-off') {
    return false;
  }
  if ((schedule.claimExpiresAt ?? 0) <= now) {
    return true;
  }
  if (
    schedule.claimOwnerTrustedDeviceId === undefined ||
    schedule.claimAuthorizationGeneration === undefined
  ) {
    return true;
  }
  const owner = await ctx.db.get(schedule.claimOwnerTrustedDeviceId);
  return (
    owner === null ||
    owner.scheduledDeliveryAuthorizationGeneration !==
      schedule.claimAuthorizationGeneration ||
    owner.scheduledDeliveryCapabilityVersion !==
      scheduledDeliveryCapabilityVersion
  );
}

function matchesClaim(
  schedule: Readonly<Doc<'scheduledSends'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents contain generated mutable fields but are not mutated here.
  device: Readonly<Doc<'trustedDevices'>>, // oxlint-disable-line typescript/prefer-readonly-parameter-types -- Convex documents contain generated mutable fields but are not mutated here.
  claim: Readonly<{ claimGeneration: number; revision: number }>,
) {
  return [
    schedule.state === 'active',
    schedule.revision === claim.revision,
    schedule.claimOwnerTrustedDeviceId === device._id, // oxlint-disable-line eslint/no-underscore-dangle -- Convex document id field
    schedule.claimAuthorizationGeneration ===
      device.scheduledDeliveryAuthorizationGeneration,
    schedule.claimGeneration === claim.claimGeneration,
  ].every(Boolean);
}

export const registerDeliveryCapability = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    capabilityVersion: v.number(),
    scheduledDeliveryAuthorization: v.optional(v.string()),
    trustedDeviceId: v.id('trustedDevices'),
  },
  // fallow-ignore-next-line complexity -- Registration atomically validates credentials, rotates authorization, and invalidates stale claims.
  handler: async (ctx, args) => {
    await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    if (args.capabilityVersion !== scheduledDeliveryCapabilityVersion) {
      throw new Error('Unsupported Scheduled Delivery capability');
    }
    const device = await ctx.db.get(args.trustedDeviceId);
    if (device === null) {
      throw new Error('Trusted device required');
    }
    if (
      args.scheduledDeliveryAuthorization !== undefined &&
      device.scheduledDeliveryAuthorizationDigest !== undefined &&
      device.scheduledDeliveryAuthorizationGeneration !== undefined &&
      device.scheduledDeliveryCapabilityVersion ===
        scheduledDeliveryCapabilityVersion &&
      (await authorizationDigest(args.scheduledDeliveryAuthorization)) ===
        device.scheduledDeliveryAuthorizationDigest
    ) {
      return {
        authorization: args.scheduledDeliveryAuthorization,
        capabilityVersion: scheduledDeliveryCapabilityVersion,
        generation: device.scheduledDeliveryAuthorizationGeneration,
      };
    }
    const authorization = issueScheduledDeliveryAuthorization();
    const generation =
      (device.scheduledDeliveryAuthorizationGeneration ?? 0) + 1;
    await ctx.db.patch(args.trustedDeviceId, {
      scheduledDeliveryAuthorizationDigest:
        await authorizationDigest(authorization),
      scheduledDeliveryAuthorizationGeneration: generation,
      scheduledDeliveryCapabilityVersion,
    });
    return {
      authorization,
      capabilityVersion: scheduledDeliveryCapabilityVersion,
      generation,
    };
  },
  returns: authorizationResponseValidator,
});

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
  // fallow-ignore-next-line complexity -- Admission atomically validates ownership, payload revision, and idempotency before scheduling.
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    const now = Date.now();
    assertValidAdmission(args, now);
    const payload = await ctx.db
      .query('encryptedProductSyncPayloads')
      .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('payloadIdentifier', args.encryptedPayloadIdentifier),
      )
      .unique();
    if (payload?.updatedAt !== args.encryptedPayloadUpdatedAt) {
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
      if (admissionConflicts(existing, args)) {
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

export const claim = mutation({
  args: {
    ...scheduledDeliveryAuthorizationArgs,
    revision: v.number(),
    scheduleId: v.string(),
  },
  // fallow-ignore-next-line complexity -- Claim acquisition atomically enforces schedule state, timing, ownership, and authorization fencing.
  handler: async (ctx, args) => {
    const device = await requireScheduledDeliveryAuthorization(ctx, args);
    const schedule = await ctx.db
      .query('scheduledSends')
      .withIndex('by_productAccountId_and_scheduleId', (q) =>
        q
          .eq('productAccountId', device.productAccountId)
          .eq('scheduleId', args.scheduleId),
      )
      .unique();
    if (
      schedule === null ||
      schedule.state !== 'active' ||
      schedule.revision !== args.revision
    ) {
      return { status: 'unavailable' as const };
    }
    const now = Date.now();
    if (now < schedule.dueAt) {
      return { status: 'unavailable' as const };
    }
    if (now > schedule.deadlineAt) {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(schedule._id, {
        scheduledFunctionId: undefined,
        state: 'needs-attention',
        updatedAt: now,
      });
      return { status: 'unavailable' as const };
    }
    if (
      schedule.claimOwnerTrustedDeviceId === args.trustedDeviceId &&
      schedule.claimAuthorizationGeneration ===
        device.scheduledDeliveryAuthorizationGeneration &&
      schedule.claimPhase !== undefined &&
      (schedule.claimPhase === 'handing-off' ||
        (schedule.claimExpiresAt ?? 0) > now)
    ) {
      return claimedResponse(schedule);
    }
    if (!(await preHandoffClaimCanBeReplaced(ctx, schedule, now))) {
      return { status: 'unavailable' as const };
    }
    const generation = (schedule.claimGeneration ?? 0) + 1;
    const expiresAt = now + claimDurationMilliseconds;
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.patch(schedule._id, {
      claimAuthorizationGeneration:
        device.scheduledDeliveryAuthorizationGeneration,
      claimExpiresAt: expiresAt,
      claimGeneration: generation,
      claimOwnerTrustedDeviceId: args.trustedDeviceId,
      claimPhase: 'pre-handoff',
      claimUpdatedAt: now,
      updatedAt: now,
    });
    return {
      authorizationGeneration: device.scheduledDeliveryAuthorizationGeneration,
      expiresAt,
      generation,
      phase: 'pre-handoff' as const,
      status: 'claimed' as const,
    };
  },
  returns: claimResponseValidator,
});

// fallow-ignore-next-line code-duplication -- Handoff advancement and release remain distinct capabilities with different permitted claim phases.
export const advanceClaimToHandoff = mutation({
  args: {
    ...scheduledDeliveryAuthorizationArgs,
    claimGeneration: v.number(),
    revision: v.number(),
    scheduleId: v.string(),
  },
  // fallow-ignore-next-line complexity -- Handoff advancement validates the complete revision-bound claim fence before one state transition.
  handler: async (ctx, args) => {
    const device = await requireScheduledDeliveryAuthorization(ctx, args);
    const schedule = await ctx.db
      .query('scheduledSends')
      .withIndex('by_productAccountId_and_scheduleId', (q) =>
        q
          .eq('productAccountId', device.productAccountId)
          .eq('scheduleId', args.scheduleId),
      )
      .unique();
    if (schedule === null || !matchesClaim(schedule, device, args)) {
      return false;
    }
    if (schedule.claimPhase === 'handing-off') {
      return true;
    }
    if (
      schedule.claimPhase !== 'pre-handoff' ||
      (schedule.claimExpiresAt ?? 0) <= Date.now()
    ) {
      return false;
    }
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.patch(schedule._id, {
      claimExpiresAt: undefined,
      claimPhase: 'handing-off',
      claimUpdatedAt: Date.now(),
      updatedAt: Date.now(),
    });
    return true;
  },
  returns: v.boolean(),
});

export const revalidateClaim = query({
  args: {
    ...scheduledDeliveryAuthorizationArgs,
    claimGeneration: v.number(),
    revision: v.number(),
    scheduleId: v.string(),
  },
  // fallow-ignore-next-line complexity -- Revalidation checks every claim identity field at the authorization boundary.
  handler: async (ctx, args) => {
    const device = await requireScheduledDeliveryAuthorization(ctx, args);
    const schedule = await ctx.db
      .query('scheduledSends')
      .withIndex('by_productAccountId_and_scheduleId', (q) =>
        q
          .eq('productAccountId', device.productAccountId)
          .eq('scheduleId', args.scheduleId),
      )
      .unique();
    if (
      schedule === null ||
      !matchesClaim(schedule, device, args) ||
      schedule.claimPhase === undefined ||
      (schedule.claimPhase === 'pre-handoff' &&
        (schedule.claimExpiresAt ?? 0) <= Date.now())
    ) {
      return { status: 'unavailable' as const };
    }
    return claimedResponse(schedule);
  },
  returns: claimResponseValidator,
});

// fallow-ignore-next-line code-duplication -- Claim release clears a pre-handoff lease and cannot share handoff mutation authority.
export const releaseClaim = mutation({
  args: {
    ...scheduledDeliveryAuthorizationArgs,
    claimGeneration: v.number(),
    revision: v.number(),
    scheduleId: v.string(),
  },
  handler: async (ctx, args) => {
    const device = await requireScheduledDeliveryAuthorization(ctx, args);
    const schedule = await ctx.db
      .query('scheduledSends')
      .withIndex('by_productAccountId_and_scheduleId', (q) =>
        q
          .eq('productAccountId', device.productAccountId)
          .eq('scheduleId', args.scheduleId),
      )
      .unique();
    if (
      schedule === null ||
      schedule.claimPhase !== 'pre-handoff' ||
      !matchesClaim(schedule, device, args)
    ) {
      return false;
    }
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.patch(schedule._id, {
      claimAuthorizationGeneration: undefined,
      claimExpiresAt: undefined,
      claimOwnerTrustedDeviceId: undefined,
      claimPhase: undefined,
      claimUpdatedAt: Date.now(),
      updatedAt: Date.now(),
    });
    return true;
  },
  returns: v.boolean(),
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
    if (schedule === null) {
      return null;
    }
    return {
      claimPhase: schedule.claimPhase,
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
      schedule.revision !== args.revision ||
      schedule.state !== 'active' ||
      schedule.claimPhase === 'handing-off'
    ) {
      return false;
    }
    if (schedule.scheduledFunctionId !== undefined) {
      await ctx.scheduler.cancel(schedule.scheduledFunctionId);
    }
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.patch(schedule._id, {
      scheduledFunctionId: undefined,
      claimAuthorizationGeneration: undefined,
      claimExpiresAt: undefined,
      claimOwnerTrustedDeviceId: undefined,
      claimPhase: undefined,
      claimUpdatedAt: Date.now(),
      state: 'cancelled',
      updatedAt: Date.now(),
    });
    return true;
  },
  returns: v.boolean(),
});

export const reschedule = mutation({
  args: {
    ...trustedDeviceCredentialArgs,
    deadlineAt: v.number(),
    dueAt: v.number(),
    encryptedPayloadIdentifier: v.string(),
    encryptedPayloadUpdatedAt: v.number(),
    expectedRevision: v.number(),
    revision: v.number(),
    scheduleId: v.string(),
    trustedDeviceId: v.id('trustedDevices'),
  },
  // fallow-ignore-next-line complexity -- Rescheduling compares the encrypted and operational revisions before replacing due work.
  handler: async (ctx, args) => {
    const account = await requireAuthenticatedTrustedDevice(
      ctx,
      args.trustedDeviceId,
      args.trustedDeviceCredential,
    );
    if (args.revision !== args.expectedRevision + 1) {
      throw new Error('Scheduled Send revision must advance exactly once');
    }
    assertValidAdmission(args, Date.now());
    const payload = await ctx.db
      .query('encryptedProductSyncPayloads')
      .withIndex('by_productAccountId_and_payloadIdentifier', (q) =>
        q
          .eq('productAccountId', account.productAccountId)
          .eq('payloadIdentifier', args.encryptedPayloadIdentifier),
      )
      .unique();
    if (payload?.updatedAt !== args.encryptedPayloadUpdatedAt) {
      throw new Error('Exact encrypted Scheduled Send payload required');
    }
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
      schedule.state !== 'active' ||
      schedule.revision !== args.expectedRevision ||
      schedule.claimPhase === 'handing-off'
    ) {
      throw new Error('Scheduled Send revision is no longer editable');
    }
    if (schedule.scheduledFunctionId !== undefined) {
      await ctx.scheduler.cancel(schedule.scheduledFunctionId);
    }
    const scheduledFunctionId = await ctx.scheduler.runAt(
      args.dueAt,
      internal.apns.deliverScheduledSendWakeup,
      {
        revision: args.revision,
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        scheduleDocumentId: schedule._id,
      },
    );
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.patch(schedule._id, {
      claimAuthorizationGeneration: undefined,
      claimExpiresAt: undefined,
      claimOwnerTrustedDeviceId: undefined,
      claimPhase: undefined,
      claimUpdatedAt: Date.now(),
      deadlineAt: args.deadlineAt,
      dueAt: args.dueAt,
      encryptedPayloadIdentifier: args.encryptedPayloadIdentifier,
      encryptedPayloadUpdatedAt: args.encryptedPayloadUpdatedAt,
      revision: args.revision,
      scheduledFunctionId,
      trustedDeviceId: args.trustedDeviceId,
      updatedAt: Date.now(),
      wakeAttemptedAt: undefined,
    });
    return {
      dueAt: args.dueAt,
      encryptedPayloadUpdatedAt: args.encryptedPayloadUpdatedAt,
      revision: args.revision,
      scheduleId: args.scheduleId,
    };
  },
  returns: admissionResponseValidator,
});

export const complete = mutation({
  args: {
    ...scheduledDeliveryAuthorizationArgs,
    claimGeneration: v.number(),
    revision: v.number(),
    scheduleId: v.string(),
    state: v.union(v.literal('completed'), v.literal('needs-attention')),
  },
  handler: async (ctx, args) => {
    const device = await requireScheduledDeliveryAuthorization(ctx, args);
    const schedule = await ctx.db
      .query('scheduledSends')
      .withIndex('by_productAccountId_and_scheduleId', (q) =>
        q
          .eq('productAccountId', device.productAccountId)
          .eq('scheduleId', args.scheduleId),
      )
      .unique();
    if (schedule === null) {
      return true;
    }
    if (
      schedule.claimPhase !== 'handing-off' ||
      !matchesClaim(schedule, device, args)
    ) {
      return false;
    }
    if (args.state === 'needs-attention') {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(schedule._id, {
        claimAuthorizationGeneration: undefined,
        claimExpiresAt: undefined,
        claimOwnerTrustedDeviceId: undefined,
        claimPhase: undefined,
        claimUpdatedAt: Date.now(),
        state: 'needs-attention',
        updatedAt: Date.now(),
      });
      return true;
    }
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.delete(schedule._id);
    return true;
  },
  returns: v.boolean(),
});

export const claimWakeup = internalMutation({
  args: wakeupArgs,
  // fallow-ignore-next-line complexity -- Wakeup claims atomically fence schedule state, deadlines, and device eligibility.
  handler: async (ctx, args) => {
    const schedule = await currentActiveSchedule(ctx, args);
    if (schedule === null) {
      return [];
    }
    const now = Date.now();
    if (now < schedule.dueAt) {
      return [];
    }
    if (now > schedule.deadlineAt) {
      await ctx.db.patch(args.scheduleDocumentId, {
        scheduledFunctionId: undefined,
        state: 'needs-attention',
        updatedAt: now,
      });
      return [];
    }
    const devices = await ctx.db
      .query('trustedDevices')
      .withIndex('by_productAccountId', (q) =>
        q.eq('productAccountId', schedule.productAccountId),
      )
      .collect();
    await ctx.db.patch(args.scheduleDocumentId, {
      scheduledFunctionId: undefined,
      updatedAt: now,
      wakeAttemptedAt: now,
    });
    return devices.flatMap((device) => {
      if (
        !hasPushRecipient(device) ||
        device.scheduledDeliveryAuthorizationDigest === undefined ||
        device.scheduledDeliveryAuthorizationGeneration === undefined ||
        device.scheduledDeliveryCapabilityVersion !==
          scheduledDeliveryCapabilityVersion
      ) {
        return [];
      }
      return [
        {
          apnsEnvironment: device.apnsEnvironment,
          apnsToken: device.apnsToken,
          pushCleanupGeneration: device.pushCleanupGeneration,
          revision: schedule.revision,
          scheduleId: schedule.scheduleId,
          // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
          trustedDeviceId: device._id,
        },
      ];
    });
  },
  returns: v.array(
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

export const retryWakeup = internalMutation({
  args: wakeupArgs,
  handler: async (ctx, args) => {
    const schedule = await currentActiveSchedule(ctx, args);
    if (schedule === null) {
      return false;
    }
    if (schedule.scheduledFunctionId !== undefined) {
      return true;
    }
    const now = Date.now();
    const retryAt = now + minuteMilliseconds;
    if (retryAt >= schedule.deadlineAt) {
      await ctx.db.patch(args.scheduleDocumentId, {
        state: 'needs-attention',
        updatedAt: now,
      });
      return false;
    }
    const scheduledFunctionId = await ctx.scheduler.runAt(
      retryAt,
      internal.apns.deliverScheduledSendWakeup,
      args,
    );
    await ctx.db.patch(args.scheduleDocumentId, {
      scheduledFunctionId,
      updatedAt: now,
    });
    return true;
  },
  returns: v.boolean(),
});
