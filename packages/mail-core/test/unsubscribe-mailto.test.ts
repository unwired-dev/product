import PostalMime from 'postal-mime';

import type { MailtoUnsubscribe } from '../src/outbox.ts';
import type { RegistrationSnapshot } from '../src/registration.ts';

import { createMailboxes } from '../src/mailboxes.ts';
import {
  createOutbox,
  pendingUnsubscribe,
  undoSendWindow,
} from '../src/outbox.ts';
import { createSyntheticProductSync } from '../src/testing/drafts.ts';
import { syntheticConnections } from '../src/testing/gmail-mailbox.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';
import { createSyntheticGraph } from '../src/testing/graph-mailbox.ts';
import { createSyntheticImap } from '../src/testing/imap-mailbox.ts';
import { createUnsubscribe } from '../src/unsubscribe.ts';
import { device, present } from './draft-sync-fixture.ts';
import { account } from './outbox-fixture.ts';

// The receiving Mailbox Connection of each provider.
const receiving = {
  gmail: { id: 'connection-gmail', address: 'alex@gmail.example.invalid' },
  graph: { id: 'connection-graph', address: 'casey@contoso.example.invalid' },
  imap: { id: 'connection-imap', address: 'alex@work.example.invalid' },
};
type Provider = keyof typeof receiving;

const offer = {
  kind: 'mailto',
  list: 'Alza.cz newsletter',
  address: 'leave@lists.alza.example',
  // A run of spaces may be part of the list's command.
  subject: 'unsubscribe  42',
  body: 'Please remove me.\r\nList 42',
} as const;

// The message that offered the request.
const source = '7.INBOX';

const listed = (provider: Provider, state: string, smtp: boolean) => ({
  ...receiving[provider],
  provider: provider === 'graph' ? 'microsoft-graph' : provider,
  state,
  ...(provider === 'imap'
    ? {
        imap: {
          host: 'imap.example.invalid',
          port: 993,
          username: receiving.imap.address,
        },
        ...(smtp
          ? {
              smtp: {
                host: 'smtp.example.invalid',
                port: 465,
                security: 'tls',
                username: receiving.imap.address,
              },
            }
          : {}),
      }
    : {}),
});

// A device whose only mailbox is `provider`'s receiving connection.
async function receiver(provider: Provider, state = 'connected', smtp = true) {
  const server = createSyntheticProductSync();
  const phone = await device(server, account, 'phone');
  const snapshot = (now: string): RegistrationSnapshot => ({
    kind: 'connected',
    productAccountId: account,
    signInProvider: 'apple',
    mailboxes: JSON.stringify([listed(provider, now, smtp)]),
  });
  phone.change(snapshot(state));
  const gmail = createSyntheticGmail();
  const graph = createSyntheticGraph({ address: receiving.graph.address });
  const imap = createSyntheticImap({ address: receiving.imap.address });
  imap.addFolder('Sent', ['sent']);
  const mailboxes = createMailboxes(
    syntheticConnections(
      { [receiving.gmail.id]: gmail, [receiving.graph.id]: graph },
      { [receiving.imap.id]: imap.native },
    ),
    phone.registration,
  );
  await mailboxes.load();
  // The device's sent unsubscribe requests, kept in memory as native storage would; a commit
  // finishes once `hold` resolves.
  const kept = {
    revision: 0,
    document: null as string | null,
    hold: Promise.resolve(),
  };
  const unsubscribe = createUnsubscribe(
    {
      requestUnsubscribe: async () => ({ outcome: 'failed' }),
      openUnsubscribeRequests: async () => ({
        owner: account,
        revision: kept.revision,
        document: kept.document,
      }),
      commitUnsubscribeRequests: async (owner, expectedRevision, document) => {
        await kept.hold;
        Object.assign(kept, { revision: expectedRevision + 1, document });
        return { owner, revision: kept.revision };
      },
    },
    phone.registration,
  );
  const outbox = createOutbox({
    drafts: phone.drafts,
    mailboxes,
    registration: phone.registration,
    claims: phone.storage.delivery,
    requests: unsubscribe,
  });
  // Every message the provider took, as raw text, and the copies its Sent mailbox holds.
  const sent = () =>
    ({
      gmail: gmail.sends.map(({ raw }) => raw),
      graph: graph.sends.map(({ raw }) => raw),
      imap: imap.smtp.accepted.map(({ raw }) => raw),
    })[provider];
  const filed = () =>
    ({
      gmail: gmail.sends.length,
      graph: graph.sends.length,
      imap: imap.server.changes.filter((change) => change === 'append Sent')
        .length,
    })[provider];
  // The receiving connection moves to state `now`.
  const become = (now: string) => {
    phone.change(snapshot(now));
  };
  return {
    ...phone,
    server,
    gmail,
    outbox,
    sent,
    filed,
    become,
    kept,
    unsubscribe,
  };
}

