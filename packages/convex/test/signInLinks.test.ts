import { convexTest } from 'convex-test';
/// <reference types="vite/client" />
import { ConvexError } from 'convex/values';
import * as Schema from 'effect/Schema';

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

const SignInProvidersSchema = Schema.Array(
  Schema.Literals(['apple', 'google']),
);
const decodeLinkRequest = Schema.decodeUnknownSync(
  Schema.Struct({
    linkTicket: Schema.optionalKey(Schema.String),
    signInProviders: SignInProvidersSchema,
  }),
);
const decodeLinkCompletion = Schema.decodeUnknownSync(
  Schema.Struct({
    productAccountId: Schema.String,
    signInProviders: SignInProvidersSchema,
  }),
);
const decodeLinkEnvelope = Schema.decodeUnknownSync(
  Schema.Union([
    Schema.Struct({ status: Schema.Literal('success'), value: Schema.Unknown }),
    Schema.Struct({
      status: Schema.Literal('error'),
      errorData: Schema.Struct({ code: Schema.String }),
    }),
  ]),
);

function identityToken(
  account: Readonly<{ issuer: string; subject: string; iat?: number }>,
): string {
  const claims = {
    iat: account.iat ?? now(),
    iss: account.issuer,
    sub: account.subject,
  };
  return `test-header.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.test-signature`;
}

