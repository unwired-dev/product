/* oxlint-disable vitest/max-expects -- Delivery journeys verify durable state, mailbox recovery and provider copies together. */
import { createDrafts, draftOf } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { createOutbox, undoSendWindow } from '@private-email/mail-core/outbox';
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
  let verified = false;
  let beforeVerification: (() => Promise<void>) | undefined = undefined;
  const registration = createRegistration({
    ...synthetic.vault,
    forgetMailboxAccess: async () => {
      verified = false;
      return synthetic.vault.forgetMailboxAccess();
    },
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
          openMailbox: async () => ({
            ...(await gmail.native.openMailbox()),
            ...(verified ? {} : { availability: 'retry' }),
          }),
          gmailSend: (message, scope) =>
            verified
              ? gmail.native.gmailSend(message, scope)
              : Promise.reject(
                  Object.assign(new Error('Synthetic unverified mailbox'), {
                    code: 'unavailable',
                  }),
                ),
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
  const outbox = createOutbox({
    drafts,
    mailboxes,
    registration,
    claims: storage.delivery,
  });
  const setOnline = (online: boolean) => {
    synthetic.backend.offline = !online;
    server.setReachable(online);
  };
  setOnline(false);
  await registration.resume();
  await mailboxes.load();
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
  return {
    id,
    drafts,
    mailboxes,
    outbox,
    gmail,
    registration,
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
});
