import { ok } from 'node:assert/strict';

import type { TurboModule } from 'react-native';

import { allMail, gmailAction } from '@private-email/mail-core/gmail-actions';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { makeMockInboxStorage } from '@private-email/mail-core/testing/mock-storage';
import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from '@testing-library/react-native';
import { DeviceEventEmitter, TurboModuleRegistry } from 'react-native';

import type { Selection } from '../src/inbox.tsx';
import type { MailboxView } from '../src/sidebar.tsx';

import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';

// Only the native menu boundary is substituted; its events arrive as the host sends them.
const commandEvents = () => {
  const get = TurboModuleRegistry.get.bind(TurboModuleRegistry);
  const menu: TurboModule = {};
  return jest
    .spyOn(TurboModuleRegistry, 'get')
    .mockImplementation((name) =>
      name === 'UnwiredCommands' ? menu : get(name),
    );
};

// A connected Gmail Inbox with one saved message.
const renderGmailInbox = async () => {
  const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
  gmail.deliver({ subject: 'Saved mail remains available' });
  const inbox = createGmailInbox(gmail.native);
  await render(
    <InboxProvider mailboxes={singleMailbox(inbox, 'work-mailbox')}>
      <Inbox
        onSelect={() => undefined}
        selected={undefined}
      />
    </InboxProvider>,
  );
  await screen.findByText('Saved mail remains available');
  return { gmail, inbox };
};

