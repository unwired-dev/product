import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';

const me = 'alex@example.invalid';

const cancellation = [
  'BEGIN:VCALENDAR',
  'VERSION:2.0',
  'METHOD:CANCEL',
  'BEGIN:VEVENT',
  'UID:roadmap-42@northwind.example',
  'SEQUENCE:3',
  'STATUS:CANCELLED',
  'SUMMARY:Q4 roadmap review',
  'DTSTART:20261106T130000Z',
  'DTEND:20261106T140000Z',
  'ORGANIZER;CN=Lena Fischer:mailto:lena@northwind.example',
  `ATTENDEE;CN=Alex:mailto:${me}`,
  'END:VEVENT',
  'END:VCALENDAR',
].join('\r\n');

// An invitation message as a calendar client sends it: text, the calendar alternative and the same
// calendar attached as a file.
const invitationMessage = (calendar: string) =>
  [
    'From: Lena Fischer <lena@northwind.example>',
    `To: ${me}`,
    'Subject: Cancelled: Q4 roadmap review',
    'Message-ID: <cancel-1@northwind.example>',
    'MIME-Version: 1.0',
    'Content-Type: multipart/mixed; boundary="mixed"',
    '',
    '--mixed',
    'Content-Type: multipart/alternative; boundary="alt"',
    '',
    '--alt',
    'Content-Type: text/plain; charset=utf-8',
    '',
    'This meeting was cancelled.',
    '--alt',
    'Content-Type: text/calendar; charset=utf-8; method=CANCEL',
    '',
    calendar,
    '--alt--',
    '--mixed',
    'Content-Type: application/ics; name="invite.ics"',
    'Content-Disposition: attachment; filename="invite.ics"',
    '',
    calendar,
    '--mixed--',
  ].join('\r\n');

describe('imap meeting invitations', () => {
  it('reads the calendar part of an opened IMAP message and keeps its attachment listed', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    const uid = imap.deliver('INBOX', {
      subject: 'Cancelled: Q4 roadmap review',
      raw: invitationMessage(cancellation),
    });
    const inbox = createImapInbox(imap.native, { connection: 'imap-1' });
    await inbox.load();
    const id = `7.${uid}.INBOX`;
    inbox.retainMessage(id, Symbol('reader'));
    await inbox.readMessage(id);
    expect(inbox.responseSource(id)?.calendar).toBe(cancellation);
    expect(inbox.messageAttachments(id)).toMatchObject([
      { name: 'invite.ics', mimeType: 'application/ics' },
    ]);
  });
});
