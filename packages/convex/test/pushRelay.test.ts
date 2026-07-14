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
  connections: [] as string[],
  requests: [] as ObservedApnsRequest[],
  responseBody: '',
  sessions: [] as Array<{
    listenerCount: (eventName: string | symbol) => number;
  }>,
  status: 200,
  statusByToken: {} as Record<string, number>,
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
            async *[Symbol.asyncIterator]() {
              if (apnsMock.responseBody.length > 0) {
                yield apnsMock.responseBody;
              }
            },
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
              });
            },
            close() {
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
    ).resolves.toStrictEqual({ verified: false });
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
    ).resolves.toStrictEqual({ verified: true });
    await expect(
      asUser.mutation(api.pushRelay.verifyGmailWatch, {
        historyId: 'history-first',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ verified: true });
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
    ).resolves.toStrictEqual({ verified: false });
    await t.mutation(internal.pushRelay.enqueueGmailWakeups, {
      emailAddress: 'matching@example.com',
      historyId: '101',
    });
    await expect(
      asUser.mutation(api.pushRelay.verifyGmailWatch, {
        historyId: '100',
        trustedDeviceId: productConnection.trustedDeviceId,
      }),
    ).resolves.toStrictEqual({ verified: true });
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

    const payload = gmailWakeupPayload('history-123');

    expect(payload).toStrictEqual({
      aps: { 'content-available': 1 },
      historyId: 'history-123',
      provider: 'gmail',
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

    apnsMock.connections.length = 0;
    apnsMock.requests.length = 0;
    apnsMock.responseBody = '';
    apnsMock.sessions.length = 0;
    apnsMock.status = 200;
    apnsMock.statusByToken = {};
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
              trustedDeviceId: badDevice.trustedDeviceId,
            },
            {
              apnsEnvironment: 'production',
              apnsToken: 'good-device-token',
              trustedDeviceId: goodDevice.trustedDeviceId,
            },
          ],
        }),
      ).resolves.toBeNull();
      const prunedDevice = await t.run(async (ctx) =>
        ctx.db.get(badDevice.trustedDeviceId),
      );
      expect({
        badAuthority: apnsMock.requests[1]?.authority,
        connections: apnsMock.connections,
        goodPath: apnsMock.requests[2]?.headers[':path'],
        prunedToken: prunedDevice?.apnsToken,
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
        sessionErrorListeners: [1, 1],
      });
    } finally {
      vi.unstubAllEnvs();
    }
  });
});
