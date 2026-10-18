/* oxlint-disable vitest/no-conditional-in-test -- Table cases control which external boundary interrupts each real delivery journey. */
/* oxlint-disable vitest/max-expects -- Each journey verifies durable state together with provider delivery. */
import { undoSendWindow } from '../src/outbox.ts';
import { alex, present } from './draft-sync-fixture.ts';
import { account, addressed, sender, sharedAccount } from './outbox-fixture.ts';

describe('outbox execution opportunities', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Delivery deadlines use a controlled clock.
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(Date.UTC(2026, 9, 18, 12));
  });
  // oxlint-disable-next-line vitest/no-hooks -- Restore the clock after each isolated journey.
  afterEach(() => {
    vi.useRealTimers();
  });

  it('keeps Undo and the original deadline while paused, then resumes a durable intent once', async () => {
    expect.hasAssertions();
    const { server, gmail } = sharedAccount();
    const phone = await sender(server, gmail, 'phone');
    try {
      const undone = await addressed(phone);
      await phone.outbox.send(() => phone.draft(undone));
      phone.outbox.pause();
      vi.setSystemTime(Date.now() + undoSendWindow - 1);
      await phone.outbox.process();
      expect(gmail.sends).toHaveLength(0);
      await expect(phone.outbox.undo(undone)).resolves.toBe(undone);

      const id = await addressed(phone);
      await phone.outbox.send(() => phone.draft(id));
      const deadline = present(
        phone.drafts.getOutbox()[0],
        'queued intent',
      ).sendAt;
      await phone.outbox.resume();
      expect(phone.drafts.getOutbox()).toMatchObject([
        { id, state: 'waiting', sendAt: deadline },
      ]);
      phone.outbox.pause();
      vi.setSystemTime(deadline + 60_000);
      await phone.outbox.process();
      expect(gmail.sends).toHaveLength(0);
      await phone.outbox.resume();
      await phone.outbox.resume();
      expect(gmail.sends).toHaveLength(1);
      expect(phone.drafts.getOutbox()).toStrictEqual([]);
    } finally {
      phone.outbox.dispose();
    }
  });

  it.each(['claim', 'handoff', 'dispose'] as const)(
    'fences a %s interrupted before the provider starts',
    async (boundary) => {
      expect.hasAssertions();
      const { server, gmail } = sharedAccount();
      const phone = await sender(server, gmail, 'phone');
      try {
        const id = await addressed(phone);
        await phone.outbox.send(() => phone.draft(id));
        const entered = Promise.withResolvers<undefined>();
        const release = Promise.withResolvers<undefined>();
        const claims = present(phone.storage.delivery, 'delivery claims');
        const claim = claims.claimDraftDelivery;
        const commit = phone.storage.native.commitDrafts;
        if (boundary === 'handoff') {
          vi.spyOn(phone.storage.native, 'commitDrafts').mockImplementation(
            async (...args) => {
              const reply = await commit(...args);
              if (args[2].document.includes('"state":"sending"')) {
                entered.resolve(undefined);
                await release.promise;
              }
              return reply;
            },
          );
        } else {
          vi.spyOn(claims, 'claimDraftDelivery').mockImplementation(
            async (...args) => {
              const reply = await claim(...args);
              entered.resolve(undefined);
              await release.promise;
              return reply;
            },
          );
        }
        vi.setSystemTime(Date.now() + undoSendWindow);
        const processing = phone.outbox.process();
        await entered.promise;
        if (boundary === 'dispose') {
          phone.outbox.dispose();
        } else {
          phone.outbox.pause();
        }
        release.resolve(undefined);
        await processing;
        expect(gmail.sends).toHaveLength(0);
        expect(phone.drafts.getOutbox()).toMatchObject([
          { id, state: 'queued', claim: 'held' },
        ]);
        await phone.outbox.resume();
        expect(gmail.sends).toHaveLength(boundary === 'dispose' ? 0 : 1);
      } finally {
        phone.outbox.dispose();
      }
    },
  );

  it.each([false, true])(
    'keeps an in-flight outcome (lost reply: %s) while pausing later messages',
    async (lost) => {
      expect.hasAssertions();
      const { server, gmail } = sharedAccount();
      const phone = await sender(server, gmail, 'phone');
      try {
        const first = await addressed(phone);
        const second = await addressed(phone);
        await phone.outbox.send(() => phone.draft(first));
        await phone.outbox.send(() => phone.draft(second));
        const entered = Promise.withResolvers<undefined>();
        const release = Promise.withResolvers<undefined>();
        const submit = gmail.native.gmailSend;
        if (lost) {
          gmail.failSend({ lost: true });
        }
        gmail.native.gmailSend = async (...args) => {
          try {
            return await submit(...args);
          } finally {
            entered.resolve(undefined);
            await release.promise;
          }
        };
        vi.setSystemTime(Date.now() + undoSendWindow);
        const processing = phone.outbox.process();
        await entered.promise;
        phone.outbox.pause();
        release.resolve(undefined);
        await processing;
        expect(gmail.sends).toHaveLength(1);
        expect(phone.drafts.getOutbox()).toMatchObject([
          ...(lost ? [{ id: first, state: 'unknown' }] : []),
          { id: second, state: 'waiting' },
        ]);
        gmail.native.gmailSend = submit;
        await phone.outbox.resume();
        await phone.relaunch();
        await phone.outbox.process();
        expect(gmail.sends).toHaveLength(2);
        expect(phone.drafts.getOutbox()).toStrictEqual([]);
      } finally {
        phone.outbox.dispose();
      }
    },
  );

  it.each(['sign-out', 'connection', 'revocation'] as const)(
    'stops an unstarted handoff after %s while its claim is pending',
    async (removal) => {
      expect.hasAssertions();
      const { server, gmail } = sharedAccount();
      const phone = await sender(server, gmail, 'phone');
      try {
        const id = await addressed(phone);
        await phone.outbox.send(() => phone.draft(id));
        const claims = present(phone.storage.delivery, 'claims');
        const claim = claims.claimDraftDelivery;
        vi.spyOn(claims, 'claimDraftDelivery').mockImplementation(
          async (...args) => {
            const reply = await claim(...args);
            phone.change(
              removal === 'connection'
                ? {
                    kind: 'connected',
                    productAccountId: account,
                    signInProvider: 'google',
                    mailboxes: '[]',
                  }
                : {
                    kind: 'signed-out',
                    ...(removal === 'revocation'
                      ? { notice: 'revoked' as const }
                      : {}),
                  },
            );
            return reply;
          },
        );
        vi.setSystemTime(Date.now() + undoSendWindow);
        await phone.outbox.process();
        expect(gmail.sends).toHaveLength(0);
        expect(
          phone.mailboxes
            .getConnections()
            .find(({ id: connection }) => connection === alex.id),
        ).toBeUndefined();
      } finally {
        phone.outbox.dispose();
      }
    },
  );

  it.each(['sign-out', 'connection', 'revocation'] as const)(
    'keeps an uncertain in-flight handoff claimed after %s, without granting another device delivery',
    async (removal) => {
      expect.hasAssertions();
      const { server, gmail } = sharedAccount();
      const phone = await sender(server, gmail, 'phone');
      const mac = await sender(server, gmail, 'mac');
      try {
        const id = await addressed(phone);
        await phone.outbox.send(() => phone.draft(id));
        const entered = Promise.withResolvers<undefined>();
        const release = Promise.withResolvers<undefined>();
        const submit = gmail.native.gmailSend;
        gmail.failSend({ lost: true });
        gmail.native.gmailSend = async (...args) => {
          try {
            return await submit(...args);
          } finally {
            entered.resolve(undefined);
            await release.promise;
          }
        };
        vi.setSystemTime(Date.now() + undoSendWindow);
        const processing = phone.outbox.process();
        await entered.promise;
        phone.change(
          removal === 'connection'
            ? {
                kind: 'connected',
                productAccountId: account,
                signInProvider: 'google',
                mailboxes: '[]',
              }
            : {
                kind: 'signed-out',
                ...(removal === 'revocation'
                  ? { notice: 'revoked' as const }
                  : {}),
              },
        );
        release.resolve(undefined);
        await processing;
        await phone.outbox.process();
        await expect(
          mac.storage.delivery?.claimDraftDelivery(account, id),
        ).resolves.toStrictEqual({ owner: account, claimed: false });
        expect(gmail.sends).toHaveLength(1);
        expect([...server.claimsOf(account)]).toStrictEqual([
          [`draft-delivery.${id}`, 'phone'],
        ]);
      } finally {
        phone.outbox.dispose();
        mac.outbox.dispose();
      }
    },
  );
});
