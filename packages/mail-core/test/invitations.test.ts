import type { BodyDocument } from '@private-email/mail-core/message-body';

import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import {
  invitationOf,
  invitationReply,
  invitationResponses,
} from '@private-email/mail-core/invitations';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';

const me = 'alex@example.invalid';
const copy = { subject: 'Accepted: Q4 roadmap review', text: 'Accepted.' };

const calendar = (event: readonly string[], method = 'REQUEST') =>
  [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    `METHOD:${method}`,
    'BEGIN:VTIMEZONE',
    'TZID:Europe/Prague',
    'END:VTIMEZONE',
    'BEGIN:VEVENT',
    ...event,
    'END:VEVENT',
    'END:VCALENDAR',
  ].join('\r\n');

const meeting = [
  'UID:roadmap-42@northwind.example',
  'SEQUENCE:2',
  String.raw`SUMMARY:Q4 roadmap review\, final`,
  'DTSTART;TZID=Europe/Prague:20261106T140000',
  'DTEND;TZID=Europe/Prague:20261106T150000',
  'LOCATION:Room 4',
  'ORGANIZER;CN="Fischer, Lena":mailto:lena@northwind.example',
  'ATTENDEE;CN=Alex;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:Alex@example.invalid',
  'ATTENDEE;CN=Team:mailto:team@northwind.example',
];

const documentOf = (text: string | undefined): BodyDocument => ({
  version: 2,
  id: 'm1',
  ...(text === undefined ? {} : { calendar: text }),
  headers: { messageId: '<invite-1@northwind.example>' },
});

// The invitation the mailbox can answer in `text`.
const offered = (text: string) => {
  const offer = invitationOf(documentOf(text), me);
  if (offer?.kind !== 'invited') {
    throw new Error('Expected an invitation for the mailbox');
  }
  return offer;
};

// The decoded calendar reply of a sent message.
const replyOf = (send: Readonly<{ raw: string }> | undefined) => {
  const raw = send?.raw ?? '';
  const match =
    /Content-Type: text\/calendar; method=REPLY; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n(?<data>[A-Za-z0-9+/=\r\n]+?)\r\n(?:\r\n|--)/u.exec(
      raw,
    );
  return Buffer.from(match?.groups?.data ?? '', 'base64').toString('utf8');
};

// A Gmail mailbox whose separately stored attachments cannot be fetched.
const withoutAttachments = (
  native: ReturnType<typeof createSyntheticGmail>['native'],
): ReturnType<typeof createSyntheticGmail>['native'] => ({
  ...native,
  gmailRequest: (path, query, request) =>
    path.includes('/attachments/')
      ? Promise.resolve({ status: 404, body: '{}' })
      : native.gmailRequest(path, query, request),
});

// An Inbox showing one received invitation and the mailbox's responses to it.
async function invited() {
  const gmail = createSyntheticGmail();
  const id = gmail.deliver({
    from: 'Lena Fischer <lena@northwind.example>',
    subject: 'Invitation: Q4 roadmap review',
    headers: { 'Message-ID': '<invite-1@northwind.example>' },
    content: {
      text: 'Join us.',
      attachments: [
        {
          filename: 'invite.ics',
          mimeType: 'text/calendar',
          bytes: [...Buffer.from(calendar(meeting))],
        },
      ],
    },
  });
  const inbox = createGmailInbox(gmail.native);
  await inbox.load();
  const close = inbox.retainMessage(id);
  await inbox.readMessage(id);
  const document = inbox.responseSource(id);
  const offer = document === undefined ? undefined : invitationOf(document, me);
  if (offer?.kind !== 'invited') {
    throw new Error('Expected an invitation for the mailbox');
  }
  return {
    gmail,
    id,
    inbox,
    close,
    invitation: offer,
    responses: invitationResponses(inbox, () => Date.UTC(2026, 10, 2, 9, 52)),
  };
}

