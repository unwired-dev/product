import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-session';
import {
  act,
  fireEvent,
  render,
  screen,
  within,
} from '@testing-library/react-native';
import { Dimensions, ScrollView, StyleSheet } from 'react-native';

import { CommandPaletteProvider } from '../src/command-palette.tsx';
import { createWindowBar, WindowBarContext } from '../src/inbox-bar.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { MessageDetail, ThreadView } from '../src/message-detail.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- The palette sheet clears the status bar itself; the host has no inset here.
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, left: 0, right: 0, bottom: 0 }),
}));

const alex = syntheticMailboxes['alex@example.invalid'];

// One Gmail thread of three messages, the newest a plain-text reply and the middle one an HTML
// reply quoting with Gmail's markup, beside an unrelated message.
function threadMailbox() {
  const gmail = createSyntheticGmail();
  const first = gmail.deliver({
    from: 'Maya Chen <maya@example.invalid>',
    subject: 'Planning',
    content: { text: 'Can we meet on Tuesday?' },
  });
  const middle = gmail.deliver({
    from: 'Alex Rivera <alex@example.invalid>',
    subject: 'Re: Planning',
    thread: first,
    content: {
      html:
        '<p>Tuesday works for me. <a href="https://example.invalid/agenda">Agenda</a></p>' +
        '<div class="gmail_quote">' +
        '<div class="gmail_attr">On Monday, Maya Chen wrote:</div>' +
        '<blockquote class="gmail_quote"><p>Original agenda</p></blockquote></div>',
    },
  });
  gmail.deliver({
    from: 'Sam Lee <sam@example.invalid>',
    subject: 'Re: Planning',
    thread: first,
    content: {
      text: 'See you then.\n\nOn Monday, Alex Rivera wrote:\n> Earlier reply\n>\n> > Older quote',
    },
  });
  gmail.deliver({
    from: 'Pat Doe <pat@example.invalid>',
    subject: 'Elsewhere',
  });
  return { native: gmail.native, middle };
}

// A Thread message's section, found by its sender header: the nearest ancestor that reports
// its layout for scrolling.
const messageBy = (sender: string) => {
  let section = screen.getByText(sender).parent;
  while (section !== null && section.props.onLayout === undefined) {
    section = section.parent;
  }
  if (section === null) {
    throw new Error(`Expected the message from ${sender}`);
  }
  return section;
};

const readerContent = () => {
  let scroll = messageBy('Alex Rivera').parent;
  while (scroll !== null && scroll.props.contentContainerStyle === undefined) {
    scroll = scroll.parent;
  }
  return StyleSheet.flatten(scroll?.props.contentContainerStyle);
};

