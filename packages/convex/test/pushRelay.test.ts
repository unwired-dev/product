/// <reference types="vite/client" />

import { convexTest } from 'convex-test';

import { api, internal } from '../convex/_generated/api.js';
import {
  decodeGmailPushEnvelope,
  gmailWakeupPayload,
} from '../convex/gmailPushPayload.js';
import schema from '../convex/schema.js';

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
});
