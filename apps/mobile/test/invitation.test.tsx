import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { AccessibilityInfo } from 'react-native';

import { GmailMessageBody } from '../src/message-body.tsx';
import { AccountContext } from '../src/registration-gate.tsx';

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
// SwiftUI controls are substituted.
async function opened(
  calendar: string,
  authorizeMailbox: (connection: string) => Promise<void> = () =>
    Promise.resolve(),
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
      <GmailMessageBody
        inbox={inbox}
        id={id}
        connection="gmail-connection"
      />
    </AccountContext>,
  );
  return { gmail, inbox, id, app };
}

describe('meeting invitations in the iPhone and iPad reader', () => {
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
    const announce = jest.spyOn(
      AccessibilityInfo,
      'announceForAccessibilityWithOptions',
    );
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
      // Nothing is sent, or announced, before the person chooses.
      expect(gmail.sends).toHaveLength(0);
      expect(announce).not.toHaveBeenCalled();

      await fireEvent.press(screen.getByRole('button', { name: 'Accept' }));
      await expect(screen.findByText('Accepted')).resolves.toBeOnTheScreen();

      expect(gmail.sends).toHaveLength(1);
      expect(announce).toHaveBeenLastCalledWith(
        expect.stringMatching(/^Accepted\. /u),
        { queue: true },
      );
      expect(screen.getByText('Accept')).toBeOnTheScreen();

      await fireEvent.press(screen.getByRole('button', { name: 'Accepted' }));

      expect(gmail.sends).toHaveLength(1);
    } finally {
      announce.mockRestore();
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

      expect(screen.getByTestId('respond-again')).toHaveTextContent(
        /^Respond again\?/u,
      );

      await fireEvent.press(screen.getByRole('button', { name: 'Cancel' }));

      expect(screen.queryByTestId('respond-again')).toBeNull();
      expect(gmail.sends).toHaveLength(0);

      await fireEvent.press(
        screen.getByRole('button', { name: 'Respond Again…' }),
      );
      await fireEvent.press(
        screen.getByRole('button', { name: 'Respond Again' }),
      );
      await expect(screen.findByText('Declined')).resolves.toBeOnTheScreen();

      expect(gmail.sends).toHaveLength(1);
    } finally {
      await app.unmount();
    }
  });
  /* oxlint-enable vitest/max-expects */

  it('announces an unchanged unknown outcome after checking a reopened invitation', async () => {
    expect.hasAssertions();
    const { gmail, inbox, id, app } = await opened(
      invitation('alex@example.invalid'),
    );
    gmail.failSend({ code: 'delivery-unknown' });
    try {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Accept' }),
      );
      await screen.findByText('Delivery unknown');
    } finally {
      await app.unmount();
    }

    const announce = jest.spyOn(
      AccessibilityInfo,
      'announceForAccessibilityWithOptions',
    );
    announce.mockClear();
    const reopened = await render(
      <GmailMessageBody
        inbox={inbox}
        id={id}
        connection="gmail-connection"
      />,
    );
    try {
      await screen.findByText('Delivery unknown');
      expect(announce).not.toHaveBeenCalled();

      await fireEvent.press(
        screen.getByRole('button', { name: 'Check Again' }),
      );
      await screen.findByText('Delivery unknown');

      expect(announce).toHaveBeenLastCalledWith(
        expect.stringMatching(/^Delivery unknown\. /u),
        { queue: true },
      );
      expect(announce).toHaveBeenCalledTimes(2);
      expect(gmail.sends).toHaveLength(0);
    } finally {
      announce.mockRestore();
      await reopened.unmount();
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

  it('says when it cannot read an invitation', async () => {
    expect.hasAssertions();
    const { app } = await opened(
      invitation('alex@example.invalid', ['RRULE:FREQ=WEEKLY']),
    );
    try {
      await expect(
        screen.findByText('Unwired can’t read this invitation'),
      ).resolves.toBeOnTheScreen();

      expect(screen.getByText('invite.ics')).toBeOnTheScreen();
    } finally {
      await app.unmount();
    }
  });
});
