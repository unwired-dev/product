import { english } from '@private-email/localization';
import PostalMime from 'postal-mime';

import type { ImapMailbox } from '../src/mailboxes.ts';
import type { RegistrationSnapshot } from '../src/registration.ts';

import { createImapInbox } from '../src/imap-inbox.ts';
import { imapInvitationResponses, invitationOf } from '../src/invitations.ts';
import { createMailboxes } from '../src/mailboxes.ts';
import { createOutbox, undoSendWindow } from '../src/outbox.ts';
import { createSyntheticProductSync } from '../src/testing/drafts.ts';
import { syntheticConnections } from '../src/testing/gmail-mailbox.ts';
import { createSyntheticImap } from '../src/testing/imap-mailbox.ts';
import { device, present } from './draft-sync-fixture.ts';
import { account } from './outbox-fixture.ts';

const work = { id: 'connection-work', address: 'alex@work.example.invalid' };

const snapshot = (smtp: boolean): RegistrationSnapshot => ({
  kind: 'connected',
  productAccountId: account,
  signInProvider: 'google',
  mailboxes: JSON.stringify([
    {
      ...work,
      provider: 'imap',
      state: 'connected',
      imap: { host: 'imap.example.invalid', port: 993, username: work.address },
      ...(smtp
        ? {
            smtp: {
              host: 'smtp.example.invalid',
              port: 465,
              security: 'tls',
              username: work.address,
            },
          }
        : {}),
    },
  ]),
});

const calendar = (sequence: number) =>
  [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'METHOD:REQUEST',
    'BEGIN:VEVENT',
    'UID:roadmap-42@northwind.example',
    `SEQUENCE:${sequence.toString()}`,
    'SUMMARY:Q4 roadmap review',
    'DTSTART:20261106T130000Z',
    'DTEND:20261106T140000Z',
    'ORGANIZER;CN=Lena Fischer:mailto:lena@northwind.example',
    `ATTENDEE;CN=Alex;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:${work.address}`,
    'END:VEVENT',
    'END:VCALENDAR',
  ].join('\r\n');

const invitationMessage = (sequence: number) =>
  [
    'From: Lena Fischer <lena@northwind.example>',
    `To: ${work.address}`,
    'Subject: Invitation: Q4 roadmap review',
    `Message-ID: <invite-${sequence.toString()}@northwind.example>`,
    'MIME-Version: 1.0',
    'Content-Type: multipart/alternative; boundary="alt"',
    '',
    '--alt',
    'Content-Type: text/plain; charset=utf-8',
    '',
    'Please join.',
    '--alt',
    'Content-Type: text/calendar; charset=utf-8; method=REQUEST',
    '',
    calendar(sequence),
    '--alt--',
  ].join('\r\n');

const clock = { now: 0 };
const later = (milliseconds: number) => {
  clock.now += milliseconds;
  vi.setSystemTime(clock.now);
};

