import PostalMime from 'postal-mime';

import type { MailtoUnsubscribe } from '../src/outbox.ts';
import type { RegistrationSnapshot } from '../src/registration.ts';
import type { MailtoProgress } from '../src/unsubscribe.ts';

import { createMailboxes } from '../src/mailboxes.ts';
import { createOutbox, undoSendWindow } from '../src/outbox.ts';
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
  const outbox = createOutbox({
    drafts: phone.drafts,
    mailboxes,
    registration: phone.registration,
    claims: phone.storage.delivery,
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
  return { ...phone, server, gmail, outbox, sent, filed, become };
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
            unsubscribe: true,
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

  it('only leaves the Outbox at Edit after its connection needs authorization before handoff', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const admitted = await phone.outbox.unsubscribe(
        receiving.gmail.id,
        offer,
      );
      const id = waitingId(admitted);
      phone.become('authorization');
      later(undoSendWindow);
      await phone.outbox.process();
      expect(phone.drafts.getOutbox()).toMatchObject([
        { id, state: 'failed', problem: 'authorization', unsubscribe: true },
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
          phone.outbox.unsubscribe(receiving[provider].id, offer),
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
        phone.outbox.unsubscribe('connection-removed', offer),
      ).resolves.toStrictEqual({ kind: 'failed' });
      expect(phone.drafts.getOutbox()).toStrictEqual([]);
    } finally {
      phone.outbox.dispose();
    }
  });
});

// The receiving device's unsubscribe store, keeping its sent requests in memory as native storage
// would for the signed-in account.
const recording = (phone: Awaited<ReturnType<typeof receiver>>) => {
  const kept = { revision: 0, document: null as string | null };
  return {
    kept,
    unsubscribe: createUnsubscribe(
      {
        requestUnsubscribe: async () => ({ outcome: 'failed' }),
        openUnsubscribeRequests: async () => ({ owner: account, ...kept }),
        commitUnsubscribeRequests: async (
          owner,
          expectedRevision,
          document,
        ) => {
          Object.assign(kept, { revision: expectedRevision + 1, document });
          return { owner, revision: kept.revision };
        },
      },
      phone.registration,
      phone.outbox,
    ),
  };
};

describe('following a mailto unsubscribe request', () => {
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

  // Starts the request, which resolves once it waits in the Outbox, with everything it reported.
  const start = async (phone: Awaited<ReturnType<typeof receiver>>) => {
    const store = recording(phone);
    const progress: MailtoProgress[] = [];
    await store.unsubscribe.email(
      { profile: 'work', connection: receiving.gmail.id, offer: listed },
      (each) => {
        progress.push(each);
      },
      () => clock.now,
    );
    const [admitted] = progress;
    return {
      ...store,
      progress,
      id: admitted?.kind === 'waiting' ? admitted.id : '',
    };
  };

  it('reports it waiting, then sent once delivered, and records it for the Profile', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const { unsubscribe, progress, id } = await start(phone);
      later(undoSendWindow);
      await phone.outbox.process();

      await vi.waitFor(() => {
        expect(progress).toStrictEqual([
          { kind: 'waiting', id },
          { kind: 'sent', at: clock.now },
        ]);
      });
      await expect(
        unsubscribe.sentRequest('work', listed, clock.now),
      ).resolves.toStrictEqual({
        profile: 'work',
        identity: listed.identity,
        list: listed.list,
        sentAt: clock.now,
      });
    } finally {
      phone.outbox.dispose();
    }
  });

  it('reports it undone at Undo and records nothing', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const { kept, progress, id } = await start(phone);
      await phone.outbox.undo(id, 'waiting');

      expect({ progress, document: kept.document }).toStrictEqual({
        progress: [{ kind: 'waiting', id }, { kind: 'undone' }],
        document: null,
      });
    } finally {
      phone.outbox.dispose();
    }
  });

  it('reports a refusal as failed, which leaving the Outbox keeps', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const { kept, progress, id } = await start(phone);
      phone.become('authorization');
      later(undoSendWindow);
      await phone.outbox.process();
      await phone.outbox.undo(id);

      expect({ progress, document: kept.document }).toStrictEqual({
        progress: [{ kind: 'waiting', id }, { kind: 'failed' }],
        document: null,
      });
    } finally {
      phone.outbox.dispose();
    }
  });

  it('reports an unknown delivery as uncertain, then sent once Check Again finds it', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const { unsubscribe, progress, id } = await start(phone);
      phone.gmail.failSend({ lost: true });
      later(undoSendWindow);
      await phone.outbox.process();
      expect(progress).toStrictEqual([
        { kind: 'waiting', id },
        { kind: 'uncertain' },
      ]);

      await phone.outbox.check(id);

      await vi.waitFor(() => {
        expect(progress.at(-1)).toStrictEqual({ kind: 'sent', at: clock.now });
      });
      await expect(
        unsubscribe.sentRequest('work', listed, clock.now),
      ).resolves.toMatchObject({ sentAt: clock.now });
    } finally {
      phone.outbox.dispose();
    }
  });

  it('reports why a connection that cannot send sends nothing', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail', 'authorization');
    try {
      const progress: MailtoProgress[] = [];
      await recording(phone).unsubscribe.email(
        { profile: 'work', connection: receiving.gmail.id, offer: listed },
        (each) => {
          progress.push(each);
        },
      );
      expect(progress).toStrictEqual([{ kind: 'authorization' }]);
    } finally {
      phone.outbox.dispose();
    }
  });
});
