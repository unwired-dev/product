import { english } from '@private-email/localization';

import type { DeliveryProblem, OutboxEntry } from '../src/drafts.ts';
import type { OutboxCheck } from '../src/outbox.ts';
import type { MailProvider } from '../src/registration.ts';

import { outboxCopy } from '../src/outbox.ts';
import { present } from './draft-sync-fixture.ts';
import { addressed, sender, sharedAccount } from './outbox-fixture.ts';

describe('outbox status and recovery copy', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Admission uses the same controlled clock as recovery journeys.
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(Date.UTC(2026, 9, 9, 12));
  });
  // oxlint-disable-next-line vitest/no-hooks -- Restore the clock even when setup or assertions fail.
  afterEach(() => {
    vi.useRealTimers();
  });

  it('words every Outbox state and problem in the provider the message was handed to', async () => {
    expect.hasAssertions();
    const { server, gmail } = sharedAccount();
    const sending = await sender(server, gmail, 'phone');
    try {
      const id = await addressed(sending);
      await sending.outbox.send(() => sending.draft(id));
      const waiting = present(
        sending.outbox.getSnapshot()[0],
        'admitted message',
      );
      const copyOf = (
        provider: MailProvider | undefined,
        outcome: Pick<OutboxEntry, 'state' | 'problem'>,
        check: OutboxCheck = 'idle',
      ) => outboxCopy(english, { ...waiting, ...outcome, check }, provider);
      // Waiting and refused messages read the same reason.
      const reasons = {
        offline:
          'Waiting to send. It sends when this device can reach Gmail and your Unwired Mail account.',
        locked:
          'Waiting to send while private storage is locked. Unlock your device.',
        'rate-limited':
          'Waiting to send. Gmail asked to wait before sending more.',
        claimed:
          'Not sent. Another of your devices claimed this message to send it.',
        authorization: 'Not sent. This mailbox needs Gmail access again.',
        mailbox: 'Not sent. This mailbox is no longer connected.',
        assets: 'Not sent. Its files are no longer on this device.',
        'too-large': 'Not sent. It is too large for Gmail.',
        refused: 'Not sent. Gmail refused this message.',
        'sent-folder':
          "Not sent. Unwired Mail cannot identify one Sent folder for this mailbox's copy.",
      } as const satisfies Readonly<Record<DeliveryProblem, string>>;
      const table: ReadonlyArray<
        readonly [
          MailProvider | undefined,
          Pick<OutboxEntry, 'state' | 'problem'>,
          string,
        ]
      > = [
        ['gmail', { state: 'waiting' }, 'Sending soon'],
        ['gmail', { state: 'queued' }, 'Sending…'],
        ['gmail', { state: 'sending' }, 'Sending…'],
        ['gmail', { state: 'filing' }, 'Sent. Saving a copy to Sent…'],
        [
          'gmail',
          { state: 'filing', problem: 'offline' },
          'Sent. Its copy is saved to Sent when the mail server can be reached.',
        ],
        [
          'gmail',
          { state: 'filing', problem: 'locked' },
          'Sent. Its copy is saved to Sent once private storage is unlocked.',
        ],
        [
          'gmail',
          { state: 'filing', problem: 'authorization' },
          "Sent. Enter this mailbox's password again in Settings to save its copy to Sent.",
        ],
        [
          'gmail',
          { state: 'filing', problem: 'sent-folder' },
          'Sent. Waiting for one Sent folder to be identified before saving its copy.',
        ],
        [
          'gmail',
          { state: 'filing', problem: 'refused' },
          'Sent. Saving a copy to Sent…',
        ],
        ['gmail', { state: 'failed' }, reasons.refused],
        ...(['queued', 'failed'] as const).flatMap((state) =>
          Object.entries(reasons).map(
            ([problem, text]) =>
              [
                'gmail',
                // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- Object.entries widens the keys of `reasons`.
                { state, problem: problem as DeliveryProblem },
                text,
              ] as const,
          ),
        ),
        [
          'gmail',
          { state: 'unknown' },
          'Delivery unknown. Check Sent in Gmail before sending it again.',
        ],
        [
          'imap',
          { state: 'queued', problem: 'offline' },
          'Waiting to send. It sends when this device can reach the mail server and your Unwired Mail account.',
        ],
        [
          'imap',
          { state: 'failed', problem: 'authorization' },
          "Not sent. The mail server did not accept this mailbox's password. Enter it again in Settings.",
        ],
        [
          'imap',
          { state: 'failed', problem: 'too-large' },
          'Not sent. It is too large for the mail server.',
        ],
        [
          'imap',
          { state: 'failed', problem: 'refused' },
          'Not sent. The mail server refused this message.',
        ],
        ['imap', { state: 'queued', problem: 'locked' }, reasons.locked],
        [
          'imap',
          { state: 'unknown' },
          'Delivery unknown. Check your Sent folder before sending it again.',
        ],
        [
          'microsoft-graph',
          { state: 'queued', problem: 'offline' },
          'Waiting to send. It sends when this device can reach Microsoft and your Unwired Mail account.',
        ],
        [
          'microsoft-graph',
          { state: 'queued', problem: 'rate-limited' },
          'Waiting to send. Microsoft asked to wait before sending more.',
        ],
        [
          'microsoft-graph',
          { state: 'failed', problem: 'authorization' },
          'Not sent. This mailbox needs Microsoft access again.',
        ],
        [
          'microsoft-graph',
          { state: 'failed', problem: 'too-large' },
          'Not sent. It is too large for Microsoft.',
        ],
        [
          'microsoft-graph',
          { state: 'failed', problem: 'refused' },
          'Not sent. Microsoft refused this message.',
        ],
        [
          'microsoft-graph',
          { state: 'unknown' },
          'Delivery unknown. Check Sent Items in Outlook before sending it again.',
        ],
        [
          undefined,
          { state: 'queued', problem: 'offline' },
          'Waiting to send. It sends when this device can reach its mail provider and your Unwired Mail account.',
        ],
        [
          undefined,
          { state: 'queued', problem: 'rate-limited' },
          'Waiting to send. Its mail provider asked to wait before sending more.',
        ],
        [
          undefined,
          { state: 'failed', problem: 'authorization' },
          'Not sent. Its mailbox needs access again.',
        ],
        [
          undefined,
          { state: 'failed', problem: 'too-large' },
          'Not sent. It is too large for its mail provider.',
        ],
        [
          undefined,
          { state: 'failed', problem: 'refused' },
          'Not sent. Its mail provider refused this message.',
        ],
        [
          undefined,
          { state: 'unknown' },
          'Delivery unknown. Check the Sent folder of the mailbox it was sent from before sending it again.',
        ],
      ];
      expect(
        table.map(([provider, outcome]) => copyOf(provider, outcome).status),
      ).toStrictEqual(table.map((row) => row[2]));

      // These states ignore a retained problem; filing recognizes only its four copy-saving reasons.
      const states = [
        ['waiting', 'Sending soon', []],
        ['sending', 'Sending…', []],
        [
          'unknown',
          'Delivery unknown. Check Sent in Gmail before sending it again.',
          [],
        ],
        [
          'filing',
          'Sent. Saving a copy to Sent…',
          [
            [
              'offline',
              'Sent. Its copy is saved to Sent when the mail server can be reached.',
            ],
            [
              'locked',
              'Sent. Its copy is saved to Sent once private storage is unlocked.',
            ],
            [
              'authorization',
              "Sent. Enter this mailbox's password again in Settings to save its copy to Sent.",
            ],
            [
              'sent-folder',
              'Sent. Waiting for one Sent folder to be identified before saving its copy.',
            ],
          ],
        ],
      ] as const;
      for (const [state, fallback, overrides] of states) {
        const expected = new Map<string, string>([
          ...Object.keys(reasons).map(
            (problem) => [problem, fallback] as const,
          ),
          ...overrides,
        ]);
        for (const problem of Object.keys(reasons)) {
          expect(
            copyOf('gmail', {
              state,
              // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- Object.keys widens the keys of `reasons`.
              problem: problem as DeliveryProblem,
            }).status,
          ).toBe(expected.get(problem));
        }
      }

      // An unknown message's notices, before and after Check Again found no confirmation.
      expect(
        (['gmail', 'imap', 'microsoft-graph', undefined] as const).map(
          (provider) => {
            const { unconfirmed, editWarning } = copyOf(
              provider,
              { state: 'unknown' },
              'unconfirmed',
            );
            return [
              copyOf(provider, { state: 'unknown' }).unconfirmed,
              unconfirmed,
              editWarning,
            ];
          },
        ),
      ).toStrictEqual([
        [
          undefined,
          'Gmail did not confirm this message. Check Sent in Gmail.',
          'Gmail may already have sent this message. Edit it only if it is not in Sent in Gmail.',
        ],
        [
          undefined,
          'Your Sent folder did not confirm this message. Check it on the mail server.',
          'The mail server may already have sent this message. Edit it only if it is not in your Sent folder.',
        ],
        [
          undefined,
          'Microsoft did not confirm this message yet. Check Sent Items in Outlook.',
          'Microsoft may already have sent this message. Edit it only if it is not in Sent Items in Outlook.',
        ],
        [
          undefined,
          'This message could not be confirmed. Check the Sent folder of the mailbox it was sent from.',
          'This message may already have been sent. Edit it only if it is not in the Sent folder of the mailbox it was sent from.',
        ],
      ]);
    } finally {
      sending.outbox.dispose();
    }
  });
});
