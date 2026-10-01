/// <reference types="vite/client" />
import { convexTest } from 'convex-test';

import type { Id } from '../convex/_generated/dataModel.js';

import { api, internal } from '../convex/_generated/api.js';
import schema from '../convex/schema.js';

const modules = import.meta.glob('../convex/**/*.ts');

const sharedEmail = 'same@example.invalid';
const now = () => Math.floor(Date.now() / 1000);
const identity = (issuer: string, subject: string, iat = now()) => ({
  email: sharedEmail,
  iat,
  issuer,
  subject,
});
const apple = (subject: string, iat?: number) =>
  identity('https://appleid.apple.com', subject, iat);
const google = (subject: string, iat?: number) =>
  identity('https://accounts.google.com', subject, iat);

function ticket(response: { linkTicket?: string }): string {
  if (response.linkTicket === undefined) {
    throw new Error('Expected a link ticket');
  }
  return response.linkTicket;
}

function pendingRequestId(result: {
  requestId?: Id<'productAccountDeletionRequests'>;
  state: string;
}): Id<'productAccountDeletionRequests'> {
  if (result.state !== 'pending' || result.requestId === undefined) {
    throw new Error('Expected a pending deletion request');
  }
  return result.requestId;
}

function credential(response: { trustedDeviceCredential?: string }): string {
  if (response.trustedDeviceCredential === undefined) {
    throw new Error('Expected a Trusted Device Credential');
  }
  return response.trustedDeviceCredential;
}

async function registered(
  t: ReturnType<typeof convexTest>,
  account: ReturnType<typeof apple>,
  deviceIdentifier = 'installation-001',
) {
  const connected = await t
    .withIdentity(account)
    .mutation(api.productAccount.connect, {
      deviceIdentifier,
      platform: 'ios',
      supportsDeviceCredentials: true,
    });
  return {
    productAccountId: connected.productAccountId,
    proof: {
      trustedDeviceCredential: credential(connected),
      trustedDeviceId: connected.trustedDeviceId,
    },
  };
}

