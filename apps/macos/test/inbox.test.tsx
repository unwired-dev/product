import { ok } from 'node:assert/strict';

import type { TurboModule } from 'react-native';

import { allMail, gmailAction } from '@private-email/mail-core/gmail-actions';
import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { createInboxStore } from '@private-email/mail-core/inbox-store';
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
import {
  AccessibilityInfo,
  DeviceEventEmitter,
  TurboModuleRegistry,
} from 'react-native';

import type { Selection } from '../src/inbox.tsx';
import type { MailboxView } from '../src/sidebar.tsx';

import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { AccountContext } from '../src/registration-gate.tsx';
import { Mailboxes } from '../src/sidebar.tsx';

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
  const inbox = createInboxStore(gmail.native);
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

// Gmail's usage limit, naming the time it asks to wait until two hours ahead.
const limitWithTime = (gmail: ReturnType<typeof createSyntheticGmail>) => {
  const until = new Date(Date.now() + 2 * 3_600_000).toISOString();
  gmail.fail({
    status: 429,
    body: JSON.stringify({
      error: { message: `Rate limit exceeded. Retry after ${until}` },
    }),
  });
};

// Two mailboxes shown together, each from its own Inbox store.
const twoMailboxes = (
  work: ReturnType<typeof createInboxStore>,
  home:
    | ReturnType<typeof createInboxStore>
    | ReturnType<typeof createPersistentInbox>,
) => {
  const both = [
    singleMailbox(work, 'work-mailbox'),
    singleMailbox(home, 'home-mailbox'),
  ];
  let shown = both.flatMap((mailbox) => mailbox.getSnapshot());
  return {
    getSnapshot: () => {
      const next = both.flatMap((mailbox) => mailbox.getSnapshot());
      if (next.some((mailbox, index) => mailbox !== shown[index])) {
        shown = next;
      }
      return shown;
    },
    subscribe: (listener: () => void) => {
      const stops = both.map((mailbox) => mailbox.subscribe(listener));
      return () => {
        for (const stop of stops) {
          stop();
        }
      };
    },
    load: async () => {
      await Promise.all(both.map((mailbox) => mailbox.load()));
    },
  };
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
    const inbox = createInboxStore(gmail.native);
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
          name: 'Sent. All Mailboxes · 1 unread',
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

  it('keeps a search when the list switches to unified Sent', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    gmail.deliver({ subject: 'Saved mail remains available' });
    for (const subject of ['Flight to Zagreb', 'Lunch in Split']) {
      const sent = gmail.deliver({ subject });
      gmail.setLabel(sent, 'INBOX', false);
      gmail.setLabel(sent, 'SENT', true);
    }
    const inbox = createInboxStore(gmail.native);
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
      await screen.findByRole('button', { name: /Saved mail remains/u });
      await fireEvent.changeText(
        screen.getByLabelText('Search senders and subjects'),
        'zagreb',
      );
      expect(
        screen.queryByRole('button', { name: /Flight to Zagreb/u }),
      ).toBeNull();
      await app.rerender(show({ unified: 'SENT' }));
      await expect(
        screen.findByRole('button', { name: /Flight to Zagreb/u }),
      ).resolves.toBeVisible();
      expect(
        screen.queryByRole('button', { name: /Lunch in Split/u }),
      ).toBeNull();
    } finally {
      await cleanup();
      inbox.forget();
    }
  });

  it('names a connection that needs sign-in after the count, in place of the scope and update time', async () => {
    expect.hasAssertions();
    const { gmail, inbox } = await renderGmailInbox();
    try {
      gmail.fail({ status: 401 });
      await act(inbox.load);
      expect(
        screen.getByRole('header', {
          name: 'All Inboxes. 1 unread · Gmail needs sign-in',
        }),
      ).toBeVisible();
    } finally {
      await cleanup();
      inbox.forget();
    }
  });

  it('keeps the search subtitle while one mailbox needs sign-in and another is offline', async () => {
    expect.hasAssertions();
    const work = createSyntheticGmail({ address: 'work@example.invalid' });
    const home = createSyntheticGmail({ address: 'home@example.invalid' });
    work.deliver({ subject: 'Saved work mail' });
    home.deliver({ subject: 'Saved home mail' });
    const workInbox = createInboxStore(work.native);
    const homeInbox = createInboxStore(home.native);
    await render(
      <InboxProvider mailboxes={twoMailboxes(workInbox, homeInbox)}>
        <Inbox
          onSelect={() => undefined}
          selected={undefined}
        />
      </InboxProvider>,
    );
    try {
      await screen.findByText('Saved home mail');
      work.fail({ status: 401 });
      home.fail({ code: 'unavailable' });
      await act(async () => {
        await Promise.all([workInbox.load(), homeInbox.load()]);
      });
      await fireEvent.changeText(
        screen.getByLabelText('Search senders and subjects'),
        'Saved',
      );
      await expect(
        screen.findByRole('header', { name: /^Search\. .* · Offline$/u }),
      ).resolves.toBeVisible();
    } finally {
      await cleanup();
      workInbox.forget();
      homeInbox.forget();
    }
  });

  it('names the searched folder when a search in it finds nothing, until a mail server search fails', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const travel = gmail.createLabel('Travel');
    gmail.setLabel(
      gmail.deliver({ subject: 'Flight to Zagreb' }),
      travel,
      true,
    );
    const inbox = createInboxStore(gmail.native);
    try {
      await render(
        <InboxProvider mailboxes={singleMailbox(inbox, 'work-mailbox')}>
          <Inbox
            onSelect={() => undefined}
            selected={undefined}
            view={{ mailbox: 'work-mailbox', folder: travel }}
          />
        </InboxProvider>,
      );
      await screen.findByRole('button', { name: /Flight to Zagreb/u });
      await fireEvent.changeText(
        screen.getByLabelText('Search senders and subjects'),
        'no such trip',
      );
      // The subtitle names the folder, as the empty state does, not the whole mailbox.
      await expect(
        screen.findByText('No results · Travel'),
      ).resolves.toBeVisible();
      expect(
        screen.getByText(/^No saved mail in Travel matches “no such trip”\./u),
      ).toBeVisible();
      // A mail server search that fails gives no answer, so No Results makes way for the failure.
      gmail.fail({ status: 404 });
      await fireEvent.press(
        screen.getByRole('button', {
          name: 'Search Mail Servers for “no such trip”',
        }),
      );
      await expect(
        screen.findByRole('button', { name: 'Try Again' }),
      ).resolves.toBeVisible();
      expect(screen.queryByText('No Results')).toBeNull();
      expect(screen.queryByText('No results · Travel')).toBeNull();
    } finally {
      await cleanup();
      inbox.forget();
    }
  });

  it('waits for a folder chosen during a search to list before saying No Results', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const travel = gmail.createLabel('Travel');
    gmail.setLabel(
      gmail.deliver({ subject: 'Flight to Zagreb' }),
      travel,
      true,
    );
    const inbox = createInboxStore(gmail.native);
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
    jest
      .mocked(AccessibilityInfo.announceForAccessibilityWithOptions)
      .mockClear();
    try {
      const app = await render(show({}));
      await screen.findByRole('button', { name: /Flight to Zagreb/u });
      await fireEvent.changeText(
        screen.getByLabelText('Search senders and subjects'),
        'zagreb',
      );
      await app.rerender(show({ mailbox: 'work-mailbox', folder: travel }));
      await expect(
        screen.findByRole('button', { name: /Flight to Zagreb/u }),
      ).resolves.toBeVisible();
      // The label lists nothing until its first page arrives, which is not an answer.
      expect(
        AccessibilityInfo.announceForAccessibilityWithOptions,
      ).not.toHaveBeenCalledWith('No Results', expect.anything());
    } finally {
      await cleanup();
      inbox.forget();
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
    const inbox = createInboxStore(gmail.native);
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

  it('pauses a Gmail connection at its usage limit until Gmail’s time, keeping saved mail', async () => {
    expect.hasAssertions();
    const { gmail, inbox } = await renderGmailInbox();
    try {
      // Gmail named a time: the capsule says so, and Try Again waits for it without asking Gmail.
      limitWithTime(gmail);
      await act(inbox.load);
      await fireEvent.press(
        screen.getByRole('button', {
          name: /^Gmail paused, until \d{1,2}:\d{2}/u,
        }),
      );
      const details = within(screen.getByTestId('sync-status-details'));
      expect(
        details.getByText(/^Limited by Gmail until \d{1,2}:\d{2}/u),
      ).toBeOnTheScreen();
      const waiting = details.getByRole('button', {
        name: 'Try Again for Gmail · work-mailbox',
      });
      expect(waiting).toBeDisabled();
      expect(
        details.getByText(/^Available at \d{1,2}:\d{2}/u),
      ).toBeOnTheScreen();
      expect(
        details.getByText(
          'Mail already on this Mac stays readable. Sending has its own status in Outbox.',
        ),
      ).toBeOnTheScreen();
      expect(
        screen.getByText('Saved mail remains available'),
      ).toBeOnTheScreen();
    } finally {
      await cleanup();
      inbox.forget();
    }
  });

  it('pauses a Gmail connection at a usage limit without a time and offers one attempt', async () => {
    expect.hasAssertions();
    const { gmail, inbox } = await renderGmailInbox();
    try {
      gmail.fail({ status: 429 });
      await act(inbox.load);
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Gmail paused' }),
      );
      const details = within(screen.getByTestId('sync-status-details'));
      expect(
        details.getByText(
          'Limited by Gmail, 1st time today. Gmail didn’t say for how long; trying again automatically, waiting longer each time.',
        ),
      ).toBeOnTheScreen();
      expect(details.queryByText(/^Available at/u)).toBeNull();
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
      await waitFor(() => {
        expect(
          screen.queryByRole('button', { name: /^Gmail paused/u }),
        ).toBeNull();
      });
    } finally {
      await cleanup();
      inbox.forget();
    }
  });

  it('asks only the shown connection on Try Again while Gmail pauses another, unshown one until its time', async () => {
    expect.hasAssertions();
    const work = createSyntheticGmail();
    const home = createSyntheticGmail();
    const workInbox = createInboxStore(work.native);
    const homeInbox = createInboxStore(home.native);
    const mailboxes = twoMailboxes(workInbox, homeInbox);
    const refreshInbox = jest.fn(async (load: () => Promise<void>) => {
      await load();
    });
    await render(
      <AccountContext
        value={{
          mailboxes: [],
          openAccount: () => undefined,
          authorizeMailbox: () => Promise.resolve(),
          refreshInbox,
          account: 'synthetic-product-account',
          profiles: [],
          createProfile: () => Promise.resolve(undefined),
          chooseFolders: () => Promise.resolve(true),
        }}>
        <InboxProvider mailboxes={mailboxes}>
          <Inbox
            onSelect={() => undefined}
            selected={undefined}
            view={{ mailbox: 'home-mailbox' }}
          />
        </InboxProvider>
      </AccountContext>,
    );
    try {
      limitWithTime(work);
      home.fail({ status: 429 });
      await act(mailboxes.load);
      await fireEvent.press(
        screen.getByRole('button', { name: 'Gmail paused' }),
      );
      const asked = work.requests.length;
      await act(async () => {
        await fireEvent.press(
          within(screen.getByTestId('sync-status-details')).getByRole(
            'button',
            { name: 'Try Again for Gmail · home-mailbox' },
          ),
        );
      });
      expect(refreshInbox).toHaveBeenCalledWith(
        expect.any(Function),
        'explicit',
        'home-mailbox',
      );
      expect(work.requests).toHaveLength(asked);
    } finally {
      await cleanup();
      workInbox.forget();
      homeInbox.forget();
    }
  });

  it('keeps the attention capsule when one mailbox is paused by Gmail and another cannot be reached', async () => {
    expect.hasAssertions();
    const work = createSyntheticGmail();
    const home = createSyntheticGmail();
    const workInbox = createInboxStore(work.native);
    const homeInbox = createInboxStore(home.native);
    const mailboxes = twoMailboxes(workInbox, homeInbox);
    await render(
      <InboxProvider mailboxes={mailboxes}>
        <Inbox
          onSelect={() => undefined}
          selected={undefined}
        />
      </InboxProvider>,
    );
    try {
      limitWithTime(work);
      home.fail({ code: 'unavailable' });
      await act(mailboxes.load);
      expect(
        screen.getByRole('button', { name: '2 accounts need attention' }),
      ).toBeOnTheScreen();
      expect(
        screen.queryByRole('button', { name: /^Gmail paused/u }),
      ).toBeNull();
    } finally {
      await cleanup();
      workInbox.forget();
      homeInbox.forget();
    }
  });

  it('keeps the attention capsule when one mailbox is paused by Gmail and another’s storage is locked', async () => {
    expect.hasAssertions();
    const work = createSyntheticGmail();
    const workInbox = createInboxStore(work.native);
    const locked = createPersistentInbox(
      {
        ...makeMockInboxStorage(),
        open: () =>
          Promise.reject(
            Object.assign(new Error('locked'), { code: 'locked' }),
          ),
      },
      createMockMailSession('open-read-relaunch').mail.list,
    );
    const mailboxes = twoMailboxes(workInbox, locked);
    await render(
      <InboxProvider mailboxes={mailboxes}>
        <Inbox
          onSelect={() => undefined}
          selected={undefined}
        />
      </InboxProvider>,
    );
    try {
      limitWithTime(work);
      await act(mailboxes.load);
      expect(
        screen.getByRole('button', { name: /needs? attention$/u }),
      ).toBeOnTheScreen();
      expect(
        screen.queryByRole('button', { name: /^Gmail paused/u }),
      ).toBeNull();
      // Only the storage notice offers Try Again: Gmail's time has not come yet.
      expect(screen.getAllByRole('button', { name: 'Try Again' })).toHaveLength(
        1,
      );
    } finally {
      await cleanup();
      workInbox.forget();
    }
  });

  it('says Gmail’s pause in the shown sidebar in place of the capsule, and opens Sync Status from it', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({ subject: 'Saved mail remains available' });
    const inbox = createInboxStore(gmail.native);
    await render(
      <InboxProvider mailboxes={singleMailbox(inbox, 'work-mailbox')}>
        <Mailboxes
          view={{}}
          onView={() => undefined}
          onProfile={() => undefined}
        />
        <Inbox
          onSelect={() => undefined}
          selected={undefined}
          sidebarShown
        />
      </InboxProvider>,
    );
    try {
      await screen.findByText('Saved mail remains available');
      limitWithTime(gmail);
      await act(inbox.load);
      const warnings = screen.getAllByRole('button', {
        name: /^Gmail paused, until \d{1,2}:\d{2}/u,
      });
      // Only the sidebar says it, and its connection's header warns of no outage.
      expect(warnings).toHaveLength(1);
      expect(
        screen.getByRole('button', { name: /^Gmail · [^,]+$/u }),
      ).toBeOnTheScreen();
      await fireEvent.press(warnings[0]!);
      expect(
        within(screen.getByTestId('sync-status-details')).getByText(
          /^Limited by Gmail until \d{1,2}:\d{2}/u,
        ),
      ).toBeOnTheScreen();
    } finally {
      await cleanup();
      inbox.forget();
    }
  });

  it('says what stays shown when a mail server search fails for an unnamed reason, and Try Again searches again', async () => {
    expect.hasAssertions();
    const { gmail, inbox } = await renderGmailInbox();
    try {
      gmail.archive(gmail.deliver({ subject: 'Saved in archive' }));
      await fireEvent.changeText(
        screen.getByLabelText('Search senders and subjects'),
        'Saved',
      );
      // Gmail answers the search with Not Found, a failure the app can't name.
      gmail.fail({ status: 404 });
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Search Mail Servers for “Saved”',
        }),
      );
      await expect(
        screen.findByText(
          'The mail server search didn’t finish. Mail saved on this device is still shown. Choose Try Again to search again.',
        ),
      ).resolves.toBeOnTheScreen();
      // The saved result stays above the failure.
      expect(
        screen.getByRole('button', { name: /Saved mail remains available/u }),
      ).toBeOnTheScreen();
      await fireEvent.press(screen.getByRole('button', { name: 'Try Again' }));
      await expect(
        screen.findByRole('button', { name: /\. Saved in archive/u }),
      ).resolves.toBeOnTheScreen();
    } finally {
      await cleanup();
      inbox.forget();
    }
  });

  it('says saved mail can’t be shown when the mailbox fails to open for an unnamed reason, and Try Again shows it', async () => {
    expect.hasAssertions();
    const { gmail, inbox } = await renderGmailInbox();
    try {
      gmail.failOpen('unavailable');
      await act(inbox.load);
      expect(
        screen.getByRole('alert', {
          name: 'Mail saved on this device can’t be shown. It has been kept. Choose Try Again to show it again.',
        }),
      ).toBeOnTheScreen();
      expect(screen.queryByText('Saved mail remains available')).toBeNull();
      await fireEvent.press(screen.getByRole('button', { name: 'Try Again' }));
      await expect(
        screen.findByText('Saved mail remains available'),
      ).resolves.toBeOnTheScreen();
      expect(screen.queryByRole('alert')).toBeNull();
    } finally {
      await cleanup();
      inbox.forget();
    }
  });

  it('points a mailbox whose saved mail can’t be shown to the message list’s Try Again in the sync status', async () => {
    expect.hasAssertions();
    const work = createSyntheticGmail();
    const home = createSyntheticGmail();
    const workInbox = createInboxStore(work.native);
    const homeInbox = createInboxStore(home.native);
    const mailboxes = twoMailboxes(workInbox, homeInbox);
    await render(
      <InboxProvider mailboxes={mailboxes}>
        <Inbox
          onSelect={() => undefined}
          selected={undefined}
        />
      </InboxProvider>,
    );
    try {
      work.fail({ code: 'unavailable' });
      home.failOpen('unavailable');
      await act(mailboxes.load);
      await fireEvent.press(
        screen.getByRole('button', { name: '1 account needs attention' }),
      );
      const details = within(screen.getByTestId('sync-status-details'));
      expect(
        details.getByLabelText(
          'Mail saved on this device can’t be shown. It has been kept. Choose Try Again in the message list to show it again.',
        ),
      ).toBeOnTheScreen();
      // That row has no Try Again of its own; the message list's notice does.
      expect(
        details.queryByRole('button', {
          name: 'Try Again for Gmail · home-mailbox',
        }),
      ).toBeNull();
      expect(
        screen.getByRole('alert', {
          name: /Mail saved on this device can’t be shown\. It has been kept\. Choose Try Again to show it again\.$/u,
        }),
      ).toBeOnTheScreen();
    } finally {
      await cleanup();
      workInbox.forget();
      homeInbox.forget();
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

  it('keeps the saved body of a listed folder the cache evicted when View › Refresh is chosen', async () => {
    expect.hasAssertions();
    const commands = commandEvents();
    const imap = createSyntheticImap();
    const names = Array.from({ length: 9 }, (_, index) => `Folder ${index}`);
    for (const name of names) {
      imap.addFolder(name);
      imap.deliver(name, { subject: `In ${name}` });
    }
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    await inbox.openFolder('Folder 0');
    // Its body is saved while the folder is cached; opening eight more folders evicts it.
    const folder = inbox.folder('Folder 0');
    ok(folder?.kind === 'ready');
    const [shown] = folder.messages;
    ok(shown !== undefined);
    const release = inbox.retainMessage(shown.id);
    await inbox.readMessage(shown.id);
    release();
    for (const name of names.slice(1)) {
      await inbox.openFolder(name);
    }
    await render(
      <InboxProvider mailboxes={singleMailbox(inbox, 'home-mailbox')}>
        <Inbox
          onSelect={() => undefined}
          selected={undefined}
          view={{ mailbox: 'home-mailbox', folder: 'Folder 0' }}
        />
      </InboxProvider>,
    );
    try {
      await screen.findByText('In Folder 0');
      const readsBefore = imap.server.reads.length;
      await act(async () => {
        DeviceEventEmitter.emit('refresh', { window: 'inbox-window-' });
        await Promise.resolve();
      });
      await waitFor(() => {
        expect(imap.server.reads.slice(readsBefore)).toStrictEqual(
          expect.arrayContaining(['examine INBOX', 'examine Folder 0']),
        );
        expect(inbox.folder('Folder 0')).toMatchObject({ status: 'current' });
      });
      expect(imap.bodies.has(shown.id)).toBe(true);
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
    const inbox = createInboxStore(gmail.native);
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