// The rendered Thread view over the real Gmail store; only native scrolling is observed.
describe('thread view', () => {
  /* oxlint-disable vitest/max-expects -- One Thread journey checks membership, order, highlight, scrolling and quoted history. */
  it('stacks the thread newest first, scrolls to the opened message once, and collapses quoted history', async () => {
    expect.hasAssertions();
    const scrollTo = jest
      .spyOn(ScrollView.prototype, 'scrollTo')
      .mockReturnValue(undefined);
    const { native, middle } = threadMailbox();
    const store = createGmailInbox(native);
    await render(
      <InboxProvider mailboxes={singleMailbox(store, alex)}>
        <WindowBarContext value={createWindowBar()}>
          <ThreadView
            id={middle}
            mailbox={alex}
          />
        </WindowBarContext>
      </InboxProvider>,
    );
    await act(store.load);

    await expect(screen.findByText('See you then.')).resolves.toBeVisible();
    expect(screen.getByRole('header', { name: 'Re: Planning' })).toBeVisible();
    // The subject text itself stays selectable inside the accessible header.
    expect(screen.getByText('Re: Planning')).toHaveProp('selectable', true);
    await expect(
      screen.findByText('Can we meet on Tuesday?'),
    ).resolves.toBeVisible();
    expect(
      screen
        .getAllByText(/^(?:Maya Chen|Alex Rivera|Sam Lee|Pat Doe)$/u)
        .map((sender) => sender.props.children),
    ).toStrictEqual(['Sam Lee', 'Alex Rivera', 'Maya Chen']);

    // The opened message is highlighted and scrolled to on its first layout only.
    const opened = messageBy('Alex Rivera');
    // The final Thread body must scroll clear of the window's floating bar.
    expect(readerContent()).toMatchObject({ paddingBottom: 84 });
    expect(screen.getByText('Alex Rivera')).toHaveProp('accessibilityState', {
      selected: true,
    });
    expect(screen.getByText('Sam Lee')).not.toHaveProp('accessibilityState', {
      selected: true,
    });
    // A bar marks it without relying on its background color.
    expect(opened).toHaveStyle({ borderLeftWidth: 4 });
    expect(messageBy('Sam Lee')).not.toHaveStyle({ borderLeftWidth: 4 });
    await act(() => {
      fireEvent(opened, 'layout', {
        nativeEvent: { layout: { x: 0, y: 480, width: 320, height: 300 } },
      });
    });
    await act(() => {
      fireEvent(opened, 'layout', {
        nativeEvent: { layout: { x: 0, y: 900, width: 320, height: 300 } },
      });
    });
    expect(scrollTo.mock.calls).toStrictEqual([[{ y: 480, animated: false }]]);

    // Quoted history starts collapsed in both replies, and the original has none to show.
    expect(screen.queryByText(/Earlier reply/u)).toBeNull();
    const document = await screen.findByTestId('message-webview');
    expect(document.props.source.html).toContain('Tuesday works for me.');
    expect(document.props.source.html).not.toContain('Original agenda');
    expect(
      screen.getAllByRole('button', { name: 'Show quoted text' }),
    ).toHaveLength(2);
    expect(
      within(messageBy('Maya Chen')).queryByRole('button', {
        name: 'Show quoted text',
      }),
    ).toBeNull();

    await act(() => {
      fireEvent.press(
        within(messageBy('Sam Lee')).getByRole('button', {
          name: 'Show quoted text',
        }),
      );
    });
    expect(screen.getByText(/On Monday, Alex Rivera wrote:/u)).toBeVisible();
    expect(screen.getByText(/Earlier reply/u)).toBeVisible();
    expect(screen.getByRole('button', { name: 'Hide quoted text' })).toHaveProp(
      'accessibilityState',
      { expanded: true },
    );

    await act(() => {
      fireEvent.press(screen.getByRole('button', { name: 'Show quoted text' }));
    });
    const expanded = await screen.findByTestId('message-webview');
    expect(expanded.props.source.html).toContain('Original agenda');
  });
  /* oxlint-enable vitest/max-expects */

  it('keeps a link confirmation while another message of the thread toggles its quoted text', async () => {
    expect.hasAssertions();
    const { native, middle } = threadMailbox();
    const store = createGmailInbox(native);
    await render(
      <InboxProvider mailboxes={singleMailbox(store, alex)}>
        <ThreadView
          id={middle}
          mailbox={alex}
        />
      </InboxProvider>,
    );
    await act(store.load);
    await screen.findByTestId('message-webview');
    await act(() => {
      fireEvent.press(
        within(messageBy('Alex Rivera')).getByRole('link', {
          name: 'Open link: Agenda',
        }),
      );
    });
    expect(screen.getByText('Open this link in your browser?')).toBeVisible();

    await act(() => {
      fireEvent.press(
        within(messageBy('Sam Lee')).getByRole('button', {
          name: 'Show quoted text',
        }),
      );
    });
    expect(screen.getByText('Open this link in your browser?')).toBeVisible();

    // Collapsing or expanding the link's own message discards it.
    await act(() => {
      fireEvent.press(
        within(messageBy('Alex Rivera')).getByRole('button', {
          name: 'Show quoted text',
        }),
      );
    });
    expect(screen.queryByText('Open this link in your browser?')).toBeNull();
  });

  it('omits the conversation count when opening one message from a cached thread', async () => {
    expect.hasAssertions();
    const { native, middle } = threadMailbox();
    const store = createGmailInbox(native);
    await render(
      <InboxProvider mailboxes={singleMailbox(store, alex)}>
        <MessageDetail
          id={middle}
          mailbox={alex}
        />
      </InboxProvider>,
    );
    await act(store.load);

    await expect(screen.findByText('Alex Rivera')).resolves.toBeVisible();
    expect(screen.getByRole('header', { name: 'Re: Planning' })).toBeVisible();
    // The subject text itself stays selectable inside the accessible header.
    expect(screen.getByText('Re: Planning')).toHaveProp('selectable', true);
    expect(screen.queryByText(/^\d+ Messages?$/u)).toBeNull();
  });

  it.each([
    { back: false, onClose: undefined },
    { back: true, onClose: () => undefined },
  ])(
    'opens the Command Palette from the thread header with Back $back',
    async ({ back, onClose }) => {
      expect.hasAssertions();
      const { native, middle } = threadMailbox();
      const store = createGmailInbox(native);
      await render(
        <InboxProvider mailboxes={singleMailbox(store, alex)}>
          <CommandPaletteProvider>
            <ThreadView
              id={middle}
              mailbox={alex}
              onClose={onClose}
            />
          </CommandPaletteProvider>
        </InboxProvider>,
      );
      await act(store.load);
      expect(screen.queryByRole('button', { name: /^Back/u }) !== null).toBe(
        back,
      );
      await fireEvent(
        await screen.findByRole('header', { name: 'Re: Planning' }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'openCommandPalette' } },
      );
      const palette = within(screen.getByTestId('command-palette'));
      expect(
        palette.getByRole('header', {
          name: 'Selected Message · Re: Planning',
        }),
      ).toBeVisible();
      expect(
        palette.getByRole('button', {
          name: 'Reply. Not available for this message',
        }),
      ).toBeDisabled();
    },
  );

  it('shows the message as unavailable when it is not cached', async () => {
    expect.hasAssertions();
    const { native } = threadMailbox();
    const store = createGmailInbox(native);
    await render(
      <InboxProvider mailboxes={singleMailbox(store, alex)}>
        <ThreadView
          id="ffff"
          mailbox={alex}
        />
      </InboxProvider>,
    );
    await act(store.load);
    await expect(
      screen.findByText('Message unavailable'),
    ).resolves.toBeVisible();
  });

  it('keeps Back, the cached unread count and the truncated subject on a landscape iPhone', async () => {
    expect.hasAssertions();
    const window = Dimensions.get('window');
    Dimensions.set({ window: { ...window, width: 844, height: 390 } });
    try {
      const { native, middle } = threadMailbox();
      const store = createGmailInbox(native);
      const onClose = jest.fn();
      await render(
        <InboxProvider mailboxes={singleMailbox(store, alex)}>
          <ThreadView
            id={middle}
            mailbox={alex}
            onClose={onClose}
          />
        </InboxProvider>,
      );
      await act(store.load);
      await expect(
        screen.findByRole('header', { name: 'Re: Planning' }),
      ).resolves.toBeVisible();
      expect(screen.getByRole('header', { name: 'Re: Planning' })).toHaveProp(
        'numberOfLines',
        1,
      );
      expect(screen.getByText('3 Messages')).toBeVisible();
      // Every delivered message is unread, including the one outside the Thread.
      await fireEvent.press(
        screen.getByRole('button', { name: 'Back, 4 unread' }),
      );
      // oxlint-disable-next-line vitest/prefer-called-once -- Jest has no toHaveBeenCalledOnce.
      expect(onClose).toHaveBeenCalledTimes(1);
    } finally {
      Dimensions.set({ window });
    }
  });
});
