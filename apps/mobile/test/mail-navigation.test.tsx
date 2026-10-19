import type { View as NativeView } from 'react-native';
import type { SplitHostCommands } from 'react-native-screens/experimental';

import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { makeMockInboxStorage } from '@private-email/mail-core/testing/mock-storage';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { useRef, useState } from 'react';
import { ScrollView } from 'react-native';

import type { mailboxes } from '../src/private-storage.ts';
import type { MailboxView } from '../src/sidebar.tsx';

import { MailNavigation } from '../src/mail-navigation.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { Mailboxes } from '../src/sidebar.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Substitute only URL delivery; the native destination composition is real.
jest.mock('expo-router', () => {
  const { View } = jest.requireActual<{ View: typeof NativeView }>(
    'react-native',
  );
  return {
    Navigator: View,
    Slot: View,
    useGlobalSearchParams: () => ({}),
  };
});

// oxlint-disable-next-line vitest/prefer-import-in-mock -- The real Inbox store uses synthetic native storage.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Native inset measurement is outside this component journey.
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, left: 0, right: 0, bottom: 0 }),
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- The native safe-area host has no insets in Jest.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

function Mail() {
  const navigation = useRef<SplitHostCommands>(null);
  const [view, setView] = useState<MailboxView>({});
  return (
    <InboxProvider>
      <MailNavigation
        ref={navigation}
        composer={null}
        topColumnForCollapsing="supplementary"
        primary={
          <Mailboxes
            view={view}
            onView={(next) => {
              setView(next);
              navigation.current?.show('supplementary');
            }}
          />
        }
        inbox={{
          view,
          onView: setView,
          selected: undefined,
          onSelect: () => undefined,
          onBack: () => navigation.current?.show('primary'),
        }}
      />
    </InboxProvider>
  );
}

async function openInbox() {
  const fixture = createPersistentInbox(
    makeMockInboxStorage(),
    createMockMailSession('open-read-relaunch').mail.list,
  );
  jest.replaceProperty(
    jest.requireMock<{ mailboxes: typeof mailboxes }>(
      '../src/private-storage.ts',
    ),
    'mailboxes',
    singleMailbox(fixture, 'preview'),
  );
  await render(<Mail />);
  await screen.findByRole('button', {
    name: /^Unread\. Oliver Park\. Saturday, by the river\?/u,
  });
}

async function reopenInbox() {
  await fireEvent.press(
    screen.getByRole('button', { name: 'Back to Mailboxes' }),
  );
  await fireEvent.press(screen.getByRole('button', { name: 'All inboxes' }));
}

const scrollEvent = (y: number) => ({
  nativeEvent: {
    contentOffset: { x: 0, y },
    contentSize: { width: 390, height: 1000 },
    layoutMeasurement: { width: 390, height: 400 },
  },
});

function observeScrollCommands() {
  // The preset has no native responder; substitute only that command boundary.
  const responder = new ScrollView({});
  const response = jest
    .spyOn(ScrollView.prototype, 'getScrollResponder')
    .mockReturnValue(responder);
  const scrollTo = jest.spyOn(responder, 'scrollTo');
  return {
    scrollTo,
    restore: () => {
      scrollTo.mockRestore();
      response.mockRestore();
    },
  };
}

