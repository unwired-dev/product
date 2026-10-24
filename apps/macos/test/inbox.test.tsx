import { ok } from 'node:assert/strict';

import { gmailAction } from '@private-email/mail-core/gmail-actions';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { makeMockInboxStorage } from '@private-email/mail-core/testing/mock-storage';
import {
  act,
  cleanup,
  render,
  screen,
  within,
} from '@testing-library/react-native';

import type { Selection } from '../src/inbox.tsx';

import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';

describe('message list', () => {
  it('finishes a leaving row when its owner selects another message directly', async () => {
    expect.hasAssertions();
    const frames = jest
      .spyOn(globalThis, 'requestAnimationFrame')
      .mockReturnValue(0);
    const gmail = createSyntheticGmail();
    gmail.deliver({ subject: 'Leaving' });
    const other = gmail.deliver({ subject: 'Selected directly' });
    const inbox = createGmailInbox(gmail.native);
    const mailboxes = singleMailbox(inbox, 'work-mailbox');
    const show = (selected: Selection | undefined) => (
      <InboxProvider mailboxes={mailboxes}>
        <Inbox
          onSelect={() => undefined}
          selected={selected}
        />
      </InboxProvider>
    );
    try {
      const app = await render(show(undefined));
      await screen.findByText('Leaving');
      const state = inbox.getSnapshot();
      ok(state.kind === 'ready');
      const leaving = state.messages.find(
        (message) => message.subject === 'Leaving',
      );
      ok(leaving !== undefined);
      await act(() => inbox.organize(leaving, gmailAction.archive));
      expect(
        screen.queryByText('Leaving', { includeHiddenElements: true }),
      ).not.toBeNull();
      // Notification opens update this prop without invoking the row's onSelect.
      await app.rerender(show({ mailbox: 'work-mailbox', id: other }));
      expect(
        screen.queryByText('Leaving', { includeHiddenElements: true }),
      ).toBeNull();
      expect(
        screen.getByRole('button', { name: /Selected directly/u }),
      ).toBeVisible();
    } finally {
      await cleanup();
      inbox.forget();
      frames.mockRestore();
    }
  });

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
