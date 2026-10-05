/// <reference types="vite/client" />
import { convexTest } from 'convex-test';

import { api } from '../convex/_generated/api.js';
import schema from '../convex/schema.js';
import { connectTrusted } from './devices.js';

const modules = import.meta.glob('../convex/**/*.ts');

describe('product registration', () => {
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
    const first = await connectTrusted(t, google, args);
    const second = await connectTrusted(t, apple, args);
    const third = await connectTrusted(t, otherGoogle, args);
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
    const resumed = await connectTrusted(t, google, {
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

  it('registers Apple first without storing its relay address or linking a Google identity that shares it', async () => {
    expect.hasAssertions();
    const t = convexTest(schema, modules);
    const relay = 'synthetic@privaterelay.appleid.com';
    const apple = t.withIdentity({
      issuer: 'https://appleid.apple.com',
      subject: 'apple-relay-001',
      email: relay,
    });
    const google = t.withIdentity({
      issuer: 'https://accounts.google.com',
      subject: 'google-relay-001',
      email: relay,
    });
    const args = {
      deviceIdentifier: 'installation-apple-001',
      platform: 'macos',
      supportsDeviceCredentials: true,
    };
    const registered = await connectTrusted(t, apple, args);
    const other = await connectTrusted(t, google, args);
    expect(other.productAccountId).not.toBe(registered.productAccountId);
    await expect(
      google.query(api.productAccount.listTrustedDevices, {
        trustedDeviceId: registered.trustedDeviceId,
        trustedDeviceCredential: registered.trustedDeviceCredential,
      }),
    ).rejects.toThrow('Trusted device required');
    // Reauthenticating the Apple identity resumes the same account and device.
    await expect(
      connectTrusted(t, apple, {
        ...args,
        trustedDeviceCredential: registered.trustedDeviceCredential,
      }),
    ).resolves.toMatchObject({
      accountCreated: false,
      productAccountId: registered.productAccountId,
      trustedDeviceId: registered.trustedDeviceId,
      trustedDeviceCredential: registered.trustedDeviceCredential,
    });
    const stored = await t.run(async (ctx) => [
      ...(await ctx.db.query('productAccounts').collect()),
      ...(await ctx.db.query('trustedDevices').collect()),
      ...(await ctx.db.query('mailProviderConnections').collect()),
    ]);
    expect(JSON.stringify(stored)).not.toContain(relay);
  });
});
