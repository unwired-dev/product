/* oxlint-disable vitest/max-expects -- Delivery journeys verify durable state, mailbox recovery and provider copies together. */
import type { Outbox } from '@private-email/mail-core/outbox';

import { english } from '@private-email/localization';
import { createDrafts, draftOf } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import {
  createOutbox,
  outboxCopy,
  undoSendWindow,
} from '@private-email/mail-core/outbox';
import { boundaryOf } from '@private-email/mail-core/outgoing-message';
import {
  createRegistration,
  mailboxesOf,
} from '@private-email/mail-core/registration';
import {
  createSyntheticDrafts,
  createSyntheticProductSync,
} from '@private-email/mail-core/testing/drafts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticVault } from '@private-email/mail-core/testing/registration-vault';

import { present } from './draft-sync-fixture.ts';

// Native access verification gates provider writes independently of network reachability.
async function offlineSender() {
  const synthetic = createSyntheticVault();
  const gmail = createSyntheticGmail();
  const requests = { opens: 0, claims: 0, submissions: 0 };
  const verification = { unavailable: false };
  let verified = false;
  let beforeVerification: (() => Promise<void>) | undefined = undefined;
  const registration = createRegistration({
    ...synthetic.vault,
    forgetMailboxAccess: async () => {
      verified = false;
      return synthetic.vault.forgetMailboxAccess();
    },
    // Native cleanup can refuse its saved-registration read before provider verification.
    retryMailboxCleanup: () =>
      verification.unavailable
        ? Promise.reject(
            Object.assign(new Error('Synthetic verification unavailable'), {
              code: 'unavailable',
            }),
          )
        : synthetic.vault.retryMailboxCleanup(),
    renewIdentity: async () => {
      const before = beforeVerification;
      beforeVerification = undefined;
      await before?.();
      return synthetic.vault.renewIdentity();
    },
    confirmMailbox: async (id) => {
      const reply = await synthetic.vault.confirmMailbox(id);
      verified = true;
      return reply;
    },
    storeMailbox: async () => {
      const reply = await synthetic.vault.storeMailbox();
      verified = true;
      return reply;
    },
  });
  await registration.register('google');
  await registration.addMailbox();
  const connection = present(
    mailboxesOf(registration.getSnapshot().snapshot)[0],
    'connected mailbox',
  );
  const mailboxes = createMailboxes(
    syntheticConnections({
      [connection.id]: {
        native: {
          ...gmail.native,
          openMailbox: async () => {
            requests.opens += 1;
            return {
              ...(await gmail.native.openMailbox()),
              ...(verified ? {} : { availability: 'retry' }),
            };
          },
          gmailSend: (message, scope) => {
            requests.submissions += 1;
            return verified
              ? gmail.native.gmailSend(message, scope)
              : Promise.reject(
                  Object.assign(new Error('Synthetic unverified mailbox'), {
                    code: 'unavailable',
                  }),
                );
          },
        },
      },
    }),
    registration,
  );
  await mailboxes.load();
  const server = createSyntheticProductSync();
  const storage = createSyntheticDrafts(
    () => synthetic.device.record?.product?.productAccountId,
    { server },
  );
  const drafts = createDrafts(storage.native, registration);
  await drafts.load();
  const delivery = present(storage.delivery, 'delivery adapter');
  const claims = {
    claimDraftDelivery: (owner: string, id: string) => {
      requests.claims += 1;
      return delivery.claimDraftDelivery(owner, id);
    },
  };
  const outbox = createOutbox({
    drafts,
    mailboxes,
    registration,
    claims,
  });
  const setOnline = (online: boolean) => {
    synthetic.backend.offline = !online;
    server.setReachable(online);
  };
  setOnline(false);
  await registration.resume();
  await mailboxes.load();
  const queue = async () => {
    const id = present(await drafts.create(connection), 'offline Draft');
    const draft = () => present(draftOf(drafts.getSnapshot(), id), 'Draft');
    const original = draft();
    await drafts.update(
      {
        ...original,
        to: [{ name: 'Recipient', address: 'recipient@example.invalid' }],
        subject: 'Offline authorization',
      },
      original,
    );
    await outbox.send(draft);
    return id;
  };
  const id = await queue();
  return {
    id,
    queue,
    synthetic,
    drafts,
    mailboxes,
    outbox,
    gmail,
    registration,
    requests,
    verification,
    server,
    storage,
    claims,
    setOnline,
    holdNextVerification: () => {
      const started = Promise.withResolvers<undefined>();
      const release = Promise.withResolvers<undefined>();
      beforeVerification = async () => {
        started.resolve(undefined);
        await release.promise;
      };
      return {
        started: started.promise,
        release: () => release.resolve(undefined),
      };
    },
  };
}

