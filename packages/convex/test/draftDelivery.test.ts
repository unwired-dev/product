/// <reference types="vite/client" />

import { convexTest } from 'convex-test';

import { api } from '../convex/_generated/api.js';
import schema from '../convex/schema.js';
import { connectTrusted } from './devices.js';

const modules = import.meta.glob('../convex/**/*.ts');

const identity = (subject: string) => ({
  issuer: 'https://appleid.apple.com',
  subject,
  tokenIdentifier: `https://appleid.apple.com|${subject}`,
});

const claimIdentifier = `draft-delivery.${'0123456789abcdef'.repeat(2)}`;

describe('claiming a Draft for delivery', () => {
  /* oxlint-disable vitest/max-expects -- One journey proves the claim's whole contract. */
  it('lets the first Trusted Device hold a claim, again after a lost reply, and refuses the others', async () => {
    expect.assertions(7);
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(identity('apple-user-001'));
    const phone = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    const mac = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-002',
      platform: 'macos',
    });
    const asOther = t.withIdentity(identity('apple-user-002'));
    const otherAccount = await connectTrusted(t, asOther, {
      deviceIdentifier: 'device-003',
      platform: 'ios',
    });
    const claim = (
      client: typeof asUser,
      device: typeof phone,
      identifier = claimIdentifier,
    ) =>
      client.mutation(api.draftDelivery.claim, {
        claimIdentifier: identifier,
        trustedDeviceId: device.trustedDeviceId,
      });

    // Concurrent claims are serialized: exactly one device holds the Draft.
    const claimed = await Promise.all([
      claim(asUser, phone),
      claim(asUser, mac),
    ]);
    const holders = [phone, mac].filter(
      (_, index) => claimed[index]?.claimed === true,
    );
    expect(holders).toHaveLength(1);
    const [holder = phone] = holders;
    await expect(claim(asUser, holder)).resolves.toStrictEqual({
      claimed: true,
    });
    // Another account's identical identifier is a separate claim.
    await expect(claim(asOther, otherAccount)).resolves.toStrictEqual({
      claimed: true,
    });
    // The stored claim names only the opaque identifier, the device and the time.
    const stored = await t.run((ctx) =>
      ctx.db.query('draftDeliveryClaims').collect(),
    );
    expect(
      stored.map(
        ({
          claimIdentifier: identifier,
          productAccountId,
          trustedDeviceId,
        }) => ({
          claimIdentifier: identifier,
          productAccountId,
          trustedDeviceId,
        }),
      ),
    ).toStrictEqual([
      {
        claimIdentifier,
        productAccountId: holder.productAccountId,
        trustedDeviceId: holder.trustedDeviceId,
      },
      {
        claimIdentifier,
        productAccountId: otherAccount.productAccountId,
        trustedDeviceId: otherAccount.trustedDeviceId,
      },
    ]);
    await expect(claim(asUser, phone, 'Lunch with Sam')).rejects.toThrow(
      'Invalid delivery claim',
    );
    // A device of another account cannot claim for this one.
    await expect(
      asOther.mutation(api.draftDelivery.claim, {
        claimIdentifier,
        trustedDeviceId: phone.trustedDeviceId,
      }),
    ).rejects.toThrow('Trusted device required');
    await expect(
      t.mutation(api.draftDelivery.claim, {
        claimIdentifier,
        trustedDeviceId: phone.trustedDeviceId,
      }),
    ).rejects.toThrow('Authentication required');
  });

  it('refuses a revoked Trusted Device', async () => {
    expect.assertions(1);
    const t = convexTest(schema, modules);
    const asUser = t.withIdentity(identity('apple-user-001'));
    const phone = await connectTrusted(t, asUser, {
      deviceIdentifier: 'device-001',
      platform: 'ios',
    });
    await t.run(async (ctx) => {
      await ctx.db.insert('revokedTrustedDevices', {
        deviceIdentifier: 'device-001',
        productAccountId: phone.productAccountId,
        productSyncKeyEpoch: 1,
        revokedAt: Date.now(),
        trustedDeviceId: phone.trustedDeviceId,
      });
      await ctx.db.delete('trustedDevices', phone.trustedDeviceId);
    });

    await expect(
      asUser.mutation(api.draftDelivery.claim, {
        claimIdentifier,
        trustedDeviceId: phone.trustedDeviceId,
      }),
    ).rejects.toMatchObject({ data: { code: 'TRUSTED_DEVICE_REVOKED' } });
  });
});
