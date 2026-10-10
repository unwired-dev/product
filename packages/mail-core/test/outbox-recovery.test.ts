import type { MockInstance } from 'vitest';

import type { NativeDeliveryClaim } from '../src/outbox.ts';
import type { Device } from './outbox-fixture.ts';

import { createDrafts } from '../src/drafts.ts';
import { createMailboxes } from '../src/mailboxes.ts';
import { createOutbox, undoSendWindow } from '../src/outbox.ts';
import { boundaryOf } from '../src/outgoing-message.ts';
import { plainText } from '../src/semantic-document.ts';
import { syntheticConnections } from '../src/testing/gmail-mailbox.ts';
import { alex, present } from './draft-sync-fixture.ts';
import { account, addressed, sender, sharedAccount } from './outbox-fixture.ts';

// A native call that never settles, as when the app stops meanwhile.
const stopped = () =>
  // oxlint-disable-next-line promise/avoid-new -- A request that never settles.
  new Promise<never>(() => {
    // Never settles.
  });

// The controlled clock every journey runs on.
const clock = { now: 0 };
const later = (milliseconds: number) => {
  clock.now += milliseconds;
  vi.setSystemTime(clock.now);
};

describe('recovering Outbox outcomes and late Send refusals', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'] });
    clock.now = Date.UTC(2026, 9, 9, 12);
    vi.setSystemTime(clock.now);
  });
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  afterEach(() => {
    vi.useRealTimers();
  });

  it('confirms a lost answer without named capture groups in the host runtime', async () => {
    expect.hasAssertions();
    const { server, gmail } = sharedAccount();
    const sending = await sender(server, gmail, 'phone');
    const captures = vi
      .spyOn(RegExp.prototype, 'exec')
      .mockImplementation(withoutNamedCaptures);
    try {
      const id = await addressed(sending);
      gmail.failSend({ lost: true });
      await sending.outbox.send(() => sending.draft(id));
      later(undoSendWindow);
      await sending.outbox.process();
      expect(gmail.sends).toHaveLength(1);
      expect(sending.drafts.getOutbox()).toStrictEqual([]);
      expect(sending.storage.stored()?.document).toContain(
        `"id":"${id}","message":"${gmail.sends[0]?.id}"`,
      );
    } finally {
      captures.mockRestore();
      sending.outbox.dispose();
    }
  });

  it('reconciles an accepted handoff after the relaunched mailbox becomes ready', async () => {
    expect.hasAssertions();
    const { server, gmail } = sharedAccount();
    const sending = await sender(server, gmail, 'phone');
    const mailboxes = createMailboxes(
      syntheticConnections({ [alex.id]: gmail }),
      sending.registration,
    );
    let recovery: ReturnType<typeof createOutbox> | undefined = undefined;
    try {
      const id = await addressed(sending);
      const submit = gmail.native.gmailSend;
      gmail.native.gmailSend = async (...args) => {
        await submit(...args);
        return stopped();
      };
      await sending.outbox.send(() => sending.draft(id));
      later(undoSendWindow);
      void sending.outbox.process();
      await vi.waitFor(() => {
        expect(gmail.sends).toHaveLength(1);
      });
      sending.outbox.dispose();
      sending.storage.relaunch();
      const drafts = createDrafts(sending.storage.native, sending.registration);
      await drafts.load();
      recovery = createOutbox({
        drafts,
        mailboxes,
        registration: sending.registration,
        claims: sending.storage.delivery,
      });
      await recovery.process();
      expect(drafts.getOutbox()).toMatchObject([{ id, state: 'unknown' }]);
      await mailboxes.load();
      await vi.waitFor(() => {
        expect(drafts.getOutbox()).toStrictEqual([]);
      });
      expect(gmail.sends).toHaveLength(1);
    } finally {
      recovery?.dispose();
      sending.outbox.dispose();
    }
  });

  it('retains unknown for conflicting Sent evidence and a failed check, without resubmission', async () => {
    expect.hasAssertions();
    const { server, gmail } = sharedAccount();
    const sending = await sender(server, gmail, 'phone');
    try {
      const id = await addressed(sending);
      await sending.outbox.send(() => sending.draft(id));
      const entry = present(sending.drafts.getOutbox()[0], 'admitted message');
      const boundary = present(
        boundaryOf(entry.message.segments),
        'MIME boundary',
      );
      // A second Sent copy with the same marker makes the evidence ambiguous.
      const other = gmail.deliver({
        headers: {
          'Content-Type': `multipart/alternative; boundary="${boundary}"`,
        },
      });
      gmail.label(other, 'SENT');
      gmail.failSend({ lost: true });
      later(undoSendWindow);
      await sending.outbox.process();
      await sending.relaunch();
      await expect(sending.outbox.check(id)).resolves.toBe(false);
      gmail.remove(other);
      gmail.fail({ status: 503, body: '{}' });
      await expect(sending.outbox.check(id)).resolves.toBe(false);
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'unknown' },
      ]);
      await expect(sending.outbox.check(id)).resolves.toBe(true);
      expect({
        accepted: gmail.sends.length,
        outbox: sending.drafts.getOutbox(),
      }).toStrictEqual({ accepted: 1, outbox: [] });
    } finally {
      sending.outbox.dispose();
    }
  });

  it('saves a definite non-delivery again when storage refused it, then sends once', async () => {
    expect.hasAssertions();
    let phone: Device | undefined = undefined;
    const { server, gmail } = sharedAccount(() => phone);
    const sending = await sender(server, gmail, 'phone');
    phone = sending;
    try {
      const id = await addressed(sending);
      await sending.outbox.send(() => sending.draft(id));
      later(undoSendWindow);
      // Gmail refuses for a rate limit, and storage refuses to record that answer.
      gmail.failSend({ status: 429, body: '{}' });
      const { gmailSend } = gmail.native;
      gmail.native.gmailSend = async (...args) => {
        gmail.native.gmailSend = gmailSend;
        const reply = await gmailSend(...args);
        sending.storage.failNextCommit('locked');
        return reply;
      };

      await sending.outbox.process();
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'sending' },
      ]);

      later(30_000);
      await sending.outbox.process();
      // The definite non-delivery is recorded, so the message stays retryable and editable.
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'queued', problem: 'rate-limited' },
      ]);
      later(30_000);
      await sending.outbox.process();
      expect(gmail.sends).toHaveLength(1);
      expect(sending.drafts.getOutbox()).toStrictEqual([]);
    } finally {
      sending.outbox.dispose();
    }
  });

  it.each([401, 403])(
    'asks for Gmail after a Sent check rejects authorization with %i while the Inbox was offline',
    async (status) => {
      expect.hasAssertions();
      const { server, gmail } = sharedAccount();
      const received = gmail.deliver();
      const sending = await sender(server, gmail, 'phone');
      try {
        const id = await addressed(sending);
        await sending.outbox.send(() => sending.draft(id));
        later(undoSendWindow);
        gmail.failSend({ status: 503, body: '{}' });
        await sending.outbox.process();
        const { inbox } = present(
          sending.mailboxes.getSnapshot()[0],
          'an open mailbox',
        );
        gmail.fail({ status: 503 });
        await inbox.load();
        expect(inbox.getSnapshot()).toMatchObject({
          kind: 'ready',
          sync: 'retry',
        });
        gmail.fail({ status });

        await expect(sending.outbox.check(id)).resolves.toBe(false);

        expect(inbox.getSnapshot()).toMatchObject({
          kind: 'ready',
          sync: 'authentication',
          messages: [{ id: received }],
        });
        expect(sending.drafts.getOutbox()).toMatchObject([
          { id, state: 'unknown' },
        ]);
        expect(gmail.sends).toStrictEqual([]);
      } finally {
        sending.outbox.dispose();
      }
    },
  );

  it.each([
    { outcome: 'sent', status: 200, states: [], editable: false },
    // Gmail never kept it, so it stays unknown; the person may still choose to edit it.
    { outcome: 'unknown', status: 503, states: ['unknown'], editable: true },
    { outcome: 'failed', status: 400, states: ['failed'], editable: true },
  ])(
    'saves a refused $outcome outcome again without another Gmail submission',
    async ({ status, states, editable }) => {
      expect.hasAssertions();
      let phone: Device | undefined = undefined;
      const { server, gmail } = sharedAccount(() => phone);
      const sending = await sender(server, gmail, 'phone');
      phone = sending;
      try {
        const id = await addressed(sending);
        await sending.outbox.send(() => sending.draft(id));
        later(undoSendWindow);
        gmail.failSend({ status, body: '{}' });
        const { gmailSend } = gmail.native;
        let submissions = 0;
        gmail.native.gmailSend = async (...args) => {
          submissions += 1;
          const reply = await gmailSend(...args);
          sending.storage.failNextCommit('locked');
          return reply;
        };
        await sending.outbox.process();
        expect(sending.drafts.getOutbox()).toMatchObject([
          { id, state: 'sending' },
        ]);
        // A second refusal retains the same answer for another storage-only retry.
        sending.storage.failNextCommit('locked');
        later(30_000);
        await sending.outbox.process();
        expect(sending.drafts.getOutbox()).toMatchObject([
          { id, state: 'sending' },
        ]);
        later(30_000);
        await sending.outbox.process();
        await sending.relaunch();
        await sending.outbox.process();
        expect(submissions).toBe(1);
        expect(
          sending.drafts
            .getOutbox()
            .map((entry) => ({ id: entry.id, state: entry.state })),
        ).toStrictEqual(states.map((state) => ({ id, state })));
        expect(typeof (await sending.outbox.undo(id)) === 'string').toBe(
          editable,
        );
      } finally {
        sending.outbox.dispose();
      }
    },
  );

  it('refuses Send when the sending mailbox changes while its files are verified', async () => {
    expect.hasAssertions();
    let phone: Device | undefined = undefined;
    const { server, gmail } = sharedAccount(() => phone);
    const sending = await sender(server, gmail, 'phone');
    phone = sending;
    const outbox = createOutbox({
      drafts: {
        ...sending.drafts,
        readAsset: async (asset, options) => {
          sending.change({
            kind: 'connected',
            productAccountId: account,
            signInProvider: 'google',
            mailboxes: JSON.stringify([
              {
                ...alex,
                address: 'renamed@example.invalid',
                state: 'connected',
              },
            ]),
          });
          return sending.drafts.readAsset(asset, options);
        },
      },
      mailboxes: sending.mailboxes,
      registration: sending.registration,
      claims: sending.storage.delivery,
    });
    try {
      const id = await addressed(sending);
      const draft = sending.draft(id);
      sending.storage.addFile('file:///notes.txt', 'notes');
      const notes = sending.drafts.prepare({
        name: 'notes.txt',
        type: 'text/plain',
      });
      await sending.drafts.update({ ...draft, attachments: [notes] }, draft);
      await sending.drafts.importAsset(notes, {
        kind: 'file',
        uri: 'file:///notes.txt',
      });

      await expect(outbox.send(() => sending.draft(id))).resolves.toBe(
        'sender',
      );

      expect(sending.drafts.getOutbox()).toStrictEqual([]);
      expect(sending.list().map((each) => each.id)).toStrictEqual([id]);
    } finally {
      outbox.dispose();
      sending.outbox.dispose();
    }
  });

  it('records the answer it got when another store marked the handoff unknown first', async () => {
    expect.hasAssertions();
    const { server, gmail } = sharedAccount();
    const sending = await sender(server, gmail, 'phone');
    try {
      const id = await addressed(sending);
      await sending.outbox.send(() => sending.draft(id));
      later(undoSendWindow);
      gmail.failSend({ status: 429, body: '{}' });
      const reply = Promise.withResolvers<undefined>();
      const submit = gmail.native.gmailSend;
      gmail.native.gmailSend = async (...args) => {
        await reply.promise;
        return submit(...args);
      };
      const processing = sending.outbox.process();
      await vi.waitFor(() => {
        expect(sending.drafts.getOutbox()).toMatchObject([
          { state: 'sending' },
        ]);
      });
      // Another store opens meanwhile, reads the handoff as unknown and saves that first.
      const recovering = createDrafts(
        sending.storage.native,
        sending.registration,
      );
      await recovering.load();
      await expect(recovering.save()).resolves.toBe(true);
      reply.resolve(undefined);
      await processing;

      // Gmail refused for a rate limit: nothing was delivered, so the message stays retryable.
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'queued', problem: 'rate-limited' },
      ]);
      later(30_000);
      await sending.outbox.process();
      expect(gmail.sends).toHaveLength(1);
    } finally {
      sending.outbox.dispose();
    }
  });

  it('refuses a Draft changed during verification rather than admitting it with earlier content', async () => {
    expect.hasAssertions();
    let phone: Device | undefined = undefined;
    const { server, gmail } = sharedAccount(() => phone);
    const sending = await sender(server, gmail, 'phone');
    phone = sending;
    let outbox: ReturnType<typeof createOutbox> | undefined = undefined;
    try {
      const id = await addressed(sending);
      const draft = sending.draft(id);
      sending.storage.addFile('file:///notes.txt', 'notes');
      const notes = sending.drafts.prepare({
        name: 'notes.txt',
        type: 'text/plain',
      });
      await sending.drafts.update({ ...draft, attachments: [notes] }, draft);
      await sending.drafts.importAsset(notes, {
        kind: 'file',
        uri: 'file:///notes.txt',
      });
      outbox = createOutbox({
        drafts: {
          ...sending.drafts,
          // The Draft changes while its files are verified, before admission.
          readAsset: async (asset, options) => {
            const current = sending.draft(id);
            await sending.drafts.update(
              { ...current, subject: 'Changed meanwhile' },
              current,
            );
            return sending.drafts.readAsset(asset, options);
          },
        },
        mailboxes: sending.mailboxes,
        registration: sending.registration,
        claims: sending.storage.delivery,
      });
      // A caller whose callback follows the live Draft.
      await expect(outbox.send(() => sending.draft(id))).resolves.toBe(
        'changed',
      );

      expect(sending.drafts.getOutbox()).toStrictEqual([]);
      expect(sending.draft(id).subject).toBe('Changed meanwhile');
    } finally {
      outbox?.dispose();
      sending.outbox.dispose();
    }
  });

  it('keeps a message waiting when its mailbox generation refreshes during the handoff', async () => {
    expect.hasAssertions();
    const { server, gmail } = sharedAccount();
    const sending = await sender(server, gmail, 'phone');
    try {
      const id = await addressed(sending);
      await sending.outbox.send(() => sending.draft(id));
      later(undoSendWindow);
      // Returning to the app refreshes the mailbox while the claimed message is handed over.
      gmail.failSend({ code: 'mailbox-invalidated' });

      await sending.outbox.process();

      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'queued', claim: 'held', problem: 'offline' },
      ]);
      later(30_000);
      await sending.outbox.process();
      expect(gmail.sends).toHaveLength(1);
      expect(sending.drafts.getOutbox()).toStrictEqual([]);
    } finally {
      sending.outbox.dispose();
    }
  });

  it('locks the Inbox when a Sent check finds storage locked, keeping the message unknown', async () => {
    expect.hasAssertions();
    const { server, gmail } = sharedAccount();
    const sending = await sender(server, gmail, 'phone');
    try {
      const id = await addressed(sending);
      await sending.outbox.send(() => sending.draft(id));
      later(undoSendWindow);
      // Gmail answers with a server error without keeping the message.
      gmail.failSend({ status: 503, body: '{}' });
      await sending.outbox.process();
      gmail.fail({ code: 'locked' });

      await expect(sending.outbox.check(id)).resolves.toBe(false);

      expect(
        sending.mailboxes.getSnapshot()[0]?.inbox.getSnapshot(),
      ).toMatchObject({ kind: 'locked' });
      expect(sending.drafts.getOutbox()).toMatchObject([
        { id, state: 'unknown' },
      ]);
      expect(gmail.sends).toStrictEqual([]);
    } finally {
      sending.outbox.dispose();
    }
  });

  it.each([
    {
      point: 'before Convex receives the claim',
      stop: (({ claims }) => {
        claims.mockImplementationOnce(stopped);
      }) satisfies Interruption,
      stored: '"claim":"requested"',
    },
    {
      point: 'after Convex takes the claim but before its reply arrives',
      stop: (({ claims, claim }) => {
        claims.mockImplementationOnce(async (...args) => {
          await claim(...args);
          return stopped();
        });
      }) satisfies Interruption,
      stored: '"claim":"requested"',
    },
    {
      point: 'after the claim is held but before Gmail is asked',
      stop: (({ gmail }) => {
        gmail.failSend({ code: 'mailbox-invalidated' });
      }) satisfies Interruption,
      stored: '"claim":"held"',
    },
    {
      point:
        'after Gmail accepts the message but before its answer is recorded',
      stop: (({ gmail, submit }) => {
        gmail.native.gmailSend = async (...args) => {
          await submit(...args);
          return stopped();
        };
      }) satisfies Interruption,
      stored: '"state":"sending"',
    },
  ])(
    'sends a message the app stopped $point once across relaunches',
    async ({ stop, stored }) => {
      expect.hasAssertions();
      await interrupted(stop, stored, ({ sending, gmail }) => {
        expect(gmail.sends).toHaveLength(1);
        expect(sending.drafts.getOutbox()).toStrictEqual([]);
      });
    },
  );

  it('keeps a message unknown when the app stopped after recording its handoff, until the person edits it', async () => {
    expect.hasAssertions();
    const stop: Interruption = ({ gmail }) => {
      gmail.native.gmailSend = stopped;
    };
    await interrupted(
      stop,
      '"state":"sending"',
      async ({ sending, gmail, id }) => {
        // Gmail never had it, and nothing confirms that: it stays unknown and is never resent.
        expect(sending.drafts.getOutbox()).toMatchObject([
          { id, state: 'unknown' },
        ]);
        await expect(sending.outbox.check(id)).resolves.toBe(false);
        // Edit returns it under a new identifier, because its old one stays claimed.
        const restored = String(await sending.outbox.undo(id));
        expect(restored).not.toBe(id);
        expect(plainText(sending.draft(restored).body)).toBe('See you there');
        expect(gmail.sends).toStrictEqual([]);
      },
    );
  });
});