function linkClient(
  t: ReturnType<typeof convexTest>,
  account: Readonly<{ issuer: string; subject: string; iat?: number }>,
) {
  // Model the gateway's verified identity without reserved token timestamps.
  const asUser = t.withIdentity({
    issuer: account.issuer,
    subject: account.subject,
  });
  async function call(
    operation: 'request' | 'complete',
    args: unknown,
  ): Promise<unknown> {
    const response = await asUser.fetch(`/sign-in-links/${operation}`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${identityToken(account)}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify(args),
    });
    const envelope = decodeLinkEnvelope(await response.json());
    if (envelope.status === 'error') {
      throw new ConvexError(envelope.errorData);
    }
    expect(response.status).toBe(200);
    return envelope.value;
  }
  return {
    request: async (args: unknown) =>
      decodeLinkRequest(await call('request', args)),
    complete: async (args: unknown) =>
      decodeLinkCompletion(await call('complete', args)),
  };
}

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
  it('rejects missing, stale, future, malformed and identity-mismatched bearer claims before issuing or completing a link', async () => {
    expect.hasAssertions();
    // Keep the six-second skew outside the bound across both HTTP requests.
    const clock = vi
      .spyOn(Date, 'now')
      .mockReturnValue(Date.UTC(2026, 9, 2, 12));
    try {
      const t = convexTest(schema, modules);
      const owner = await registered(t, google('google-current'));
      const asUser = t.withIdentity({
        issuer: 'https://accounts.google.com',
        subject: 'google-current',
      });
      const claimsToken = (claims: unknown) =>
        `header.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.signature`;
      const claims = {
        iat: now(),
        iss: 'https://accounts.google.com',
        sub: 'google-current',
      };
      const rejectedTokens = [
        '',
        'malformed',
        claimsToken({ ...claims, iat: now() - 301 }),
        claimsToken({ ...claims, iat: now() + 6 }),
        claimsToken({ ...claims, iat: String(now()) }),
        claimsToken({ iss: claims.iss, sub: claims.sub }),
        claimsToken({ ...claims, sub: 'another-person' }),
        claimsToken({ ...claims, iss: 'https://appleid.apple.com' }),
      ];
      const statuses = [];
      for (const operation of ['request', 'complete']) {
        for (const token of rejectedTokens) {
          const response = await asUser.fetch(`/sign-in-links/${operation}`, {
            method: 'POST',
            headers: { authorization: `Bearer ${token}` },
            body: JSON.stringify({
              ...owner.proof,
              provider: 'apple',
              linkTicket: 'unused',
            }),
          });
          statuses.push(response.status);
        }
      }
      expect(statuses).toStrictEqual(
        Array.from({ length: rejectedTokens.length * 2 }, () => 401),
      );
      const unauthenticated = await t.fetch('/sign-in-links/request', {
        method: 'POST',
        headers: { authorization: `Bearer ${claimsToken(claims)}` },
        body: JSON.stringify({ ...owner.proof, provider: 'apple' }),
      });
      expect(unauthenticated.status).toBe(401);
      for (const operation of ['request', 'complete']) {
        const malformed = await asUser.fetch(`/sign-in-links/${operation}`, {
          method: 'POST',
          headers: { authorization: `Bearer ${claimsToken(claims)}` },
          body: '{}',
        });
        expect(malformed.status).toBe(400);
      }
      await expect(
        t.run((ctx) => ctx.db.query('signInLinkRequests').collect()),
      ).resolves.toStrictEqual([]);
      await expect(
        t.run((ctx) => ctx.db.query('linkedSignIns').collect()),
      ).resolves.toStrictEqual([]);
    } finally {
      clock.mockRestore();
    }
  });

  it('links Apple to a Google account when the verified identity omits reserved JWT timestamps', async () => {
    expect.hasAssertions();
    const t = convexTest(schema, modules);
    const current = {
      issuer: 'https://accounts.google.com',
      subject: 'google-current',
    };
    const owner = await registered(t, google('google-current'));
    const requested = await linkClient(t, current).request({
      ...owner.proof,
      provider: 'apple',
    });
    expect(requested.signInProviders).toStrictEqual(['google']);
    const linked = await linkClient(t, apple('apple-added')).complete({
      ...owner.proof,
      linkTicket: ticket(requested),
    });
    expect(linked).toStrictEqual({
      productAccountId: owner.productAccountId,
      signInProviders: ['google', 'apple'],
    });
    const alternate = await registered(
      t,
      apple('apple-added'),
      'apple-installation',
    );
    expect(alternate.productAccountId).toBe(owner.productAccountId);
  });

  it('lets a verified Google identity open the Apple Product Account on another installation, while a same-email Google identity stays separate', async () => {
    expect.hasAssertions();
    const t = convexTest(schema, modules);
    const owner = await registered(t, apple('apple-001'));
    const requested = await linkClient(t, apple('apple-001')).request({
      ...owner.proof,
      provider: 'google',
    });
    expect(requested.signInProviders).toStrictEqual(['apple']);
    await expect(
      linkClient(t, google('google-001')).complete({
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
      linkClient(t, google('google-001')).request({
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
      linkClient(t, apple('apple-owner')).request({
        ...owner.proof,
        provider: 'google',
      });
    // An identity with its own Product Account is never attached or merged.
    await expect(
      linkClient(t, google('google-registered')).complete({
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
      await linkClient(t, apple('apple-owner')).request({
        ...second.proof,
        provider: 'google',
      }),
    );
    await expect(
      linkClient(t, google('google-first')).complete({
        ...owner.proof,
        linkTicket: firstTicket,
      }),
    ).rejects.toMatchObject({ data: { code: 'SIGN_IN_LINK_EXPIRED' } });
    const thirdTicket = ticket(await request());
    await linkClient(t, google('google-first')).complete({
      ...owner.proof,
      linkTicket: thirdTicket,
    });
    await expect(
      linkClient(t, google('google-late')).complete({
        ...second.proof,
        linkTicket: secondTicket,
      }),
    ).rejects.toMatchObject({ data: { code: 'SIGN_IN_LINK_EXPIRED' } });

    // Another account cannot take over an identity that is already linked.
    const otherTicket = ticket(
      await linkClient(t, google('google-registered')).request({
        ...other.proof,
        provider: 'apple',
      }),
    );
    await expect(
      linkClient(t, apple('apple-owner')).complete({
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
      linkClient(t, google('google-owner', stale)).request({
        ...owner.proof,
        provider: 'apple',
      }),
    ).rejects.toMatchObject({
      data: { code: 'SIGN_IN_RECENT_AUTHENTICATION_REQUIRED' },
    });
    const request = async () =>
      ticket(
        await linkClient(t, google('google-owner')).request({
          ...owner.proof,
          provider: 'apple',
        }),
      );
    const linkTicket = await request();
    await expect(
      linkClient(t, apple('apple-new', stale)).complete({
        ...owner.proof,
        linkTicket,
      }),
    ).rejects.toMatchObject({
      data: { code: 'SIGN_IN_RECENT_AUTHENTICATION_REQUIRED' },
    });
    // A malformed ticket names no request and links nothing.
    await expect(
      linkClient(t, apple('apple-malformed')).complete({
        ...owner.proof,
        linkTicket: 'not-a-ticket',
      }),
    ).rejects.toMatchObject({ data: { code: 'SIGN_IN_LINK_EXPIRED' } });
    // A ticket is bound to its provider and to the device that requested it.
    await expect(
      linkClient(t, google('google-new')).complete({
        ...owner.proof,
        linkTicket,
      }),
    ).rejects.toMatchObject({ data: { code: 'SIGN_IN_LINK_EXPIRED' } });
    const elsewhere = await registered(
      t,
      google('google-owner'),
      'installation-elsewhere',
    );
    await expect(
      linkClient(t, apple('apple-new')).complete({
        ...elsewhere.proof,
        linkTicket,
      }),
    ).rejects.toMatchObject({ data: { code: 'SIGN_IN_LINK_EXPIRED' } });
    await t.run(async (ctx) => {
      for (const pending of await ctx.db
        .query('signInLinkRequests')
        .collect()) {
        await ctx.db.patch('signInLinkRequests', pending._id, {
          expiresAt: Date.now() - 1,
        });
      }
    });
    await expect(
      linkClient(t, apple('apple-new')).complete({
        ...owner.proof,
        linkTicket,
      }),
    ).rejects.toMatchObject({ data: { code: 'SIGN_IN_LINK_EXPIRED' } });
    await expect(
      t.run((ctx) => ctx.db.query('linkedSignIns').collect()),
    ).resolves.toStrictEqual([]);

    const fresh = await request();
    const linked = await linkClient(t, apple('apple-new')).complete({
      ...owner.proof,
      linkTicket: fresh,
    });
    // The response was lost; retrying the consumed ticket confirms the committed link.
    await expect(
      linkClient(t, apple('apple-new')).complete({
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
      await linkClient(t, apple('apple-deleted')).request({
        ...owner.proof,
        provider: 'google',
      }),
    );
    await linkClient(t, google('google-deleted')).complete({
      ...owner.proof,
      linkTicket,
    });
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
