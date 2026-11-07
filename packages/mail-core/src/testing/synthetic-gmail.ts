import * as Arr from 'effect/Array';
import * as Context from 'effect/Context';
import * as Effect from 'effect/Effect';
import * as Base64 from 'effect/encoding/Base64';
import * as Layer from 'effect/Layer';
import * as Order from 'effect/Order';
import * as Schema from 'effect/Schema';

import type { Reply, RequestURL } from './synthetic-relay.ts';

import { allMail, inView } from '../gmail-actions.ts';
import { historyPageSize } from '../gmail-history.ts';
import {
  SyntheticScenario,
  refuse,
  reply,
  requestURL,
} from './synthetic-relay.ts';

// A synthetic Gmail message; `disposition` is served as its Content-Disposition header, and a
// `calendar` makes it multipart/mixed: its body, then the calendar as `invite.ics`.
interface SyntheticGmailMessage {
  readonly threadId?: string;
  readonly from?: string;
  readonly subject?: string;
  readonly snippet?: string;
  readonly internalDate?: string;
  readonly labelIds?: readonly string[];
  readonly html?: string;
  readonly text?: string;
  readonly disposition?: string;
  readonly calendar?: string;
}

// A synthetic Gmail mailbox: three Inbox messages over two list pages, one label with an archived
// message, and a trashed message. Label changes from this launch apply; history reports no other
// changes.
export const SyntheticGmailMessages = Context.Reference<
  Readonly<Record<string, SyntheticGmailMessage>>
>('@private-email/mail-core/testing/SyntheticGmailMessages', {
  defaultValue: () => ({
    '19a0c0ffee000001': {
      from: 'Rowan Hale <rowan@example.invalid>',
      subject: 'Garden plans for spring',
      snippet: 'The seed order arrived. Shall we plan the beds this weekend?',
      internalDate: '1759219200000',
      labelIds: ['INBOX', 'UNREAD'],
      html:
        '<p>The seed order arrived. Shall we plan the beds this weekend?</p>' +
        '<p>Planting notes: <a href="https://example.invalid/garden">garden plan</a></p>' +
        // A link whose visible address differs from its destination, which the reader flags.
        '<p>Seed order: <a href="https://seeds.example.invalid/order">https://garden.example.invalid/order</a></p>' +
        '<img src="https://example.invalid/pixel.gif" alt="">',
    },
    '19a0c0ffee000002': {
      from: '"Ada Brook" <ada@example.invalid>',
      subject: 'Notes from Tuesday',
      snippet: 'Thanks for the thoughtful questions &amp; the follow-up.',
      internalDate: '1759132800000',
      labelIds: ['INBOX'],
      text: 'Thanks for the thoughtful questions & the follow-up.\n\nAda',
    },
    '19a0c0ffee000003': {
      from: 'test@example.invalid',
      subject: 'Welcome to your synthetic Inbox',
      snippet: 'Nothing here came from a real mailbox.',
      internalDate: '1759046400000',
      labelIds: ['INBOX', 'CATEGORY_UPDATES'],
      text: 'Nothing here came from a real mailbox.',
    },
    '19a0c0ffee000004': {
      from: 'Lena Park <lena@example.invalid>',
      subject: 'Train tickets to Vienna',
      snippet: 'Both seats are booked for the 9:10 departure.',
      internalDate: '1758960000000',
      labelIds: ['Label_1'],
      text: 'Both seats are booked for the 9:10 departure.',
    },
    '19a0c0ffee000005': {
      from: 'Store <orders@example.invalid>',
      subject: 'Your order has shipped',
      snippet: 'Your parcel is on its way.',
      internalDate: '1758873600000',
      labelIds: ['TRASH'],
      text: 'Your parcel is on its way.',
    },
  }),
});

// The `registration-thread` mailbox adds one long Thread of six plain-text messages, Crew 6 the
// newest, each body taller than a screen, and a field guide whose HTML body is taller than a screen.
const syntheticThread: Readonly<Record<string, SyntheticGmailMessage>> = {
  ...Object.fromEntries(
    [1, 2, 3, 4, 5, 6].map((crew) => [
      `19a0c0ffee00001${crew}`,
      {
        threadId: '19a0c0ffee000011',
        from: `Crew ${crew} <crew${crew}@example.invalid>`,
        subject: crew === 1 ? 'Trail maintenance' : 'Re: Trail maintenance',
        snippet: `Crew ${crew}, note 1.`,
        internalDate: String(1_759_300_000_000 + crew * 3_600_000),
        labelIds: ['INBOX'],
        text: Array.from(
          { length: 40 },
          (_, note) => `Crew ${crew}, note ${note + 1}.`,
        ).join('\n\n'),
      },
    ]),
  ),
  '19a0c0ffee000021': {
    from: 'Iris Vale <iris@example.invalid>',
    subject: 'Trail field guide',
    snippet: 'Field guide, section 1.',
    internalDate: '1759290000000',
    labelIds: ['INBOX'],
    html: Array.from(
      { length: 40 },
      (_, section) => `<p>Field guide, section ${section + 1}.</p>`,
    ).join(''),
  },
};