describe('phone mail navigation', () => {
  /* oxlint-disable vitest/max-expects -- One native/button Back journey checks retained state and its scroll bridge. */
  it('retains search and filters through native and button Back while Mailboxes remains the predecessor', async () => {
    expect.hasAssertions();
    await openInbox();
    expect(screen.queryByText('Mailboxes')).toBeNull();
    expect(
      screen.getByText('Mailboxes', { includeHiddenElements: true }),
    ).toBeDefined();
    await fireEvent.press(screen.getByRole('togglebutton', { name: 'Filter' }));
    await fireEvent.press(screen.getByRole('button', { name: 'Search' }));
    await fireEvent.changeText(
      screen.getByLabelText('Search senders and subjects'),
      'Oliver',
    );
    await screen.findByRole('button', {
      name: /^Unread\. Oliver Park\. Saturday, by the river\?/u,
    });
    await act(async () => {
      await fireEvent(screen.getByTestId('inbox-screen'), 'dismissed', {
        nativeEvent: { dismissCount: 1 },
      });
    });
    expect(screen.getByText('Mailboxes')).toBeVisible();
    expect(screen.queryByLabelText('Search senders and subjects')).toBeNull();
    await fireEvent.press(screen.getByRole('button', { name: 'All inboxes' }));
    expect(screen.getByLabelText('Search senders and subjects')).toHaveProp(
      'value',
      'Oliver',
    );
    await fireEvent.press(screen.getByRole('button', { name: 'Close Search' }));
    expect(screen.getByRole('togglebutton', { name: 'Filter' })).toHaveProp(
      'accessibilityState',
      { checked: true },
    );
    await fireEvent.scroll(screen.getByLabelText('Inbox messages'), {
      nativeEvent: {
        contentOffset: { x: 0, y: 120 },
        contentSize: { width: 390, height: 1000 },
        layoutMeasurement: { width: 390, height: 400 },
      },
    });
    await fireEvent.press(
      screen.getByRole('button', { name: 'Back to Mailboxes' }),
    );
    await fireEvent.press(screen.getByRole('button', { name: 'All inboxes' }));
    expect(screen.getByLabelText('Inbox messages')).toHaveProp(
      'contentOffset',
      {
        x: 0,
        y: 120,
      },
    );
    expect(screen.getByRole('togglebutton', { name: 'Filter' })).toHaveProp(
      'accessibilityState',
      { checked: true },
    );
  });
  /* oxlint-enable vitest/max-expects */

  it('restores a recreated list after both viewport and sufficient content layout, then stops restoring', async () => {
    expect.hasAssertions();
    const { scrollTo, restore } = observeScrollCommands();
    try {
      await openInbox();
      await fireEvent.scroll(
        screen.getByLabelText('Inbox messages'),
        scrollEvent(120),
      );
      await reopenInbox();
      const list = screen.getByLabelText('Inbox messages');
      await fireEvent.scroll(list, scrollEvent(0));
      await fireEvent(list, 'contentSizeChange', 390, 300);
      await fireEvent(list, 'layout', {
        nativeEvent: { layout: { x: 0, y: 0, width: 390, height: 400 } },
      });
      expect(scrollTo).not.toHaveBeenCalled();
      await fireEvent(list, 'contentSizeChange', 390, 1000);
      expect(scrollTo).toHaveBeenLastCalledWith({
        x: 0,
        y: 120,
        animated: false,
      });
      await fireEvent.scroll(list, scrollEvent(120));
      await fireEvent(list, 'contentSizeChange', 390, 1300);
      // oxlint-disable-next-line vitest/prefer-called-once -- Jest does not provide toHaveBeenCalledOnce.
      expect(scrollTo).toHaveBeenCalledTimes(1);
      await fireEvent.scroll(list, scrollEvent(240));
      await fireEvent(list, 'contentSizeChange', 390, 1400);
      // oxlint-disable-next-line vitest/prefer-called-once -- Jest does not provide toHaveBeenCalledOnce.
      expect(scrollTo).toHaveBeenCalledTimes(1);
    } finally {
      restore();
    }
  });

  it('cancels a pending restore when the person starts scrolling and saves their new position', async () => {
    expect.hasAssertions();
    const { scrollTo, restore } = observeScrollCommands();
    try {
      await openInbox();
      await fireEvent.scroll(
        screen.getByLabelText('Inbox messages'),
        scrollEvent(120),
      );
      await reopenInbox();
      const list = screen.getByLabelText('Inbox messages');
      await fireEvent.scroll(list, scrollEvent(0));
      await fireEvent(list, 'scrollBeginDrag', scrollEvent(0));
      await fireEvent(list, 'layout', {
        nativeEvent: { layout: { x: 0, y: 0, width: 390, height: 400 } },
      });
      await fireEvent(list, 'contentSizeChange', 390, 1000);
      expect(scrollTo).not.toHaveBeenCalled();
      await fireEvent.scroll(list, scrollEvent(240));
      await reopenInbox();
      const reopened = screen.getByLabelText('Inbox messages');
      await fireEvent(reopened, 'contentSizeChange', 390, 1000);
      await fireEvent(reopened, 'layout', {
        nativeEvent: { layout: { x: 0, y: 0, width: 390, height: 400 } },
      });
      expect(scrollTo).toHaveBeenLastCalledWith({
        x: 0,
        y: 240,
        animated: false,
      });
      await fireEvent.scroll(reopened, scrollEvent(240));
      await fireEvent(reopened, 'contentSizeChange', 390, 1200);
      // oxlint-disable-next-line vitest/prefer-called-once -- Jest does not provide toHaveBeenCalledOnce.
      expect(scrollTo).toHaveBeenCalledTimes(1);
    } finally {
      restore();
    }
  });

  it('retires a pending position when the search changes', async () => {
    expect.hasAssertions();
    const { scrollTo, restore } = observeScrollCommands();
    try {
      await openInbox();
      await fireEvent.scroll(
        screen.getByLabelText('Inbox messages'),
        scrollEvent(120),
      );
      await reopenInbox();
      await fireEvent.scroll(
        screen.getByLabelText('Inbox messages'),
        scrollEvent(0),
      );
      await fireEvent(
        screen.getByLabelText('Search senders and subjects'),
        'focus',
      );
      await fireEvent.changeText(
        screen.getByLabelText('Search senders and subjects'),
        'Oliver',
      );
      await screen.findByRole('button', {
        name: /^Unread\. Oliver Park\. Saturday, by the river\?/u,
      });
      const list = screen.getByLabelText('Inbox messages');
      await fireEvent(list, 'layout', {
        nativeEvent: { layout: { x: 0, y: 0, width: 390, height: 400 } },
      });
      await fireEvent(list, 'contentSizeChange', 390, 1000);
      expect(scrollTo).not.toHaveBeenCalled();
      expect(screen.getByLabelText('Search senders and subjects')).toHaveProp(
        'value',
        'Oliver',
      );
      await fireEvent.press(
        screen.getByRole('button', { name: 'Close Search' }),
      );
      expect(screen.getByLabelText('Inbox messages')).toHaveProp(
        'contentOffset',
        { x: 0, y: 0 },
      );
      await reopenInbox();
      const reopened = screen.getByLabelText('Inbox messages');
      await fireEvent(reopened, 'layout', {
        nativeEvent: { layout: { x: 0, y: 0, width: 390, height: 400 } },
      });
      await fireEvent(reopened, 'contentSizeChange', 390, 1000);
      expect(scrollTo).not.toHaveBeenCalled();
    } finally {
      restore();
    }
  });
});
