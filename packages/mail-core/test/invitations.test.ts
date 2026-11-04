import type {
  InvitationChoice,
  ResponseState,
} from '@private-email/mail-core/invitations';
import type { BodyDocument } from '@private-email/mail-core/message-body';

import { english } from '@private-email/localization';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import {
  createInvitationFormats,
  invitationBlockedBy,
  invitationOf,
  invitationReply,
  invitationResponses,
  invitationStatus,
  invitationWas,
  invitationWhen,
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
  failure: number | Readonly<{ code: string }>,
): ReturnType<typeof createSyntheticGmail>['native'] => ({
  ...native,
  gmailRequest: (path, query, request) => {
    if (!path.includes('/attachments/')) {
      return native.gmailRequest(path, query, request);
    }
    return typeof failure === 'number'
      ? Promise.resolve({ status: failure, body: '{}' })
      : Promise.reject(Object.assign(new Error('Attachment refused'), failure));
  },
});

type NativeGmail = ReturnType<typeof createSyntheticGmail>['native'];

// An Inbox showing one received invitation and the mailbox's responses to it.
async function invited(
  native: (gmail: NativeGmail) => NativeGmail = (gmail) => gmail,
) {
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
  const inbox = createGmailInbox(native(gmail.native));
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

// The same mailbox's responses after the app relaunches and opens the invitation again.
async function relaunched(
  gmail: ReturnType<typeof createSyntheticGmail>,
  id: string,
) {
  const inbox = createGmailInbox(gmail.native);
  await inbox.load();
  const close = inbox.retainMessage(id);
  await inbox.readMessage(id);
  return {
    close,
    responses: invitationResponses(inbox, () => Date.UTC(2026, 10, 2, 10, 5)),
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

  it.each([
    ['names the mailbox', me],
    ['names only other addresses', 'mara@example.invalid'],
  ])('reads a cancellation that %s', (_, address) => {
    expect.hasAssertions();
    expect(
      invitationOf(
        documentOf(calendar([...meeting, 'STATUS:CANCELLED'], 'CANCEL')),
        address,
      ),
    ).toStrictEqual({
      kind: 'cancelled',
      details: expect.objectContaining({
        summary: 'Q4 roadmap review, final',
        organizer: { name: 'Fischer, Lena', address: 'lena@northwind.example' },
        start: { at: Date.UTC(2026, 10, 6, 13), allDay: false },
      }),
    });
    expect(
      invitationOf(documentOf(calendar(meeting, 'CANCEL')), me)?.kind,
    ).toBe('cancelled');
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

  const withoutEnd = meeting.filter((line) => !line.startsWith('DTEND'));

  it.each([
    [
      'a timed meeting',
      [...withoutEnd, 'DURATION:PT1H30M'],
      { at: Date.UTC(2026, 10, 6, 14, 30), allDay: false },
    ],
    [
      'an all-day meeting',
      [
        ...withoutEnd.map((line) =>
          line.replace(
            'DTSTART;TZID=Europe/Prague:20261106T140000',
            'DTSTART;VALUE=DATE:20261106',
          ),
        ),
        'DURATION:P3D',
      ],
      { at: Date.UTC(2026, 10, 9), allDay: true },
    ],
  ])('ends %s after its DURATION', (_, event, end) => {
    expect.hasAssertions();
    expect(offered(calendar(event)).details.end).toStrictEqual(end);
  });

  it.each([
    ['a recurring meeting', calendar([...meeting, 'RRULE:FREQ=WEEKLY'])],
    [
      'a recurring cancellation',
      calendar([...meeting, 'RRULE:FREQ=WEEKLY'], 'CANCEL'),
    ],
    [
      'a cancellation of one occurrence',
      calendar(
        [...meeting, 'RECURRENCE-ID;TZID=Europe/Prague:20261106T140000'],
        'CANCEL',
      ),
    ],
    [
      'a cancellation whose status is not cancelled',
      calendar([...meeting, 'STATUS:CONFIRMED'], 'CANCEL'),
    ],
    [
      'a cancellation with two statuses',
      calendar([...meeting, 'STATUS:CANCELLED', 'STATUS:CANCELLED'], 'CANCEL'),
    ],
    ['an unsupported method', calendar(meeting, 'PUBLISH')],
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
    ['both an end and a duration', calendar([...meeting, 'DURATION:PT1H'])],
    [
      'a timed meeting lasting whole days',
      calendar([...withoutEnd, 'DURATION:P1D']),
    ],
    ['a negative duration', calendar([...withoutEnd, 'DURATION:-PT1H'])],
    [
      'a duration beyond the supported date range',
      calendar([...withoutEnd, 'DURATION:PT99999999999999999H']),
    ],
    ['a truncated event', calendar(meeting).replace('END:VEVENT\r\n', '')],
    [
      'a mismatched ending',
      calendar(meeting).replace('END:VEVENT', 'END:VTODO'),
    ],
    ['an invalid content line', calendar([...meeting, 'RRULE;FREQ=WEEKLY'])],
    [
      'a parameter name containing an underscore',
      calendar([...meeting, 'X-NOTE;a_b=c:x']),
    ],
    [
      'a parameter name containing a space',
      calendar([...meeting, 'X-NOTE;a b=c:x']),
    ],
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

  it.each([
    [
      'a damaged line of unquoted lists',
      `ATTENDEE;CN=${'a,'.repeat(60_000)}":mailto:${me}`,
      'unreadable',
    ],
    [
      'a line of many parameters',
      `X-NOTE${';a=b'.repeat(30_000)}:x`,
      'invited',
    ],
  ])('classifies %s', (_, line, kind) => {
    expect.hasAssertions();

    expect(
      invitationOf(documentOf(calendar([...meeting, line])), me)?.kind,
    ).toBe(kind);
  });

  it.each([
    [
      'nested calendar data',
      calendar([
        ...meeting,
        ...Array.from({ length: 1000 }, () => 'BEGIN:X'),
        'X-NOTE:nested',
        ...Array.from({ length: 1000 }, () => 'END:X'),
      ]),
    ],
    [
      'a long extension component name',
      calendar(meeting).replace(
        'END:VCALENDAR',
        [
          `BEGIN:X-${'A'.repeat(1000)}`,
          ...Array.from({ length: 1000 }, () => 'X-NOTE:x'),
          `END:X-${'A'.repeat(1000)}`,
          'END:VCALENDAR',
        ].join('\r\n'),
      ),
    ],
  ])('keeps component scope work linear for %s', (_, input) => {
    expect.hasAssertions();
    const { join } = Array.prototype;
    let joinedCharacters = 0;
    const spy = vi
      .spyOn(Array.prototype, 'join')
      .mockImplementation(function countJoinedCharacters(
        this: unknown[],
        separator?: string,
      ) {
        const result = join.call(this, separator);
        joinedCharacters += result.length;
        return result;
      });
    try {
      expect(invitationOf(documentOf(input), me)?.kind).toBe('invited');
      expect(joinedCharacters).toBeLessThanOrEqual(input.length);
    } finally {
      spy.mockRestore();
    }
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
    expect(sent?.raw).toContain('Subject: Re: Invitation: Q4 roadmap review');
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

  it('asks again for a revised meeting after answering the earlier one', async () => {
    expect.hasAssertions();
    const { gmail, invitation, responses, close } = await invited();
    await responses.respond(invitation, 'accepted', copy);
    const revised = { ...invitation, sequence: invitation.sequence + 1 };

    expect(responses.state(revised)).toStrictEqual({ kind: 'unanswered' });

    await responses.respond(revised, 'accepted', copy);

    expect(gmail.sends).toHaveLength(2);
    expect(replyOf(gmail.sends[1])).toContain('SEQUENCE:3');

    close();
  });

  it('names the earlier answer to a revision that moved the meeting', async () => {
    expect.hasAssertions();
    const { gmail, id, invitation, responses, close } = await invited();
    const hour = 60 * 60 * 1000;
    // The fixture meeting has an end.
    const { start, end = start } = invitation.details;
    const later = (time: typeof start) => ({
      ...time,
      at: time.at + 20 * hour,
    });
    const moved = {
      ...invitation,
      sequence: 3,
      details: {
        ...invitation.details,
        start: later(start),
        end: later(end),
      },
    };
    await responses.respond(invitation, 'accepted', copy);

    expect(responses.earlier(moved)).toMatchObject({
      choice: 'accepted',
      start,
      end,
    });
    expect(responses.earlier({ ...invitation, sequence: 3 })).toBeUndefined();
    expect(responses.state(moved)).toStrictEqual({ kind: 'unanswered' });

    close();
    const relaunch = await relaunched(gmail, id);
    await relaunch.responses.respond(moved, 'declined', copy);

    expect(relaunch.responses.earlier(moved)).toMatchObject({
      choice: 'accepted',
      start,
    });
    expect(relaunch.responses.state(moved)).toMatchObject({
      kind: 'sent',
      choice: 'declined',
    });

    relaunch.close();
  });

  it('names the latest earlier answer, and none once a newer revision was answered', async () => {
    expect.hasAssertions();
    const { inbox, invitation, responses, close } = await invited();
    const { uid, sequence } = invitation;
    const { start, end = start } = invitation.details;
    const at = Date.UTC(2026, 10, 1, 8, 0);
    const answered = (
      revision: number,
      choice: InvitationChoice,
      until: typeof end,
    ) =>
      inbox.recordResponse(
        { uid, sequence: revision },
        {
          kind: 'sent',
          uid,
          sequence: revision,
          choice,
          at,
          start,
          end: until,
        },
      );
    await answered(sequence - 2, 'accepted', { ...end, at: end.at + 1 });
    // Only the end moved since this answer.
    await answered(sequence - 1, 'tentative', { ...end, at: end.at - 1 });

    expect(responses.earlier(invitation)).toMatchObject({
      choice: 'tentative',
    });

    await answered(sequence + 1, 'declined', end);

    expect(responses.earlier(invitation)).toBeUndefined();

    close();
  });

  it('names no earlier answer it cannot compare or that was never confirmed', async () => {
    expect.hasAssertions();
    const { inbox, invitation, responses, close } = await invited();
    const { uid } = invitation;
    const at = Date.UTC(2026, 10, 1, 8, 0);
    await inbox.recordResponse(
      { uid, sequence: 1 },
      { kind: 'sent', uid, sequence: 1, choice: 'declined', at },
    );

    expect(responses.earlier(invitation)).toBeUndefined();

    await inbox.recordResponse(
      { uid, sequence: 1 },
      {
        kind: 'unknown',
        uid,
        sequence: 1,
        choice: 'declined',
        boundary: 'b',
        start: { at, allDay: false },
      },
    );

    expect(responses.earlier(invitation)).toBeUndefined();

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

  it('restores a confirmed response after relaunch without sending it again', async () => {
    expect.hasAssertions();
    const { gmail, id, invitation, responses, close } = await invited();
    await responses.respond(invitation, 'tentative', copy);
    close();

    const later = await relaunched(gmail, id);

    expect(later.responses.state(invitation)).toStrictEqual({
      kind: 'sent',
      choice: 'tentative',
      at: Date.UTC(2026, 10, 2, 9, 52),
    });

    await later.responses.respond(invitation, 'tentative', copy);

    expect(gmail.sends).toHaveLength(1);

    later.close();
  });

  it('restores an unknown delivery after relaunch and still finds it in Sent', async () => {
    expect.hasAssertions();
    const { gmail, id, invitation, responses, close } = await invited();
    gmail.failSend({ lost: true });
    await responses.respond(invitation, 'accepted', copy);
    close();

    const later = await relaunched(gmail, id);

    expect(later.responses.state(invitation)).toMatchObject({
      kind: 'unknown',
      choice: 'accepted',
    });

    await later.responses.respond(invitation, 'accepted', copy);

    expect(gmail.sends).toHaveLength(1);

    await later.responses.check(invitation);

    expect(later.responses.state(invitation)).toStrictEqual({
      kind: 'sent',
      choice: 'accepted',
      at: Date.UTC(2026, 10, 2, 10, 5),
    });

    later.close();
    const again = await relaunched(gmail, id);

    expect(again.responses.state(invitation)).toMatchObject({ kind: 'sent' });

    again.close();
  });

  it('shows a response the app quit while sending as an unknown delivery', async () => {
    expect.hasAssertions();
    const sending = Promise.withResolvers<undefined>();
    const unanswered = Promise.withResolvers<never>();
    const { gmail, id, invitation, responses, close } = await invited(
      (native) => ({
        ...native,
        gmailSend: () => {
          sending.resolve(undefined);
          return unanswered.promise;
        },
      }),
    );
    void responses.respond(invitation, 'declined', copy);
    await sending.promise;
    close();

    const later = await relaunched(gmail, id);

    expect(later.responses.state(invitation)).toMatchObject({
      kind: 'unknown',
      choice: 'declined',
    });

    later.close();
  });

  it('sends nothing it cannot record', async () => {
    expect.hasAssertions();
    const { gmail, invitation, responses, close } = await invited();
    gmail.failCommit('storage-unavailable');

    await responses.respond(invitation, 'accepted', copy);

    expect(gmail.sends).toHaveLength(0);
    expect(responses.state(invitation)).toStrictEqual({
      kind: 'refused',
      choice: 'accepted',
    });

    close();
  });

  it('keeps an unknown delivery when responding again cannot be recorded', async () => {
    expect.hasAssertions();
    const { gmail, invitation, responses, close } = await invited();
    gmail.failSend({ code: 'delivery-unknown' });
    await responses.respond(invitation, 'accepted', copy);
    const unknown = responses.state(invitation);
    gmail.failCommit('storage-unavailable');

    await responses.respondAgain(invitation, 'declined', copy);

    expect(gmail.sends).toHaveLength(0);
    expect(responses.state(invitation)).toStrictEqual(unknown);

    close();
  });

  it('restores unknown delivery when saving the confirmation fails and checks it without resending', async () => {
    expect.hasAssertions();
    let refuseConfirmation: () => void = () => undefined;
    const { gmail, id, invitation, responses, close } = await invited(
      (native) => ({
        ...native,
        gmailSend: async (message, scope) => {
          const reply = await native.gmailSend(message, scope);
          refuseConfirmation();
          return reply;
        },
      }),
    );
    refuseConfirmation = () => gmail.failCommit('unavailable');
    await responses.respond(invitation, 'accepted', copy);
    close();

    const later = await relaunched(gmail, id);

    expect(later.responses.state(invitation)).toMatchObject({
      kind: 'unknown',
    });

    await later.responses.check(invitation);

    expect(later.responses.state(invitation)).toMatchObject({ kind: 'sent' });
    expect(gmail.sends).toHaveLength(1);

    later.close();
  });

  it('keeps a confirmed response when a quick second response follows a refused one', async () => {
    expect.hasAssertions();
    const restoring = Promise.withResolvers<undefined>();
    const proceed = Promise.withResolvers<undefined>();
    let held = -1;
    const { gmail, id, invitation, responses, close } = await invited(
      (native) => ({
        ...native,
        commitMailbox: async (...commit) => {
          held -= 1;
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Hold only the refused response's restore at the storage boundary.
          if (held === 0) {
            restoring.resolve(undefined);
            await proceed.promise;
          }
          return native.commitMailbox(...commit);
        },
      }),
    );
    await responses.respond(invitation, 'accepted', copy);
    gmail.failSend({ status: 400 }, { status: 400 });
    held = 2;
    const declining = responses.respond(invitation, 'declined', copy);
    await restoring.promise;
    const retrying = responses.respond(invitation, 'tentative', copy);
    proceed.resolve(undefined);
    await Promise.all([declining, retrying]);
    close();

    const later = await relaunched(gmail, id);

    expect(later.responses.state(invitation)).toStrictEqual({
      kind: 'sent',
      choice: 'accepted',
      at: Date.UTC(2026, 10, 2, 9, 52),
    });

    later.close();
  });

  it('keeps an unknown response after recording more than one metadata window of responses', async () => {
    expect.hasAssertions();
    const { gmail, id, inbox, invitation, responses, close } = await invited();
    gmail.failSend({ lost: true });
    await responses.respond(invitation, 'accepted', copy);
    for (let index = 0; index < 200; index += 1) {
      const revision = { uid: `other-${index}`, sequence: 0 };
      await inbox.recordResponse(revision, {
        ...revision,
        kind: 'sent',
        choice: 'accepted',
        at: Date.UTC(2026, 10, 2, 10),
      });
    }
    close();

    const later = await relaunched(gmail, id);

    expect(later.responses.state(invitation)).toMatchObject({
      kind: 'unknown',
      choice: 'accepted',
    });

    later.close();
  });

  it('does not resurrect a removed response when a concurrent synchronization rebases', async () => {
    expect.hasAssertions();
    const reading = Promise.withResolvers<undefined>();
    const proceed = Promise.withResolvers<undefined>();
    let hold = false;
    const { gmail, id, inbox, invitation, responses, close } = await invited(
      (native) => ({
        ...native,
        gmailRequest: async (path, query, scope) => {
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Hold only the next history request at the provider boundary.
          if (hold && path === 'history') {
            hold = false;
            reading.resolve(undefined);
            await proceed.promise;
          }
          return native.gmailRequest(path, query, scope);
        },
      }),
    );
    await responses.respond(invitation, 'accepted', copy);
    hold = true;
    const loading = inbox.load();
    await reading.promise;
    await inbox.recordResponse(invitation, undefined);
    proceed.resolve(undefined);
    await loading;
    close();

    const later = await relaunched(gmail, id);

    expect(later.responses.state(invitation)).toStrictEqual({
      kind: 'unanswered',
    });

    later.close();
  });

  it.each([
    ['locked', { kind: 'locked' }],
    ['mailbox-revoked', { kind: 'loading' }],
    ['gmail-unavailable', { kind: 'ready', sync: 'authentication' }],
  ] as const)(
    'recovers mailbox access when recording discovers %s',
    async (code, expected) => {
      expect.hasAssertions();
      const { gmail, inbox, invitation, responses, close } = await invited();
      gmail.failOpen(code);

      await responses.respond(invitation, 'accepted', copy);

      expect(inbox.getSnapshot()).toMatchObject(expected);
      expect(gmail.sends).toHaveLength(0);

      close();
    },
  );

  it('removes recorded responses with the mailbox', async () => {
    expect.hasAssertions();
    const { gmail, id, invitation, responses, close } = await invited();
    await responses.respond(invitation, 'accepted', copy);
    close();
    gmail.reselect(me);

    const later = await relaunched(gmail, id);

    expect(later.responses.state(invitation)).toStrictEqual({
      kind: 'unanswered',
    });

    later.close();
  });

  it.each([
    [{ code: 'mailbox-invalidated' }, 'offline'],
    [{ status: 401 }, 'authentication'],
    [{ status: 400 }, 'refused'],
  ] as const)(
    'keeps nothing to send later when Gmail does not take it',
    async (failure, kind) => {
      expect.hasAssertions();
      const { gmail, id, invitation, responses, close } = await invited();
      gmail.failSend(failure);

      await responses.respond(invitation, 'declined', copy);

      expect(gmail.sends).toHaveLength(0);
      expect(responses.state(invitation)).toStrictEqual({
        kind,
        choice: 'declined',
      });

      close();

      const later = await relaunched(gmail, id);

      expect(later.responses.state(invitation)).toStrictEqual({
        kind: 'unanswered',
      });

      later.close();
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

  it.each([
    [404, 'current', expect.objectContaining({ text: 'Join us.' })],
    [401, 'authentication', expect.objectContaining({ text: 'Join us.' })],
    [{ code: 'locked' }, 'current', undefined],
  ] as const)(
    'preserves body access and sign-in state after invitation fetch failure %s',
    async (failure, sync, source) => {
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
      const inbox = createGmailInbox(withoutAttachments(gmail.native, failure));
      await inbox.load();
      const close = inbox.retainMessage(id);
      await inbox.readMessage(id);

      expect(inbox.responseSource(id)).toStrictEqual(source);
      expect(inbox.responseSource(id)?.calendar).toBeUndefined();
      expect(inbox.getSnapshot()).toMatchObject({ kind: 'ready', sync });

      close();
    },
  );

  it('lists the attachments of a message whose calendar part cannot decode', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const bytes = [...Buffer.from(calendar(meeting))];
    const id = gmail.deliver({
      from: 'Lena Fischer <lena@northwind.example>',
      subject: 'Invitation',
      content: {
        text: 'Join us.',
        attachments: [
          {
            filename: 'invite.ics',
            mimeType: 'text/calendar',
            bytes,
            size: bytes.length + 1,
          },
        ],
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const close = inbox.retainMessage(id);
    await inbox.readMessage(id);

    expect(inbox.responseSource(id)?.calendar).toBeUndefined();
    expect(inbox.messageAttachments(id)).toContainEqual(
      expect.objectContaining({ name: 'invite.ics' }),
    );

    close();
  });

  it('keeps a cached invitation readable and asks for sign-in before fetching more parts', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      from: 'Lena Fischer <lena@northwind.example>',
      subject: 'Invitation',
      content: {
        html: '<p>Join us.</p><img src="cid:logo">',
        images: [{ contentId: 'logo', mimeType: 'image/png', bytes: [1] }],
        attachments: [
          {
            filename: 'invite.ics',
            mimeType: 'text/calendar',
            bytes: [...Buffer.from(calendar(meeting))],
          },
        ],
      },
    });
    const native = { ...withoutAttachments(gmail.native, 503) };
    const inbox = createGmailInbox(native);
    await inbox.load();
    const first = inbox.retainMessage(id);
    await inbox.readMessage(id);
    first();
    const requests: string[] = [];
    native.gmailRequest = (path, query, request) => {
      requests.push(path);
      // oxlint-disable-next-line vitest/no-conditional-in-test -- Only the calendar is refused; a successful image read must not hide the rejected grant.
      return path.endsWith('/attachments/file-0')
        ? Promise.resolve({ status: 401, body: '{}' })
        : gmail.native.gmailRequest(path, query, request);
    };
    const second = inbox.retainMessage(id);
    try {
      await inbox.readMessage(id);

      expect(inbox.responseSource(id)?.html).toContain('Join us.');
      expect(inbox.getSnapshot()).toMatchObject({
        kind: 'ready',
        sync: 'authentication',
      });
      expect(requests).not.toContain(`messages/${id}/attachments/image-0`);
    } finally {
      second();
    }
  });

  it('shows the invitation once Gmail can send it after an earlier open failed', async () => {
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
    const failing = withoutAttachments(gmail.native, 503);
    const native = { ...gmail.native };
    const inbox = createGmailInbox(native);
    native.gmailRequest = failing.gmailRequest;
    await inbox.load();
    const first = inbox.retainMessage(id);
    await inbox.readMessage(id);
    const missing = inbox.responseSource(id)?.calendar;
    first();
    native.gmailRequest = gmail.native.gmailRequest;
    const second = inbox.retainMessage(id);
    await inbox.readMessage(id);

    expect(missing).toBeUndefined();
    expect(inbox.responseSource(id)?.calendar).toContain(
      'UID:roadmap-42@northwind.example',
    );

    second();
  });

  it.each(['locked', 'mailbox-revoked', 'mailbox-invalidated'])(
    'hides a shown invitation when its cached calendar retry discovers %s',
    async (code) => {
      expect.hasAssertions();
      const gmail = createSyntheticGmail();
      const id = gmail.deliver({
        from: 'Lena Fischer <lena@northwind.example>',
        subject: 'Invitation',
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
      const native = { ...withoutAttachments(gmail.native, 503) };
      const inbox = createGmailInbox(native);
      await inbox.load();
      const close = inbox.retainMessage(id);
      await inbox.readMessage(id);
      native.gmailRequest = withoutAttachments(gmail.native, {
        code,
      }).gmailRequest;
      try {
        await inbox.readMessage(id, { refresh: true });

        expect(inbox.responseSource(id)).toBeUndefined();
        expect(inbox.messageBody(id)).toMatchObject({ kind: 'unavailable' });
      } finally {
        close();
      }
    },
  );

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

  describe('card text shared by the Mac, iPhone and iPad readers', () => {
    const utc = (options: Intl.DateTimeFormatOptions) =>
      new Intl.DateTimeFormat('en-US', { ...options, timeZone: 'UTC' });
    // Pinned to UTC so the expected text doesn't depend on the test machine's time zone.
    const formats = {
      ...createInvitationFormats('en-US'),
      day: utc({
        weekday: 'short',
        day: 'numeric',
        month: 'short',
        year: 'numeric',
      }),
      time: utc({ hour: 'numeric', minute: '2-digit' }),
      earlierDay: utc({ weekday: 'short', day: 'numeric', month: 'short' }),
    };
    const organizer = {
      name: 'Lena Fischer',
      address: 'lena@northwind.example',
    };
    const when = (
      start: { at: number; allDay: boolean },
      end?: { at: number; allDay: boolean },
    ) =>
      invitationWhen(english, formats, {
        organizer,
        start,
        ...(end === undefined ? {} : { end }),
      } as Parameters<typeof invitationWhen>[2]).replaceAll('\u202F', ' ');

    it('reads an all-day end as exclusive', () => {
      expect.hasAssertions();

      const allDay = (date: number) => ({
        at: Date.UTC(2026, 10, date),
        allDay: true,
      });
      expect(when(allDay(6), allDay(7))).toBe('Fri, Nov 6, 2026, all day');
      expect(when(allDay(6), allDay(9))).toBe(
        'Fri, Nov 6, 2026 – Sun, Nov 8, 2026, all day',
      );
    });

    it('names the day once for a same-day meeting and twice across days', () => {
      expect.hasAssertions();

      const at = (date: number, hour: number) => ({
        at: Date.UTC(2026, 10, date, hour),
        allDay: false,
      });
      expect(when(at(6, 13), at(6, 14))).toBe(
        'Fri, Nov 6, 2026, 1:00 PM–2:00 PM',
      );
      expect(when(at(6, 22), at(7, 1))).toBe(
        'Fri, Nov 6, 2026, 10:00 PM – Sat, Nov 7, 2026, 1:00 AM',
      );
      expect(when(at(6, 13))).toBe('Fri, Nov 6, 2026, 1:00 PM');
    });

    it('names the earlier answer and time of a moved meeting', () => {
      expect.hasAssertions();

      const earlier = {
        choice: 'tentative',
        start: { at: Date.UTC(2026, 10, 6, 13), allDay: false },
        end: { at: Date.UTC(2026, 10, 6, 14), allDay: false },
      } as const;

      expect(
        invitationStatus(
          { kind: 'unanswered' },
          {
            t: english,
            name: 'Lena Fischer',
            address: me,
            provider: 'Gmail',
            time: formats.time,
            earlier: earlier.choice,
          },
        ),
      ).toStrictEqual({
        icon: 'info.circle',
        title: 'Lena Fischer changed the time',
        detail:
          'You tentatively accepted the earlier time. Respond to the new time.',
      });
      expect(
        invitationWas(english, formats, earlier).replaceAll('\u202F', ' '),
      ).toBe('Was Fri, Nov 6, 1:00 PM–2:00 PM');
    });

    it('describes each response state', () => {
      expect.hasAssertions();

      const context = {
        t: english,
        name: 'Lena Fischer',
        address: me,
        provider: 'Gmail',
        time: formats.time,
      };
      const normalized = (status: ReturnType<typeof invitationStatus>) => ({
        ...status,
        detail: status.detail.replaceAll('\u202F', ' '),
      });
      const choice = 'accepted' as const;
      const boundary = 'b';
      const states: readonly ResponseState[] = [
        { kind: 'unanswered' },
        { kind: 'sending', choice },
        { kind: 'sent', choice, at: Date.UTC(2026, 10, 4, 9, 41) },
        { kind: 'refused', choice },
        { kind: 'unknown', choice, boundary },
        { kind: 'checking', choice, boundary },
        { kind: 'offline', choice },
        { kind: 'authentication', choice },
      ];

      expect(
        states.map((state) => normalized(invitationStatus(state, context))),
      ).toStrictEqual([
        {
          title: 'Not answered yet',
          detail: `Your response goes to Lena Fischer from ${me}.`,
        },
        {
          busy: true,
          title: 'Sending your response…',
          detail: `Accept, from ${me}.`,
        },
        {
          icon: 'checkmark.circle.fill',
          tone: 'accentInk',
          title: 'Accepted',
          detail:
            'Gmail confirmed it sent your response to Lena Fischer at 9:41 AM. Choose another response to change it.',
        },
        {
          icon: 'exclamationmark.triangle.fill',
          tone: 'statusDestructive',
          title: 'Not sent',
          detail:
            'Gmail refused your Accept response, so Lena Fischer didn’t get it. Choose a response to try again.',
        },
        {
          icon: 'exclamationmark.triangle.fill',
          tone: 'statusWarning',
          title: 'Delivery unknown',
          detail:
            'Gmail may have sent your Accept response. Unwired won’t send it again on its own — check Sent in Gmail, or check again.',
        },
        {
          busy: true,
          title: 'Checking with Gmail…',
          detail: 'Looking for your Accept response in Sent.',
        },
        {
          icon: 'wifi.slash',
          title: 'You’re offline',
          detail:
            'Connect to respond. Unwired doesn’t keep a response to send later.',
        },
        {
          icon: 'exclamationmark.triangle.fill',
          tone: 'statusWarning',
          title: 'Gmail needs you to sign in again',
          detail: `${me} can’t send responses until you sign in. Nothing has been sent.`,
        },
      ]);
      expect([
        invitationBlockedBy('retry'),
        invitationBlockedBy('authentication'),
        invitationBlockedBy('idle'),
      ]).toStrictEqual(['offline', 'authentication', undefined]);
    });
  });
});
