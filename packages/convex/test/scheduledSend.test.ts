/// <reference types="vite/client" />

import { convexTest } from 'convex-test';

import type { Id } from '../convex/_generated/dataModel.js';

import { api, internal } from '../convex/_generated/api.js';
import schema from '../convex/schema.js';

const modules = import.meta.glob('../convex/**/*.ts');

function requireValue<Value>(value: Value | null): Value {
  if (value === null) {
    throw new Error('Scheduled Send fixture missing');
  }
  return value;
}

function claimedGeneration(
  claim: Readonly<{ generation?: number; status: string }>,
): number {
  if (claim.status !== 'claimed' || claim.generation === undefined) {
    throw new Error('Scheduled Send claim missing');
  }
  return claim.generation;
}

const appleIdentity = {
  issuer: 'https://appleid.apple.com',
  subject: 'apple-user-001',
  tokenIdentifier: 'https://appleid.apple.com|apple-user-001',
};

const encryptedPayload = {
  algorithm: 'AES-GCM-256' as const,
  ciphertextBase64: 'c2NoZWR1bGVkLXNlbmQ',
  keyVersion: 1,
  nonceBase64: 'bm9uY2U',
  schemaVersion: 1,
  tagBase64: 'dGFn',
};

async function fixture() {
  const t = convexTest(schema, modules);
  const asUser = t.withIdentity(appleIdentity);
  const device = await asUser.mutation(api.productAccount.connect, {
    deviceIdentifier: 'origin-device',
    platform: 'ios',
  });
  const payload = await asUser.mutation(
    api.productSync.putEncryptedPayloadIfUnchanged,
    {
      encryptedPayload,
      expectedUpdatedAt: undefined,
      payloadIdentifier: 'scheduled-send.v1.schedule-001',
      trustedDeviceId: device.trustedDeviceId,
    },
  );
  return { asUser, device, payload, t };
}

async function claimFixture() {
  const base = await fixture();
  const secondDevice = await base.asUser.mutation(api.productAccount.connect, {
    deviceIdentifier: 'second-device',
    platform: 'macos',
  });
  const originAuthorization = await base.asUser.mutation(
    api.scheduledSend.registerDeliveryCapability,
    {
      capabilityVersion: 1,
      trustedDeviceId: base.device.trustedDeviceId,
    },
  );
  const secondAuthorization = await base.asUser.mutation(
    api.scheduledSend.registerDeliveryCapability,
    {
      capabilityVersion: 1,
      trustedDeviceId: secondDevice.trustedDeviceId,
    },
  );
  const dueAt = Date.now() + 2 * 60 * 1000;
  await base.asUser.mutation(api.scheduledSend.admit, {
    deadlineAt: dueAt + 24 * 60 * 60 * 1000,
    dueAt,
    encryptedPayloadIdentifier: base.payload.payloadIdentifier,
    encryptedPayloadUpdatedAt: base.payload.updatedAt,
    revision: 1,
    scheduleId: 'schedule-001',
    trustedDeviceId: base.device.trustedDeviceId,
  });
  const schedule = await base.t.run(async (ctx) => {
    const stored = await ctx.db
      .query('scheduledSends')
      .withIndex('by_productAccountId_and_scheduleId', (q) =>
        q
          .eq('productAccountId', base.device.productAccountId)
          .eq('scheduleId', 'schedule-001'),
      )
      .unique();
    const schedule = requireValue(stored);
    // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
    await ctx.db.patch(schedule._id, {
      deadlineAt: Date.now() + 24 * 60 * 60 * 1000,
      dueAt: Date.now() - 1,
    });
    return schedule;
  });
  return {
    ...base,
    originAuthorization,
    schedule,
    secondAuthorization,
    secondDevice,
  };
}

function claimArgs(
  authorization: string,
  trustedDeviceId: Id<'trustedDevices'>,
) {
  return {
    revision: 1,
    scheduleId: 'schedule-001',
    scheduledDeliveryAuthorization: authorization,
    trustedDeviceId,
  };
}

