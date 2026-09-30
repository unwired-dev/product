/// <reference types="vite/client" />
import { convexTest } from 'convex-test';

import { api } from '../convex/_generated/api.js';
import schema from '../convex/schema.js';

const modules = import.meta.glob('../convex/**/*.ts');

describe('google registration', () => {
  it('keeps same-address Google and Apple identities isolated and resumes Google setup without mailbox or sync-key claims', async () => {
    expect.hasAssertions();
    const t = convexTest(schema, modules);
    const google = t.withIdentity({
      issuer: 'https://accounts.google.com',
      subject: 'google-001',
      email: 'same@example.invalid',
    });
    const apple = t.withIdentity({
      issuer: 'https://appleid.apple.com',
      subject: 'apple-001',
      email: 'same@example.invalid',
    });
    const otherGoogle = t.withIdentity({
      issuer: 'https://accounts.google.com',
      subject: 'google-002',
      email: 'same@example.invalid',
    });
    const args = {
      deviceIdentifier: 'installation-001',
      platform: 'ios',
      supportsDeviceCredentials: true,
    };
    const first = await google.mutation(api.productAccount.connect, args);
    const second = await apple.mutation(api.productAccount.connect, args);
    const third = await otherGoogle.mutation(api.productAccount.connect, args);
    expect(
      new Set([
        first.productAccountId,
        second.productAccountId,
        third.productAccountId,
      ]).size,
    ).toBe(3);
    expect(first).toMatchObject({
      accountCreated: true,
      productSyncMaterialInitialized: false,
    });
    const resumed = await google.mutation(api.productAccount.connect, {
      ...args,
      trustedDeviceCredential: first.trustedDeviceCredential,
    });
    expect(resumed).toMatchObject({
      accountCreated: false,
      productAccountId: first.productAccountId,
      trustedDeviceId: first.trustedDeviceId,
      trustedDeviceCredential: first.trustedDeviceCredential,
      productSyncMaterialInitialized: false,
    });
    await expect(
      apple.query(api.productAccount.listTrustedDevices, {
        trustedDeviceId: first.trustedDeviceId,
        trustedDeviceCredential: first.trustedDeviceCredential,
      }),
    ).rejects.toThrow('Trusted device required');
    const connections = await t.run((ctx) =>
      ctx.db.query('mailProviderConnections').collect(),
    );
    expect(connections).toStrictEqual([]);
  });
});
