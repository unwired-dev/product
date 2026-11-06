import type { MailProvider } from '@private-email/mail-core/registration';

import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { act, fireEvent, render, screen } from '@testing-library/react-native';

import { OpenMessageContext } from '../src/invitation.tsx';
import { InboxProvider, ProfileScope } from '../src/mailbox.tsx';
import { MessageBody } from '../src/message-body.tsx';
import { AccountContext } from '../src/registration-gate.tsx';
import { chooseSheetButton, sheetShown } from './native-alert.ts';

// The application callback that a queued native button event would deliver.
const pressHandler = (
  element: Parameters<typeof fireEvent.press>[0],
): (() => void) => {
  let fiber = element.unstable_fiber;
  while (fiber !== null) {
    const handler = fiber.memoizedProps?.onPress;
    if (typeof handler === 'function') {
      return () => {
        handler();
      };
    }
    fiber = fiber.return;
  }
  throw new Error('Expected a rendered press handler');
};

const me = 'alex@example.invalid';

const invitation = (attendee: string, extra: readonly string[] = []) =>
  [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'METHOD:REQUEST',
    'BEGIN:VEVENT',
    'UID:roadmap-42@northwind.example',
    'SEQUENCE:0',
    'SUMMARY:Q4 roadmap review',
    'DTSTART:20261106T130000Z',
    'DTEND:20261106T140000Z',
    'LOCATION:Room 4',
    'ORGANIZER;CN=Lena Fischer:mailto:lena@northwind.example',
    `ATTENDEE;CN=Alex;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:${attendee}`,
    ...extra,
    'END:VEVENT',
    'END:VCALENDAR',
  ].join('\r\n');

// The reader showing a received invitation from a synthetic Gmail mailbox. Only WebKit and the
// AppKit controls are substituted.
async function opened(
  calendar: string,
  authorizeMailbox: (connection: string) => Promise<void> = () =>
    Promise.resolve(),
  // Every connected mailbox besides the opened Gmail one, by owning Profile.
  others: ReadonlyArray<
    Readonly<{ provider: MailProvider; address: string; profile: string }>
  > = [],
) {
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
          bytes: [...Buffer.from(calendar)],
        },
      ],
    },
  });
  const inbox = createGmailInbox(gmail.native);
  await inbox.load();
  // The messages the reader's window opened in its place.
  const shown: string[] = [];
  const mailboxes = [
    { provider: 'gmail' as const, address: me, profile: 'default' },
    ...others,
  ].map((mailbox, index) => ({
    ...mailbox,
    id: index === 0 ? 'gmail-connection' : `connection-${index}`,
    inbox,
    state: inbox.getSnapshot(),
  }));
  const app = await render(
    <AccountContext
      value={{
        mailboxes: [],
        openAccount: () => undefined,
        authorizeMailbox,
        refreshInbox: (load) => load(),
        account: 'synthetic-product-account',
        profiles: [],
        createProfile: () => Promise.resolve(undefined),
        chooseFolders: () => Promise.resolve(true),
      }}>
      <InboxProvider
        mailboxes={{
          getSnapshot: () => mailboxes,
          subscribe: () => () => undefined,
          load: () => Promise.resolve(),
        }}>
        <ProfileScope profile="default">
          <OpenMessageContext
            value={(opened) => {
              shown.push(opened);
            }}>
            <MessageBody
              inbox={inbox}
              id={id}
              connection="gmail-connection"
            />
          </OpenMessageContext>
        </ProfileScope>
      </InboxProvider>
    </AccountContext>,
  );
  return { gmail, inbox, app, shown };
}