describe('scheduled Send admission', () => {
  it('admits only after the exact encrypted payload revision exists', async () => {
    expect.assertions(5);
    const { asUser, device, payload, t } = await fixture();
    const dueAt = Date.now() + 2 * 60 * 1000;

    const admission = await asUser.mutation(api.scheduledSend.admit, {
      deadlineAt: dueAt + 24 * 60 * 60 * 1000,
      dueAt,
      encryptedPayloadIdentifier: payload.payloadIdentifier,
      encryptedPayloadUpdatedAt: payload.updatedAt,
      revision: 1,
      scheduleId: 'schedule-001',
      trustedDeviceId: device.trustedDeviceId,
    });
    const stored = await t.run(async (ctx) =>
      ctx.db
        .query('scheduledSends')
        .withIndex('by_productAccountId_and_scheduleId', (q) =>
          q
            .eq('productAccountId', device.productAccountId)
            .eq('scheduleId', 'schedule-001'),
        )
        .unique(),
    );

    expect(admission).toMatchObject({
      encryptedPayloadUpdatedAt: payload.updatedAt,
      revision: 1,
      scheduleId: 'schedule-001',
    });
    expect(stored?.state).toBe('active');
    expect(stored?.trustedDeviceId).toBe(device.trustedDeviceId);
    expect(stored).not.toBeNull();
    expect(Object.keys(stored!).toSorted()).toStrictEqual([
      '_creationTime',
      '_id',
      'deadlineAt',
      'dueAt',
      'encryptedPayloadIdentifier',
      'encryptedPayloadUpdatedAt',
      'productAccountId',
      'revision',
      'scheduleId',
      'scheduledFunctionId',
      'state',
      'trustedDeviceId',
      'updatedAt',
    ]);
  });

  it('rejects a payload revision the backend did not acknowledge', async () => {
    expect.assertions(1);
    const { asUser, device, payload } = await fixture();
    const dueAt = Date.now() + 2 * 60 * 1000;

    await expect(
      asUser.mutation(api.scheduledSend.admit, {
        deadlineAt: dueAt + 24 * 60 * 60 * 1000,
        dueAt,
        encryptedPayloadIdentifier: payload.payloadIdentifier,
        encryptedPayloadUpdatedAt: payload.updatedAt + 1,
        revision: 1,
        scheduleId: 'schedule-001',
        trustedDeviceId: device.trustedDeviceId,
      }),
    ).rejects.toThrow('Exact encrypted Scheduled Send payload required');
  });

  it('is idempotent for one opaque identity and revision', async () => {
    expect.assertions(1);
    const { asUser, device, payload } = await fixture();
    const dueAt = Date.now() + 2 * 60 * 1000;
    const args = {
      deadlineAt: dueAt + 24 * 60 * 60 * 1000,
      dueAt,
      encryptedPayloadIdentifier: payload.payloadIdentifier,
      encryptedPayloadUpdatedAt: payload.updatedAt,
      revision: 1,
      scheduleId: 'schedule-001',
      trustedDeviceId: device.trustedDeviceId,
    };

    const first = await asUser.mutation(api.scheduledSend.admit, args);
    const repeated = await asUser.mutation(api.scheduledSend.admit, args);

    expect(repeated).toStrictEqual(first);
  });

  it('moves a delivery that missed the 24-hour start deadline to Needs Attention', async () => {
    expect.assertions(2);
    const { asUser, device, payload, t } = await fixture();
    const dueAt = Date.now() + 2 * 60 * 1000;
    await asUser.mutation(api.scheduledSend.admit, {
      deadlineAt: dueAt + 24 * 60 * 60 * 1000,
      dueAt,
      encryptedPayloadIdentifier: payload.payloadIdentifier,
      encryptedPayloadUpdatedAt: payload.updatedAt,
      revision: 1,
      scheduleId: 'schedule-001',
      trustedDeviceId: device.trustedDeviceId,
    });
    const schedule = await t.run(async (ctx) => {
      const stored = await ctx.db
        .query('scheduledSends')
        .withIndex('by_productAccountId_and_scheduleId', (q) =>
          q
            .eq('productAccountId', device.productAccountId)
            .eq('scheduleId', 'schedule-001'),
        )
        .unique();
      const schedule = requireValue(stored);
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(schedule._id, {
        deadlineAt: Date.now() - 1,
        dueAt: Date.now() - 2,
      });
      return schedule;
    });

    const recipient = await t.mutation(internal.scheduledSend.claimWakeup, {
      revision: 1,
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      scheduleDocumentId: schedule._id,
    });
    const status = await asUser.query(api.scheduledSend.status, {
      scheduleId: 'schedule-001',
      trustedDeviceId: device.trustedDeviceId,
    });

    expect(recipient).toStrictEqual([]);
    expect(status?.state).toBe('needs-attention');
  });
});

