import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { act, fireEvent, render, screen } from '@testing-library/react-native';

import { MessageBody } from '../src/message-body.tsx';
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
async function opened(calendar: string) {
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
    <MessageBody
      inbox={inbox}
      id={id}
    />,
  );
  return { gmail, app };
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