// The `registration-performance` mailbox adds 125 older Inbox Threads of one message each, every
// other one HTML, for the warm-cache performance journey; Gmail update 001 is the newest.
export const syntheticPerformanceCount = 125;
const syntheticPerformance: Readonly<Record<string, SyntheticGmailMessage>> =
  Object.fromEntries(
    Array.from({ length: syntheticPerformanceCount }, (_, index) => {
      const number = String(index + 1).padStart(3, '0');
      const text = `Gmail update ${number} body. Nothing here came from a real mailbox.`;
      const snippet = `Gmail update ${number} preview.`;
      return [
        `19a0c0ffee${(0x10_00_00 + index).toString(16)}`,
        {
          from: `Sender ${number} <sender${number}@example.invalid>`,
          subject: `Gmail update ${number}`,
          snippet,
          internalDate: String(1_758_000_000_000 - index * 7_200_000),
          labelIds: ['INBOX'],
          ...(index % 2 === 0 ? { text } : { html: `<p>${text}</p>` }),
        },
      ];
    }),
  );

// A calendar of one meeting, from Lena Fischer, holding the event's own lines.
const meetingCalendar = (event: readonly string[], method = 'REQUEST') =>
  [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    `METHOD:${method}`,
    'BEGIN:VEVENT',
    ...event,
    'ORGANIZER;CN=Lena Fischer:mailto:lena@example.invalid',
    'END:VEVENT',
    'END:VCALENDAR',
  ].join('\r\n');
const invited = (address: string) =>
  `ATTENDEE;CN=Alex;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:${address}`;
const weeklyReview = [
  'UID:design-review-7@example.invalid',
  'SEQUENCE:0',
  'SUMMARY:Weekly design review',
  'DTSTART:20261113T150000Z',
  'DTEND:20261113T160000Z',
  'LOCATION:Room 2',
];
// Below the answerable invitation, each invitation state the card shows without a response:
// another attendee, a cancellation, a weekly series, one meeting of it, an update that carries
// the series and names one meeting, and a calendar Unwired can't read.
const invitationStates = [
  {
    subject: 'Invitation: Hiring sync',
    calendar: meetingCalendar([
      'UID:hiring-3@example.invalid',
      'SEQUENCE:0',
      'SUMMARY:Hiring sync',
      'DTSTART:20261116T100000Z',
      'DTEND:20261116T103000Z',
      invited('mara@example.invalid'),
    ]),
  },
  {
    subject: 'Cancelled: Budget check-in',
    calendar: meetingCalendar(
      [
        'UID:budget-5@example.invalid',
        'SEQUENCE:1',
        'SUMMARY:Budget check-in',
        'DTSTART:20261117T130000Z',
        'DTEND:20261117T133000Z',
        'STATUS:CANCELLED',
        invited('other@example.invalid'),
      ],
      'CANCEL',
    ),
  },
  {
    subject: 'Invitation: Weekly design review',
    calendar: meetingCalendar([
      ...weeklyReview,
      'RRULE:FREQ=WEEKLY;COUNT=6',
      invited('other@example.invalid'),
    ]),
  },
  {
    subject: 'Updated invitation: Weekly design review on 20 Nov',
    calendar: meetingCalendar([
      ...weeklyReview.map((line) => line.replace('20261113', '20261120')),
      'RECURRENCE-ID:20261120T150000Z',
      invited('other@example.invalid'),
    ]),
  },
  {
    subject: 'Updated series: Weekly design review',
    calendar: meetingCalendar([
      ...weeklyReview,
      'RRULE:FREQ=WEEKLY;COUNT=6',
      'RECURRENCE-ID:20261120T150000Z',
      invited('other@example.invalid'),
    ]),
  },
  {
    subject: 'Invitation: Daily launch check',
    calendar: meetingCalendar([
      'UID:launch-9@example.invalid',
      'SEQUENCE:0',
      'SUMMARY:Daily launch check',
      'DTSTART:20261116T090000Z',
      'DTEND:20261116T091500Z',
      'RRULE:FREQ=DAILY;COUNT=5',
      invited('other@example.invalid'),
    ]),
  },
];