describe('scheduled Send cross-device claims', () => {
  it('allows exactly one compatible device to claim the current due revision', async () => {
    expect.assertions(4);
    const fixture = await claimFixture();

    const claims = await Promise.all([
      fixture.asUser.mutation(
        api.scheduledSend.claim,
        claimArgs(
          fixture.originAuthorization.authorization,
          fixture.device.trustedDeviceId,
        ),
      ),
      fixture.asUser.mutation(
        api.scheduledSend.claim,
        claimArgs(
          fixture.secondAuthorization.authorization,
          fixture.secondDevice.trustedDeviceId,
        ),
      ),
    ]);
    const winners = claims.filter((claim) => claim.status === 'claimed');
    const losers = claims.filter((claim) => claim.status === 'unavailable');

    expect(winners).toHaveLength(1);
    expect(losers).toHaveLength(1);
    expect(winners[0]).toMatchObject({ generation: 1, phase: 'pre-handoff' });
    expect(winners[0]).not.toHaveProperty('provider');
  });

  it('rejects early and stale-revision claims using backend time', async () => {
    expect.assertions(2);
    const fixture = await claimFixture();
    await fixture.t.run(async (ctx) => {
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(fixture.schedule._id, { dueAt: Date.now() + 60_000 });
    });

    await expect(
      fixture.asUser.mutation(
        api.scheduledSend.claim,
        claimArgs(
          fixture.originAuthorization.authorization,
          fixture.device.trustedDeviceId,
        ),
      ),
    ).resolves.toStrictEqual({ status: 'unavailable' });
    await expect(
      fixture.asUser.mutation(api.scheduledSend.claim, {
        ...claimArgs(
          fixture.originAuthorization.authorization,
          fixture.device.trustedDeviceId,
        ),
        revision: 2,
      }),
    ).resolves.toStrictEqual({ status: 'unavailable' });
  });

  it('expires or invalidates only pre-handoff ownership and permits failover', async () => {
    expect.assertions(4);
    const fixture = await claimFixture();
    const firstClaim = await fixture.asUser.mutation(
      api.scheduledSend.claim,
      claimArgs(
        fixture.originAuthorization.authorization,
        fixture.device.trustedDeviceId,
      ),
    );
    const rotated = await fixture.asUser.mutation(
      api.scheduledSend.registerDeliveryCapability,
      {
        capabilityVersion: 1,
        trustedDeviceId: fixture.device.trustedDeviceId,
      },
    );

    await expect(
      fixture.asUser.mutation(
        api.scheduledSend.claim,
        claimArgs(
          fixture.originAuthorization.authorization,
          fixture.device.trustedDeviceId,
        ),
      ),
    ).rejects.toThrow('Scheduled Delivery Authorization required');
    expect(rotated.generation).toBe(fixture.originAuthorization.generation + 1);
    const failover = await fixture.asUser.mutation(
      api.scheduledSend.claim,
      claimArgs(
        fixture.secondAuthorization.authorization,
        fixture.secondDevice.trustedDeviceId,
      ),
    );
    expect(firstClaim).toMatchObject({ generation: 1, status: 'claimed' });
    expect(failover).toMatchObject({ generation: 2, status: 'claimed' });
  });

  it('keeps provider handoff fenced across rotation, cancellation, and takeover', async () => {
    expect.assertions(5);
    const fixture = await claimFixture();
    const claim = await fixture.asUser.mutation(
      api.scheduledSend.claim,
      claimArgs(
        fixture.originAuthorization.authorization,
        fixture.device.trustedDeviceId,
      ),
    );
    const generation = claimedGeneration(claim);
    const advanced = await fixture.asUser.mutation(
      api.scheduledSend.advanceClaimToHandoff,
      {
        ...claimArgs(
          fixture.originAuthorization.authorization,
          fixture.device.trustedDeviceId,
        ),
        claimGeneration: generation,
      },
    );
    await fixture.asUser.mutation(
      api.scheduledSend.registerDeliveryCapability,
      {
        capabilityVersion: 1,
        trustedDeviceId: fixture.device.trustedDeviceId,
      },
    );

    expect(advanced).toBe(true);
    await expect(
      fixture.asUser.mutation(
        api.scheduledSend.claim,
        claimArgs(
          fixture.secondAuthorization.authorization,
          fixture.secondDevice.trustedDeviceId,
        ),
      ),
    ).resolves.toStrictEqual({ status: 'unavailable' });
    await expect(
      fixture.asUser.mutation(api.scheduledSend.cancel, {
        revision: 1,
        scheduleId: 'schedule-001',
        trustedDeviceId: fixture.secondDevice.trustedDeviceId,
      }),
    ).resolves.toBe(false); // oxlint-disable-line vitest/prefer-to-be-falsy -- The mutation contract returns a strict boolean.
    await expect(
      fixture.asUser.mutation(api.scheduledSend.releaseClaim, {
        ...claimArgs(
          fixture.secondAuthorization.authorization,
          fixture.secondDevice.trustedDeviceId,
        ),
        claimGeneration: generation,
      }),
    ).resolves.toBe(false); // oxlint-disable-line vitest/prefer-to-be-falsy -- The mutation contract returns a strict boolean.
    const status = await fixture.asUser.query(api.scheduledSend.status, {
      scheduleId: 'schedule-001',
      trustedDeviceId: fixture.secondDevice.trustedDeviceId,
    });
    expect(status?.claimPhase).toBe('handing-off');
  });

  it('lets revision-fenced cancellation win before provider handoff', async () => {
    expect.assertions(3);
    const fixture = await claimFixture();
    await fixture.asUser.mutation(
      api.scheduledSend.claim,
      claimArgs(
        fixture.originAuthorization.authorization,
        fixture.device.trustedDeviceId,
      ),
    );

    await expect(
      fixture.asUser.mutation(api.scheduledSend.cancel, {
        revision: 2,
        scheduleId: 'schedule-001',
        trustedDeviceId: fixture.secondDevice.trustedDeviceId,
      }),
    ).resolves.toBe(false); // oxlint-disable-line vitest/prefer-to-be-falsy -- The mutation contract returns a strict boolean.
    await expect(
      fixture.asUser.mutation(api.scheduledSend.cancel, {
        revision: 1,
        scheduleId: 'schedule-001',
        trustedDeviceId: fixture.secondDevice.trustedDeviceId,
      }),
    ).resolves.toBe(true);
    await expect(
      fixture.asUser.mutation(
        api.scheduledSend.claim,
        claimArgs(
          fixture.originAuthorization.authorization,
          fixture.device.trustedDeviceId,
        ),
      ),
    ).resolves.toStrictEqual({ status: 'unavailable' });
  });

  it('reschedules only from the current pre-handoff revision', async () => {
    expect.assertions(3);
    const fixture = await claimFixture();
    await fixture.asUser.mutation(
      api.scheduledSend.claim,
      claimArgs(
        fixture.originAuthorization.authorization,
        fixture.device.trustedDeviceId,
      ),
    );
    const replacementPayload = await fixture.asUser.mutation(
      api.productSync.putEncryptedPayloadIfUnchanged,
      {
        encryptedPayload: {
          ...encryptedPayload,
          ciphertextBase64: 'cmVzY2hlZHVsZWQ',
        },
        expectedUpdatedAt: fixture.payload.updatedAt,
        payloadIdentifier: fixture.payload.payloadIdentifier,
        trustedDeviceId: fixture.secondDevice.trustedDeviceId,
      },
    );
    const dueAt = Date.now() + 3 * 60 * 1000;

    await expect(
      fixture.asUser.mutation(api.scheduledSend.reschedule, {
        deadlineAt: dueAt + 24 * 60 * 60 * 1000,
        dueAt,
        encryptedPayloadIdentifier: replacementPayload.payloadIdentifier,
        encryptedPayloadUpdatedAt: replacementPayload.updatedAt,
        expectedRevision: 1,
        revision: 2,
        scheduleId: 'schedule-001',
        trustedDeviceId: fixture.secondDevice.trustedDeviceId,
      }),
    ).resolves.toMatchObject({ revision: 2, scheduleId: 'schedule-001' });
    await expect(
      fixture.asUser.mutation(
        api.scheduledSend.claim,
        claimArgs(
          fixture.originAuthorization.authorization,
          fixture.device.trustedDeviceId,
        ),
      ),
    ).resolves.toStrictEqual({ status: 'unavailable' });
    await expect(
      fixture.asUser.mutation(api.scheduledSend.reschedule, {
        deadlineAt: dueAt + 24 * 60 * 60 * 1000,
        dueAt,
        encryptedPayloadIdentifier: replacementPayload.payloadIdentifier,
        encryptedPayloadUpdatedAt: replacementPayload.updatedAt,
        expectedRevision: 1,
        revision: 2,
        scheduleId: 'schedule-001',
        trustedDeviceId: fixture.secondDevice.trustedDeviceId,
      }),
    ).rejects.toThrow('Scheduled Send revision is no longer editable');
  });

  it('releases a revoked device pre-handoff claim without weakening the fence', async () => {
    expect.assertions(2);
    const fixture = await claimFixture();
    await fixture.asUser.mutation(
      api.scheduledSend.claim,
      claimArgs(
        fixture.originAuthorization.authorization,
        fixture.device.trustedDeviceId,
      ),
    );
    await fixture.t.run(async (ctx) => {
      await ctx.db.insert('revokedTrustedDevices', {
        deviceIdentifier: 'origin-device',
        productAccountId: fixture.device.productAccountId,
        productSyncKeyEpoch: 1,
        revokedAt: Date.now(),
        trustedDeviceId: fixture.device.trustedDeviceId,
      });
      await ctx.db.delete(fixture.device.trustedDeviceId);
    });

    await expect(
      fixture.asUser.mutation(
        api.scheduledSend.claim,
        claimArgs(
          fixture.originAuthorization.authorization,
          fixture.device.trustedDeviceId,
        ),
      ),
    ).rejects.toThrow('Scheduled Delivery Authorization required');
    await expect(
      fixture.asUser.mutation(
        api.scheduledSend.claim,
        claimArgs(
          fixture.secondAuthorization.authorization,
          fixture.secondDevice.trustedDeviceId,
        ),
      ),
    ).resolves.toMatchObject({ generation: 2, status: 'claimed' });
  });

  it('removes the operational record only after fenced completion', async () => {
    expect.assertions(2);
    const fixture = await claimFixture();
    const claim = await fixture.asUser.mutation(
      api.scheduledSend.claim,
      claimArgs(
        fixture.originAuthorization.authorization,
        fixture.device.trustedDeviceId,
      ),
    );
    const generation = claimedGeneration(claim);
    await fixture.asUser.mutation(api.scheduledSend.advanceClaimToHandoff, {
      ...claimArgs(
        fixture.originAuthorization.authorization,
        fixture.device.trustedDeviceId,
      ),
      claimGeneration: generation,
    });

    await expect(
      fixture.asUser.mutation(api.scheduledSend.complete, {
        ...claimArgs(
          fixture.originAuthorization.authorization,
          fixture.device.trustedDeviceId,
        ),
        claimGeneration: generation,
        state: 'completed',
      }),
    ).resolves.toBe(true);
    await expect(
      fixture.asUser.query(api.scheduledSend.status, {
        scheduleId: 'schedule-001',
        trustedDeviceId: fixture.device.trustedDeviceId,
      }),
    ).resolves.toBeNull();
  });
});