describe('meeting invitations', () => {
  it('reads an invitation when the host omits named capture groups', () => {
    expect.hasAssertions();
    const nativeExec = RegExp.prototype.exec;
    const spy = vi
      .spyOn(RegExp.prototype, 'exec')
      .mockImplementation(function withoutNamedGroups(this: RegExp, input) {
        const result = nativeExec.call(this, input);
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Only matches carry groups to remove.
        if (result !== null) {
          delete result.groups;
        }
        return result;
      });
    try {
      expect(invitationOf(documentOf(calendar(meeting)), me)).toMatchObject({
        kind: 'invited',
        details: {
          organizer: { address: 'lena@northwind.example' },
          start: { at: Date.UTC(2026, 10, 6, 13), allDay: false },
        },
      });
    } finally {
      spy.mockRestore();
    }
  });

  it('reads one meeting for the mailbox the invitation names', () => {
    expect.hasAssertions();
    const offer = invitationOf(documentOf(calendar(meeting)), me);

    expect(offer).toMatchObject({
      kind: 'invited',
      uid: 'roadmap-42@northwind.example',
      sequence: 2,
      messageId: '<invite-1@northwind.example>',
      details: {
        summary: 'Q4 roadmap review, final',
        location: 'Room 4',
        organizer: { name: 'Fischer, Lena', address: 'lena@northwind.example' },
        start: { at: Date.UTC(2026, 10, 6, 13), allDay: false },
        end: { at: Date.UTC(2026, 10, 6, 14), allDay: false },
      },
    });
  });

  it('answers only an address the invitation names', () => {
    expect.hasAssertions();
    expect(
      invitationOf(documentOf(calendar(meeting)), 'mara@example.invalid'),
    ).toStrictEqual({
      kind: 'elsewhere',
      details: expect.objectContaining({ summary: 'Q4 roadmap review, final' }),
      invited: ['Alex@example.invalid', 'team@northwind.example'],
    });
  });

  it.each([
    ['20261025T023000', Date.UTC(2026, 9, 25, 0, 30)],
    ['20260329T023000', Date.UTC(2026, 2, 29, 1, 30)],
  ])('uses iCalendar daylight-saving rules for %s', (local, at) => {
    expect.hasAssertions();
    const event = meeting
      .filter((line) => !line.startsWith('DTEND'))
      .map((line) => line.replace('20261106T140000', local));

    expect(offered(calendar(event)).details.start).toStrictEqual({
      at,
      allDay: false,
    });
  });

  it.each([
    ['a recurring meeting', calendar([...meeting, 'RRULE:FREQ=WEEKLY'])],
    ['a cancellation', calendar(meeting, 'CANCEL')],
    [
      'a floating time',
      calendar(meeting.map((line) => line.replace(';TZID=Europe/Prague', ''))),
    ],
    [
      'an unknown time zone',
      calendar(
        meeting.map((line) => line.replace('Europe/Prague', 'Mars/Olympus')),
      ),
    ],
    [
      'a missing organizer',
      calendar(meeting.filter((line) => !line.startsWith('ORGANIZER'))),
    ],
    ['damaged text', 'not a calendar'],
    [
      'a missing calendar version',
      calendar(meeting).replace('VERSION:2.0\r\n', ''),
    ],
    [
      'an unsupported calendar version',
      calendar(meeting).replace('VERSION:2.0', 'VERSION:1.0'),
    ],
    ['a truncated event', calendar(meeting).replace('END:VEVENT\r\n', '')],
    [
      'a mismatched ending',
      calendar(meeting).replace('END:VEVENT', 'END:VTODO'),
    ],
    ['an invalid content line', calendar([...meeting, 'RRULE;FREQ=WEEKLY'])],
    ['two event identifiers', calendar([...meeting, 'UID:other-meeting'])],
    [
      'an invalid sequence',
      calendar(
        meeting.map((line) => line.replace('SEQUENCE:2', 'SEQUENCE:2e0')),
      ),
    ],
    [
      'an invalid date',
      calendar(
        meeting.map((line) =>
          line.replace('20261106T140000', '20260230T140000'),
        ),
      ),
    ],
    [
      'an invalid end',
      calendar(
        meeting.map((line) => line.replace('20261106T150000', 'not-a-time')),
      ),
    ],
    [
      'an end before the start',
      calendar(
        meeting.map((line) =>
          line.replace('20261106T150000', '20261106T120000'),
        ),
      ),
    ],
    [
      'a DATE value containing a time',
      calendar(
        meeting.map((line) =>
          line
            .replace('DTSTART;TZID=Europe/Prague', 'DTSTART;VALUE=DATE')
            .replace('20261106T140000', '20261106T140000Z'),
        ),
      ),
    ],
    [
      'an organizer address list',
      calendar(
        meeting.map((line) =>
          line.replace(
            'mailto:lena@northwind.example',
            'mailto:lena@northwind.example,other@northwind.example',
          ),
        ),
      ),
    ],
  ])('cannot read %s', (_, text) => {
    expect.hasAssertions();
    expect(invitationOf(documentOf(text), me)).toStrictEqual({
      kind: 'unreadable',
    });
  });

  it('shows no invitation for a message without a calendar part', () => {
    expect.hasAssertions();
    expect(invitationOf(documentOf(undefined), me)).toBeUndefined();
  });

  it('replies with the invitation identity and only the chosen status', () => {
    expect.hasAssertions();

    expect(
      invitationReply(
        offered(calendar(meeting)),
        'tentative',
        Date.UTC(2026, 10, 2, 9, 52),
      ),
    ).toBe(
      [
        'BEGIN:VCALENDAR',
        'PRODID:-//Unwired//Unwired Mail//EN',
        'VERSION:2.0',
        'METHOD:REPLY',
        'BEGIN:VEVENT',
        'UID:roadmap-42@northwind.example',
        'SEQUENCE:2',
        'DTSTAMP:20261102T095200Z',
        'ORGANIZER;CN="Fischer, Lena":mailto:lena@northwind.example',
        'ATTENDEE;CN=Alex;PARTSTAT=TENTATIVE:mailto:Alex@example.invalid',
        String.raw`SUMMARY:Q4 roadmap review\, final`,
        'END:VEVENT',
        'END:VCALENDAR',
        '',
      ].join('\r\n'),
    );
  });

  /* oxlint-disable vitest/max-expects -- Each journey proves one response path end to end. */
  it('sends one chosen response to the organizer in the invitation thread', async () => {
    expect.hasAssertions();
    const { gmail, id, invitation, responses, close } = await invited();

    const first = responses.respond(invitation, 'accepted', copy);
    const repeated = responses.respond(invitation, 'accepted', copy);

    expect(responses.state(invitation)).toStrictEqual({
      kind: 'sending',
      choice: 'accepted',
    });

    await Promise.all([first, repeated]);

    expect(gmail.sends).toHaveLength(1);

    const [sent] = gmail.sends;

    expect(sent?.threadId).toBe(id);
    expect(sent?.raw).toContain('From: alex@example.invalid');
    expect(sent?.raw).toContain('To: "Fischer, Lena" <lena@northwind.example>');
    expect(sent?.raw).toContain('In-Reply-To: <invite-1@northwind.example>');
    expect(replyOf(sent)).toContain(
      'ATTENDEE;CN=Alex;PARTSTAT=ACCEPTED:mailto:Alex@example.invalid',
    );
    expect(responses.state(invitation)).toStrictEqual({
      kind: 'sent',
      choice: 'accepted',
      at: Date.UTC(2026, 10, 2, 9, 52),
    });

    await responses.respond(invitation, 'accepted', copy);
    await responses.respond(invitation, 'declined', copy);

    expect(gmail.sends).toHaveLength(2);
    expect(replyOf(gmail.sends[1])).toContain('PARTSTAT=DECLINED');

    close();
  });

  it('never sends again on its own after an unknown delivery', async () => {
    expect.hasAssertions();
    const { gmail, invitation, responses, close } = await invited();
    gmail.failSend({ lost: true });

    await responses.respond(invitation, 'accepted', copy);

    expect(responses.state(invitation)).toMatchObject({
      kind: 'unknown',
      choice: 'accepted',
    });

    await responses.respond(invitation, 'declined', copy);

    expect(gmail.sends).toHaveLength(1);

    await responses.check(invitation);

    expect(responses.state(invitation)).toMatchObject({
      kind: 'sent',
      choice: 'accepted',
    });

    close();
  });

  it('sends after an unknown delivery only when asked to respond again', async () => {
    expect.hasAssertions();
    const { gmail, invitation, responses, close } = await invited();
    gmail.failSend({ code: 'delivery-unknown' });

    await responses.respond(invitation, 'accepted', copy);
    await responses.check(invitation);

    expect(responses.state(invitation)).toMatchObject({ kind: 'unknown' });
    expect(gmail.sends).toHaveLength(0);

    await responses.respondAgain(invitation, 'accepted', copy);

    expect(gmail.sends).toHaveLength(1);
    expect(responses.state(invitation)).toMatchObject({ kind: 'sent' });

    close();
  });
  /* oxlint-enable vitest/max-expects */

  it.each([
    [{ code: 'mailbox-invalidated' }, 'offline'],
    [{ status: 401 }, 'authentication'],
    [{ status: 400 }, 'refused'],
  ] as const)(
    'keeps nothing to send later when Gmail does not take it',
    async (failure, kind) => {
      expect.hasAssertions();
      const { gmail, invitation, responses, close } = await invited();
      gmail.failSend(failure);

      await responses.respond(invitation, 'declined', copy);

      expect(gmail.sends).toHaveLength(0);
      expect(responses.state(invitation)).toStrictEqual({
        kind,
        choice: 'declined',
      });

      close();
    },
  );

  it('lets the person respond again after signing in', async () => {
    expect.hasAssertions();
    const { gmail, invitation, responses, close } = await invited();
    gmail.failSend({ status: 401 });
    await responses.respond(invitation, 'accepted', copy);

    responses.signedIn(invitation);
    await responses.respond(invitation, 'accepted', copy);

    expect(gmail.sends).toHaveLength(1);
    expect(responses.state(invitation)).toMatchObject({ kind: 'sent' });

    close();
  });

  it('keeps the message readable when its invitation cannot be fetched', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      from: 'Lena Fischer <lena@northwind.example>',
      subject: 'Invitation: Q4 roadmap review',
      content: {
        text: 'Join us.',
        attachments: [
          {
            filename: 'invite.ics',
            mimeType: 'text/calendar',
            bytes: [...Buffer.from(calendar(meeting))],
          },
        ],
      },
    });
    const inbox = createGmailInbox(withoutAttachments(gmail.native));
    await inbox.load();
    const close = inbox.retainMessage(id);
    await inbox.readMessage(id);

    expect(inbox.responseSource(id)).toMatchObject({ text: 'Join us.' });
    expect(inbox.responseSource(id)).not.toHaveProperty('calendar');

    close();
  });

  it('prevents simultaneous readers of one Inbox from sending twice', async () => {
    expect.hasAssertions();
    const { inbox, invitation, gmail, responses, close } = await invited();
    const otherReader = invitationResponses(inbox);

    await Promise.all([
      responses.respond(invitation, 'accepted', copy),
      otherReader.respond(invitation, 'declined', copy),
    ]);

    expect(gmail.sends).toHaveLength(1);
    expect(otherReader.state(invitation)).toMatchObject({
      kind: 'sent',
      choice: 'accepted',
    });

    close();
  });
});
