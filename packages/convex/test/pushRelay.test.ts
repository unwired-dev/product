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
  requests: [] as ObservedApnsRequest[],
  responseBody: '',
  status: 200,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- A partial HTTP/2 transport fake intentionally cannot satisfy the full Node module type.
vi.mock('node:http2', async () => {
  const { EventEmitter } = await import('node:events');

  return {
    connect: (authority: URL | string) => ({
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
              request.emit('response', { ':status': apnsMock.status });
            });
          },
          setEncoding(_encoding: string) {
            return undefined;
          },
        });
        return request;
      },
    }),
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
    expect.assertions(2);

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
    await firstUser.mutation(api.pushRelay.registerDevice, {
      apnsEnvironment: 'production',
      apnsToken: 'matching-apns-token',
      trustedDeviceId: firstConnection.trustedDeviceId,
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

    expect(recipients).toStrictEqual([
      {
        apnsEnvironment: 'production',
        apnsToken: 'matching-apns-token',
      },
    ]);
    expect(JSON.stringify(recipients)).not.toMatch(
      /accessToken|refreshToken|messageBody|category|classification/iu,
    );
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

    apnsMock.requests.length = 0;
    apnsMock.responseBody = '';
    apnsMock.status = 200;
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
      await t.action(internal.apns.deliverGmailWakeups, {
        historyId: 'history-123',
        recipients: [
          {
            apnsEnvironment: 'sandbox',
            apnsToken: 'device-token',
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
      apnsMock.status = 410;
      await expect(
        t.action(internal.apns.deliverGmailWakeups, {
          historyId: 'history-124',
          recipients: [
            {
              apnsEnvironment: 'production',
              apnsToken: 'bad-device-token',
            },
          ],
        }),
      ).rejects.toThrow('APNs request failed (410)');
      expect(apnsMock.requests[1]?.authority).toBe(
        'https://api.push.apple.com',
      );
    } finally {
      vi.unstubAllEnvs();
    }
  });
});
