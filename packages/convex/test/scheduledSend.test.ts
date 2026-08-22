/// <reference types="vite/client" />

import { convexTest } from 'convex-test';

import { api, internal } from '../convex/_generated/api.js';
import schema from '../convex/schema.js';

const modules = import.meta.glob('../convex/**/*.ts');

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

function requireValue<Value>(value: Value | null): Value {
  if (value === null) {
    throw new Error('Scheduled Send fixture missing');
  }
  return value;
}

describe('scheduled Send admission', () => {
  it('admits only after the exact encrypted payload revision exists', async () => {
    expect.assertions(4);
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
    expect(stored).not.toHaveProperty('message');
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

    expect(recipient).toBeNull();
    expect(status?.state).toBe('needs-attention');
  });
});