/* oxlint-disable vitest/max-expects -- Each journey proves one ownership contract across both identities. */
describe('linked sign-ins', () => {
  it('lets a verified Google identity open the Apple Product Account on another installation, while a same-email Google identity stays separate', async () => {
    expect.hasAssertions();
    const t = convexTest(schema, modules);
    const owner = await registered(t, apple('apple-001'));
    const requested = await t
      .withIdentity(apple('apple-001'))
      .mutation(api.signInLinks.request, {
        ...owner.proof,
        provider: 'google',
      });
    expect(requested.signInProviders).toStrictEqual(['apple']);
    await expect(
      t.withIdentity(google('google-001')).mutation(api.signInLinks.complete, {
        ...owner.proof,
        linkTicket: ticket(requested),
      }),
    ).resolves.toStrictEqual({
      productAccountId: owner.productAccountId,
      signInProviders: ['apple', 'google'],
    });

    // Either provider now enters the same Product Account from a new installation.
    const alternate = await t
      .withIdentity(google('google-001'))
      .mutation(api.productAccount.connect, {
        deviceIdentifier: 'installation-002',
        platform: 'macos',
        supportsDeviceCredentials: true,
      });
    expect(alternate).toMatchObject({
      accountCreated: false,
      productAccountId: owner.productAccountId,
      signInProviders: ['apple', 'google'],
    });
    await expect(
      t
        .withIdentity(google('google-001'))
        .query(api.productAccount.listTrustedDevices, owner.proof),
    ).resolves.toHaveLength(2);
    // Requesting an already linked provider reports it without issuing a ticket.
    await expect(
      t.withIdentity(google('google-001')).mutation(api.signInLinks.request, {
        ...owner.proof,
        provider: 'apple',
      }),
    ).resolves.toStrictEqual({ signInProviders: ['apple', 'google'] });

    // A matching email address never links or reaches the account.
    await expect(
      t
        .withIdentity(google('google-same-email'))
        .mutation(api.productAccount.connect, {
          deviceIdentifier: 'installation-001',
          expectedProductAccountId:
            owner.productAccountId as Id<'productAccounts'>,
          platform: 'ios',
          supportsDeviceCredentials: true,
        }),
    ).rejects.toMatchObject({ data: { code: 'SIGN_IN_NOT_LINKED' } });
    await expect(
      t.run((ctx) => ctx.db.query('productAccounts').collect()),
    ).resolves.toHaveLength(1);
    const separate = await registered(t, google('google-same-email'));
    expect(separate.productAccountId).not.toBe(owner.productAccountId);
    await expect(
      t
        .withIdentity(google('google-same-email'))
        .query(api.productAccount.listTrustedDevices, owner.proof),
    ).rejects.toThrow('Trusted device required');
    const stored = await t.run((ctx) =>
      ctx.db.query('linkedSignIns').collect(),
    );
    expect(stored.map(({ provider }) => provider)).toStrictEqual(['google']);
    expect(JSON.stringify(stored)).not.toContain(sharedEmail);
  });

  it('rejects identities owned elsewhere and concurrent links without partial ownership', async () => {
    expect.hasAssertions();
    const t = convexTest(schema, modules);
    const owner = await registered(t, apple('apple-owner'));
    const other = await registered(
      t,
      google('google-registered'),
      'installation-other',
    );
    const request = () =>
      t.withIdentity(apple('apple-owner')).mutation(api.signInLinks.request, {
        ...owner.proof,
        provider: 'google',
      });
    // An identity with its own Product Account is never attached or merged.
    await expect(
      t
        .withIdentity(google('google-registered'))
        .mutation(api.signInLinks.complete, {
          ...owner.proof,
          linkTicket: ticket(await request()),
        }),
    ).rejects.toMatchObject({ data: { code: 'SIGN_IN_IDENTITY_OWNED' } });

    // Devices racing to link Google: only the newest ticket can commit.
    const second = await registered(
      t,
      apple('apple-owner'),
      'installation-second',
    );
    const firstTicket = ticket(await request());
    const secondTicket = ticket(
      await t
        .withIdentity(apple('apple-owner'))
        .mutation(api.signInLinks.request, {
          ...second.proof,
          provider: 'google',
        }),
    );
    await expect(
      t
        .withIdentity(google('google-first'))
        .mutation(api.signInLinks.complete, {
          ...owner.proof,
          linkTicket: firstTicket,
        }),
    ).rejects.toMatchObject({ data: { code: 'SIGN_IN_LINK_EXPIRED' } });
    const thirdTicket = ticket(await request());
    await t
      .withIdentity(google('google-first'))
      .mutation(api.signInLinks.complete, {
        ...owner.proof,
        linkTicket: thirdTicket,
      });
    await expect(
      t.withIdentity(google('google-late')).mutation(api.signInLinks.complete, {
        ...second.proof,
        linkTicket: secondTicket,
      }),
    ).rejects.toMatchObject({ data: { code: 'SIGN_IN_LINK_EXPIRED' } });

    // Another account cannot take over an identity that is already linked.
    const otherTicket = ticket(
      await t
        .withIdentity(google('google-registered'))
        .mutation(api.signInLinks.request, {
          ...other.proof,
          provider: 'apple',
        }),
    );
    await expect(
      t.withIdentity(apple('apple-owner')).mutation(api.signInLinks.complete, {
        ...other.proof,
        linkTicket: otherTicket,
      }),
    ).rejects.toMatchObject({ data: { code: 'SIGN_IN_IDENTITY_OWNED' } });
    const links = await t.run((ctx) => ctx.db.query('linkedSignIns').collect());
    expect(
      links.map(({ productAccountId, tokenIdentifier }) => ({
        productAccountId,
        tokenIdentifier,
      })),
    ).toStrictEqual([
      {
        productAccountId: owner.productAccountId,
        tokenIdentifier: 'https://accounts.google.com|google-first',
      },
    ]);
    await expect(
      t
        .withIdentity(google('google-late'))
        .mutation(api.productAccount.connect, {
          deviceIdentifier: 'installation-second',
          expectedProductAccountId:
            owner.productAccountId as Id<'productAccounts'>,
          platform: 'ios',
        }),
    ).rejects.toMatchObject({ data: { code: 'SIGN_IN_NOT_LINKED' } });
  });

  it('requires recent authentication of both identities and a live ticket from the same device, and resumes an interrupted completion', async () => {
    expect.hasAssertions();
    const t = convexTest(schema, modules);
    const owner = await registered(t, google('google-owner'));
    const stale = now() - 301;
    await expect(
      t
        .withIdentity(google('google-owner', stale))
        .mutation(api.signInLinks.request, {
          ...owner.proof,
          provider: 'apple',
        }),
    ).rejects.toMatchObject({
      data: { code: 'SIGN_IN_RECENT_AUTHENTICATION_REQUIRED' },
    });
    const request = async () =>
      ticket(
        await t
          .withIdentity(google('google-owner'))
          .mutation(api.signInLinks.request, {
            ...owner.proof,
            provider: 'apple',
          }),
      );
    const linkTicket = await request();
    await expect(
      t
        .withIdentity(apple('apple-new', stale))
        .mutation(api.signInLinks.complete, { ...owner.proof, linkTicket }),
    ).rejects.toMatchObject({
      data: { code: 'SIGN_IN_RECENT_AUTHENTICATION_REQUIRED' },
    });
    // A ticket is bound to its provider and to the device that requested it.
    await expect(
      t
        .withIdentity(google('google-new'))
        .mutation(api.signInLinks.complete, { ...owner.proof, linkTicket }),
    ).rejects.toMatchObject({ data: { code: 'SIGN_IN_LINK_EXPIRED' } });
    const elsewhere = await registered(
      t,
      google('google-owner'),
      'installation-elsewhere',
    );
    await expect(
      t
        .withIdentity(apple('apple-new'))
        .mutation(api.signInLinks.complete, { ...elsewhere.proof, linkTicket }),
    ).rejects.toMatchObject({ data: { code: 'SIGN_IN_LINK_EXPIRED' } });
    await t.run(async (ctx) => {
      for (const pending of await ctx.db
        .query('signInLinkRequests')
        .collect()) {
        // oxlint-disable-next-line eslint/no-underscore-dangle -- Convex document id field
        await ctx.db.patch(pending._id, { expiresAt: Date.now() - 1 });
      }
    });
    await expect(
      t
        .withIdentity(apple('apple-new'))
        .mutation(api.signInLinks.complete, { ...owner.proof, linkTicket }),
    ).rejects.toMatchObject({ data: { code: 'SIGN_IN_LINK_EXPIRED' } });
    await expect(
      t.run((ctx) => ctx.db.query('linkedSignIns').collect()),
    ).resolves.toStrictEqual([]);

    const fresh = await request();
    const linked = await t
      .withIdentity(apple('apple-new'))
      .mutation(api.signInLinks.complete, {
        ...owner.proof,
        linkTicket: fresh,
      });
    // The response was lost; retrying the consumed ticket confirms the committed link.
    await expect(
      t.withIdentity(apple('apple-new')).mutation(api.signInLinks.complete, {
        ...owner.proof,
        linkTicket: fresh,
      }),
    ).resolves.toStrictEqual(linked);
    expect(linked.signInProviders).toStrictEqual(['google', 'apple']);
  });

  it('tombstones every Linked Sign-In when the Product Account is deleted', async () => {
    expect.hasAssertions();
    const t = convexTest(schema, modules);
    const owner = await registered(t, apple('apple-deleted'));
    const linkTicket = ticket(
      await t
        .withIdentity(apple('apple-deleted'))
        .mutation(api.signInLinks.request, {
          ...owner.proof,
          provider: 'google',
        }),
    );
    await t
      .withIdentity(google('google-deleted'))
      .mutation(api.signInLinks.complete, { ...owner.proof, linkTicket });
    // Deletion requested through the Linked Sign-In is keyed by the original identity.
    const linkedUser = t.withIdentity(google('google-deleted'));
    const prepared = await linkedUser.mutation(
      internal.productAccountDeletionData.prepareDeletion,
      {
        ...owner.proof,
        attemptId: 'deletion-attempt-001',
        authorizationCode: 'recent-apple-authorization-code',
      },
    );
    const requestId = pendingRequestId(prepared);
    await linkedUser.mutation(
      internal.productAccountDeletionData.markRevocationComplete,
      { attemptId: 'deletion-attempt-001', requestId },
    );
    let complete = false;
    while (!complete) {
      ({ complete } = await linkedUser.mutation(
        internal.productAccountDeletionData.deleteNextBatch,
        { requestId },
      ));
    }
    await expect(
      t.run(async (ctx) => [
        ...(await ctx.db.query('productAccounts').collect()),
        ...(await ctx.db.query('linkedSignIns').collect()),
      ]),
    ).resolves.toStrictEqual([]);
    for (const deleted of [apple('apple-deleted'), google('google-deleted')]) {
      await expect(
        t.withIdentity(deleted).mutation(api.productAccount.connect, {
          deviceIdentifier: 'installation-new',
          platform: 'ios',
        }),
      ).rejects.toMatchObject({ data: { code: 'PRODUCT_ACCOUNT_DELETED' } });
    }
  });
});