// A device whose IMAP mailbox received an invitation, opened in its reader.
async function invited({
  smtp = true,
  sent = true,
  sequence = 2,
}: Readonly<{ smtp?: boolean; sent?: boolean; sequence?: number }> = {}) {
  const server = createSyntheticImap({ address: work.address });
  if (sent) {
    server.addFolder('Sent', ['sent']);
  }
  const uid = server.deliver('INBOX', {
    subject: 'Invitation: Q4 roadmap review',
    raw: invitationMessage(sequence),
  });
  const phone = await device(createSyntheticProductSync(), account, 'phone');
  phone.change(snapshot(smtp));
  const mailboxes = createMailboxes(
    syntheticConnections({}, { [work.id]: server.native }),
    phone.registration,
  );
  await mailboxes.load();
  const outbox = createOutbox({
    drafts: phone.drafts,
    mailboxes,
    registration: phone.registration,
    claims: phone.storage.delivery,
  });
  const mailbox = present(
    mailboxes
      .getConnections()
      .find(
        (each): each is ImapMailbox =>
          each.id === work.id && each.provider === 'imap',
      ),
    'the IMAP mailbox',
  );
  await mailbox.inbox.load();
  const id = `7.${uid.toString()}.INBOX`;
  mailbox.inbox.retainMessage(id, Symbol('reader'));
  await mailbox.inbox.readMessage(id);
  const offer = invitationOf(
    present(mailbox.inbox.responseSource(id), 'the opened invitation'),
    work.address,
  );
  if (offer?.kind !== 'invited') {
    throw new Error('Expected an invitation to answer');
  }
  const responses = imapInvitationResponses(mailbox.inbox, outbox, work.id);
  return {
    server,
    phone,
    outbox,
    inbox: mailbox.inbox,
    invitation: offer,
    responses,
    respond: (choice: 'accepted' | 'tentative' | 'declined') =>
      responses.respond(offer, choice, english),
    state: () => responses.state(offer),
    // Ends the Undo Send Window and hands what is due to the mail server.
    deliver: async () => {
      later(undoSendWindow);
      await outbox.process();
    },
  };
}