// Sends one message, stops the app at `stop` once storage holds `stored`, relaunches twice and
// processes the Outbox after each relaunch, then hands the result to `check`.
async function interrupted(
  stop: Interruption,
  stored: string,
  check: (
    result: Readonly<{
      sending: Awaited<ReturnType<typeof sender>>;
      gmail: ReturnType<typeof sharedAccount>['gmail'];
      id: string;
    }>,
  ) => Promise<void> | void,
) {
  let phone: Device | undefined = undefined;
  const { server, gmail } = sharedAccount(() => phone);
  const sending = await sender(server, gmail, 'phone');
  phone = sending;
  try {
    const id = await addressed(sending);
    await sending.outbox.send(() => sending.draft(id));
    later(undoSendWindow);
    const delivery = present(sending.storage.delivery, 'delivery claims');
    const claim = delivery.claimDraftDelivery.bind(delivery);
    const submit = gmail.native.gmailSend;
    stop({
      claims: vi.spyOn(delivery, 'claimDraftDelivery'),
      claim,
      gmail,
      submit,
    });
    void sending.outbox.process();
    await vi.waitFor(() => {
      expect(sending.storage.stored()?.document).toContain(stored);
    });
    gmail.native.gmailSend = submit;
    // Relaunching more than once never hands the message to Gmail again.
    const restart = async () => {
      await sending.relaunch();
      later(30_000);
      await sending.outbox.process();
    };
    await restart();
    await restart();
    await check({ sending, gmail, id });
  } finally {
    sending.outbox.dispose();
  }
}

// Stops the app at one point of a delivery; `claim` and `submit` are the unstopped calls.
type Interruption = (
  stopping: Readonly<{
    claims: MockInstance<NativeDeliveryClaim['claimDraftDelivery']>;
    claim: NativeDeliveryClaim['claimDraftDelivery'];
    gmail: ReturnType<typeof sharedAccount>['gmail'];
    submit: ReturnType<typeof sharedAccount>['gmail']['native']['gmailSend'];
  }>,
) => void;

// The host transform can preserve positional captures without exposing named groups.
const { exec } = RegExp.prototype;
function withoutNamedCaptures(this: RegExp, text: string) {
  const result = exec.call(this, text);
  if (
    result !== null &&
    (this.source.includes('?<boundary>') ||
      this.source.includes('?<value>multipart'))
  ) {
    result.groups = undefined;
  }
  return result;
}