describe('meeting invitations in the Mac reader', () => {
  it('ignores a queued response after the reader closes', async () => {
    expect.hasAssertions();
    const { gmail, app } = await opened(invitation('alex@example.invalid'));
    const staleAccept = pressHandler(
      await screen.findByRole('button', { name: 'Accept' }),
    );
    await app.unmount();
    await act(async () => {
      staleAccept();
    });
    expect(gmail.sends).toHaveLength(0);
  });

  /* oxlint-disable vitest/max-expects -- The journey proves each visible response step. */
  it('sends the chosen response once and shows that Gmail sent it', async () => {
    expect.hasAssertions();
    const { gmail, app } = await opened(invitation('alex@example.invalid'));
    try {
      await expect(
        screen.findByText('Invitation from Lena Fischer'),
      ).resolves.toBeOnTheScreen();
      expect(screen.getByText('Q4 roadmap review')).toBeOnTheScreen();
      expect(screen.getByText('Room 4')).toBeOnTheScreen();
      expect(screen.getByText('Not answered yet')).toBeOnTheScreen();
      expect(
        screen.getByText(
          'Your response goes to Lena Fischer from alex@example.invalid.',
        ),
      ).toBeOnTheScreen();
      // Nothing is sent before the person chooses.
      expect(gmail.sends).toHaveLength(0);

      await fireEvent.press(screen.getByRole('button', { name: 'Accept' }));
      await expect(screen.findByText('Accepted')).resolves.toBeOnTheScreen();

      expect(gmail.sends).toHaveLength(1);
      expect(screen.getByRole('button', { name: 'Accepted' }).props.text).toBe(
        '✓ Accept',
      );

      await fireEvent.press(screen.getByRole('button', { name: 'Accepted' }));

      expect(gmail.sends).toHaveLength(1);
    } finally {
      await app.unmount();
    }
  });

  it('sends nothing more once the mailbox is removed while sending', async () => {
    expect.hasAssertions();
    const { gmail, app } = await opened(invitation('alex@example.invalid'));
    try {
      gmail.failSend({ code: 'mailbox-revoked' });
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Accept' }),
      );

      await expect(screen.findByText('Not sent')).resolves.toBeOnTheScreen();
      expect(
        screen.getByText(
          'alex@example.invalid was removed from Unwired before your response was sent. Unwired won’t send it from another address.',
        ),
      ).toBeOnTheScreen();
      for (const name of ['Accept', 'Maybe', 'Decline']) {
        expect(screen.queryByRole('button', { name })).toBeNull();
      }
      expect(gmail.sends).toHaveLength(0);
    } finally {
      await app.unmount();
    }
  });

  it('offers responses again only once Gmail accepts the sign-in', async () => {
    expect.hasAssertions();
    const authorizations: string[] = [];
    const { gmail, app } = await opened(
      invitation('alex@example.invalid'),
      (connection) => {
        authorizations.push(connection);
        return Promise.resolve();
      },
    );
    try {
      gmail.failSend({ status: 401 });
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Accept' }),
      );
      await expect(
        screen.findByText('Gmail needs you to sign in again'),
      ).resolves.toBeOnTheScreen();

      // The person cancels signing in, so Gmail still refuses the mailbox.
      gmail.fail({ status: 401 });
      await fireEvent.press(screen.getByRole('button', { name: 'Sign In…' }));

      expect(authorizations).toStrictEqual(['gmail-connection']);
      expect(screen.queryByRole('button', { name: 'Accept' })).toBeNull();

      await fireEvent.press(screen.getByRole('button', { name: 'Sign In…' }));

      await expect(
        screen.findByRole('button', { name: 'Accept' }),
      ).resolves.toBeOnTheScreen();
      expect(gmail.sends).toHaveLength(0);
    } finally {
      await app.unmount();
    }
  });

  it('asks before responding again after an unknown delivery', async () => {
    expect.hasAssertions();
    const { gmail, app } = await opened(invitation('alex@example.invalid'));
    gmail.failSend({ code: 'delivery-unknown' });
    try {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Decline' }),
      );
      await expect(
        screen.findByText('Delivery unknown'),
      ).resolves.toBeOnTheScreen();

      expect(screen.queryByRole('button', { name: 'Decline' })).toBeNull();

      await fireEvent.press(
        screen.getByRole('button', { name: 'Respond Again…' }),
      );

      expect(sheetShown()).toMatchObject({
        title: 'Respond again?',
        buttons: ['Respond Again', 'Cancel'],
      });

      await act(async () => {
        chooseSheetButton('Cancel');
        await Promise.resolve();
      });

      expect(gmail.sends).toHaveLength(0);

      await fireEvent.press(
        screen.getByRole('button', { name: 'Respond Again…' }),
      );
      await act(async () => {
        chooseSheetButton('Respond Again');
        await Promise.resolve();
      });
      await expect(screen.findByText('Declined')).resolves.toBeOnTheScreen();

      expect(gmail.sends).toHaveLength(1);
    } finally {
      await app.unmount();
    }
  });
  /* oxlint-enable vitest/max-expects */

  it('responds only for the opened address when the Profile is invited at two', async () => {
    expect.hasAssertions();
    const { gmail, app } = await opened(
      invitation(me, [
        'ATTENDEE;CN=Alex:mailto:Alex@iCloud.example',
        'ATTENDEE;CN=Alex:mailto:alex@work.example',
      ]),
      undefined,
      [
        {
          provider: 'imap',
          address: 'alex@icloud.example',
          profile: 'default',
        },
        { provider: 'gmail', address: 'alex@work.example', profile: 'work' },
      ],
    );
    try {
      await expect(
        screen.findByLabelText(
          `Responding as ${me}. You’re invited at two of your addresses. This copy responds only for ${me}.`,
        ),
      ).resolves.toBeOnTheScreen();
      expect(screen.getByText('alex@icloud.example · IMAP')).toBeOnTheScreen();
      // Another Profile's mailbox is never listed, though the invitation names it.
      expect(
        screen.getByLabelText(
          `Invited, ${me} · Gmail, alex@icloud.example · IMAP`,
        ),
      ).toBeOnTheScreen();

      await fireEvent.press(screen.getByRole('button', { name: 'Accept' }));
      await expect(screen.findByText('Accepted')).resolves.toBeOnTheScreen();

      expect(gmail.sends.map(({ raw }) => raw)).toStrictEqual([
        expect.stringContaining(`From: ${me}`),
      ]);
    } finally {
      await app.unmount();
    }
  });

  it('offers no response for an address the invitation does not name', async () => {
    expect.hasAssertions();
    const { app } = await opened(invitation('team@northwind.example'));
    try {
      await expect(
        screen.findByText('You can’t respond from here'),
      ).resolves.toBeOnTheScreen();

      expect(screen.queryByRole('button', { name: 'Accept' })).toBeNull();
    } finally {
      await app.unmount();
    }
  });

  it('shows every day of a multi-day all-day meeting', async () => {
    expect.hasAssertions();
    const { app } = await opened(
      invitation('alex@example.invalid')
        .replace('DTSTART:20261106T130000Z', 'DTSTART;VALUE=DATE:20261106')
        .replace('DTEND:20261106T140000Z', 'DTEND;VALUE=DATE:20261109'),
    );
    try {
      await expect(
        screen.findByText('Fri, Nov 6, 2026 – Sun, Nov 8, 2026, all day'),
      ).resolves.toBeOnTheScreen();
    } finally {
      await app.unmount();
    }
  });

  it('names an organizer once when the name is the address', async () => {
    expect.hasAssertions();
    const { app } = await opened(
      invitation('alex@example.invalid').replace(
        'CN=Lena Fischer',
        'CN=lena@northwind.example',
      ),
    );
    try {
      await expect(
        screen.findAllByText('lena@northwind.example'),
      ).resolves.toHaveLength(1);
    } finally {
      await app.unmount();
    }
  });

  // Opens a revision that moved the meeting, then records an answer to the earlier time.
  const answeredBeforeMove = async () => {
    const opening = await opened(
      invitation('alex@example.invalid')
        .replace('SEQUENCE:0', 'SEQUENCE:1')
        .replace('DTSTART:20261106T130000Z', 'DTSTART:20261107T090000Z')
        .replace('DTEND:20261106T140000Z', 'DTEND:20261107T100000Z'),
    );
    await screen.findByText('Not answered yet');
    const uid = 'roadmap-42@northwind.example';
    await act(async () => {
      await opening.inbox.recordResponse(
        { uid, sequence: 0 },
        {
          kind: 'sent',
          uid,
          sequence: 0,
          choice: 'accepted',
          at: Date.UTC(2026, 10, 2, 9, 52),
          start: { at: Date.UTC(2026, 10, 6, 13), allDay: false },
          end: { at: Date.UTC(2026, 10, 6, 14), allDay: false },
        },
      );
    });
    return opening;
  };

  it('shows an updated invitation that moved the meeting after an earlier answer', async () => {
    expect.hasAssertions();
    const { app } = await answeredBeforeMove();
    try {
      expect(
        screen.getByLabelText('Invitation from Lena Fischer, Updated'),
      ).toBeOnTheScreen();
      expect(screen.getByText(/^Was /u)).toBeOnTheScreen();
      expect(
        screen.getByText('Lena Fischer changed the time'),
      ).toBeOnTheScreen();
      expect(
        screen.getByText(
          'You accepted the earlier time. Respond to the new time.',
        ),
      ).toBeOnTheScreen();
      // The earlier answer was for the old time, so none is chosen.
      expect(screen.queryByRole('button', { name: 'Accepted' })).toBeNull();
    } finally {
      await app.unmount();
    }
  });

  it('keeps the update marks after responding to the moved meeting', async () => {
    expect.hasAssertions();
    const { gmail, app } = await answeredBeforeMove();
    try {
      await fireEvent.press(screen.getByRole('button', { name: 'Decline' }));
      await expect(screen.findByText('Declined')).resolves.toBeOnTheScreen();

      expect(gmail.sends).toHaveLength(1);
      expect(screen.getByText('Updated')).toBeOnTheScreen();
      expect(screen.getByText(/^Was /u)).toBeOnTheScreen();
    } finally {
      await app.unmount();
    }
  });

  it('shows an older revision with nothing to respond to once a newer one was answered', async () => {
    expect.hasAssertions();
    const opening = await opened(invitation('alex@example.invalid'));
    const { app } = opening;
    try {
      await screen.findByText('Not answered yet');
      const uid = 'roadmap-42@northwind.example';
      await act(async () => {
        await opening.inbox.recordResponse(
          { uid, sequence: 1 },
          {
            kind: 'sent',
            uid,
            sequence: 1,
            choice: 'accepted',
            at: Date.UTC(2026, 10, 2, 9, 52),
            start: { at: Date.UTC(2026, 10, 6, 13), allDay: false },
          },
        );
      });

      expect(
        screen.getByLabelText('Invitation from Lena Fischer, Older version'),
      ).toBeOnTheScreen();
      expect(
        screen.getByLabelText(
          'There’s a newer version of this invitation. Respond from the latest invitation so your answer matches it.',
        ),
      ).toBeOnTheScreen();
      expect(screen.queryByText('Invited')).toBeNull();
      // A response recorded before it kept its message names none to show.
      expect(
        ['Accept', 'Maybe', 'Decline', 'Show Latest'].map((name) =>
          screen.queryByRole('button', { name }),
        ),
      ).toStrictEqual([null, null, null, null]);
    } finally {
      await app.unmount();
    }
  });

  it('opens the newer invitation it answered from an older revision', async () => {
    expect.hasAssertions();
    const { app, gmail, inbox, shown } = await opened(
      invitation('alex@example.invalid'),
    );
    try {
      await screen.findByText('Not answered yet');
      const newer = gmail.deliver({
        from: 'Lena Fischer <lena@northwind.example>',
        subject: 'Updated invitation: Q4 roadmap review',
        content: { text: 'Moved.' },
      });
      const uid = 'roadmap-42@northwind.example';
      await act(async () => {
        await inbox.load();
        await inbox.recordResponse(
          { uid, sequence: 1 },
          {
            kind: 'sent',
            uid,
            sequence: 1,
            choice: 'accepted',
            at: Date.UTC(2026, 10, 2, 9, 52),
            start: { at: Date.UTC(2026, 10, 6, 13), allDay: false },
            message: newer,
          },
        );
      });

      await fireEvent.press(
        screen.getByRole('button', { name: 'Show Latest' }),
      );

      expect(shown).toStrictEqual([newer]);
    } finally {
      await app.unmount();
    }
  });

  it('shows a cancelled meeting with nothing to respond to', async () => {
    expect.hasAssertions();
    const { app } = await opened(
      invitation('alex@example.invalid', ['STATUS:CANCELLED'])
        .replace('METHOD:REQUEST', 'METHOD:CANCEL')
        .replace('SEQUENCE:0', 'SEQUENCE:1'),
    );
    try {
      await expect(
        screen.findByText('This meeting was cancelled'),
      ).resolves.toBeOnTheScreen();

      expect(
        screen.getByLabelText('Cancelled by Lena Fischer'),
      ).toBeOnTheScreen();
      expect(screen.getByText('Q4 roadmap review')).toHaveStyle({
        textDecorationLine: 'line-through',
      });
      expect(screen.queryByText('Invited')).toBeNull();
      for (const action of ['Accept', 'Maybe', 'Decline', 'Add to Calendar']) {
        expect(screen.queryByRole('button', { name: action })).toBeNull();
      }
    } finally {
      await app.unmount();
    }
  });

  it.each([
    ['COUNT=7', 'Every week from Nov 6 to Dec 18, 2026'],
    ['UNTIL=20461231T235959Z', 'Every week from Nov 6, 2026 to Dec 28, 2046'],
  ])(
    'shows the weekday and span of a weekly series ending %s',
    async (end, repeats) => {
      expect.hasAssertions();
      const zone = new Intl.DateTimeFormat().resolvedOptions().timeZone;
      const { app } = await opened(
        invitation('alex@example.invalid', [`RRULE:FREQ=WEEKLY;${end}`])
          .replace(
            'DTSTART:20261106T130000Z',
            `DTSTART;TZID=${zone}:20261106T120000`,
          )
          .replace(
            'DTEND:20261106T140000Z',
            `DTEND;TZID=${zone}:20261106T130000`,
          ),
      );
      try {
        await expect(
          screen.findByText(/^Fridays, /u),
        ).resolves.toBeOnTheScreen();

        expect(screen.getByText(repeats)).toBeOnTheScreen();
        expect(
          screen.getByLabelText(
            new RegExp(`^When, Fridays, .+, ${repeats}$`, 'u'),
          ),
        ).toBeOnTheScreen();
        expect(
          screen.getByText(
            'Your response applies to every meeting in the series.',
          ),
        ).toBeOnTheScreen();
      } finally {
        await app.unmount();
      }
    },
  );

  it('answers only the one meeting of a series it invites to', async () => {
    expect.hasAssertions();
    const zone = new Intl.DateTimeFormat().resolvedOptions().timeZone;
    const { gmail, app } = await opened(
      invitation('alex@example.invalid', [
        `RECURRENCE-ID;TZID=${zone}:20261106T120000`,
      ])
        .replace(
          'DTSTART:20261106T130000Z',
          `DTSTART;TZID=${zone}:20261106T120000`,
        )
        .replace(
          'DTEND:20261106T140000Z',
          `DTEND;TZID=${zone}:20261106T130000`,
        ),
    );
    try {
      await expect(
        screen.findByText('Invitation from Lena Fischer · one meeting'),
      ).resolves.toBeOnTheScreen();

      expect(
        screen.getByLabelText(/^When, Fri, .+, One meeting in a series$/u),
      ).toBeOnTheScreen();
      expect(
        screen.getByText('Your response applies only to Fri, Nov 6.'),
      ).toBeOnTheScreen();

      await fireEvent.press(screen.getByRole('button', { name: 'Decline' }));
      await expect(screen.findByText('Declined')).resolves.toBeOnTheScreen();

      expect(gmail.sends).toHaveLength(1);
    } finally {
      await app.unmount();
    }
  });

  it('says when it cannot read an invitation', async () => {
    expect.hasAssertions();
    const { app } = await opened(
      invitation('alex@example.invalid', ['RRULE:FREQ=WEEKLY']),
    );
    try {
      await expect(
        screen.findByText('Unwired can’t read this invitation'),
      ).resolves.toBeOnTheScreen();

      // VoiceOver skips plain Text on macOS, so the heading needs its own label.
      expect(screen.getByLabelText('Invitation')).toBeOnTheScreen();
      expect(screen.getByText('invite.ics')).toBeOnTheScreen();
    } finally {
      await app.unmount();
    }
  });
});