describe('message list', () => {
  it('shows the last update only for Inboxes, leaving it out of a label and unified Sent', async () => {
    expect.hasAssertions();
    const clock = jest
      .spyOn(Date, 'now')
      .mockReturnValue(Date.parse('2026-10-27T09:41:00Z'));
    const gmail = createSyntheticGmail();
    const travel = gmail.createLabel('Travel');
    const message = gmail.deliver({ subject: 'Flight to Zagreb' });
    gmail.setLabel(message, travel, true);
    gmail.setLabel(message, 'SENT', true);
    const inbox = createGmailInbox(gmail.native);
    const mailboxes = singleMailbox(inbox, 'work-mailbox');
    const show = (view: MailboxView) => (
      <InboxProvider mailboxes={mailboxes}>
        <Inbox
          onSelect={() => undefined}
          selected={undefined}
          view={view}
        />
      </InboxProvider>
    );
    try {
      const app = await render(show({}));
      await expect(
        screen.findByRole('header', {
          name: 'All Inboxes. Preview mailbox · 1 unread · Updated just now',
        }),
      ).resolves.toBeVisible();
      await app.rerender(show({ mailbox: 'work-mailbox', folder: travel }));
      await expect(
        screen.findByRole('button', { name: /Flight to Zagreb/u }),
      ).resolves.toBeVisible();
      expect(
        screen.getByRole('header', {
          name: 'Travel. Preview mailbox · 1 unread',
        }),
      ).toBeVisible();
      await app.rerender(show({ unified: 'SENT' }));
      await screen.findByRole('button', { name: /Flight to Zagreb/u });
      expect(
        screen.getByRole('header', {
          name: 'Sent. All mailboxes · 1 unread',
        }),
      ).toBeVisible();
      await app.rerender(show({}));
      await expect(
        screen.findByRole('header', {
          name: 'All Inboxes. Preview mailbox · 1 unread · Updated just now',
        }),
      ).resolves.toBeVisible();
    } finally {
      await cleanup();
      inbox.forget();
      clock.mockRestore();
    }
  });

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

  it('opens each connection’s sync status from the capsule and tries that connection again', async () => {
    expect.hasAssertions();
    const { gmail, inbox } = await renderGmailInbox();
    try {
      gmail.fail({ code: 'unavailable' });
      await act(inbox.load);
      await fireEvent.press(
        screen.getByRole('button', { name: '1 account needs attention' }),
      );
      const details = within(screen.getByTestId('sync-status-details'));
      expect([
        details.getByRole('header', { name: 'Sync Status' }).props
          .accessibilityLabel,
        details.getByLabelText('Gmail · work-mailbox').props.accessibilityLabel,
        details.getByLabelText(
          'Gmail could not be reached. Showing mail saved on this device.',
        ).props.accessibilityLabel,
      ]).toStrictEqual([
        'Sync Status',
        'Gmail · work-mailbox',
        'Gmail could not be reached. Showing mail saved on this device.',
      ]);
      expect(
        details.getByLabelText(/^Last updated .* · View › Refresh \(⌘R\)$/u),
      ).toBeOnTheScreen();
      // The connection's own Try Again synchronizes it, and the capsule leaves with its failure.
      gmail.deliver({ subject: 'Arrives after Try Again' });
      await act(async () => {
        await fireEvent.press(
          details.getByRole('button', {
            name: 'Try Again for Gmail · work-mailbox',
          }),
        );
      });
      await expect(
        screen.findByText('Arrives after Try Again'),
      ).resolves.toBeOnTheScreen();
      expect(
        screen.queryByRole('button', { name: '1 account needs attention' }),
      ).toBeNull();
    } finally {
      await cleanup();
      inbox.forget();
    }
  });

  it('clears an IMAP connection’s attention when Try Again succeeds while another folder is listed', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.addFolder('Archive', ['archive']);
    imap.deliver('Archive', { subject: 'Filed invoice' });
    const inbox = createImapInbox(imap.native);
    await render(
      <InboxProvider mailboxes={singleMailbox(inbox, 'home-mailbox')}>
        <Inbox
          onSelect={() => undefined}
          selected={undefined}
          view={{ mailbox: 'home-mailbox', folder: 'Archive' }}
        />
      </InboxProvider>,
    );
    try {
      // The sidebar opens a chosen folder; this test opens it directly.
      await act(inbox.load);
      await act(() => inbox.openFolder('Archive'));
      await screen.findByText('Filed invoice');
      imap.server.failure = 'offline';
      await act(inbox.load);
      imap.server.failure = undefined;
      await act(async () => {
        await fireEvent.press(
          screen.getByRole('button', { name: 'Try Again' }),
        );
      });
      await waitFor(() => {
        expect(
          screen.queryByRole('button', { name: '1 account needs attention' }),
        ).toBeNull();
      });
    } finally {
      await cleanup();
      inbox.forget();
    }
  });

  it('synchronizes the Inbox when View › Refresh is chosen in its window', async () => {
    expect.hasAssertions();
    const commands = commandEvents();
    const { gmail, inbox } = await renderGmailInbox();
    try {
      gmail.deliver({ subject: 'Arrives with Refresh' });
      await act(async () => {
        DeviceEventEmitter.emit('refresh', { window: 'inbox-window-other' });
        await Promise.resolve();
      });
      expect(screen.queryByText('Arrives with Refresh')).toBeNull();
      await act(async () => {
        DeviceEventEmitter.emit('refresh', { window: 'inbox-window-' });
        await Promise.resolve();
      });
      await expect(
        screen.findByText('Arrives with Refresh'),
      ).resolves.toBeOnTheScreen();
    } finally {
      await cleanup();
      inbox.forget();
      commands.mockRestore();
    }
  });

  it('shows how much of All Mail has downloaded and ends it with older mail still arriving', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    for (const index of Array.from({ length: 250 }, (_, at) => at)) {
      gmail.archive(gmail.deliver({ subject: `Message ${index}` }));
    }
    // Gmail stops answering partway through the history download.
    gmail.failPage('200', { code: 'unavailable' });
    const inbox = createGmailInbox(gmail.native);
    try {
      await render(
        <InboxProvider mailboxes={singleMailbox(inbox, 'work-mailbox')}>
          <Inbox
            onSelect={() => undefined}
            selected={undefined}
            view={{ mailbox: 'work-mailbox', folder: allMail }}
          />
        </InboxProvider>,
      );
      await expect(
        screen.findByRole('header', {
          name: 'All Mail. Preview mailbox · 200 of 250 downloaded',
        }),
      ).resolves.toBeVisible();
      expect(
        screen.getByRole('progressbar', {
          name: /^Downloading older mail… Mail from before \S.* appears here as it arrives\./u,
        }),
      ).toBeVisible();
    } finally {
      await cleanup();
      inbox.forget();
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