describe('outbox cache-only authorization recovery', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Exercise automatic deadlines through the external clock.
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date', 'setTimeout', 'clearTimeout'] });
  });
  // oxlint-disable-next-line vitest/no-hooks -- Restore the clock after each journey.
  afterEach(() => {
    vi.useRealTimers();
  });

  it.each([
    {
      failure: 'unavailable',
      failed: true,
      nativeUnavailable: true,
      refreshFailure: undefined,
    },
    {
      failure: 'offline',
      failed: false,
      nativeUnavailable: false,
      refreshFailure: 'offline',
    },
  ])(
    'keeps resolved $failure verification queued before claims or handoff through reopening',
    async ({ failed, nativeUnavailable, refreshFailure }) => {
      expect.hasAssertions();
      const phone = await offlineSender();
      let reopened: Outbox | undefined = undefined;
      const states: string[] = [];
      const unsubscribe = phone.drafts.subscribe(() => {
        states.push(...phone.drafts.getOutbox().map(({ state }) => state));
      });
      try {
        // Only native verification fails; Product claims and durable storage remain reachable.
        phone.setOnline(true);
        phone.verification.unavailable = nativeUnavailable;
        phone.synthetic.google.refreshFailure = refreshFailure;
        await expect(phone.registration.resume()).resolves.toBeUndefined();
        expect(phone.registration.getSnapshot().failed).toBe(failed);
        expect(
          mailboxesOf(phone.registration.getSnapshot().snapshot),
        ).toMatchObject([{ state: 'cached' }]);
        expect(phone.synthetic.backend.offline).toBe(false);
        expect(phone.server.reach()).toBeUndefined();
        const { opens } = phone.requests;
        const reads = phone.gmail.requests.length;

        vi.setSystemTime(Date.now() + undoSendWindow);
        await phone.outbox.process();

        expect(phone.requests).toStrictEqual({
          opens,
          claims: 0,
          submissions: 0,
        });
        expect(phone.gmail.requests).toHaveLength(reads);
        expect(phone.gmail.sends).toHaveLength(0);
        expect(states).not.toContain('sending');
        expect(phone.drafts.getOutbox()).toMatchObject([
          { id: phone.id, state: 'queued', problem: 'offline' },
        ]);
        expect(
          present(phone.drafts.getOutbox()[0], 'queued message').claim,
        ).toBeUndefined();
        expect(
          outboxCopy(
            english,
            present(phone.outbox.getSnapshot()[0], 'waiting message'),
            'gmail',
          ).status,
        ).toBe(
          'Waiting to send. It sends when this device can reach Gmail and your Unwired Mail account.',
        );

        phone.outbox.dispose();
        phone.storage.relaunch();
        const drafts = createDrafts(phone.storage.native, phone.registration);
        await drafts.load();
        expect(drafts.getOutbox()).toStrictEqual(phone.drafts.getOutbox());
        reopened = createOutbox({
          drafts,
          registration: phone.registration,
          mailboxes: phone.mailboxes,
          claims: phone.claims,
        });
        await reopened.process();
        expect(drafts.getOutbox()).toMatchObject([
          { id: phone.id, state: 'queued', problem: 'offline' },
        ]);
        expect(phone.requests).toStrictEqual({
          opens,
          claims: 0,
          submissions: 0,
        });
        expect(phone.gmail.requests).toHaveLength(reads);

        phone.verification.unavailable = false;
        phone.synthetic.google.refreshFailure = undefined;
        await vi.advanceTimersByTimeAsync(29_999);
        expect(phone.requests.claims).toBe(0);
        expect(phone.requests.submissions).toBe(0);
        expect(drafts.getOutbox()).toMatchObject([
          { id: phone.id, state: 'queued', problem: 'offline' },
        ]);
        await vi.advanceTimersByTimeAsync(1);
        expect(phone.requests.claims).toBe(1);
        expect(phone.requests.submissions).toBe(1);
        expect(phone.gmail.sends).toHaveLength(1);
        expect(drafts.getOutbox()).toStrictEqual([]);
        expect(
          mailboxesOf(phone.registration.getSnapshot().snapshot),
        ).toMatchObject([{ state: 'connected' }]);
        await vi.advanceTimersByTimeAsync(30_000);
        expect(phone.gmail.sends).toHaveLength(1);
      } finally {
        unsubscribe();
        phone.outbox.dispose();
        reopened?.dispose();
      }
    },
  );

  it('reverifies an offline mailbox and sends once after reconnecting without activation or navigation', async () => {
    expect.hasAssertions();
    const phone = await offlineSender();
    try {
      await vi.advanceTimersByTimeAsync(undoSendWindow);
      expect(phone.drafts.getOutbox()).toMatchObject([
        { id: phone.id, state: 'queued', problem: 'offline' },
      ]);
      expect(phone.gmail.sends).toHaveLength(0);

      phone.setOnline(true);
      await vi.advanceTimersByTimeAsync(60_000);
      expect(phone.gmail.sends).toHaveLength(1);
      expect(phone.drafts.getOutbox()).toStrictEqual([]);
      expect(phone.mailboxes.getConnections()[0]?.state).toMatchObject({
        kind: 'ready',
        sync: 'current',
        organize: true,
      });
      await vi.advanceTimersByTimeAsync(30_000);
      expect(phone.gmail.sends).toHaveLength(1);
    } finally {
      phone.outbox.dispose();
    }
  });

  it('keeps non-delivery queued and fences a pause while cache-only verification waits', async () => {
    expect.hasAssertions();
    const phone = await offlineSender();
    let processing: Promise<void> | undefined = undefined;
    const verification = phone.holdNextVerification();
    try {
      phone.setOnline(true);
      vi.setSystemTime(Date.now() + undoSendWindow);
      processing = phone.outbox.process();
      await verification.started;
      phone.outbox.pause();
      expect(phone.drafts.getOutbox()).toMatchObject([
        { id: phone.id, state: 'queued' },
      ]);
      verification.release();
      await processing;
      expect(phone.gmail.sends).toHaveLength(0);
      await phone.outbox.resume();
      expect(phone.gmail.sends).toHaveLength(1);
      expect(phone.drafts.getOutbox()).toStrictEqual([]);
    } finally {
      phone.outbox.dispose();
      verification.release();
      await processing;
    }
  });

  it('backs off a rejected verification without submitting its message or blocking a later entry', async () => {
    expect.hasAssertions();
    const phone = await offlineSender();
    let rejected = false;
    const unsubscribe = phone.registration.subscribe(() => {
      // oxlint-disable-next-line vitest/no-conditional-in-test -- Inject one listener defect; later notifications must run normally.
      if (!rejected) {
        rejected = true;
        throw new Error('Synthetic registration listener defect');
      }
    });
    try {
      await phone.queue();
      phone.setOnline(true);
      vi.setSystemTime(Date.now() + undoSendWindow);
      await phone.outbox.process();
      expect(phone.gmail.sends).toHaveLength(1);
      expect(phone.drafts.getOutbox()).toMatchObject([
        { id: phone.id, state: 'queued', problem: 'offline' },
      ]);
      expect(
        outboxCopy(
          english,
          present(phone.outbox.getSnapshot()[0], 'waiting message'),
          'gmail',
        ).status,
      ).toBe(
        'Waiting to send. It sends when this device can reach Gmail and your Unwired Mail account.',
      );
      await vi.advanceTimersByTimeAsync(29_999);
      expect(phone.gmail.sends).toHaveLength(1);
      expect(phone.drafts.getOutbox()).toMatchObject([
        { id: phone.id, state: 'queued', problem: 'offline' },
      ]);
      await vi.advanceTimersByTimeAsync(1);
      expect(phone.gmail.sends).toHaveLength(2);
      expect(phone.drafts.getOutbox()).toStrictEqual([]);
    } finally {
      unsubscribe();
      phone.outbox.dispose();
    }
  });

  it('stops delivery when native device removal is reported through Registration during held verification', async () => {
    expect.hasAssertions();
    const phone = await offlineSender();
    let processing: Promise<void> | undefined = undefined;
    let removing: Promise<void> | undefined = undefined;
    const verification = phone.holdNextVerification();
    try {
      phone.setOnline(true);
      vi.setSystemTime(Date.now() + undoSendWindow);
      processing = phone.outbox.process();
      await verification.started;
      // A mailbox request purges native registration before reporting device removal to the store.
      await phone.synthetic.vault.purge('revoked');
      removing = phone.registration.deviceRemoved();
      verification.release();
      await Promise.all([processing, removing]);
      expect(phone.registration.getSnapshot().snapshot).toStrictEqual({
        kind: 'signed-out',
        notice: 'revoked',
      });
      expect(phone.mailboxes.getConnections()).toStrictEqual([]);
      expect(phone.gmail.sends).toHaveLength(0);
    } finally {
      phone.outbox.dispose();
      verification.release();
      await Promise.all([processing, removing]);
    }
  });

  it.each([
    {
      name: 'automatic recovery',
      recover: (outbox: Outbox) => outbox.resume(),
    },
    {
      name: 'Check Again',
      recover: (outbox: Outbox, id: string) => outbox.check(id),
    },
  ])(
    'defers $name while verification is unavailable or rejects and later checks Sent without resubmission',
    async ({ recover }) => {
      expect.hasAssertions();
      const phone = await offlineSender();
      let unsubscribe: (() => void) | undefined = undefined;
      try {
        const admitted = present(
          phone.drafts.getOutbox()[0],
          'admitted message',
        );
        const boundary = present(
          boundaryOf(admitted.message.segments),
          'MIME boundary',
        );
        // Conflicting Sent evidence retains the real accepted handoff as unknown.
        const other = phone.gmail.deliver({
          headers: {
            'Content-Type': `multipart/alternative; boundary="${boundary}"`,
          },
        });
        phone.gmail.label(other, 'SENT');
        phone.gmail.failSend({ lost: true });
        phone.setOnline(true);
        vi.setSystemTime(Date.now() + undoSendWindow);
        await phone.outbox.process();
        const unknown = present(phone.drafts.getOutbox()[0], 'unknown message');
        expect(unknown.state).toBe('unknown');
        expect(phone.gmail.sends).toHaveLength(1);

        // Registration loses verification while the existing ready Inbox stays cached.
        phone.setOnline(false);
        await phone.registration.resume();
        expect(
          mailboxesOf(phone.registration.getSnapshot().snapshot),
        ).toMatchObject([{ state: 'cached' }]);
        expect(phone.mailboxes.getConnections()[0]?.state).toMatchObject({
          kind: 'ready',
          organize: true,
        });
        const sentLists = () =>
          phone.gmail.requests.filter(
            ({ path, query }) =>
              // oxlint-disable-next-line vitest/no-conditional-in-test -- Count only Sent-list provider requests for the lookup assertion.
              path === 'messages' && query.get('labelIds') === 'SENT',
          ).length;
        const before = sentLists();
        expect(before).toBe(1);
        phone.setOnline(true);
        phone.verification.unavailable = true;
        await expect(phone.registration.resume()).resolves.toBeUndefined();
        expect(phone.registration.getSnapshot().failed).toBe(true);
        expect(
          mailboxesOf(phone.registration.getSnapshot().snapshot),
        ).toMatchObject([{ state: 'cached' }]);
        const { opens } = phone.requests;
        await recover(phone.outbox, phone.id);
        expect(phone.requests.opens).toBe(opens);
        expect(sentLists()).toBe(before);
        expect(phone.drafts.getOutbox()).toStrictEqual([unknown]);
        expect(phone.outbox.getSnapshot()).toMatchObject([
          { id: phone.id, state: 'unknown', check: 'idle' },
        ]);
        expect(
          outboxCopy(
            english,
            present(phone.outbox.getSnapshot()[0], 'deferred message'),
            'gmail',
          ).unconfirmed,
        ).toBeUndefined();
        const { refreshes } = phone.synthetic.google;
        await vi.advanceTimersByTimeAsync(60_000);
        expect(phone.synthetic.google.refreshes).toBe(refreshes);
        expect(sentLists()).toBe(before);
        expect(phone.requests.submissions).toBe(1);
        phone.verification.unavailable = false;
        let rejections = 0;
        unsubscribe = phone.registration.subscribe(() => {
          rejections += 1;
          throw new Error('Synthetic registration listener defect');
        });
        phone.setOnline(true);

        await recover(phone.outbox, phone.id);

        expect(rejections).toBe(1);
        expect(sentLists()).toBe(before);
        expect(phone.drafts.getOutbox()).toStrictEqual([unknown]);
        expect(phone.outbox.getSnapshot()).toMatchObject([
          { id: phone.id, state: 'unknown', check: 'idle' },
        ]);
        expect(
          outboxCopy(
            english,
            present(phone.outbox.getSnapshot()[0], 'deferred message'),
            'gmail',
          ).unconfirmed,
        ).toBeUndefined();
        await vi.advanceTimersByTimeAsync(60_000);
        expect(rejections).toBe(1);
        expect(sentLists()).toBe(before);
        expect(phone.gmail.sends).toHaveLength(1);

        unsubscribe();
        phone.gmail.setLabel(other, 'SENT', false);
        await expect(phone.outbox.check(phone.id)).resolves.toBe(true);
        expect(sentLists()).toBe(before + 1);
        expect(phone.drafts.getOutbox()).toStrictEqual([]);
        expect(phone.outbox.getSnapshot()).toStrictEqual([]);
        expect(phone.gmail.sends).toHaveLength(1);
      } finally {
        unsubscribe?.();
        phone.outbox.dispose();
      }
    },
  );
});