// The Outbox identifier of a request waiting out the Undo Send Window.
const waitingId = (result: MailtoUnsubscribe) => {
  if (result.kind !== 'waiting') {
    throw new Error(`The request was not admitted: ${result.kind}`);
  }
  return result.id;
};

const clock = { now: 0 };
const later = (milliseconds: number) => {
  clock.now += milliseconds;
  vi.setSystemTime(clock.now);
};

describe('a mailto unsubscribe request', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'] });
    clock.now = Date.UTC(2026, 10, 25, 12);
    vi.setSystemTime(clock.now);
  });
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it.each(['gmail', 'graph', 'imap'] as const)(
    'sends one message from the receiving %s connection after the Undo Send Window, into Sent',
    async (provider) => {
      expect.hasAssertions();
      const logged = vi.spyOn(console, 'log');
      const errors = vi.spyOn(console, 'error');
      const phone = await receiver(provider);
      try {
        const admitted = await phone.outbox.unsubscribe(
          receiving[provider].id,
          offer,
          source,
        );
        expect(admitted).toStrictEqual({
          kind: 'waiting',
          id: expect.any(String),
        });
        // It waits in the Outbox as an ordinary message and never becomes a Draft.
        expect(phone.drafts.getOutbox()).toMatchObject([
          {
            sendAt: clock.now + undoSendWindow,
            state: 'waiting',
            unsubscribe: {
              account,
              profile: 'default',
              list: offer.list,
              message: source,
            },
          },
        ]);
        expect(phone.list()).toStrictEqual([]);
        later(undoSendWindow - 1);
        await phone.outbox.process();
        expect(phone.sent()).toStrictEqual([]);

        later(1);
        await phone.outbox.process();

        const [raw, ...others] = phone.sent();
        const message = await PostalMime.parse(present(raw, 'a sent message'));
        const output = [...logged.mock.calls, ...errors.mock.calls]
          .flat()
          .map(String)
          .join('\n');
        expect({
          others,
          from: message.from?.address,
          to: message.to?.map(({ address }) => address),
          cc: message.cc,
          bcc: message.bcc,
          subject: message.subject,
          text: message.text?.trim(),
          filed: phone.filed(),
          outbox: phone.drafts.getOutbox(),
          drafts: phone.list(),
          // Nothing logs the request; Convex hears only the claim's identifier.
          logged: /leave@|unsubscribe\s+42|remove me/u.test(output),
          claims: [...phone.server.claimsOf(account)],
        }).toStrictEqual({
          others: [],
          from: receiving[provider].address,
          to: [offer.address],
          cc: undefined,
          bcc: undefined,
          subject: offer.subject,
          text: 'Please remove me.\nList 42',
          filed: 1,
          outbox: [],
          drafts: [],
          logged: false,
          claims: [[`draft-delivery.${waitingId(admitted)}`, 'phone']],
        });
      } finally {
        phone.outbox.dispose();
      }
    },
  );

  it('leaves the Outbox at Undo without becoming a Draft, and sends nothing', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const admitted = await phone.outbox.unsubscribe(
        receiving.gmail.id,
        offer,
        source,
      );
      const id = waitingId(admitted);
      await expect(phone.outbox.undo(id, 'waiting')).resolves.toBe(id);
      later(undoSendWindow);
      await phone.outbox.process();
      expect({
        outbox: phone.drafts.getOutbox(),
        drafts: phone.list(),
        sent: phone.sent(),
      }).toStrictEqual({ outbox: [], drafts: [], sent: [] });
    } finally {
      phone.outbox.dispose();
    }
  });

  it('admits one request when the same list is confirmed twice at once', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const [first, second] = await Promise.all([
        phone.outbox.unsubscribe(receiving.gmail.id, offer, source),
        phone.outbox.unsubscribe(receiving.gmail.id, offer, source),
      ]);
      expect({
        same: waitingId(first) === waitingId(second),
        outbox: phone.drafts.getOutbox().length,
      }).toStrictEqual({ same: true, outbox: 1 });
    } finally {
      phone.outbox.dispose();
    }
  });

  it('only leaves the Outbox at Edit after its connection needs authorization before handoff', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const admitted = await phone.outbox.unsubscribe(
        receiving.gmail.id,
        offer,
        source,
      );
      const id = waitingId(admitted);
      phone.become('authorization');
      later(undoSendWindow);
      await phone.outbox.process();
      expect(phone.drafts.getOutbox()).toMatchObject([
        {
          id,
          state: 'failed',
          problem: 'authorization',
          unsubscribe: {
            account,
            profile: 'default',
            list: offer.list,
            message: source,
          },
        },
      ]);
      await expect(phone.outbox.undo(id)).resolves.toBe(id);
      expect({
        outbox: phone.drafts.getOutbox(),
        drafts: phone.list(),
        sent: phone.sent(),
      }).toStrictEqual({ outbox: [], drafts: [], sent: [] });
    } finally {
      phone.outbox.dispose();
    }
  });

  it.each([
    { provider: 'imap', state: 'connected', smtp: false, kind: 'receive-only' },
    {
      provider: 'imap',
      state: 'authorization',
      smtp: true,
      kind: 'authorization',
    },
    {
      provider: 'graph',
      state: 'authorization',
      smtp: true,
      kind: 'authorization',
    },
    {
      provider: 'gmail',
      state: 'authorization',
      smtp: true,
      kind: 'authorization',
    },
  ] as const)(
    'sends nothing from a $state $provider connection that cannot send, and says why: $kind',
    async ({ provider, state, smtp, kind }) => {
      expect.hasAssertions();
      const phone = await receiver(provider, state, smtp);
      try {
        await expect(
          phone.outbox.unsubscribe(receiving[provider].id, offer, source),
        ).resolves.toStrictEqual({ kind });
        later(undoSendWindow);
        await phone.outbox.process();
        expect({
          outbox: phone.drafts.getOutbox(),
          sent: phone.sent(),
        }).toStrictEqual({ outbox: [], sent: [] });
      } finally {
        phone.outbox.dispose();
      }
    },
  );

  it('fails without admitting anything for a connection that is gone', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      await expect(
        phone.outbox.unsubscribe('connection-removed', offer, source),
      ).resolves.toStrictEqual({ kind: 'failed' });
      expect(phone.drafts.getOutbox()).toStrictEqual([]);
    } finally {
      phone.outbox.dispose();
    }
  });
});

