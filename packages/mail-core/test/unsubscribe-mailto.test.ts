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
import {
  createUnsubscribe,
  unsubscribeOfferReturnsAfter,
} from '../src/unsubscribe.ts';
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
  // In `epoch`, the incarnation a connection added again lists.
  const snapshot = (now: string, epoch?: string): RegistrationSnapshot => ({
    kind: 'connected',
    productAccountId: account,
    signInProvider: 'apple',
    mailboxes: JSON.stringify([
      {
        ...listed(provider, now, smtp),
        ...(epoch === undefined ? {} : { epoch }),
      },
    ]),
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
  // finishes once `hold` resolves, and storage answers for `owner`.
  const kept = {
    revision: 0,
    document: null as string | null,
    hold: Promise.resolve(),
    owner: account,
  };
  const unsubscribe = createUnsubscribe(
    {
      requestUnsubscribe: async () => ({ outcome: 'failed' }),
      openUnsubscribeRequests: async () => ({
        owner: kept.owner,
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
  // `before` and `restoring` may answer 'refuse' to have storage refuse the step or removal.
  const stepping = {
    before: async (
      _id: string,
      _step: Parameters<typeof phone.drafts.deliver>[1],
    ) => undefined as unknown,
    restoring: async (_id: string) => undefined as unknown,
  };
  // The device's Outbox; `relaunch` opens it again over the same storage, as a new launch would.
  const relaunch = () =>
    createOutbox({
      // Each Outbox step waits for `stepping` first, as a competing writer would delay it.
      drafts: {
        ...phone.drafts,
        deliver: async (id, step) =>
          (await stepping.before(id, step)) === 'refuse'
            ? false
            : phone.drafts.deliver(id, step),
        restore: async (id, only) =>
          (await stepping.restoring(id)) === 'refuse'
            ? false
            : phone.drafts.restore(id, only),
      },
      mailboxes,
      registration: phone.registration,
      claims: phone.storage.delivery,
      requests: unsubscribe,
    });
  const outbox = relaunch();
  // A relaunch that also reopens the Drafts' storage, as a new process does.
  const reopen = async () => {
    await phone.relaunch();
    return relaunch();
  };
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
  const become = (now: string, epoch?: string) => {
    phone.change(snapshot(now, epoch));
  };
  return {
    ...phone,
    server,
    gmail,
    imap,
    outbox,
    sent,
    filed,
    become,
    kept,
    unsubscribe,
    stepping,
    relaunch,
    reopen,
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
          { message: source },
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
        { message: source },
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
        phone.outbox.unsubscribe(receiving.gmail.id, offer, {
          message: source,
        }),
        phone.outbox.unsubscribe(receiving.gmail.id, offer, {
          message: source,
        }),
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
        { message: source },
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
          phone.outbox.unsubscribe(receiving[provider].id, offer, {
            message: source,
          }),
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
        phone.outbox.unsubscribe('connection-removed', offer, {
          message: source,
        }),
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
    // The requests the reader showed for the message.
    retrying: readonly string[] = [],
  ) =>
    waitingId(
      await phone.outbox.unsubscribe(receiving[provider].id, listed, {
        message: source,
        retrying,
      }),
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
      await phone.outbox.unsubscribe(receiving.gmail.id, offer, {
        message: source,
      });
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
          { message: 'later.INBOX' },
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

  it('answers with an unknown request Check Again found sent before its retry was admitted', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const id = await lose(phone);
      await phone.outbox.check(id);
      await vi.waitFor(() => {
        expect(pending(phone)).toBeUndefined();
      });

      await expect(start(phone, 'gmail', [id])).resolves.toBe(id);
      expect(phone.outbox.getSnapshot()).toStrictEqual([]);
      expect(phone.gmail.sends).toHaveLength(1);
    } finally {
      phone.outbox.dispose();
    }
  });

  it('never sends a retry once the unknown request found sent, though a retry between them was refused', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const id = await lose(phone);
      await start(phone);
      phone.become('authorization');
      later(undoSendWindow);
      await phone.outbox.process();
      expect(pending(phone)?.state).toBe('failed');
      phone.become('connected');
      const retry = await start(phone);
      await phone.outbox.check(id);
      later(undoSendWindow);
      await phone.outbox.process();

      await vi.waitFor(() => {
        expect(pending(phone)).toBeUndefined();
      });
      expect(phone.gmail.sends).toHaveLength(1);
      expect(phone.outbox.delivered(retry)).toStrictEqual(
        phone.outbox.delivered(id),
      );
    } finally {
      phone.outbox.dispose();
    }
  });

  it.each(['gmail', 'imap'] as const)(
    'keeps a confirmed request from %s in the Outbox until storage records it, without sending it again',
    async (provider) => {
      expect.hasAssertions();
      const phone = await receiver(provider);
      try {
        const id = await start(phone, provider);
        const profile = profileOf(pending(phone, provider));
        phone.kept.owner = 'another-product-account';
        later(undoSendWindow);
        await phone.outbox.process();
        const confirmedAt = clock.now;
        await vi.waitFor(() => {
          expect(pending(phone, provider)?.unsubscribe?.sentAt).toBe(
            confirmedAt,
          );
        });
        expect(phone.outbox.delivered(id)).toMatchObject({ at: confirmedAt });

        later(86_400_000);
        phone.kept.owner = account;
        await phone.outbox.process();
        await vi.waitFor(() => {
          expect(pending(phone, provider)).toBeUndefined();
        });
        await expect(
          phone.unsubscribe.sentRequest(profile, listed, clock.now),
        ).resolves.toMatchObject({ sentAt: confirmedAt, to: listed.address });
        expect([phone.sent().length, phone.filed()]).toStrictEqual([1, 1]);
      } finally {
        phone.outbox.dispose();
      }
    },
  );

  it('never files the Sent copy again for a confirmed IMAP request whose record waited, though the copy was deleted meanwhile', async () => {
    expect.hasAssertions();
    const phone = await receiver('imap');
    try {
      await start(phone, 'imap');
      phone.kept.owner = 'another-product-account';
      later(undoSendWindow);
      await phone.outbox.process();
      await vi.waitFor(() => {
        expect(pending(phone, 'imap')?.unsubscribe?.sentAt).toBeDefined();
      });
      phone.imap.expunge('Sent', 1);

      phone.kept.owner = account;
      await phone.outbox.process();
      await vi.waitFor(() => {
        expect(phone.outbox.getSnapshot()).toStrictEqual([]);
      });
      expect([phone.sent().length, phone.filed()]).toStrictEqual([1, 1]);
    } finally {
      phone.outbox.dispose();
    }
  });

  // Storage refuses once the step that would take a request out of the Outbox as sent, and with
  // `checkpoint`, once the step that keeps when its filed copy was confirmed.
  const refuseLeavingOnce = (
    phone: Awaited<ReturnType<typeof receiver>>,
    checkpoint = false,
  ) => {
    const refused = { done: false, checkpoint: !checkpoint };
    phone.stepping.before = async (id, step) => {
      const entry = phone.drafts.getOutbox().find((each) => each.id === id);
      const next = entry === undefined ? undefined : step(entry);
      if (next === undefined) {
        return undefined;
      }
      if (!('state' in next)) {
        const leaving = !refused.done;
        refused.done = true;
        return leaving ? 'refuse' : undefined;
      }
      const keeping =
        !refused.checkpoint &&
        entry?.unsubscribe?.sentAt === undefined &&
        next.unsubscribe?.sentAt !== undefined;
      refused.checkpoint ||= keeping;
      return keeping ? 'refuse' : undefined;
    };
    return refused;
  };

  it.each([false, true])(
    'never files the Sent copy again for a confirmed IMAP request whose leaving storage refused, though the copy was deleted before a relaunch (its filed time refused too: %s)',
    async (checkpoint) => {
      expect.hasAssertions();
      const phone = await receiver('imap');
      const id = await start(phone, 'imap');
      const refused = refuseLeavingOnce(phone, checkpoint);
      later(undoSendWindow);
      await vi.waitFor(async () => {
        await phone.outbox.process();
        expect(refused).toStrictEqual({ done: true, checkpoint: true });
      });
      expect(phone.outbox.getSnapshot()).toMatchObject([{ id }]);
      phone.imap.expunge('Sent', 1);
      phone.outbox.dispose();

      const relaunched = phone.relaunch();
      try {
        await relaunched.process();
        await vi.waitFor(() => {
          expect(relaunched.getSnapshot()).toStrictEqual([]);
        });
        expect([phone.sent().length, phone.filed()]).toStrictEqual([1, 1]);
      } finally {
        relaunched.dispose();
      }
    },
  );

  it('records a confirmed Gmail request whose leaving storage refused after a relaunch, never asking whether it was sent', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    const id = await start(phone);
    const refused = refuseLeavingOnce(phone);
    later(undoSendWindow);
    await phone.outbox.process();
    await vi.waitFor(() => {
      expect(refused.done).toBe(true);
    });
    expect(pending(phone)?.unsubscribe?.sentAt).toBe(clock.now);
    phone.outbox.dispose();

    const relaunched = await phone.reopen();
    try {
      expect(relaunched.getSnapshot()).toMatchObject([
        { id, state: 'sending' },
      ]);
      await relaunched.process();
      await vi.waitFor(() => {
        expect(relaunched.getSnapshot()).toStrictEqual([]);
      });
      expect(phone.sent()).toHaveLength(1);
    } finally {
      relaunched.dispose();
    }
  });

  it('records a confirmed IMAP request whose record waited after a relaunch that cannot reach its mailbox, and answers for it with its recipient', async () => {
    expect.hasAssertions();
    const phone = await receiver('imap');
    const id = await start(phone, 'imap');
    phone.kept.owner = 'another-product-account';
    later(undoSendWindow);
    await phone.outbox.process();
    const confirmedAt = clock.now;
    await vi.waitFor(() => {
      expect(pending(phone, 'imap')?.unsubscribe?.sentAt).toBe(confirmedAt);
    });
    phone.outbox.dispose();

    phone.become('cached');
    const relaunched = phone.relaunch();
    try {
      expect(relaunched.delivered(id)).toStrictEqual({
        at: confirmedAt,
        to: offer.address,
      });
      phone.kept.owner = account;
      await relaunched.process();
      await vi.waitFor(() => {
        expect(relaunched.getSnapshot()).toStrictEqual([]);
      });
      expect([phone.sent().length, phone.filed()]).toStrictEqual([1, 1]);
    } finally {
      relaunched.dispose();
    }
  });

  it.each([
    { refused: 'record', owner: 'another-product-account' },
    { refused: 'leaving', owner: account },
  ])(
    'offers a request again to a message the list sent more than 14 days after a confirmed one whose $refused storage refused, and keeps the first for its own message',
    async ({ refused, owner }) => {
      expect.hasAssertions();
      const phone = await receiver('gmail');
      try {
        const id = await start(phone);
        const leaving = refuseLeavingOnce(phone);
        phone.kept.owner = owner;
        later(undoSendWindow);
        await phone.outbox.process();
        const confirmedAt = clock.now;
        await vi.waitFor(() => {
          expect(pending(phone)?.unsubscribe?.sentAt).toBe(confirmedAt);
        });
        expect(leaving.done).toBe(refused === 'leaving');
        const held = (message: string, receivedAt?: number) =>
          pendingUnsubscribe(phone.outbox.getSnapshot(), receiving.gmail.id, {
            ...listed,
            message,
            receivedAt,
          });
        expect([
          held('9.INBOX', confirmedAt + unsubscribeOfferReturnsAfter)?.id,
          held('9.INBOX')?.id,
        ]).toStrictEqual([id, undefined]);

        later(unsubscribeOfferReturnsAfter + 1);
        expect(held('9.INBOX', clock.now)).toBeUndefined();
        const again = waitingId(
          await phone.outbox.unsubscribe(receiving.gmail.id, listed, {
            message: '9.INBOX',
            receivedAt: clock.now,
          }),
        );
        expect([
          held('9.INBOX', clock.now)?.id,
          held(source, confirmedAt)?.id,
        ]).toStrictEqual([again, id]);
      } finally {
        phone.outbox.dispose();
      }
    },
  );

  it('answers for a confirmed IMAP request as soon as its copy is filed, while storage refuses its confirmed time', async () => {
    expect.hasAssertions();
    const phone = await receiver('imap');
    try {
      const id = await start(phone, 'imap');
      const refused = refuseLeavingOnce(phone, true);
      later(undoSendWindow);
      await phone.outbox.process();
      await vi.waitFor(() => {
        expect(refused.checkpoint).toBe(true);
      });
      expect(phone.outbox.delivered(id)).toStrictEqual({
        at: clock.now,
        to: offer.address,
      });
    } finally {
      phone.outbox.dispose();
    }
  });

  it('never tries a request again for a connection added again since, whose message offers another address', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const old = await start(phone);
      phone.become('connected', 'added-again');
      later(undoSendWindow);
      await phone.outbox.process();
      expect(pending(phone)?.state).toBe('failed');
      const current = { ...listed, message: source, epoch: 'added-again' };
      expect(
        pendingUnsubscribe(
          phone.outbox.getSnapshot(),
          receiving.gmail.id,
          current,
        ),
      ).toBeUndefined();
      // A retry confirmed for the earlier incarnation, as a sign-in finishing meanwhile sends it.
      await expect(
        phone.outbox.unsubscribe(receiving.gmail.id, listed, {
          message: source,
          retrying: [old],
          epoch: 'legacy',
        }),
      ).resolves.toStrictEqual({ kind: 'failed' });

      const fresh = waitingId(
        await phone.outbox.unsubscribe(
          receiving.gmail.id,
          { ...listed, address: 'other@lists.alza.example' },
          { message: source, retrying: [old] },
        ),
      );
      expect(fresh).not.toBe(old);
      expect(
        pendingUnsubscribe(
          phone.outbox.getSnapshot(),
          receiving.gmail.id,
          current,
        )?.draft.to,
      ).toStrictEqual([{ address: 'other@lists.alza.example' }]);
    } finally {
      phone.outbox.dispose();
    }
  });

  // Before the Outbox marks `retry` sending, another writer of the same Drafts records `original`
  // as sent, as another window's Check Again would.
  const confirmDuring = (
    phone: Awaited<ReturnType<typeof receiver>>,
    { retry, original }: Readonly<{ retry: string; original: string }>,
  ) => {
    const confirmed = { done: false };
    phone.stepping.before = async (id, step) => {
      const entry = phone.drafts.getOutbox().find((each) => each.id === id);
      const next = entry === undefined ? undefined : step(entry);
      if (
        confirmed.done ||
        id !== retry ||
        next === undefined ||
        !('state' in next) ||
        next.state !== 'sending'
      ) {
        return;
      }
      confirmed.done = true;
      await phone.drafts.deliver(original, () => ({
        id: original,
        sentAt: clock.now,
      }));
    };
    return confirmed;
  };

  it('never sends a retry whose unknown request is found sent while it is marked sending', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const original = await lose(phone);
      const retry = await start(phone);
      const confirmed = confirmDuring(phone, { retry, original });
      later(undoSendWindow);
      await phone.outbox.process();

      await vi.waitFor(() => {
        expect(pending(phone)).toBeUndefined();
      });
      expect(confirmed.done).toBe(true);
      expect(phone.gmail.sends).toHaveLength(1);
      expect(phone.outbox.delivered(retry)).toStrictEqual({ at: clock.now });
    } finally {
      phone.outbox.dispose();
    }
  });

  it('offers a request again to a message the list sent after a confirmed retry, with its own recipient', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const id = await lose(phone);
      const retry = await start(phone);
      later(undoSendWindow);
      await phone.outbox.process();
      await vi.waitFor(() => {
        expect(phone.outbox.delivered(retry)).toBeDefined();
      });
      expect(phone.outbox.getSnapshot()).toMatchObject([
        { id, state: 'unknown', unsubscribe: { answered: true } },
      ]);
      expect(pending(phone)).toBeUndefined();

      later(15 * 86_400_000);
      const fresh = waitingId(
        await phone.outbox.unsubscribe(
          receiving.gmail.id,
          { ...listed, address: 'other@lists.alza.example', subject: 'stop' },
          { message: '9.INBOX' },
        ),
      );
      expect([fresh === id, fresh === retry]).toStrictEqual([false, false]);
      expect(pending(phone)?.draft).toMatchObject({
        to: [{ address: 'other@lists.alza.example' }],
        subject: 'stop',
      });
    } finally {
      phone.outbox.dispose();
    }
  });

  // Storage refuses to take `id` out of the Outbox.
  const refuseRemoving = (
    phone: Awaited<ReturnType<typeof receiver>>,
    refused: string,
  ) => {
    phone.stepping.restoring = async (id) =>
      id === refused ? 'refuse' : undefined;
  };
  // Storage refuses to mark `original` answered.
  const refuseAnswered = (
    phone: Awaited<ReturnType<typeof receiver>>,
    original: string,
  ) => {
    phone.stepping.before = async (id, step) => {
      const entry = phone.drafts.getOutbox().find((each) => each.id === id);
      const next = entry === undefined ? undefined : step(entry);
      return id === original &&
        next !== undefined &&
        'unsubscribe' in next &&
        next.unsubscribe?.answered === true
        ? 'refuse'
        : undefined;
    };
  };

  it('keeps a confirmed retry in the Outbox until the unknown request it tries again is marked answered', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const original = await lose(phone);
      const retry = await start(phone);
      refuseAnswered(phone, original);
      later(undoSendWindow);
      await phone.outbox.process();
      await vi.waitFor(() => {
        expect(phone.outbox.delivered(retry)).toBeDefined();
      });
      expect(phone.outbox.getSnapshot().map(({ id }) => id)).toStrictEqual([
        original,
        retry,
      ]);

      phone.stepping.before = async () => undefined;
      await phone.outbox.process();
      await vi.waitFor(() => {
        expect(phone.outbox.getSnapshot()).toMatchObject([
          { id: original, unsubscribe: { answered: true } },
        ]);
      });
      // The lost original and the retry, never the retry again.
      expect(phone.gmail.sends).toHaveLength(2);
    } finally {
      phone.outbox.dispose();
    }
  });

  it('keeps the list’s 14 days from a confirmed retry when Check Again later finds the unknown request sent', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const original = await lose(phone);
      const profile = profileOf(pending(phone));
      const retry = await start(phone);
      later(undoSendWindow);
      await phone.outbox.process();
      await vi.waitFor(() => {
        expect(phone.outbox.delivered(retry)).toBeDefined();
      });

      later(15 * 86_400_000);
      await phone.outbox.check(original);
      await vi.waitFor(() => {
        expect(phone.outbox.getSnapshot()).toStrictEqual([]);
      });
      await expect(
        phone.unsubscribe.sentRequest(profile, listed, clock.now),
      ).resolves.toBeUndefined();
    } finally {
      phone.outbox.dispose();
    }
  });

  it('keeps the list’s 14 days from a confirmed retry whose answered mark storage refused when Check Again finds the unknown request sent', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const original = await lose(phone);
      const profile = profileOf(pending(phone));
      const retry = await start(phone);
      refuseAnswered(phone, original);
      later(undoSendWindow);
      await phone.outbox.process();
      await vi.waitFor(() => {
        expect(phone.outbox.delivered(retry)).toBeDefined();
      });

      later(15 * 86_400_000);
      await phone.outbox.check(original);
      await vi.waitFor(() => {
        expect(phone.outbox.getSnapshot()).toStrictEqual([]);
      });
      await expect(
        phone.unsubscribe.sentRequest(profile, listed, clock.now),
      ).resolves.toBeUndefined();
    } finally {
      phone.outbox.dispose();
    }
  });

  // Storage refuses every step that would keep when `refused` was confirmed.
  const refuseKeeping = (
    phone: Awaited<ReturnType<typeof receiver>>,
    refused?: string,
  ) => {
    phone.stepping.before = async (id, step) => {
      const entry = phone.drafts.getOutbox().find((each) => each.id === id);
      const next = entry === undefined ? undefined : step(entry);
      return (refused === undefined || id === refused) &&
        next !== undefined &&
        'state' in next &&
        entry?.unsubscribe?.sentAt === undefined &&
        next.unsubscribe?.sentAt !== undefined
        ? 'refuse'
        : undefined;
    };
  };
  // The request the reader finds for `message`, which the list sent at `receivedAt`.
  const heldFor = (
    phone: Awaited<ReturnType<typeof receiver>>,
    message: string,
    receivedAt: number,
  ) =>
    pendingUnsubscribe(phone.outbox.getSnapshot(), receiving.gmail.id, {
      ...listed,
      message,
      receivedAt,
      delivered: phone.outbox.delivered,
    });

  it('offers a request again to a message the list sent more than 14 days after one confirmed only in memory, as storage refuses its time', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const id = await start(phone);
      refuseKeeping(phone);
      later(undoSendWindow);
      await phone.outbox.process();
      await vi.waitFor(() => {
        expect(phone.outbox.delivered(id)).toBeDefined();
      });
      expect(pending(phone)?.unsubscribe?.sentAt).toBeUndefined();

      later(unsubscribeOfferReturnsAfter + 1);
      expect(heldFor(phone, '9.INBOX', clock.now)).toBeUndefined();
      expect(heldFor(phone, source, clock.now)?.id).toBe(id);
      const again = waitingId(
        await phone.outbox.unsubscribe(receiving.gmail.id, listed, {
          message: '9.INBOX',
          receivedAt: clock.now,
        }),
      );
      expect(again).not.toBe(id);
    } finally {
      phone.outbox.dispose();
    }
  });

  it('offers another message’s own request more than 14 days after a confirmed retry, never the unknown request it answered though its mark was refused', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const original = await lose(phone);
      const retry = await start(phone);
      refuseAnswered(phone, original);
      later(undoSendWindow);
      await phone.outbox.process();
      await vi.waitFor(() => {
        expect(phone.outbox.delivered(retry)).toBeDefined();
      });

      later(15 * 86_400_000);
      expect(heldFor(phone, '9.INBOX', clock.now)).toBeUndefined();
      const fresh = waitingId(
        await phone.outbox.unsubscribe(
          receiving.gmail.id,
          { ...listed, address: 'other@lists.alza.example', subject: 'stop' },
          { message: '9.INBOX', receivedAt: clock.now },
        ),
      );
      const entries = phone.outbox.getSnapshot();
      expect(entries.find(({ id }) => id === fresh)).toMatchObject({
        draft: { to: [{ address: 'other@lists.alza.example' }] },
        unsubscribe: { message: '9.INBOX' },
      });
      expect(
        entries.find(({ id }) => id === fresh)?.unsubscribe?.retries,
      ).toBeUndefined();
      // The unknown request stays for Check Again.
      expect(entries.some(({ id }) => id === original)).toBe(true);
    } finally {
      phone.outbox.dispose();
    }
  });

  it('offers a request again more than 14 days after the unknown request a refused retry tried again was found sent', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const original = await lose(phone);
      const retry = await start(phone);
      phone.become('authorization');
      later(undoSendWindow);
      await phone.outbox.process();
      expect(pending(phone)).toMatchObject({ id: retry, state: 'failed' });
      phone.become('connected');
      await phone.outbox.check(original);
      await vi.waitFor(() => {
        expect(phone.outbox.delivered(original)).toBeDefined();
      });
      expect(pending(phone)).toMatchObject({ id: retry, state: 'failed' });

      later(15 * 86_400_000);
      const fresh = waitingId(
        await phone.outbox.unsubscribe(receiving.gmail.id, listed, {
          message: '9.INBOX',
          receivedAt: clock.now,
        }),
      );
      expect([fresh === original, fresh === retry]).toStrictEqual([
        false,
        false,
      ]);
      expect(
        phone.outbox.getSnapshot().find(({ id }) => id === fresh)?.unsubscribe
          ?.retries,
      ).toStrictEqual([retry]);
    } finally {
      phone.outbox.dispose();
    }
  });

  it('keeps the list’s 14 days from a retry confirmed only in memory when Check Again finds the unknown request sent', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const original = await lose(phone);
      const profile = profileOf(pending(phone));
      const retry = await start(phone);
      refuseKeeping(phone, retry);
      later(undoSendWindow);
      await phone.outbox.process();
      await vi.waitFor(() => {
        expect(phone.outbox.delivered(retry)).toBeDefined();
      });
      const confirmedAt = clock.now;

      later(15 * 86_400_000);
      await phone.outbox.check(original);
      phone.stepping.before = async () => undefined;
      await vi.waitFor(async () => {
        await phone.outbox.process();
        expect(phone.outbox.getSnapshot()).toStrictEqual([]);
      });
      await expect(
        phone.unsubscribe.sentRequest(profile, listed, confirmedAt),
      ).resolves.toMatchObject({ sentAt: confirmedAt });
    } finally {
      phone.outbox.dispose();
    }
  });

  it('takes a refused request storage kept at its retry out of the Outbox once the retry is confirmed', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const refused = await start(phone);
      phone.become('authorization');
      later(undoSendWindow);
      await phone.outbox.process();
      expect(pending(phone)?.state).toBe('failed');
      phone.become('connected');
      refuseRemoving(phone, refused);
      const retry = await start(phone);
      expect(phone.outbox.getSnapshot().map(({ id }) => id)).toStrictEqual([
        refused,
        retry,
      ]);

      phone.stepping.restoring = async () => undefined;
      later(undoSendWindow);
      await phone.outbox.process();
      await vi.waitFor(() => {
        expect(phone.outbox.getSnapshot()).toStrictEqual([]);
      });
      expect(pending(phone)).toBeUndefined();
      expect(phone.gmail.sends).toHaveLength(1);
    } finally {
      phone.outbox.dispose();
    }
  });

  it('keeps a newer confirmation for the list when an older one is saved after it', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      const request = {
        profile: 'default',
        identity: listed.identity,
        list: listed.list,
      };
      await phone.unsubscribe.record(account, {
        ...request,
        sentAt: clock.now,
      });

      await expect(
        phone.unsubscribe.record(account, {
          ...request,
          sentAt: clock.now - 86_400_000,
        }),
      ).resolves.toBe(true);
      await expect(
        phone.unsubscribe.sentRequest('default', listed, clock.now),
      ).resolves.toMatchObject({ sentAt: clock.now });
    } finally {
      phone.outbox.dispose();
    }
  });

  it('answers for the message that offered a request without a list identity once it is sent, in its Profile', async () => {
    expect.hasAssertions();
    const phone = await receiver('gmail');
    try {
      waitingId(
        await phone.outbox.unsubscribe(receiving.gmail.id, offer, {
          message: source,
        }),
      );
      const profile = profileOf(phone.outbox.getSnapshot()[0]);
      later(undoSendWindow);
      await phone.outbox.process();

      await vi.waitFor(() => {
        expect(
          phone.outbox.emailedUnsubscribe(receiving.gmail.id, {
            profile,
            message: source,
          }),
        ).toStrictEqual({ at: clock.now, to: offer.address });
      });
      expect([
        phone.outbox.emailedUnsubscribe(receiving.gmail.id, {
          profile,
          message: '8.INBOX',
        }),
        phone.outbox.emailedUnsubscribe(receiving.gmail.id, {
          profile: 'another-profile',
          message: source,
        }),
      ]).toStrictEqual([undefined, undefined]);
    } finally {
      phone.outbox.dispose();
    }
  });
});
