/// <reference types="vite/client" />

import { generateKeyPairSync } from 'node:crypto';

import { convexTest } from 'convex-test';

import { api, internal } from '../convex/_generated/api.js';
import {
  decodeGmailPushEnvelope,
  gmailWakeupPayload,
} from '../convex/gmailPushPayload.js';
import schema from '../convex/schema.js';

type ObservedApnsRequest = Readonly<{
  authority: string;
  headers: Record<string, unknown>;
  payload: string;
}>;

const apnsMock = vi.hoisted(() => ({
  closedRequests: 0,
  connections: [] as string[],
  requests: [] as ObservedApnsRequest[],
  responseBody: '',
  sessions: [] as Array<{
    listenerCount: (eventName: string | symbol) => number;
  }>,
  status: 200,
  statusByToken: {} as Record<string, number>,
  stallResponseBody: false,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- A partial HTTP/2 transport fake intentionally cannot satisfy the full Node module type.
vi.mock('node:http2', async () => {
  const { EventEmitter } = await import('node:events');

  return {
    connect: (authority: URL | string) => {
      apnsMock.connections.push(String(authority));
      // oxlint-disable-next-line unicorn/prefer-event-target -- the production client is an EventEmitter.
      const session = Object.assign(new EventEmitter(), {
        close() {
          return undefined;
        },
        request: (headers: Record<string, unknown>) => {
          // oxlint-disable-next-line unicorn/prefer-event-target -- node:events.once requires EventEmitter semantics.
          const request = Object.assign(new EventEmitter(), {
            end(payload: string) {
              apnsMock.requests.push({
                authority: String(authority),
                headers,
                payload,
              });
              queueMicrotask(() => {
                const token = String(headers[':path']).split('/').at(-1) ?? '';
                request.emit('response', {
                  ':status': apnsMock.statusByToken[token] ?? apnsMock.status,
                });
                setTimeout(() => {
                  if (apnsMock.stallResponseBody) {
                    return;
                  }
                  if (apnsMock.responseBody.length > 0) {
                    request.emit('data', apnsMock.responseBody);
                  }
                  request.emit('end');
                }, 0);
              });
            },
            close() {
              apnsMock.closedRequests += 1;
              return undefined;
            },
            setEncoding(_encoding: string) {
              return undefined;
            },
          });
          return request;
        },
      });
      apnsMock.sessions.push(session);
      return session;
    },
  };
});

const modules = import.meta.glob('../convex/**/*.ts');

const appleIdentity = {
  issuer: 'https://appleid.apple.com',
  subject: 'apple-user-001',
  tokenIdentifier: 'https://appleid.apple.com|apple-user-001',
};

describe('gmail push relay', () => {
  it('stops a mailbox watch only after its last active device route', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const firstDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const secondDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    for (const trustedDeviceId of [
      firstDevice.trustedDeviceId,
      secondDevice.trustedDeviceId,
    ]) {
      await asUser.mutation(api.productAccount.connectGmailProvider, {
        emailAddress: 'matching@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId,
      });
    }
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'second-apns-token',
      trustedDeviceId: secondDevice.trustedDeviceId,
    });
    await t.run(async (ctx) => {
      const connection = await ctx.db
        .query('mailProviderConnections')
        .withIndex('by_provider_and_emailAddress', (q) =>
          q.eq('provider', 'gmail').eq('emailAddress', 'matching@example.com'),
        )
        .filter((q) =>
          q.eq(q.field('trustedDeviceId'), secondDevice.trustedDeviceId),
        )
        .unique();
      expect(connection).not.toBeNull();
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(connection!._id, { pushVerifiedAt: Date.now() });
    });

    await expect(
      asUser.query(api.pushRelay.shouldStopGmailWatch, {
        trustedDeviceId: firstDevice.trustedDeviceId,
      }),
      // oxlint-disable-next-line vitest/prefer-to-be-falsy -- The strict boolean matcher is required by vitest/prefer-strict-boolean-matchers.
    ).resolves.toBe(false);
    await asUser.mutation(api.pushRelay.unregisterDevice, {
      trustedDeviceId: secondDevice.trustedDeviceId,
    });
    await expect(
      asUser.query(api.pushRelay.shouldStopGmailWatch, {
        trustedDeviceId: firstDevice.trustedDeviceId,
      }),
    ).resolves.toBe(true);
  });

  it('keeps a mailbox watch when another account has an active verified route', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connection = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await asUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'shared@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: connection.trustedDeviceId,
    });
    await t.run(async (ctx) => {
      const productAccountId = await ctx.db.insert('productAccounts', {
        createdAt: Date.now(),
        lastSeenAt: Date.now(),
        tokenIdentifier: 'other-account',
      });
      const trustedDeviceId = await ctx.db.insert('trustedDevices', {
        apnsEnvironment: 'production',
        apnsToken: 'other-token',
        deviceIdentifier: 'other-device',
        lastSeenAt: Date.now(),
        platform: 'ios',
        productAccountId,
        registeredAt: Date.now(),
      });
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: Date.now(),
        emailAddress: 'shared@example.com',
        lastVerifiedAt: Date.now(),
        productAccountId,
        provider: 'gmail',
        providerAccountIdentifier: 'other-gmail-user',
        pushVerifiedAt: Date.now(),
        trustedDeviceId,
        updatedAt: Date.now(),
      });
    });

    await expect(
      asUser.query(api.pushRelay.shouldStopGmailWatch, {
        trustedDeviceId: connection.trustedDeviceId,
      }),
      // oxlint-disable-next-line vitest/prefer-to-be-falsy -- The strict boolean matcher is required by vitest/prefer-strict-boolean-matchers.
    ).resolves.toBe(false);
  });

  it('stops a mailbox watch when the only other route is unverified', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const firstDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const secondDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    for (const trustedDeviceId of [
      firstDevice.trustedDeviceId,
      secondDevice.trustedDeviceId,
    ]) {
      await asUser.mutation(api.productAccount.connectGmailProvider, {
        emailAddress: 'matching@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId,
      });
    }
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'second-apns-token',
      trustedDeviceId: secondDevice.trustedDeviceId,
    });
    await expect(
      asUser.query(api.pushRelay.shouldStopGmailWatch, {
        trustedDeviceId: firstDevice.trustedDeviceId,
      }),
    ).resolves.toBe(true);
  });

  it('checks account routes before applying the connection cap', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      const otherProductAccountId = await ctx.db.insert('productAccounts', {
        createdAt: Date.now(),
        lastSeenAt: Date.now(),
        tokenIdentifier: 'other-account',
      });
      for (let index = 0; index < 100; index += 1) {
        const trustedDeviceId = await ctx.db.insert('trustedDevices', {
          deviceIdentifier: `other-device-${index}`,
          lastSeenAt: Date.now(),
          platform: 'ios',
          productAccountId: otherProductAccountId,
          registeredAt: Date.now(),
        });
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: Date.now(),
          emailAddress: 'shared@example.com',
          lastVerifiedAt: Date.now(),
          productAccountId: otherProductAccountId,
          provider: 'gmail',
          providerAccountIdentifier: `other-gmail-${index}`,
          trustedDeviceId,
          updatedAt: Date.now(),
        });
      }
    });
    const asUser = t.withIdentity(appleIdentity);
    const firstDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const secondDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    for (const trustedDeviceId of [
      firstDevice.trustedDeviceId,
      secondDevice.trustedDeviceId,
    ]) {
      await asUser.mutation(api.productAccount.connectGmailProvider, {
        emailAddress: 'shared@example.com',
        providerAccountIdentifier: 'gmail-user-001',
        trustedDeviceId,
      });
    }
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'second-apns-token',
      trustedDeviceId: secondDevice.trustedDeviceId,
    });

    await t.run(async (ctx) => {
      const connection = await ctx.db
        .query('mailProviderConnections')
        .withIndex('by_provider_and_emailAddress', (q) =>
          q.eq('provider', 'gmail').eq('emailAddress', 'shared@example.com'),
        )
        .filter((q) =>
          q.eq(q.field('trustedDeviceId'), secondDevice.trustedDeviceId),
        )
        .unique();
      expect(connection).not.toBeNull();
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(connection!._id, { pushVerifiedAt: Date.now() });
    });

    await expect(
      asUser.query(api.pushRelay.shouldStopGmailWatch, {
        trustedDeviceId: firstDevice.trustedDeviceId,
      }),
      // oxlint-disable-next-line vitest/prefer-to-be-falsy -- The strict boolean matcher is required by vitest/prefer-strict-boolean-matchers.
    ).resolves.toBe(false);
  });

  it('registers APNs routing data for an owned trusted device', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connection = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });

    const result = await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'sandbox',
      apnsToken: 'apns-device-token',
      trustedDeviceId: connection.trustedDeviceId,
    });

    expect(result).toStrictEqual({ registered: true });
    await expect(
      asUser.mutation(api.pushRelay.unregisterDevice, {
        trustedDeviceId: connection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ registered: false });
    const otherUser = t.withIdentity({
      ...appleIdentity,
      subject: 'apple-user-002',
      tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
    });
    await otherUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-002',
      platform: 'ios',
    });
    await expect(
      otherUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'sandbox',
        apnsToken: 'other-apns-device-token',
        trustedDeviceId: connection.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
  });

  it('clears a reused APNs token from the previous device route', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const firstUser = t.withIdentity(appleIdentity);
    const firstConnection = await firstUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    const secondUser = t.withIdentity({
      ...appleIdentity,
      subject: 'apple-user-002',
      tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
    });
    const secondConnection = await secondUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-002',
        platform: 'ios',
      },
    );

    await firstUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'sandbox',
      apnsToken: 'shared-apns-token',
      trustedDeviceId: firstConnection.trustedDeviceId,
    });
    await secondUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'shared-apns-token',
      trustedDeviceId: secondConnection.trustedDeviceId,
    });

    await expect(
      t.run((ctx) => ctx.db.get(firstConnection.trustedDeviceId)),
    ).resolves.toStrictEqual(
      expect.not.objectContaining({
        apnsEnvironment: expect.anything(),
        apnsToken: expect.anything(),
      }),
    );
    await expect(
      t.run((ctx) => ctx.db.get(secondConnection.trustedDeviceId)),
    ).resolves.toStrictEqual(
      expect.objectContaining({
        apnsEnvironment: 'production',
        apnsToken: 'shared-apns-token',
      }),
    );
  });

  it('reconciles stale APNs routes without clearing a refreshed route', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const staleDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-stale',
      platform: 'ios',
    });
    const legacyStaleDevice = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-legacy-stale',
        platform: 'ios',
      },
    );
    const refreshedDevice = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-refreshed',
      platform: 'ios',
    });
    await asUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-legacy-stale',
      trustedDeviceId: legacyStaleDevice.trustedDeviceId,
    });
    await asUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-stale',
      trustedDeviceId: staleDevice.trustedDeviceId,
    });
    await asUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-refreshed',
      trustedDeviceId: refreshedDevice.trustedDeviceId,
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'sandbox',
      apnsToken: 'stale-apns-token',
      trustedDeviceId: staleDevice.trustedDeviceId,
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'sandbox',
      apnsToken: 'legacy-stale-apns-token',
      trustedDeviceId: legacyStaleDevice.trustedDeviceId,
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'refreshed-apns-token',
      trustedDeviceId: refreshedDevice.trustedDeviceId,
    });

    const staleBefore = Date.now() - 1000;
    await t.run(async (ctx) => {
      const staleHeartbeat = await ctx.db
        .query('devicePushRouteHeartbeats')
        .withIndex('by_trustedDeviceId', (q) =>
          q.eq('trustedDeviceId', staleDevice.trustedDeviceId),
        )
        .unique();
      const legacyStaleHeartbeat = await ctx.db
        .query('devicePushRouteHeartbeats')
        .withIndex('by_trustedDeviceId', (q) =>
          q.eq('trustedDeviceId', legacyStaleDevice.trustedDeviceId),
        )
        .unique();
      const refreshedHeartbeat = await ctx.db
        .query('devicePushRouteHeartbeats')
        .withIndex('by_trustedDeviceId', (q) =>
          q.eq('trustedDeviceId', refreshedDevice.trustedDeviceId),
        )
        .unique();
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(staleHeartbeat!._id, { refreshedAt: staleBefore - 1 });
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.delete(legacyStaleHeartbeat!._id);
      await ctx.db.patch(legacyStaleDevice.trustedDeviceId, {
        lastSeenAt: staleBefore - 1,
      });
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      await ctx.db.patch(refreshedHeartbeat!._id, {
        refreshedAt: staleBefore + 1,
      });
      const connections = await ctx.db
        .query('mailProviderConnections')
        .withIndex('by_provider_and_emailAddress', (q) =>
          q.eq('provider', 'gmail').eq('emailAddress', 'matching@example.com'),
        )
        .take(3);
      await Promise.all(
        connections.map((connection) =>
          // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
          ctx.db.patch(connection._id, { pushVerifiedAt: staleBefore }),
        ),
      );
    });

    await expect(
      t.mutation(internal.pushRelay.reconcileStaleDevicePushRoutes, {
        staleBefore,
      }),
    ).resolves.toStrictEqual({ clearedRouteCount: 2 });
    await expect(
      t.query(internal.pushRelay.resolveGmailRecipients, {
        emailAddress: 'matching@example.com',
      }),
    ).resolves.toStrictEqual([
      {
        apnsEnvironment: 'production',
        apnsToken: 'refreshed-apns-token',
        routeId: expect.any(String),
        trustedDeviceId: refreshedDevice.trustedDeviceId,
      },
    ]);
  });

  it('requires fresh Gmail push proof after device unregistration', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const connection = await asUser.mutation(api.productAccount.connect, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await asUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: connection.trustedDeviceId,
    });
    await asUser.mutation(api.pushRelay.verifyGmailWatch, {
      historyId: '100',
      trustedDeviceId: connection.trustedDeviceId,
    });
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      emailAddress: 'matching@example.com',
      historyId: '100',
    });
    await t.run(async (ctx) => {
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: Date.now(),
        emailAddress: 'matching@example.com',
        lastVerifiedAt: Date.now(),
        productAccountId: connection.productAccountId,
        provider: 'gmail',
        providerAccountIdentifier: 'duplicate-gmail-user-001',
        pushVerificationHistoryId: '100',
        pushVerificationRequestedAt: Date.now(),
        pushVerifiedHistoryId: '100',
        pushVerifiedAt: Date.now(),
        trustedDeviceId: connection.trustedDeviceId,
        updatedAt: Date.now(),
      });
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'first-apns-token',
      trustedDeviceId: connection.trustedDeviceId,
    });

    await expect(
      asUser.mutation(api.pushRelay.unregisterDevice, {
        trustedDeviceId: connection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ registered: false });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'second-apns-token',
      trustedDeviceId: connection.trustedDeviceId,
    });
    await expect(
      t.query(internal.pushRelay.resolveGmailRecipients, {
        emailAddress: 'matching@example.com',
      }),
    ).resolves.toStrictEqual([]);
  });

  it('clears every Gmail push proof in bounded continuations', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const device = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      const verifiedAt = Date.now();
      await t.run(async (ctx) => {
        for (let index = 0; index < 11; index += 1) {
          await ctx.db.insert('mailProviderConnections', {
            connectedAt: verifiedAt,
            emailAddress: `matching-${index}@example.com`,
            lastVerifiedAt: verifiedAt,
            productAccountId: device.productAccountId,
            provider: 'gmail',
            providerAccountIdentifier: `gmail-user-${index}`,
            pushVerifiedHistoryId: '100',
            pushVerifiedAt: verifiedAt,
            trustedDeviceId: device.trustedDeviceId,
            updatedAt: verifiedAt,
          });
        }
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'first-apns-token',
        trustedDeviceId: device.trustedDeviceId,
      });

      await asUser.mutation(api.pushRelay.unregisterDevice, {
        trustedDeviceId: device.trustedDeviceId,
      });
      await t.finishAllScheduledFunctions(vi.runAllTimers);

      const proofsWereCleared = await t.run(async (ctx) => {
        const connections = await ctx.db
          .query('mailProviderConnections')
          .withIndex(
            'by_productAccountId_and_provider_and_trustedDeviceId',
            (q) =>
              q
                .eq('productAccountId', device.productAccountId)
                .eq('provider', 'gmail')
                .eq('trustedDeviceId', device.trustedDeviceId),
          )
          .take(11);
        return connections.map((connection) => ({
          pushVerifiedAt: connection.pushVerifiedAt,
          pushVerifiedHistoryId: connection.pushVerifiedHistoryId,
        }));
      });
      expect(proofsWereCleared).toStrictEqual(
        Array.from({ length: 11 }, () => ({})),
      );
    } finally {
      vi.useRealTimers();
    }
  });

  it('preserves refreshed proofs while clearing stale paginated proofs', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const device = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      });
      const originalVerifiedAt = Date.now();
      await t.run(async (ctx) => {
        for (let index = 0; index < 11; index += 1) {
          await ctx.db.insert('mailProviderConnections', {
            connectedAt: originalVerifiedAt,
            emailAddress: `matching-${index}@example.com`,
            lastVerifiedAt: originalVerifiedAt,
            productAccountId: device.productAccountId,
            provider: 'gmail',
            providerAccountIdentifier: `gmail-user-${index}`,
            pushVerifiedHistoryId: '100',
            pushVerifiedAt: originalVerifiedAt,
            trustedDeviceId: device.trustedDeviceId,
            updatedAt: originalVerifiedAt,
          });
        }
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'first-apns-token',
        trustedDeviceId: device.trustedDeviceId,
      });
      await asUser.mutation(api.pushRelay.unregisterDevice, {
        trustedDeviceId: device.trustedDeviceId,
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'second-apns-token',
        trustedDeviceId: device.trustedDeviceId,
      });
      const refreshedVerifiedAt = originalVerifiedAt + 1;
      await t.run(async (ctx) => {
        const connections = await ctx.db
          .query('mailProviderConnections')
          .withIndex(
            'by_productAccountId_and_provider_and_trustedDeviceId',
            (q) =>
              q
                .eq('productAccountId', device.productAccountId)
                .eq('provider', 'gmail')
                .eq('trustedDeviceId', device.trustedDeviceId),
          )
          .take(11);
        await Promise.all(
          connections.slice(-1).map((connection) =>
            // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
            ctx.db.patch(connection._id, {
              pushVerifiedHistoryId: '101',
              pushVerifiedAt: refreshedVerifiedAt,
            }),
          ),
        );
      });

      await t.finishAllScheduledFunctions(vi.runAllTimers);

      const freshProofWasPreserved = await t.run(async (ctx) => {
        const connections = await ctx.db
          .query('mailProviderConnections')
          .withIndex(
            'by_productAccountId_and_provider_and_trustedDeviceId',
            (q) =>
              q
                .eq('productAccountId', device.productAccountId)
                .eq('provider', 'gmail')
                .eq('trustedDeviceId', device.trustedDeviceId),
          )
          .take(11);
        return connections.map(
          (connection) => connection.pushVerifiedAt === refreshedVerifiedAt,
        );
      });
      expect(freshProofWasPreserved).toStrictEqual([
        ...Array.from({ length: 10 }, () => false),
        true,
      ]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('clears every reused APNs token route in bounded continuations', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const currentDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'current-device',
        platform: 'ios',
      });
      await t.run(async (ctx) => {
        for (let index = 0; index < 101; index += 1) {
          await ctx.db.insert('trustedDevices', {
            apnsEnvironment: 'sandbox',
            apnsToken: 'shared-apns-token',
            deviceIdentifier: `old-device-${index}`,
            lastSeenAt: Date.now(),
            platform: 'ios',
            productAccountId: currentDevice.productAccountId,
            registeredAt: Date.now(),
          });
        }
      });

      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'shared-apns-token',
        trustedDeviceId: currentDevice.trustedDeviceId,
      });
      await t.finishAllScheduledFunctions(vi.runAllTimers);

      const routes = await t.run((ctx) =>
        ctx.db
          .query('trustedDevices')
          .withIndex('by_apnsToken', (q) =>
            q.eq('apnsToken', 'shared-apns-token'),
          )
          .take(102),
      );
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      expect(routes.map((route) => route._id)).toStrictEqual([
        currentDevice.trustedDeviceId,
      ]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('stops reused-token cleanup when another device takes ownership', async () => {
    expect.assertions(1);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const firstDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'first-device',
        platform: 'ios',
      });
      const secondDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'second-device',
        platform: 'ios',
      });
      await t.run(async (ctx) => {
        for (let index = 0; index < 10; index += 1) {
          await ctx.db.insert('trustedDevices', {
            apnsEnvironment: 'sandbox',
            apnsToken: 'shared-apns-token',
            deviceIdentifier: `old-device-${index}`,
            lastSeenAt: Date.now(),
            platform: 'ios',
            productAccountId: firstDevice.productAccountId,
            registeredAt: Date.now(),
          });
        }
      });

      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'shared-apns-token',
        trustedDeviceId: firstDevice.trustedDeviceId,
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'shared-apns-token',
        trustedDeviceId: secondDevice.trustedDeviceId,
      });
      await t.finishAllScheduledFunctions(vi.runAllTimers);

      const routes = await t.run((ctx) =>
        ctx.db
          .query('trustedDevices')
          .withIndex('by_apnsToken', (q) =>
            q.eq('apnsToken', 'shared-apns-token'),
          )
          .take(12),
      );
      // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
      expect(routes.map((route) => route._id)).toStrictEqual([
        secondDevice.trustedDeviceId,
      ]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('continues route reconciliation and backfills a fresh legacy route', async () => {
    expect.assertions(2);
    vi.useFakeTimers();
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const connectRoute = async (index: number) => {
        const device = await asUser.mutation(api.productAccount.connect, {
          deviceIdentifier: `device-${index}`,
          platform: 'ios',
        });
        await asUser.mutation(api.pushRelay.registerDevice, {
          apnsEnvironment: 'sandbox',
          apnsToken: `route-token-${String(index).padStart(2, '0')}`,
          trustedDeviceId: device.trustedDeviceId,
        });
        return device;
      };
      for (let index = 0; index < 9; index += 1) {
        await connectRoute(index);
      }
      const freshLegacyDevice = await connectRoute(9);
      const staleSecondPageDevice = await connectRoute(10);
      const staleBefore = Date.now() - 1000;
      const freshLegacyLastSeenAt = await t.run(async (ctx) => {
        const freshLegacyHeartbeat = await ctx.db
          .query('devicePushRouteHeartbeats')
          .withIndex('by_trustedDeviceId', (q) =>
            q.eq('trustedDeviceId', freshLegacyDevice.trustedDeviceId),
          )
          .unique();
        const staleHeartbeat = await ctx.db
          .query('devicePushRouteHeartbeats')
          .withIndex('by_trustedDeviceId', (q) =>
            q.eq('trustedDeviceId', staleSecondPageDevice.trustedDeviceId),
          )
          .unique();
        const freshLegacyRoute = await ctx.db.get(
          freshLegacyDevice.trustedDeviceId,
        );
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        await ctx.db.delete(freshLegacyHeartbeat!._id);
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        await ctx.db.patch(staleHeartbeat!._id, {
          refreshedAt: staleBefore - 1,
        });
        return freshLegacyRoute!.lastSeenAt;
      });

      await t.mutation(internal.pushRelay.reconcileStaleDevicePushRoutes, {
        staleBefore,
      });
      await t.finishAllScheduledFunctions(vi.runAllTimers);

      const state = await t.run(async (ctx) => ({
        freshLegacyHeartbeat: await ctx.db
          .query('devicePushRouteHeartbeats')
          .withIndex('by_trustedDeviceId', (q) =>
            q.eq('trustedDeviceId', freshLegacyDevice.trustedDeviceId),
          )
          .unique(),
        staleRoute: await ctx.db.get(staleSecondPageDevice.trustedDeviceId),
      }));
      expect(state.freshLegacyHeartbeat).toStrictEqual(
        expect.objectContaining({ refreshedAt: freshLegacyLastSeenAt }),
      );
      expect(state.staleRoute).not.toHaveProperty('apnsToken');
    } finally {
      vi.useRealTimers();
    }
  });

  it('associates minimal Gmail metadata only with matching connected devices', async () => {
    expect.assertions(5);

    const t = convexTest(schema, modules);
    const firstUser = t.withIdentity(appleIdentity);
    const secondUser = t.withIdentity({
      ...appleIdentity,
      subject: 'apple-user-002',
      tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
    });
    const firstConnection = await firstUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    const secondConnection = await secondUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-002',
        platform: 'macos',
      },
    );

    await firstUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: firstConnection.trustedDeviceId,
    });
    await secondUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'other@example.com',
      providerAccountIdentifier: 'gmail-user-002',
      trustedDeviceId: secondConnection.trustedDeviceId,
    });
    await secondUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'other-apns-token',
      trustedDeviceId: secondConnection.trustedDeviceId,
    });

    const recipients = await t.query(
      internal.pushRelay.resolveGmailRecipients,
      {
        emailAddress: 'matching@example.com',
      },
    );

    expect(recipients).toStrictEqual([]);
    await expect(
      firstUser.mutation(api.pushRelay.verifyGmailWatch, {
        historyId: 'history-123',
        trustedDeviceId: firstConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: false }));
    await expect(
      t.mutation(internal.pushRelay.enqueueGmailWakeups, {
        emailAddress: 'matching@example.com',
        historyId: 'history-123',
      }),
    ).resolves.toStrictEqual({ recipientCount: 0 });
    await firstUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'matching-apns-token',
      trustedDeviceId: firstConnection.trustedDeviceId,
    });

    const verifiedRecipients = await t.query(
      internal.pushRelay.resolveGmailRecipients,
      {
        emailAddress: 'matching@example.com',
      },
    );

    expect(verifiedRecipients).toStrictEqual([
      {
        apnsEnvironment: 'production',
        apnsToken: 'matching-apns-token',
        routeId: expect.any(String),
        trustedDeviceId: firstConnection.trustedDeviceId,
      },
    ]);
    expect(JSON.stringify(verifiedRecipients)).not.toMatch(
      /accessToken|refreshToken|messageBody|category|classification/iu,
    );
  });

  it('keeps multiple Gmail verification signals until the matching device verifies', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const productConnection = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    await asUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: productConnection.trustedDeviceId,
    });
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      emailAddress: 'matching@example.com',
      historyId: 'history-first',
    });
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      emailAddress: 'matching@example.com',
      historyId: 'history-second',
    });

    await expect(
      asUser.mutation(api.pushRelay.verifyGmailWatch, {
        historyId: 'history-first',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
    await expect(
      asUser.mutation(api.pushRelay.verifyGmailWatch, {
        historyId: 'history-first',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
  });

  it('keeps a Gmail verification signal available for another device', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const firstUser = t.withIdentity(appleIdentity);
    const secondUser = t.withIdentity({
      ...appleIdentity,
      subject: 'apple-user-002',
      tokenIdentifier: 'https://appleid.apple.com|apple-user-002',
    });
    const firstConnection = await firstUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    const secondConnection = await secondUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-002',
        platform: 'ios',
      },
    );
    await firstUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: firstConnection.trustedDeviceId,
    });
    await secondUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: secondConnection.trustedDeviceId,
    });
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      emailAddress: 'matching@example.com',
      historyId: 'history-shared',
    });

    await expect(
      firstUser.mutation(api.pushRelay.verifyGmailWatch, {
        historyId: 'history-shared',
        trustedDeviceId: firstConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
    await expect(
      secondUser.mutation(api.pushRelay.verifyGmailWatch, {
        historyId: 'history-shared',
        trustedDeviceId: secondConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
  });

  it('searches the newest Gmail verification signals first', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const productConnection = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    await asUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'busy@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: productConnection.trustedDeviceId,
    });
    await t.run(async (ctx) => {
      for (let index = 0; index < 100; index += 1) {
        await ctx.db.insert('gmailPushVerificationSignals', {
          emailAddress: 'busy@example.com',
          historyId: String(index),
          receivedAt: Date.now(),
        });
      }
    });
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      emailAddress: 'busy@example.com',
      historyId: '200',
    });

    await expect(
      asUser.mutation(api.pushRelay.verifyGmailWatch, {
        historyId: '150',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
  });

  it('expires verification signals without another Gmail push', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const signalId = await t.run((ctx) =>
      ctx.db.insert('gmailPushVerificationSignals', {
        emailAddress: 'quiet@example.com',
        historyId: '100',
        receivedAt: 100,
      }),
    );
    await t.run((ctx) => ctx.db.patch(signalId, { receivedAt: 200 }));

    await t.mutation(internal.pushRelay.expireGmailVerificationSignal, {
      receivedAt: 100,
      signalId,
    });
    await expect(t.run((ctx) => ctx.db.get(signalId))).resolves.not.toBeNull();

    await t.mutation(internal.pushRelay.expireGmailVerificationSignal, {
      receivedAt: 200,
      signalId,
    });
    await expect(t.run((ctx) => ctx.db.get(signalId))).resolves.toBeNull();
  });

  it('applies the Gmail recipient cap after filtering inactive routes', async () => {
    expect.assertions(1);

    const t = convexTest(schema, modules);
    const verifiedDeviceId = await t.run(async (ctx) => {
      const productAccountId = await ctx.db.insert('productAccounts', {
        createdAt: Date.now(),
        lastSeenAt: Date.now(),
        tokenIdentifier: 'verified-account',
      });
      for (let index = 0; index < 100; index += 1) {
        const trustedDeviceId = await ctx.db.insert('trustedDevices', {
          deviceIdentifier: `inactive-device-${index}`,
          lastSeenAt: Date.now(),
          platform: 'ios',
          productAccountId,
          registeredAt: Date.now(),
        });
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: Date.now(),
          emailAddress: 'crowded@example.com',
          lastVerifiedAt: Date.now(),
          productAccountId,
          provider: 'gmail',
          providerAccountIdentifier: `inactive-${index}`,
          pushVerifiedAt: Date.now(),
          trustedDeviceId,
          updatedAt: Date.now(),
        });
      }
      const trustedDeviceId = await ctx.db.insert('trustedDevices', {
        apnsEnvironment: 'production',
        apnsToken: 'verified-token',
        deviceIdentifier: 'verified-device',
        lastSeenAt: Date.now(),
        platform: 'ios',
        productAccountId,
        registeredAt: Date.now(),
      });
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: Date.now(),
        emailAddress: 'crowded@example.com',
        lastVerifiedAt: Date.now(),
        productAccountId,
        provider: 'gmail',
        providerAccountIdentifier: 'verified',
        pushVerifiedAt: Date.now(),
        trustedDeviceId,
        updatedAt: Date.now(),
      });
      return trustedDeviceId;
    });

    await expect(
      t.query(internal.pushRelay.resolveGmailRecipients, {
        emailAddress: 'crowded@example.com',
      }),
    ).resolves.toStrictEqual([
      {
        apnsEnvironment: 'production',
        apnsToken: 'verified-token',
        routeId: expect.any(String),
        trustedDeviceId: verifiedDeviceId,
      },
    ]);
  });

  it('filters pending Gmail watch proofs before applying the cap', async () => {
    expect.assertions(1);

    const now = Date.now();
    const t = convexTest(schema, modules);
    const pendingDeviceId = await t.run(async (ctx) => {
      const productAccountId = await ctx.db.insert('productAccounts', {
        createdAt: now,
        lastSeenAt: now,
        tokenIdentifier: 'pending-account',
      });
      for (let index = 0; index < 100; index += 1) {
        const trustedDeviceId = await ctx.db.insert('trustedDevices', {
          deviceIdentifier: `non-pending-device-${index}`,
          lastSeenAt: now,
          platform: 'ios',
          productAccountId,
          registeredAt: now,
        });
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: now,
          emailAddress: 'crowded-pending@example.com',
          lastVerifiedAt: now,
          productAccountId,
          provider: 'gmail',
          providerAccountIdentifier: `non-pending-${index}`,
          trustedDeviceId,
          updatedAt: now,
        });
      }
      const trustedDeviceId = await ctx.db.insert('trustedDevices', {
        deviceIdentifier: 'pending-device',
        lastSeenAt: now,
        platform: 'ios',
        productAccountId,
        registeredAt: now,
      });
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        emailAddress: 'crowded-pending@example.com',
        lastVerifiedAt: now,
        productAccountId,
        provider: 'gmail',
        providerAccountIdentifier: 'pending',
        pushVerificationHistoryId: '100',
        pushVerificationRequestedAt: now,
        trustedDeviceId,
        updatedAt: now,
      });
      return trustedDeviceId;
    });

    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      emailAddress: 'crowded-pending@example.com',
      historyId: '101',
    });
    await t.run(async (ctx) => {
      await ctx.db.patch(pendingDeviceId, {
        apnsEnvironment: 'production',
        apnsToken: 'pending-token',
      });
    });
    await expect(
      t.query(internal.pushRelay.resolveGmailRecipients, {
        emailAddress: 'crowded-pending@example.com',
      }),
    ).resolves.toStrictEqual([
      {
        apnsEnvironment: 'production',
        apnsToken: 'pending-token',
        routeId: expect.any(String),
        trustedDeviceId: pendingDeviceId,
      },
    ]);
  });

  it('checks the newest pending Gmail watch proofs before applying the cap', async () => {
    expect.assertions(1);

    const now = Date.now();
    const t = convexTest(schema, modules);
    const pendingDeviceId = await t.run(async (ctx) => {
      const productAccountId = await ctx.db.insert('productAccounts', {
        createdAt: now,
        lastSeenAt: now,
        tokenIdentifier: 'newest-pending-account',
      });
      for (let index = 0; index < 100; index += 1) {
        const trustedDeviceId = await ctx.db.insert('trustedDevices', {
          deviceIdentifier: `older-pending-device-${index}`,
          lastSeenAt: now,
          platform: 'ios',
          productAccountId,
          registeredAt: now,
        });
        await ctx.db.insert('mailProviderConnections', {
          connectedAt: now,
          emailAddress: 'many-pending@example.com',
          lastVerifiedAt: now,
          productAccountId,
          provider: 'gmail',
          providerAccountIdentifier: `older-pending-${index}`,
          pushVerificationHistoryId: `${300 + index}`,
          pushVerificationRequestedAt: now - 100 + index,
          trustedDeviceId,
          updatedAt: now,
        });
      }
      const trustedDeviceId = await ctx.db.insert('trustedDevices', {
        deviceIdentifier: 'newest-pending-device',
        lastSeenAt: now,
        platform: 'ios',
        productAccountId,
        registeredAt: now,
      });
      await ctx.db.insert('mailProviderConnections', {
        connectedAt: now,
        emailAddress: 'many-pending@example.com',
        lastVerifiedAt: now,
        productAccountId,
        provider: 'gmail',
        providerAccountIdentifier: 'newest-pending',
        pushVerificationHistoryId: '200',
        pushVerificationRequestedAt: now,
        trustedDeviceId,
        updatedAt: now,
      });
      return trustedDeviceId;
    });

    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      emailAddress: 'many-pending@example.com',
      historyId: '200',
    });
    await t.run(async (ctx) => {
      await ctx.db.patch(pendingDeviceId, {
        apnsEnvironment: 'production',
        apnsToken: 'newest-pending-token',
      });
    });

    await expect(
      t.query(internal.pushRelay.resolveGmailRecipients, {
        emailAddress: 'many-pending@example.com',
      }),
    ).resolves.toStrictEqual([
      {
        apnsEnvironment: 'production',
        apnsToken: 'newest-pending-token',
        routeId: expect.any(String),
        trustedDeviceId: pendingDeviceId,
      },
    ]);
  });

  it('verifies a Gmail watch from a later notification history id', async () => {
    expect.assertions(2);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const productConnection = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    await asUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: productConnection.trustedDeviceId,
    });

    await expect(
      asUser.mutation(api.pushRelay.verifyGmailWatch, {
        historyId: '100',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: false }));
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      emailAddress: 'matching@example.com',
      historyId: '101',
    });
    await expect(
      asUser.mutation(api.pushRelay.verifyGmailWatch, {
        historyId: '100',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
  });

  it('does not regress the verified Gmail history watermark', async () => {
    expect.assertions(3);

    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const productConnection = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    await asUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'matching@example.com',
      providerAccountIdentifier: 'gmail-user-001',
      trustedDeviceId: productConnection.trustedDeviceId,
    });
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      emailAddress: 'matching@example.com',
      historyId: '200',
    });
    await expect(
      asUser.mutation(api.pushRelay.verifyGmailWatch, {
        historyId: '150',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      emailAddress: 'matching@example.com',
      historyId: '120',
    });
    await expect(
      asUser.mutation(api.pushRelay.verifyGmailWatch, {
        historyId: '100',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
    await expect(
      asUser.mutation(api.pushRelay.verifyGmailWatch, {
        historyId: '150',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual(expect.objectContaining({ verified: true }));
  });

  it('does not route client-asserted Gmail addresses without matching push proof', async () => {
    expect.assertions(2);

    const nowSpy = vi.spyOn(Date, 'now').mockReturnValue(1_784_000_000_000);
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(appleIdentity);
    const productConnection = await asUser.mutation(
      api.productAccount.connect,
      {
        deviceIdentifier: 'device-001',
        platform: 'ios',
      },
    );
    await asUser.mutation(api.productAccount.connectGmailProvider, {
      emailAddress: 'victim@example.com',
      providerAccountIdentifier: 'client-asserted-id',
      trustedDeviceId: productConnection.trustedDeviceId,
    });
    await asUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'attacker-device-token',
      trustedDeviceId: productConnection.trustedDeviceId,
    });
    await asUser.mutation(api.pushRelay.verifyGmailWatch, {
      historyId: 'victim-history-id',
      trustedDeviceId: productConnection.trustedDeviceId,
    });
    nowSpy.mockReturnValue(1_784_000_600_001);

    await expect(
      t.mutation(internal.pushRelay.enqueueGmailWakeups, {
        emailAddress: 'victim@example.com',
        historyId: 'victim-history-id',
      }),
    ).resolves.toStrictEqual({ recipientCount: 0 });
    await expect(
      t.query(internal.pushRelay.resolveGmailRecipients, {
        emailAddress: 'victim@example.com',
      }),
    ).resolves.toStrictEqual([]);
    nowSpy.mockRestore();
  });

  it('creates a content-free background wakeup payload', () => {
    expect.assertions(2);

    const payload = gmailWakeupPayload('history-123', 'route-001');

    expect(payload).toStrictEqual({
      aps: { 'content-available': 1 },
      historyId: 'history-123',
      provider: 'gmail',
      routeId: 'route-001',
    });
    expect(JSON.stringify(payload)).not.toMatch(
      /email|subject|snippet|body|category|classification|accessToken|refreshToken/iu,
    );
  });

  it('decodes only Gmail Minimal Push Metadata from Pub/Sub', () => {
    expect.assertions(1);

    const encodedData = btoa(
      JSON.stringify({
        emailAddress: 'matching@example.com',
        historyId: 'history-123',
        ignoredProviderField: 'not-routed',
      }),
    )
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replaceAll('=', '');

    expect(
      decodeGmailPushEnvelope({
        message: {
          data: encodedData,
          messageId: 'pubsub-message-001',
          publishTime: '2026-07-14T09:00:00Z',
        },
        subscription: 'projects/example/subscriptions/gmail-push',
      }),
    ).toStrictEqual({
      emailAddress: 'matching@example.com',
      historyId: 'history-123',
    });
  });

  it('preserves UTF-8 Gmail addresses from Pub/Sub', () => {
    expect.assertions(1);

    const metadata = JSON.stringify({
      emailAddress: 'josé@example.com',
      historyId: 'history-utf8',
    });
    const encodedData = Buffer.from(metadata, 'utf8').toString('base64url');

    expect(
      decodeGmailPushEnvelope({ message: { data: encodedData } }),
    ).toStrictEqual({
      emailAddress: 'josé@example.com',
      historyId: 'history-utf8',
    });
  });

  it('authenticates and validates the Gmail Pub/Sub HTTP ingress', async () => {
    expect.assertions(4);

    vi.stubEnv('GMAIL_PUSH_VERIFICATION_TOKEN', 'push-secret');
    try {
      const t = convexTest(schema, modules);
      const metadata = btoa(
        JSON.stringify({
          emailAddress: 'matching@example.com',
          historyId: 'history-123',
        }),
      );

      const missingToken = await t.fetch('/gmail/push', { method: 'POST' });
      expect(missingToken.status).toBe(401);

      const wrongToken = await t.fetch('/gmail/push?token=wrong', {
        method: 'POST',
      });
      expect(wrongToken.status).toBe(401);

      const malformed = await t.fetch('/gmail/push?token=push-secret', {
        body: JSON.stringify({ message: { data: 'not-base64-json' } }),
        method: 'POST',
      });
      expect(malformed.status).toBe(400);

      const accepted = await t.fetch('/gmail/push?token=push-secret', {
        body: JSON.stringify({ message: { data: metadata } }),
        method: 'POST',
      });
      expect(accepted.status).toBe(204);
    } finally {
      vi.unstubAllEnvs();
    }
  });

  it('sends content-free background requests to the selected APNs environment', async () => {
    expect.assertions(5);

    apnsMock.closedRequests = 0;
    apnsMock.connections.length = 0;
    apnsMock.requests.length = 0;
    apnsMock.responseBody = '';
    apnsMock.sessions.length = 0;
    apnsMock.status = 200;
    apnsMock.statusByToken = {};
    apnsMock.stallResponseBody = false;
    vi.stubEnv('APNS_KEY_ID', 'key-id');
    vi.stubEnv('APNS_TEAM_ID', 'team-id');
    const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
    vi.stubEnv(
      'APNS_PRIVATE_KEY',
      privateKey.export({ format: 'pem', type: 'pkcs8' }),
    );
    vi.stubEnv('APNS_TOPIC', 'dev.unwired.mail');
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const goodDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'good-device',
        platform: 'ios',
      });
      const badDevice = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'bad-device',
        platform: 'ios',
      });
      await asUser.mutation(api.productAccount.connectGmailProvider, {
        emailAddress: 'bad-device@example.com',
        providerAccountIdentifier: 'bad-device-gmail',
        trustedDeviceId: badDevice.trustedDeviceId,
      });
      await asUser.mutation(api.pushRelay.verifyGmailWatch, {
        historyId: '100',
        trustedDeviceId: badDevice.trustedDeviceId,
      });
      await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
        emailAddress: 'bad-device@example.com',
        historyId: '100',
      });
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'bad-device-token',
        trustedDeviceId: badDevice.trustedDeviceId,
      });
      await t.action(internal.apns.deliverGmailWakeups, {
        historyId: 'history-123',
        recipients: [
          {
            apnsEnvironment: 'sandbox',
            apnsToken: 'device-token',
            routeId: 'good-route',
            trustedDeviceId: goodDevice.trustedDeviceId,
          },
        ],
      });

      expect(apnsMock.requests).toHaveLength(1);
      const request = apnsMock.requests[0]!;
      expect({
        authority: request.authority,
        path: request.headers[':path'],
        priority: request.headers['apns-priority'],
        pushType: request.headers['apns-push-type'],
        topic: request.headers['apns-topic'],
      }).toStrictEqual({
        authority: 'https://api.sandbox.push.apple.com',
        path: '/3/device/device-token',
        priority: '5',
        pushType: 'background',
        topic: 'dev.unwired.mail',
      });
      expect(JSON.parse(request.payload)).toStrictEqual({
        aps: { 'content-available': 1 },
        historyId: 'history-123',
        provider: 'gmail',
        routeId: 'good-route',
      });

      apnsMock.responseBody = '{"reason":"BadDeviceToken"}';
      apnsMock.statusByToken = { 'bad-device-token': 410 };
      await expect(
        t.action(internal.apns.deliverGmailWakeups, {
          historyId: 'history-124',
          recipients: [
            {
              apnsEnvironment: 'production',
              apnsToken: 'bad-device-token',
              routeId: 'bad-route',
              trustedDeviceId: badDevice.trustedDeviceId,
            },
            {
              apnsEnvironment: 'production',
              apnsToken: 'good-device-token',
              routeId: 'good-route',
              trustedDeviceId: goodDevice.trustedDeviceId,
            },
          ],
        }),
      ).resolves.toBeNull();
      const prunedDevice = await t.run(async (ctx) =>
        ctx.db.get(badDevice.trustedDeviceId),
      );
      await asUser.mutation(api.pushRelay.registerDevice, {
        apnsEnvironment: 'production',
        apnsToken: 'replacement-device-token',
        trustedDeviceId: badDevice.trustedDeviceId,
      });
      const remainingRecipients = await t.query(
        internal.pushRelay.resolveGmailRecipients,
        { emailAddress: 'bad-device@example.com' },
      );
      expect({
        badAuthority: apnsMock.requests[1]?.authority,
        connections: apnsMock.connections,
        goodPath: apnsMock.requests[2]?.headers[':path'],
        prunedToken: prunedDevice?.apnsToken,
        remainingRecipients,
        sessionErrorListeners: apnsMock.sessions.map((session) =>
          session.listenerCount('error'),
        ),
      }).toStrictEqual({
        badAuthority: 'https://api.push.apple.com',
        connections: [
          'https://api.sandbox.push.apple.com',
          'https://api.push.apple.com',
        ],
        goodPath: '/3/device/good-device-token',
        prunedToken: undefined,
        remainingRecipients: [],
        sessionErrorListeners: [1, 1],
      });
    } finally {
      vi.unstubAllEnvs();
    }
  });

  it('times out stalled APNs response bodies', async () => {
    expect.assertions(3);

    vi.useFakeTimers();
    apnsMock.closedRequests = 0;
    apnsMock.connections.length = 0;
    apnsMock.requests.length = 0;
    apnsMock.responseBody = '';
    apnsMock.sessions.length = 0;
    apnsMock.status = 200;
    apnsMock.statusByToken = {};
    apnsMock.stallResponseBody = true;
    vi.stubEnv('APNS_KEY_ID', 'key-id');
    vi.stubEnv('APNS_TEAM_ID', 'team-id');
    const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
    vi.stubEnv(
      'APNS_PRIVATE_KEY',
      privateKey.export({ format: 'pem', type: 'pkcs8' }),
    );
    vi.stubEnv('APNS_TOPIC', 'dev.unwired.mail');
    try {
      const t = convexTest(schema, modules);
      const asUser = t.withIdentity(appleIdentity);
      const device = await asUser.mutation(api.productAccount.connect, {
        deviceIdentifier: 'stalled-device',
        platform: 'ios',
      });
      const delivery = t.action(internal.apns.deliverGmailWakeups, {
        historyId: 'history-125',
        recipients: [
          {
            apnsEnvironment: 'production',
            apnsToken: 'stalled-device-token',
            routeId: 'stalled-route',
            trustedDeviceId: device.trustedDeviceId,
          },
        ],
      });

      await vi.advanceTimersByTimeAsync(0);
      expect(apnsMock.requests).toHaveLength(1);
      await vi.advanceTimersByTimeAsync(10_000);
      await expect(delivery).resolves.toBeNull();
      expect(apnsMock.closedRequests).toBe(1);
    } finally {
      vi.useRealTimers();
      vi.unstubAllEnvs();
      apnsMock.stallResponseBody = false;
    }
  });
});