describe('recording a mailto unsubscribe request', () => {
  const listed = { ...offer, identity: 'newsletter.alza.example' };
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'] });
    clock.now = Date.UTC(2026, 10, 25, 12);
    vi.setSystemTime(clock.now);
  });
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  afterEach(() => {
    vi.useRealTimers();
  });

  // Admits the request from `provider`'s receiving connection, which then waits in the Outbox.
  const start = async (
    phone: Awaited<ReturnType<typeof receiver>>,
    provider: Provider = 'gmail',
  ) =>
    waitingId(
      await phone.outbox.unsubscribe(receiving[provider].id, listed, source),
    );
  // The request the Outbox holds for the receiving connection, as the reader finds it.
  const pending = (
    phone: Awaited<ReturnType<typeof receiver>>,
    provider: Provider = 'gmail',
  ) =>
    pendingUnsubscribe(phone.outbox.getSnapshot(), receiving[provider].id, {
      ...listed,
      message: source,
    });

  // The Mail Profile a waiting request is recorded for.
  const profileOf = (entry: ReturnType<typeof pending>) => {
    const profile = entry?.unsubscribe?.profile;
    if (profile === undefined) {
      throw new Error('No unsubscribe request waits in the Outbox');
    }
    return profile;
  };

  it.each(['gmail', 'imap'] as const)(
    'records a %s request for its Profile once it is confirmed, as it leaves the Outbox',
    async (provider) => {
      expect.hasAssertions();
      const phone = await receiver(provider);
      try {
        const id = await start(phone, provider);
        const profile = profileOf(pending(phone, provider));
        later(undoSendWindow);
        await phone.outbox.process();

        await vi.waitFor(() => {
          expect(phone.outbox.delivered(id)).toStrictEqual({
            at: clock.now,
            to: listed.address,
          });
        });
        expect(pending(phone, provider)).toBeUndefined();
        await expect(
          phone.unsubscribe.sentRequest(profile, listed, clock.now),
        ).resolves.toStrictEqual({
          profile,
          identity: listed.identity,
          list: listed.list,
          sentAt: clock.now,
          to: listed.address,
        });
      } finally {
        phone.outbox.dispose();
      }
    },
  );

  it('keeps another list’s request at the same address, or another message’s without a list identity, apart', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      await start(phone);
      await phone.outbox.unsubscribe(receiving.gmail.id, offer, source);
      const find = (each: Readonly<{ identity?: string; message: string }>) =>
        pendingUnsubscribe(phone.outbox.getSnapshot(), receiving.gmail.id, each)
          ?.unsubscribe;

      expect({
        listed: find({ identity: listed.identity, message: 'other' }),
        otherList: find({ identity: 'deals.alza.example', message: source }),
        unlisted: find({ message: source }),
        otherMessage: find({ message: 'other' }),
      }).toStrictEqual({
        listed: expect.objectContaining({ identity: listed.identity }),
        otherList: undefined,
        unlisted: expect.not.objectContaining({ identity: expect.anything() }),
        otherMessage: undefined,
      });
    } finally {
      phone.outbox.dispose();
    }
  });

  it('records a confirmed request only for the Product Account that sent it', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      await phone.unsubscribe.record('another-product-account', {
        profile: 'default',
        identity: listed.identity,
        list: listed.list,
        sentAt: clock.now,
      });
      expect(phone.kept.document).toBeNull();
    } finally {
      phone.outbox.dispose();
    }
  });

  it('records nothing at Undo', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const id = await start(phone);
      expect(pending(phone)?.id).toBe(id);
      await phone.outbox.undo(id, 'waiting');

      expect({
        pending: pending(phone),
        document: phone.kept.document,
      }).toStrictEqual({
        pending: undefined,
        document: null,
      });
    } finally {
      phone.outbox.dispose();
    }
  });

  it('keeps a refusal in the Outbox, saying when sign-in is needed, and records nothing', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      await start(phone);
      phone.become('authorization');
      later(undoSendWindow);
      await phone.outbox.process();

      expect({
        pending: pending(phone),
        document: phone.kept.document,
      }).toMatchObject({
        pending: { state: 'failed', problem: 'authorization' },
        document: null,
      });
    } finally {
      phone.outbox.dispose();
    }
  });

  it('tries a refused request again as confirmed, though another message of the list offers another address', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const refused = await start(phone);
      phone.become('authorization');
      later(undoSendWindow);
      await phone.outbox.process();
      phone.become('connected');
      const retried = waitingId(
        await phone.outbox.unsubscribe(
          receiving.gmail.id,
          { ...listed, address: 'other@lists.alza.example', subject: 'stop' },
          'later.INBOX',
        ),
      );

      expect(
        phone.drafts.getOutbox().map(({ id, draft }) => ({
          retry: id === retried,
          to: draft.to,
          subject: draft.subject,
        })),
      ).toStrictEqual([
        {
          retry: true,
          to: [{ address: listed.address }],
          subject: listed.subject,
        },
      ]);
      expect(retried).not.toBe(refused);
    } finally {
      phone.outbox.dispose();
    }
  });

  it('records an unknown delivery once Check Again finds it sent', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const id = await start(phone);
      const profile = profileOf(pending(phone));
      phone.gmail.failSend({ lost: true });
      later(undoSendWindow);
      await phone.outbox.process();
      expect(pending(phone)?.state).toBe('unknown');

      await phone.outbox.check(id);

      await vi.waitFor(() => {
        expect(pending(phone)).toBeUndefined();
      });
      await expect(
        phone.unsubscribe.sentRequest(profile, listed, clock.now),
      ).resolves.toMatchObject({ sentAt: clock.now });
    } finally {
      phone.outbox.dispose();
    }
  });

  // Leaves the request from Gmail unknown: Gmail took it, but its answer was lost.
  const lose = async (phone: Awaited<ReturnType<typeof receiver>>) => {
    const id = await start(phone);
    phone.gmail.failSend({ lost: true });
    later(undoSendWindow);
    await phone.outbox.process();
    expect(pending(phone)?.state).toBe('unknown');
    return id;
  };

  it('never sends a retry once the unknown request it tries again is found sent', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const id = await lose(phone);
      const retry = await start(phone);
      await phone.outbox.check(id);
      later(undoSendWindow);
      await phone.outbox.process();

      await vi.waitFor(() => {
        expect(phone.outbox.getSnapshot()).toStrictEqual([]);
      });
      expect(phone.gmail.sends).toHaveLength(1);
      expect(phone.outbox.delivered(retry)).toStrictEqual(
        phone.outbox.delivered(id),
      );
    } finally {
      phone.outbox.dispose();
    }
  });

  it('answers with an unknown request found sent while it is recorded, in place of trying it again', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const id = await lose(phone);
      const recorded = Promise.withResolvers<undefined>();
      phone.kept.hold = recorded.promise;
      const checked = phone.outbox.check(id);
      await vi.waitFor(() => {
        expect(phone.outbox.delivered(id)).toBeDefined();
      });

      await expect(start(phone)).resolves.toBe(id);
      recorded.resolve(undefined);
      await checked;
      await vi.waitFor(() => {
        expect(phone.outbox.getSnapshot()).toStrictEqual([]);
      });
      expect(phone.gmail.sends).toHaveLength(1);
    } finally {
      phone.outbox.dispose();
    }
  });

  it('answers for the message that offered a request without a list identity once it is sent', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      waitingId(
        await phone.outbox.unsubscribe(receiving.gmail.id, offer, source),
      );
      later(undoSendWindow);
      await phone.outbox.process();

      await vi.waitFor(() => {
        expect(
          phone.outbox.emailedUnsubscribe(receiving.gmail.id, source),
        ).toStrictEqual({ at: clock.now, to: offer.address });
      });
      expect(
        phone.outbox.emailedUnsubscribe(receiving.gmail.id, '8.INBOX'),
      ).toBeUndefined();
    } finally {
      phone.outbox.dispose();
    }
  });
});
