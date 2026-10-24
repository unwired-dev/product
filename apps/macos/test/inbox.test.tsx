import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { makeMockInboxStorage } from '@private-email/mail-core/testing/mock-storage';
import { render, screen, within } from '@testing-library/react-native';

import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';

describe('message list', () => {
  it('draws no separator under a day’s last row, above the next day’s divider', async () => {
    expect.hasAssertions();
    const clock = jest
      .spyOn(Date, 'now')
      .mockReturnValue(Date.parse('2026-09-28T12:00:00Z'));
    try {
      const fixture = createPersistentInbox(
        makeMockInboxStorage(),
        createMockMailSession('open-read-relaunch').mail.list,
      );
      await fixture.load();
      await render(
        <InboxProvider mailboxes={singleMailbox(fixture, 'work-mailbox')}>
          <Inbox
            onSelect={() => undefined}
            selected={undefined}
          />
        </InboxProvider>,
      );
      await screen.findByRole('header', { name: 'Yesterday' });
      const separator = (name: string) =>
        within(screen.getByRole('button', { name })).queryByTestId(
          'row-separator',
        );
      expect(
        separator('Unread. Maya Chen. A little more room to think'),
      ).toBeVisible();
      expect(
        separator('Unread. Oliver Park. Saturday, by the river?'),
      ).toBeNull();
      // The list's last row keeps its separator.
      expect(
        separator('North House. Your table is ready for Friday'),
      ).toBeVisible();
    } finally {
      clock.mockRestore();
    }
  });
});