// The `registration-invitation` mailbox adds Lena Fischer's meeting invitation to the mailbox's
// own address, the newest Inbox message, then the invitation states.
const syntheticInvitation: Readonly<Record<string, SyntheticGmailMessage>> = {
  ...Object.fromEntries(
    invitationStates.map(({ subject, calendar }, index) => [
      `19a0c0ffee00004${index}`,
      {
        from: 'Lena Fischer <lena@example.invalid>',
        subject,
        snippet: subject,
        internalDate: String(1_759_390_000_000 - index * 60_000),
        labelIds: ['INBOX'],
        text: subject,
        calendar,
      },
    ]),
  ),
  '19a0c0ffee000031': {
    from: 'Lena Fischer <lena@example.invalid>',
    subject: 'Invitation: Q4 roadmap review',
    snippet: 'Join us to review the Q4 roadmap.',
    internalDate: '1759400000000',
    labelIds: ['INBOX', 'UNREAD'],
    text: 'Join us to review the Q4 roadmap.',
    calendar: [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'METHOD:REQUEST',
      'BEGIN:VEVENT',
      'UID:roadmap-42@example.invalid',
      'SEQUENCE:0',
      'SUMMARY:Q4 roadmap review',
      'DTSTART:20261112T150000Z',
      'DTEND:20261112T160000Z',
      'LOCATION:Room 4',
      'ORGANIZER;CN=Lena Fischer:mailto:lena@example.invalid',
      'ATTENDEE;CN=Alex;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:other@example.invalid',
      'END:VEVENT',
      'END:VCALENDAR',
    ].join('\r\n'),
  },
};

const gmailScope = 'https://www.googleapis.com/auth/gmail.modify';
const mailbox = 'synthetic-alternate-mailbox';
const LabelChange = Schema.fromJsonString(
  Schema.Struct({
    addLabelIds: Schema.optionalKey(Schema.Array(Schema.String)),
    removeLabelIds: Schema.optionalKey(Schema.Array(Schema.String)),
  }),
);
const identity = (subject: string, granted: boolean) => ({
  subject,
  scopes: granted ? [gmailScope] : [],
});
// The MIME headers a message part declares for its type.
const mimeHeaders = (message: SyntheticGmailMessage, mimeType: string) => [
  { name: 'Content-Type', value: `${mimeType}; charset=UTF-8` },
  ...(message.disposition === undefined
    ? []
    : [{ name: 'Content-Disposition', value: message.disposition }]),
];
const missing: Reply = { status: 404, body: '' };
const newestFirst = Order.flip(
  Order.mapInput(
    Order.Number,
    ([, message]: readonly [string, SyntheticGmailMessage]) =>
      Number(message.internalDate ?? 0),
  ),
);

const bodyTypeOf = (message: SyntheticGmailMessage) =>
  message.html === undefined ? 'text/plain' : 'text/html';
const mimeTypeOf = (message: SyntheticGmailMessage) =>
  message.calendar === undefined ? bodyTypeOf(message) : 'multipart/mixed';
// The body-free preflight prefetch makes: only the requested admission headers are returned.
const admission = (
  message: SyntheticGmailMessage,
  requested: ReadonlySet<string>,
) => {
  const mimeType = mimeTypeOf(message);
  const headers = mimeHeaders(message, mimeType).filter(({ name }) =>
    requested.has(name.toLowerCase()),
  );
  return { payload: { mimeType, headers } };
};
// A part's inline base64url body.
const encoded = (content: string) => ({
  size: new TextEncoder().encode(content).length,
  data: Base64.encode(content).replaceAll('+', '-').replaceAll('/', '_'),
});
// The message's parts with every MIME header and their base64url bodies.
const full = (message: SyntheticGmailMessage) => {
  const bodyType = bodyTypeOf(message);
  const body = {
    mimeType: bodyType,
    headers: mimeHeaders(message, bodyType),
    body: encoded(message.html ?? message.text ?? ''),
  };
  return {
    payload:
      message.calendar === undefined
        ? body
        : {
            mimeType: 'multipart/mixed',
            headers: mimeHeaders(message, 'multipart/mixed'),
            parts: [
              { ...body, headers: mimeHeaders({}, bodyType) },
              {
                mimeType: 'text/calendar',
                filename: 'invite.ics',
                headers: [
                  {
                    name: 'Content-Type',
                    value: 'text/calendar; charset=UTF-8; method=REQUEST',
                  },
                ],
                body: encoded(message.calendar),
              },
            ],
          },
  };
};
// The message as the Inbox list reads it: its snippet, date and envelope headers.
const summary = (message: SyntheticGmailMessage) => ({
  snippet: message.snippet ?? '',
  historyId: '100',
  internalDate: message.internalDate ?? '',
  payload: {
    headers: [
      { name: 'From', value: message.from ?? '' },
      { name: 'Subject', value: message.subject ?? '' },
    ],
  },
});
// A message as its request's format shows it, beside its identifiers and labels.
function view(message: SyntheticGmailMessage, { item, query }: RequestURL) {
  // Gmail repeats metadataHeaders once per requested header, in any order and case.
  const requested = new Set(
    query
      .filter(([name]) => name === 'metadataHeaders')
      .map(([, value]) => value.toLowerCase()),
  );
  if (
    item('format') === 'metadata' &&
    (requested.has('content-type') || requested.has('content-disposition'))
  ) {
    return admission(message, requested);
  }
  return item('format') === 'full' ? full(message) : summary(message);
}