describe('imap invitation responses', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'] });
    clock.now = Date.UTC(2026, 10, 2, 9, 52);
    vi.setSystemTime(clock.now);
  });
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  afterEach(() => {
    vi.useRealTimers();
  });

  it('waits out the Undo Send Window, sends one reply through SMTP and records it in the mailbox', async () => {
    expect.hasAssertions();
    const mail = await invited();
    try {
      await mail.respond('accepted');
      const waiting = mail.state();
      await mail.outbox.process();
      expect({
        waiting,
        submitted: mail.server.smtp.accepted.length,
        drafts: mail.phone.drafts.getSnapshot(),
        outbox: mail.outbox.getSnapshot(),
      }).toMatchObject({
        waiting: { kind: 'waiting', choice: 'accepted' },
        submitted: 0,
        drafts: { kind: 'ready', drafts: [] },
        outbox: [
          {
            state: 'waiting',
            draft: { connection: work.id, from: work.address },
            invitation: {
              uid: 'roadmap-42@northwind.example',
              sequence: 2,
              choice: 'accepted',
              summary: 'Q4 roadmap review',
            },
          },
        ],
      });
      // Choosing again while it waits sends nothing more.
      await mail.respond('declined');
      await mail.deliver();

      const [submitted, ...others] = mail.server.smtp.accepted;
      const sent = await PostalMime.parse(present(submitted, 'a reply').raw, {
        attachmentEncoding: 'utf8',
      });
      const reply = present(
        sent.attachments.find(({ mimeType }) => mimeType === 'text/calendar'),
        'the calendar reply',
      ).content;
      expect({
        others,
        recipients: submitted?.recipients,
        from: sent.from?.address,
        subject: sent.subject,
        inReplyTo: sent.inReplyTo,
        reply,
        outbox: mail.outbox.getSnapshot(),
        state: mail.state(),
      }).toMatchObject({
        others: [],
        recipients: ['lena@northwind.example'],
        from: work.address,
        subject: 'Re: Invitation: Q4 roadmap review',
        inReplyTo: '<invite-2@northwind.example>',
        reply: expect.stringMatching(
          /METHOD:REPLY[\s\S]*SEQUENCE:2[\s\S]*PARTSTAT=ACCEPTED/u,
        ) as unknown,
        outbox: [],
        state: { kind: 'sent', choice: 'accepted', at: clock.now },
      });
      // The Sent folder holds the copy.
      expect(mail.server.server.changes).toStrictEqual([
        expect.stringMatching(/^append Sent/u) as unknown,
      ]);

      // Another run of the app reads the response from the mailbox's cache.
      const relaunched = createImapInbox(mail.server.native, {
        connection: work.id,
      });
      await relaunched.load();
      expect(
        imapInvitationResponses(relaunched, mail.outbox, work.id).state(
          mail.invitation,
        ),
      ).toStrictEqual({ kind: 'sent', choice: 'accepted', at: clock.now });
      // The confirmed choice is not sent twice.
      await mail.respond('accepted');
      await mail.deliver();
      expect(mail.server.smtp.accepted).toHaveLength(1);
    } finally {
      mail.outbox.dispose();
    }
  });

  it('takes a response back with Undo during the window without creating a Draft', async () => {
    expect.hasAssertions();
    const mail = await invited();
    try {
      await mail.respond('tentative');
      await mail.responses.undo(mail.invitation);
      await mail.deliver();
      expect({
        state: mail.state(),
        outbox: mail.outbox.getSnapshot(),
        drafts: mail.phone.drafts.getSnapshot(),
        submitted: mail.server.smtp.accepted,
      }).toMatchObject({
        state: { kind: 'unanswered' },
        outbox: [],
        drafts: { kind: 'ready', drafts: [] },
        submitted: [],
      });
    } finally {
      mail.outbox.dispose();
    }
  });

  it('leaves a refused response Not sent and replaces it with the next choice', async () => {
    expect.hasAssertions();
    const mail = await invited();
    try {
      await mail.respond('accepted');
      mail.server.smtp.failure = 'smtp-rejected';
      await mail.deliver();
      expect(mail.state()).toStrictEqual({
        kind: 'refused',
        choice: 'accepted',
      });
      await mail.respond('declined');
      expect(mail.outbox.getSnapshot()).toMatchObject([
        { state: 'waiting', invitation: { choice: 'declined' } },
      ]);
      await mail.deliver();
      expect({
        submitted: mail.server.smtp.accepted.length,
        state: mail.state(),
      }).toStrictEqual({
        submitted: 1,
        state: { kind: 'sent', choice: 'declined', at: clock.now },
      });
    } finally {
      mail.outbox.dispose();
    }
  });

  it('never sends an unconfirmed response again and confirms it from its Sent copy', async () => {
    expect.hasAssertions();
    const mail = await invited();
    try {
      await mail.respond('accepted');
      mail.server.smtp.lost = true;
      await mail.deliver();
      expect(mail.state()).toMatchObject({
        kind: 'unknown',
        choice: 'accepted',
      });
      await mail.respond('declined');
      await mail.deliver();
      await mail.responses.check(mail.invitation);
      expect({
        submitted: mail.server.smtp.accepted.length,
        state: mail.state(),
      }).toMatchObject({ submitted: 1, state: { kind: 'unknown' } });
      // The server filed its own copy, which confirms it.
      mail.server.deliver('Sent', {
        subject: 'Re: Invitation: Q4 roadmap review',
        raw: present(mail.server.smtp.accepted[0], 'a reply').raw,
      });
      await mail.responses.check(mail.invitation);
      expect({
        submitted: mail.server.smtp.accepted.length,
        outbox: mail.outbox.getSnapshot(),
        state: mail.state(),
      }).toStrictEqual({
        submitted: 1,
        outbox: [],
        state: { kind: 'sent', choice: 'accepted', at: clock.now },
      });
    } finally {
      mail.outbox.dispose();
    }
  });

  it.each([
    { name: 'no Sent folder', options: { sent: false } },
    { name: 'no outgoing server', options: { smtp: false } },
  ])('refuses a choice from a mailbox with $name', async ({ options }) => {
    expect.hasAssertions();
    const mail = await invited(options);
    try {
      await mail.respond('accepted');
      await mail.deliver();
      expect({
        state: mail.state(),
        outbox: mail.outbox.getSnapshot(),
        submitted: mail.server.smtp.accepted,
      }).toStrictEqual({
        state: { kind: 'refused', choice: 'accepted' },
        outbox: [],
        submitted: [],
      });
    } finally {
      mail.outbox.dispose();
    }
  });
});