// Google sign-in and the Gmail API, as the native Google provider sees them.
export class SyntheticGoogle extends Context.Service<SyntheticGoogle>()(
  '@private-email/mail-core/testing/SyntheticGoogle',
  {
    make: Effect.gen(function* () {
      const { scenario } = yield* SyntheticScenario;
      const messages = {
        ...(yield* SyntheticGmailMessages),
        ...(scenario === 'registration-thread' ? syntheticThread : {}),
        ...(scenario === 'registration-invitation' ? syntheticInvitation : {}),
        ...(scenario === 'registration-performance'
          ? syntheticPerformance
          : {}),
      };
      const threadOf = (id: string) =>
        (Object.hasOwn(messages, id) ? messages[id]?.threadId : undefined) ??
        id;
      const labels = new Map(
        Object.entries(messages).map(([id, message]) => [
          id,
          message.labelIds ?? [],
        ]),
      );

      const signIn = Effect.fn('SyntheticGoogle.signIn')(function* (
        mail: boolean,
        hint: string | null,
      ) {
        if (!mail) {
          return identity('synthetic-product-subject', false);
        }
        if (hint === null) {
          return identity(mailbox, true);
        }
        switch (scenario) {
          case 'registration-cancelled': {
            return yield* refuse('cancelled');
          }
          case 'registration-no-gmail': {
            return identity('synthetic-no-gmail', true);
          }
          case 'registration-interrupted': {
            return yield* refuse('unavailable');
          }
          default: {
            return identity('synthetic-product-subject', false);
          }
        }
      });
      const refresh = Effect.fn('SyntheticGoogle.refresh')(function* (
        subject: string,
      ) {
        if (!subject.startsWith('synthetic-')) {
          return yield* refuse('invalid-identity');
        }
        return identity(subject, subject === mailbox);
      });
      const verify = Effect.fn('SyntheticGoogle.verify')(function* (
        subject: string,
      ) {
        if (subject === 'synthetic-no-gmail') {
          return yield* refuse('gmail-unavailable');
        }
        return { subject, address: 'other@example.invalid' };
      });

      const modify = Effect.fn('SyntheticGoogle.modify')(function* (
        id: string,
        body: string | null,
      ) {
        const current = labels.get(id);
        const change =
          body === null
            ? undefined
            : yield* Schema.decodeEffect(LabelChange)(body).pipe(
                Effect.orElseSucceed(() => undefined),
              );
        if (current === undefined || change === undefined) {
          return missing;
        }
        const removed = new Set(change.removeLabelIds);
        const remaining = current.filter((label) => !removed.has(label));
        const next = [
          ...remaining,
          ...(change.addLabelIds ?? []).filter(
            (label) => !remaining.includes(label),
          ),
        ];
        labels.set(id, next);
        return yield* reply(200, {
          id,
          threadId: threadOf(id),
          labelIds: next,
        });
      });
      // The `registration-sync-status` mailbox downloads its history slowly, so the Inbox shows
      // the Sync Status Capsule: the history listing returns two messages, holds the next page for
      // two minutes and fails it once, then lists the rest.
      const slowHistory =
        scenario === 'registration-sync-status' ? { failed: false } : undefined;
      const historyPage = Effect.fnUntraced(function* (
        listed: ReadonlyArray<{
          readonly id: string;
          readonly threadId: string;
        }>,
        pageToken: string | undefined,
      ) {
        if (pageToken === undefined) {
          return yield* reply(200, {
            messages: listed.slice(0, 2),
            nextPageToken: 'rest',
          });
        }
        if (slowHistory?.failed === false) {
          slowHistory.failed = true;
          yield* Effect.sleep('2 minutes');
          return yield* reply(503, { error: { code: 503 } });
        }
        return yield* reply(200, { messages: listed.slice(2) });
      });
      // Gmail's named resources, by the request's last path segment.
      const resources: Readonly<
        Record<
          string,
          (
            url: RequestURL,
            body: string | null,
          ) => Effect.Effect<Reply, Schema.SchemaError>
        >
      > = {
        profile: () =>
          reply(200, {
            emailAddress: 'other@example.invalid',
            historyId: '100',
            ...(slowHistory === undefined
              ? {}
              : {
                  messagesTotal: [...labels.values()].filter((ids) =>
                    inView(allMail, ids),
                  ).length,
                }),
          }),
        // Synthetic Gmail accepts every message and keeps nothing of it.
        send: () =>
          reply(200, { id: '19a0c0ffee0000ff', threadId: '19a0c0ffee0000ff' }),
        history: () => reply(200, { historyId: '100' }),
        labels: () =>
          reply(200, {
            labels: [{ id: 'Label_1', name: 'Travel', type: 'user' }],
          }),
        modify: ({ segments }, body) => modify(segments.at(-2) ?? '', body),
        // The Inbox and search list the Inbox messages, the first two then the rest on a second
        // page; another view lists its messages as Gmail does, Spam and Trash only with
        // includeSpamTrash and every other message without a label.
        messages: ({ item }) => {
          if (item('labelIds') !== 'INBOX' && item('q') === undefined) {
            const listed = Arr.sort(
              Object.entries(messages).filter(
                ([id]) =>
                  inView(item('labelIds') ?? allMail, labels.get(id) ?? []) &&
                  (item('includeSpamTrash') === 'true' ||
                    !['SPAM', 'TRASH'].includes(item('labelIds') ?? '')),
              ),
              newestFirst,
            ).map(([id]) => ({ id, threadId: threadOf(id) }));
            return slowHistory !== undefined &&
              item('labelIds') === undefined &&
              item('maxResults') === String(historyPageSize)
              ? historyPage(listed, item('pageToken'))
              : reply(200, { messages: listed });
          }
          const listed = Object.entries(messages)
            .filter(([, message]) => message.labelIds?.includes('INBOX'))
            .map(([id]) => ({ id, threadId: threadOf(id) }));
          return reply(
            200,
            item('pageToken') === '2'
              ? { messages: listed.slice(2) }
              : { messages: listed.slice(0, 2), nextPageToken: '2' },
          );
        },
      };
      // One message, as its format asks for it.
      const read = (id: string, url: RequestURL) => {
        const message = Object.hasOwn(messages, id) ? messages[id] : undefined;
        return message === undefined
          ? Effect.succeed(missing)
          : reply(200, {
              id,
              threadId: threadOf(id),
              labelIds: labels.get(id) ?? [],
              ...view(message, url),
            });
      };
      // One Gmail API request with the identity's access token.
      const gmail = Effect.fn('SyntheticGoogle.gmail')(function* ({
        subject,
        url,
        body,
      }: Readonly<{ subject: string; url: string; body: string | null }>) {
        if (subject !== mailbox) {
          return { status: 401, body: '' };
        }
        const request = requestURL(url);
        const last = request.segments.at(-1) ?? '';
        const resource = Object.hasOwn(resources, last)
          ? resources[last]
          : undefined;
        return yield* resource === undefined
          ? read(last, request)
          : resource(request, body);
      });

      return { signIn, refresh, verify, gmail } as const;
    }),
  },
) {
  /**
   * Consumers provide SyntheticScenario; SyntheticGmailMessages has its default
   * mailbox.
   */
  public static readonly layer = Layer.effect(this, this.make);
}

// Sign in with Apple, whose synthetic identity stays authorized.
export class SyntheticApple extends Context.Service<SyntheticApple>()(
  '@private-email/mail-core/testing/SyntheticApple',
  {
    make: Effect.succeed({
      signIn: Effect.succeed({
        subject: 'synthetic-apple-subject',
        email: 'relay@privaterelay.example.invalid',
      }),
      credentialState: (subject: string) =>
        Effect.succeed({
          state:
            subject === 'synthetic-apple-subject' ? 'authorized' : 'revoked',
        }),
    } as const),
  },
) {
  public static readonly layer = Layer.effect(this, this.make);
}
