import { ok } from 'node:assert/strict';

import type { NativeGmailMailbox } from '@private-email/mail-core/inbox-store';
import type { NativePins, Pins } from '@private-email/mail-core/pins';
import type { Registration } from '@private-email/mail-core/registration';

import { ownerOf } from '@private-email/mail-core/drafts';
import { gmailAction } from '@private-email/mail-core/gmail-actions';
import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { createInboxStore } from '@private-email/mail-core/inbox-store';
import {
  createMailboxes,
  singleMailbox,
} from '@private-email/mail-core/mailboxes';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createPins } from '@private-email/mail-core/pins';
import {
  createRegistration,
  defaultProfile,
} from '@private-email/mail-core/registration';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { makeMockInboxStorage } from '@private-email/mail-core/testing/mock-storage';
import { createRegistrationScenario } from '@private-email/mail-core/testing/registration-scenarios';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-vault';
import { palette } from '@private-email/mail-core/theme';
import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from '@testing-library/react-native';
import { setStringAsync } from 'expo-clipboard';
import { useMemo, useState } from 'react';
import {
  AccessibilityInfo,
  Alert,
  Animated,
  AppState,
  Dimensions,
  Linking,
  StyleSheet,
  useWindowDimensions,
  View,
} from 'react-native';
import { useReanimatedKeyboardAnimation } from 'react-native-keyboard-controller';
import { makeMutable, withTiming } from 'react-native-reanimated';
import { scheduleOnRN } from 'react-native-worklets';

import type { ipad } from '../src/inbox-styles.ts';
import type { Selection } from '../src/inbox.tsx';
import type { mailboxes } from '../src/private-storage.ts';
import type { MailboxView } from '../src/sidebar.tsx';
import type { usePalette } from '../src/theme.ts';

import { CommandPaletteProvider } from '../src/command-palette.tsx';
import { Composer } from '../src/composer.tsx';
import {
  createWindowBar,
  WindowBarContext,
  WindowBarHost,
} from '../src/inbox-bar.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider, ProfileScope } from '../src/mailbox.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
import { PinsContext } from '../src/pins.tsx';
import { RegistrationGate } from '../src/registration-gate.tsx';
import { SidebarToggleContext } from '../src/sidebar-toggle.tsx';
import { Mailboxes } from '../src/sidebar.tsx';
import { started } from './started.ts';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires string module names.
jest.mock('expo-clipboard', () => ({ setStringAsync: jest.fn() }));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Only the external animation completion and cross-runtime queue are controlled.
jest.mock('react-native-reanimated', () => {
  const actual = jest.requireActual('react-native-reanimated');
  return {
    ...actual,
    __esModule: true,
    withTiming: jest.fn(actual.withTiming),
  };
});

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Keep real Worklets except the controllable RN completion queue.
jest.mock('react-native-worklets', () => {
  const actual = jest.requireActual('react-native-worklets');
  return {
    ...actual,
    __esModule: true,
    scheduleOnRN: jest.fn(actual.scheduleOnRN),
  };
});

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- The palette sheet clears the status bar itself; the host has no inset here.
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, left: 0, right: 0, bottom: 0 }),
}));

const preview = 'preview';
const alex = syntheticMailboxes['alex@example.invalid'];

function InboxJourney() {
  const [selected, setSelected] = useState<Selection>();
  return (
    <InboxProvider>
      <Inbox
        onSelect={setSelected}
        selected={selected}
      />
      <MessageDetail
        id={selected?.id}
        mailbox={selected?.mailbox}
      />
    </InboxProvider>
  );
}

describe('preview Inbox', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Each test owns a fresh native-boundary store.
  beforeEach(() => {
    const fixture = createPersistentInbox(
      makeMockInboxStorage(),
      createMockMailSession('open-read-relaunch').mail.list,
    );
    jest.replaceProperty(
      jest.requireMock<{ mailboxes: typeof mailboxes }>(
        '../src/private-storage.ts',
      ),
      'mailboxes',
      singleMailbox(fixture, preview),
    );
  });

  it('keeps refreshing until every shown mailbox settles after one rejects', async () => {
    expect.hasAssertions();
    const first = createPersistentInbox(makeMockInboxStorage());
    const storage = makeMockInboxStorage();
    let held = Promise.resolve();
    const second = createPersistentInbox({
      ...storage,
      open: async (seed) => {
        await held;
        return storage.open(seed);
      },
    });
    await Promise.all([first.load(), second.load()]);
    const one = singleMailbox(first, 'first');
    const two = singleMailbox(second, 'second');
    const snapshot = [...one.getSnapshot(), ...two.getSnapshot()];
    await render(
      <InboxProvider mailboxes={{ ...one, getSnapshot: () => snapshot }}>
        <Inbox
          selected={undefined}
          onSelect={() => undefined}
        />
      </InboxProvider>,
    );
    let release: () => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Explicitly hold one action past the other's rejection.
    held = new Promise<void>((resolve) => {
      release = resolve;
    });
    // Provider failures become state. A broken subscriber rejects the real store action instead.
    const unsubscribe = first.subscribe(() => {
      throw new Error('Mailbox subscriber failed');
    });
    try {
      await act(async () => {
        fireEvent(screen.getByLabelText('Inbox messages'), 'refresh');
      });
      expect(screen.getByLabelText('Inbox messages')).toHaveProp(
        'refreshing',
        true,
      );
      await act(async () => {
        release();
      });
      expect(screen.getByLabelText('Inbox messages')).toHaveProp(
        'refreshing',
        false,
      );
    } finally {
      release();
      unsubscribe();
    }
  });

  it.each(['light', 'dark'] as const)(
    'keeps the selected row legible in %s appearance',
    async (appearance) => {
      expect.hasAssertions();
      const colors = palette[appearance];
      const paletteSpy = jest
        .spyOn(
          jest.requireActual<{ usePalette: typeof usePalette }>(
            '../src/theme.ts',
          ),
          'usePalette',
        )
        .mockReturnValue(colors);
      try {
        await render(<InboxJourney />);
        const message = await screen.findByRole('button', {
          name: 'Unread. Oliver Park. Saturday, by the river?',
        });
        expect(message).toHaveStyle({ backgroundColor: 'transparent' });
        expect(
          within(message).getByText('Saturday, by the river?'),
        ).toHaveStyle({ fontWeight: '600' });
        await fireEvent.press(message);
        expect(message).toHaveStyle({ backgroundColor: colors.accentFill });
        // Opening the message read it.
        expect(within(message).getByText('Oliver Park')).toHaveStyle({
          color: colors.accentOnFill,
          fontWeight: '400',
        });
      } finally {
        paletteSpy.mockRestore();
      }
    },
  );

  it.each(['light', 'dark'] as const)(
    'keeps Apply Filters legible while held in %s appearance',
    async (appearance) => {
      expect.hasAssertions();
      const colors = palette[appearance];
      const paletteSpy = jest
        .spyOn(
          jest.requireActual<{ usePalette: typeof usePalette }>(
            '../src/theme.ts',
          ),
          'usePalette',
        )
        .mockReturnValue(colors);
      try {
        await render(<InboxJourney />);
        await screen.findByRole('button', {
          name: 'Unread. Oliver Park. Saturday, by the river?',
        });
        await fireEvent.press(
          screen.getByRole('togglebutton', { name: 'Filter' }),
        );
        await fireEvent.press(
          screen.getByRole('button', { name: 'Filtered by Unread' }),
        );
        const confirm = screen.getByRole('button', { name: 'Apply Filters' });
        await fireEvent(confirm, 'responderGrant', {
          persist: () => undefined,
          currentTarget: 1,
          nativeEvent: {
            pageX: 0,
            pageY: 0,
            locationX: 0,
            locationY: 0,
            timestamp: 0,
          },
        });
        expect(confirm).toHaveStyle({ backgroundColor: colors.accentFill });
      } finally {
        paletteSpy.mockRestore();
      }
    },
  );

  /* oxlint-disable vitest/max-expects -- Each journey proves one search or filter flow end to end. */
  it('opens search over a blank list, marks matches under Top Results, keeps search through edits and closes back to the Inbox', async () => {
    expect.hasAssertions();
    await render(<InboxJourney />);
    const row = await screen.findByRole('button', {
      name: 'Unread. Oliver Park. Saturday, by the river?',
    });
    // Jest's window reports fontScale 2, an accessibility text size, where the preview takes two
    // lines.
    expect(
      within(row).getByText(
        'The forecast looks good. Coffee first, then the long way home.',
      ),
    ).toHaveProp('numberOfLines', 2);
    const field = screen.getByLabelText('Search senders and subjects');
    await fireEvent(field, 'focus');
    // Before typing, search shows neither the Inbox heading nor its rows.
    expect(screen.queryByRole('header', { name: 'Inbox' })).toBeNull();
    expect(screen.queryByRole('button', { name: /Oliver Park/u })).toBeNull();
    await fireEvent.changeText(field, 'MAYA room');
    const results = await screen.findByRole('header', {
      name: 'Top Results. 1 result in Preview mailbox',
    });
    expect(results).toHaveTextContent('Top Results');
    const maya = screen.getByRole('button', {
      name: 'Unread. Maya Chen. A little more room to think. Saved on this device',
    });
    // Each matched word is bold where search found it, ignoring case.
    expect(within(maya).getByText('Maya')).toHaveStyle({ fontWeight: '600' });
    expect(within(maya).getByText('room')).toHaveStyle({ fontWeight: '600' });
    // Unread must not give the surrounding text the same weight as a match.
    expect(within(maya).getByText('Maya Chen')).toHaveStyle({
      fontWeight: '400',
    });
    expect(within(maya).getByText('A little more room to think')).toHaveStyle({
      fontWeight: '400',
    });
    // Clearing the query keeps search open rather than flashing the Inbox.
    await fireEvent.changeText(field, '');
    await waitFor(() => {
      expect(
        screen.queryByRole('header', { name: /^Top Results/u }),
      ).toBeNull();
    });
    expect(screen.queryByRole('header', { name: 'Inbox' })).toBeNull();
    expect(screen.queryByRole('button', { name: /Oliver Park/u })).toBeNull();
    await fireEvent.changeText(field, 'nothing like this');
    await expect(
      screen.findByText(
        'No mail saved on this device matches “nothing like this”.',
      ),
    ).resolves.toBeVisible();
    await fireEvent.press(screen.getByRole('button', { name: 'Close Search' }));
    expect(screen.getByRole('header', { name: 'Inbox' })).toBeVisible();
    expect(
      screen.getByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    ).toBeVisible();
    const restored = within(
      screen.getByRole('button', {
        name: 'Unread. Maya Chen. A little more room to think',
      }),
    );
    expect(restored.getByText('Maya Chen')).toHaveStyle({ fontWeight: '600' });
    expect(restored.getByText('A little more room to think')).toHaveStyle({
      fontWeight: '600',
    });
  });

  // iPhone keeps the saved-search line under No Results; iPad names the scope, as the Mac does.
  it.each([
    {
      isPad: false,
      empty: 'No mail saved on this device matches “no matching mail”.',
    },
    {
      isPad: true,
      empty:
        'No saved mail in Preview mailbox matches “no matching mail”. Check the spelling or search for fewer words.',
    },
  ])(
    'shows search day dividers only on iPad and one empty notice (isPad=$isPad)',
    async ({ isPad, empty }) => {
      expect.hasAssertions();
      const platform = jest.replaceProperty(
        jest.requireActual<{ ipad: typeof ipad }>('../src/inbox-styles.ts'),
        'ipad',
        isPad,
      );
      const clock = jest
        .spyOn(Date, 'now')
        .mockReturnValue(Date.parse('2026-09-28T12:00:00Z'));
      try {
        await render(<InboxJourney />);
        await screen.findByRole('button', {
          name: 'Unread. Maya Chen. A little more room to think',
        });
        const field = screen.getByLabelText('Search senders and subjects');
        await fireEvent(field, 'focus');
        await fireEvent.changeText(field, 'Maya');
        await expect(
          screen.findByRole('header', {
            name: 'Top Results. 1 result in Preview mailbox',
          }),
        ).resolves.toBeVisible();
        expect(screen.getAllByText('Top Results')).toHaveLength(1);
        expect(screen.queryByRole('header', { name: 'Today' }) !== null).toBe(
          isPad,
        );
        expect(
          screen.getByRole('button', {
            name: 'Unread. Maya Chen. A little more room to think. Saved on this device',
          }),
        ).toBeVisible();
        await fireEvent.changeText(field, 'no matching mail');
        await waitFor(() => {
          expect(screen.getAllByText(empty)).toHaveLength(1);
        });
        expect(
          screen.getAllByRole('header', { name: 'No Results' }),
        ).toHaveLength(1);
      } finally {
        clock.mockRestore();
        platform.restore();
      }
    },
  );

  it('filters the Inbox by Unread and Today, leaves search unfiltered and turns off when nothing narrows', async () => {
    expect.hasAssertions();
    const clock = jest
      .spyOn(Date, 'now')
      .mockReturnValue(Date.parse('2026-09-28T12:00:00Z'));
    try {
      await render(<InboxJourney />);
      const fieldNotes = { name: 'Field Notes. Things worth keeping' };
      await expect(
        screen.findByRole('button', fieldNotes),
      ).resolves.toBeVisible();
      const filter = screen.getByRole('togglebutton', { name: 'Filter' });
      expect(filter).toHaveProp('accessibilityState', { checked: false });
      // Filtering starts from Unread.
      await fireEvent.press(filter);
      expect(screen.getByRole('togglebutton', { name: 'Filter' })).toHaveProp(
        'accessibilityState',
        { checked: true },
      );
      expect(screen.queryByRole('button', fieldNotes)).toBeNull();
      expect(
        screen.getByRole('button', {
          name: 'Unread. Maya Chen. A little more room to think',
        }),
      ).toBeVisible();

      // The sheet edits a copy: Today instead of Unread keeps today's mail, read or not.
      await fireEvent.press(
        screen.getByRole('button', { name: 'Filtered by Unread' }),
      );
      const sheet = within(screen.getByTestId('bottom-sheet'));
      expect(sheet.getByRole('header', { name: 'Filters' })).toBeVisible();
      // A single mailbox offers no mailboxes to leave out.
      expect(sheet.queryByText('Include Mail From')).toBeNull();
      const unread = sheet.getByRole('checkbox', { name: 'Unread' });
      expect(unread).toBeChecked();
      // Leaving the sheet discards its edits and restores the applied criterion.
      await fireEvent.press(unread);
      await fireEvent(
        screen.getByTestId('bottom-sheet'),
        'accessibilityEscape',
      );
      expect(screen.queryByTestId('bottom-sheet')).toBeNull();
      await fireEvent.press(
        screen.getByRole('button', { name: 'Filtered by Unread' }),
      );
      const reopened = within(screen.getByTestId('bottom-sheet'));
      expect(reopened.getByRole('checkbox', { name: 'Unread' })).toBeChecked();
      await fireEvent.press(reopened.getByRole('checkbox', { name: 'Unread' }));
      await fireEvent(
        reopened.getByLabelText('Only Mail from Today'),
        'valueChange',
        true,
      );
      expect(screen.queryByRole('button', fieldNotes)).toBeNull();
      await fireEvent.press(
        reopened.getByRole('button', { name: 'Apply Filters' }),
      );
      expect(screen.queryByTestId('bottom-sheet')).toBeNull();
      expect(
        screen.getByRole('button', { name: 'Filtered by Today' }),
      ).toBeVisible();
      expect(
        screen.getAllByRole('button', { name: /^Unread\. /u }),
      ).toHaveLength(2);
      expect(screen.queryByRole('button', fieldNotes)).toBeNull();

      // Search reaches mail the filter leaves out, and Close returns to the filtered Inbox.
      await fireEvent.press(screen.getByRole('button', { name: 'Search' }));
      await fireEvent.changeText(
        screen.getByLabelText('Search senders and subjects'),
        'field notes',
      );
      await expect(
        screen.findByRole('button', {
          name: `${fieldNotes.name}. Saved on this device`,
        }),
      ).resolves.toBeVisible();
      await fireEvent.press(
        screen.getByRole('button', { name: 'Close Search' }),
      );
      expect(screen.queryByRole('button', fieldNotes)).toBeNull();

      // Applying a filter that leaves nothing out turns filtering off.
      await fireEvent.press(
        screen.getByRole('button', { name: 'Filtered by Today' }),
      );
      await fireEvent(
        within(screen.getByTestId('bottom-sheet')).getByLabelText(
          'Only Mail from Today',
        ),
        'valueChange',
        false,
      );
      await fireEvent.press(
        screen.getByRole('button', { name: 'Apply Filters' }),
      );
      expect(screen.getByRole('togglebutton', { name: 'Filter' })).toHaveProp(
        'accessibilityState',
        { checked: false },
      );
      expect(screen.getByRole('button', fieldNotes)).toBeVisible();
      // Turning it on again starts from Unread.
      await fireEvent.press(
        screen.getByRole('togglebutton', { name: 'Filter' }),
      );
      expect(
        screen.getByRole('button', { name: 'Filtered by Unread' }),
      ).toBeVisible();
    } finally {
      clock.mockRestore();
    }
  });

  it('spans a regular-width window with its bar and opens Filters as a popover on the Filter control', async () => {
    expect.hasAssertions();
    const window = Dimensions.get('window');
    function WindowJourney({
      keyboardLift = 0,
    }: {
      readonly keyboardLift?: number;
    }) {
      const { width } = useWindowDimensions();
      const windowBar = useMemo(() => createWindowBar(), []);
      return (
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Like the app, only a regular-width window has the bar.
        <WindowBarContext value={width >= 600 ? windowBar : undefined}>
          <InboxJourney />
          <WindowBarHost
            windowBar={windowBar}
            readerWidth={500}
            bottom={20 + keyboardLift}
            keyboardLift={keyboardLift}
          />
        </WindowBarContext>
      );
    }
    try {
      const app = await render(<WindowJourney />);
      await screen.findByRole('button', {
        name: 'Unread. Maya Chen. A little more room to think',
      });
      const bar = within(screen.getByTestId('window-bar'));
      expect(
        screen.getAllByLabelText('Search senders and subjects'),
      ).toStrictEqual([bar.getByLabelText('Search senders and subjects')]);
      // Filtered, the window keeps its search field beside what the Inbox is filtered by.
      await fireEvent.press(bar.getByRole('togglebutton', { name: 'Filter' }));
      expect(bar.getByLabelText('Search senders and subjects')).toBeVisible();
      expect(screen.queryByRole('button', { name: 'Search' })).toBeNull();
      await fireEvent.press(
        bar.getByRole('button', { name: 'Filtered by Unread' }),
      );
      expect(screen.queryByTestId('bottom-sheet')).toBeNull();
      const popover = within(screen.getByTestId('popover'));
      expect(popover.getByTestId('filters')).toHaveStyle({ width: 420 });
      expect(popover.getByRole('header', { name: 'Filters' })).toBeVisible();
      // Resizing the window keeps the popover and its edits; iOS keeps it on the control.
      await fireEvent.press(popover.getByRole('checkbox', { name: 'Unread' }));
      await act(() => {
        Dimensions.set({ window: { ...window, width: 1024, height: 768 } });
      });
      expect(
        within(screen.getByTestId('popover')).getByRole('checkbox', {
          name: 'Unread',
        }),
      ).toHaveProp('accessibilityState', { checked: false });
      // Dismissing it discards the edits.
      await fireEvent(screen.getByTestId('popover'), 'accessibilityEscape');
      expect(screen.queryByTestId('popover')).toBeNull();
      expect(
        bar.getByRole('button', { name: 'Filtered by Unread' }),
      ).toBeVisible();
      // Crossing into a compact window closes Filters without applying their edits.
      await fireEvent.press(
        bar.getByRole('button', { name: 'Filtered by Unread' }),
      );
      await fireEvent.press(
        within(screen.getByTestId('popover')).getByRole('checkbox', {
          name: 'Unread',
        }),
      );
      await act(() => {
        Dimensions.set({ window: { ...window, width: 500, height: 768 } });
      });
      expect(screen.queryByTestId('popover')).toBeNull();
      expect(screen.queryByTestId('bottom-sheet')).toBeNull();
      await act(() => {
        Dimensions.set({ window: { ...window, width: 1024, height: 768 } });
      });
      expect(
        within(screen.getByTestId('window-bar')).getByRole('button', {
          name: 'Filtered by Unread',
        }),
      ).toBeVisible();
      await fireEvent(
        bar.getByLabelText('Search senders and subjects'),
        'focus',
      );
      const keyboard = jest.mocked(useReanimatedKeyboardAnimation);
      keyboard.mockReturnValue({
        height: makeMutable(-280),
        progress: makeMutable(1),
      });
      await app.rerender(<WindowJourney keyboardLift={280} />);
      expect(screen.getByTestId('window-bar')).toHaveStyle({ bottom: 300 });
      // Sync status over the list rises with the bar, 12 pt above it.
      expect(screen.getByTestId('list-notice')).toHaveStyle({ bottom: 356 });
      // The keyboard must not move the bar on top of the window bar's own lift.
      // Reanimated's test renderer applies animated styles to `jestAnimatedStyle` on the next frame.
      const sticky = screen.getByTestId('keyboard-bar');
      await waitFor(() => {
        expect(sticky.props.jestAnimatedStyle).toMatchObject({
          value: { top: 0 },
        });
      });
      expect(screen.getByLabelText('Inbox messages')).toHaveProp(
        'automaticallyAdjustKeyboardInsets',
        true,
      );
      const edge = screen
        .getAllByTestId('scroll-edge')
        .find((view) => StyleSheet.flatten(view.props.style)?.width === 500);
      expect(edge).toHaveStyle({ bottom: 280 });
      await app.rerender(<WindowJourney />);
      expect(screen.getByTestId('list-notice')).toHaveStyle({ bottom: 76 });
      await act(() => {
        Dimensions.set({ window: { ...window, width: 500, height: 768 } });
      });
      // The compact bar tracks the keyboard 12pt above it, 8pt more than its 4pt bottom padding.
      await waitFor(() => {
        expect(sticky.props.jestAnimatedStyle).toMatchObject({
          value: { top: -288, bottom: 288 },
        });
      });
      expect(screen.getByLabelText('Inbox messages')).toHaveProp(
        'automaticallyAdjustKeyboardInsets',
        true,
      );
    } finally {
      jest.mocked(useReanimatedKeyboardAnimation).mockReturnValue({
        height: makeMutable(0),
        progress: makeMutable(0),
      });
      await act(() => {
        Dimensions.set({ window });
      });
    }
  });

  it('centers the filtered control with the search field clear of a shown sidebar, truncating its summary', async () => {
    expect.hasAssertions();
    const window = Dimensions.get('window');
    function WindowJourney({ shown }: { readonly shown: boolean }) {
      const windowBar = useMemo(() => createWindowBar(), []);
      return (
        <WindowBarContext value={windowBar}>
          <SidebarToggleContext value={{ shown, toggle: () => undefined }}>
            <InboxJourney />
            <WindowBarHost
              windowBar={windowBar}
              readerWidth={500}
              bottom={20}
              keyboardLift={0}
            />
          </SidebarToggleContext>
        </WindowBarContext>
      );
    }
    // The leading side and the glass of the Filter control, around its switch.
    const filterControl = () => {
      const glass = screen.getByRole('togglebutton', { name: 'Filter' }).parent;
      ok(glass?.parent);
      return { glass, side: glass.parent };
    };
    try {
      await act(() => {
        Dimensions.set({ window: { ...window, width: 1194, height: 834 } });
      });
      const app = await render(<WindowJourney shown />);
      await screen.findByRole('button', {
        name: 'Unread. Maya Chen. A little more room to think',
      });
      // Unfiltered, the search field centers alone.
      expect(filterControl().side).not.toHaveStyle({ flex: 0 });
      await fireEvent.press(
        screen.getByRole('togglebutton', { name: 'Filter' }),
      );
      // Filtered, the control and the field center together; the control truncates past 180pt
      // (1194 - 2 × 303 - 400 - 8), which would reach the list's content edge.
      expect(filterControl().side).toHaveStyle({
        flex: 0,
        flexGrow: 1,
        paddingLeft: 8,
      });
      expect(filterControl().glass).toHaveStyle({ maxWidth: 180 });
      expect(
        screen.getByRole('button', { name: 'Filtered by Unread' }),
      ).toBeVisible();
      // With the sidebar hidden, or where the field cannot fit beside it, nothing changes.
      await app.rerender(<WindowJourney shown={false} />);
      expect(filterControl().side).not.toHaveStyle({ flex: 0 });
      expect(filterControl().glass).not.toHaveStyle({ maxWidth: 180 });
      await app.rerender(<WindowJourney shown />);
      // 56pt would leave the summary that opens Filters no room beside the switch.
      await act(() => {
        Dimensions.set({ window: { ...window, width: 1070, height: 834 } });
      });
      expect(filterControl().side).not.toHaveStyle({ flex: 0 });
      await act(() => {
        Dimensions.set({ window: { ...window, width: 834, height: 1194 } });
      });
      expect(filterControl().side).not.toHaveStyle({ flex: 0 });
    } finally {
      await act(() => {
        Dimensions.set({ window });
      });
    }
  });

  it('keeps a closed query empty after the window bar remounts and mailbox readiness returns', async () => {
    expect.hasAssertions();
    const storage = makeMockInboxStorage();
    const { open: openStorage } = storage;
    let open = openStorage;
    const fixture = createPersistentInbox(
      {
        ...storage,
        open: (...args) => open(...args),
      },
      createMockMailSession('open-read-relaunch').mail.list,
    );
    const mailboxes = singleMailbox(fixture, preview);
    const bar = createWindowBar();
    function Layout({
      windowBar,
    }: {
      readonly windowBar?: ReturnType<typeof createWindowBar>;
    }) {
      const [selected, setSelected] = useState<Selection>();
      return (
        <InboxProvider mailboxes={mailboxes}>
          <WindowBarContext value={windowBar}>
            <Inbox
              onSelect={setSelected}
              selected={selected}
            />
            <WindowBarHost
              windowBar={bar}
              readerWidth={500}
              bottom={20}
              keyboardLift={0}
            />
          </WindowBarContext>
        </InboxProvider>
      );
    }
    const app = await render(<Layout />);
    await screen.findByRole('button', { name: /Maya Chen/u });
    await fireEvent(
      screen.getByLabelText('Search senders and subjects'),
      'focus',
    );
    await fireEvent.changeText(
      screen.getByLabelText('Search senders and subjects'),
      'Maya',
    );
    await app.rerender(<Layout windowBar={bar} />);
    expect(
      screen.getByLabelText('Search senders and subjects'),
    ).toHaveDisplayValue('Maya');
    open = () =>
      Promise.reject(Object.assign(new Error('locked'), { code: 'locked' }));
    await act(fixture.load);
    await fireEvent.press(screen.getByRole('button', { name: 'Close Search' }));
    expect(screen.queryByLabelText('Search senders and subjects')).toBeNull();
    open = openStorage;
    await act(fixture.load);
    expect(
      screen.getByLabelText('Search senders and subjects'),
    ).toHaveDisplayValue('');
  });

  /* oxlint-enable vitest/max-expects */

  it('groups rows under the day they arrived and names today by the clock', async () => {
    expect.hasAssertions();
    const clock = jest
      .spyOn(Date, 'now')
      .mockReturnValue(Date.parse('2026-09-28T12:00:00Z'));
    try {
      await render(<InboxJourney />);
      const today = await screen.findByRole('header', { name: 'Today' });
      expect(today).toBeVisible();
      expect(screen.getByRole('header', { name: 'Yesterday' })).toBeVisible();
      expect(
        within(
          screen.getByRole('button', {
            name: 'Unread. Oliver Park. Saturday, by the river?',
          }),
        ).getByText(/^0?8:15/u),
      ).toBeVisible();
      expect(screen.getAllByText('Yesterday')).toHaveLength(3);
      expect(screen.getByText(/No unread messages|unread$/u)).toBeVisible();
    } finally {
      clock.mockRestore();
    }
  });

  it('draws no separator under a day’s last row, above the next day’s divider', async () => {
    expect.hasAssertions();
    const clock = jest
      .spyOn(Date, 'now')
      .mockReturnValue(Date.parse('2026-09-28T12:00:00Z'));
    try {
      await render(<InboxJourney />);
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

  it('opens the activated message and exposes its selected state', async () => {
    expect.hasAssertions();
    await render(<InboxJourney />);
    const message = await screen.findByRole('button', {
      name: 'Unread. Oliver Park. Saturday, by the river?',
    });
    await fireEvent.press(message);
    expect(
      screen.getByRole('header', { name: 'Saturday, by the river?' }),
    ).toBeVisible();
    expect(message).toBeSelected();
    expect(screen.getByText('oliver@example.com')).toBeVisible();
    expect(screen.queryByText('maya@example.com')).toBeNull();
  });

  it('moves selection to the next activated message without mixing message bodies', async () => {
    expect.hasAssertions();
    await render(<InboxJourney />);
    const first = await screen.findByRole('button', {
      name: 'Unread. Maya Chen. A little more room to think',
    });
    await fireEvent.press(first);
    await fireEvent.press(
      screen.getByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    );
    expect(first).not.toBeSelected();
    expect(
      screen.getByRole('header', { name: 'Saturday, by the river?' }),
    ).toBeVisible();
    expect(
      screen.queryByText(/Could we spend the first ten minutes/u),
    ).toBeNull();
  });

  it('does not show another message when a route contains an unknown identifier', async () => {
    expect.hasAssertions();
    await render(
      <InboxProvider>
        <MessageDetail
          id="not-in-this-mailbox"
          mailbox={preview}
        />
      </InboxProvider>,
    );
    await expect(
      screen.findByRole('header', { name: 'Message unavailable' }),
    ).resolves.toBeVisible();
    expect(screen.queryByText('maya@example.com')).toBeNull();
  });

  it('shows a reused reader only in the Profile that owns its mailbox', async () => {
    expect.hasAssertions();
    const link = (profileId: unknown) => (
      <InboxProvider>
        <ProfileScope profile={profileId}>
          <MessageDetail
            id="weekend-walk"
            mailbox={preview}
          />
        </ProfileScope>
      </InboxProvider>
    );
    // The preview mailbox, like every mailbox listed before Profiles, belongs to the Default Profile.
    const app = await render(link(defaultProfile));
    await expect(
      screen.findByRole('header', { name: 'Saturday, by the river?' }),
    ).resolves.toBeVisible();
    // The same link targeted at another Profile, or one unknown here, finds nothing.
    await app.rerender(link('work'));
    await expect(
      screen.findByRole('header', { name: 'Message unavailable' }),
    ).resolves.toBeVisible();
    expect(screen.queryByText('oliver@example.com')).toBeNull();
    await app.rerender(link([defaultProfile, 'work']));
    expect(
      screen.getByRole('header', { name: 'Message unavailable' }),
    ).toBeVisible();
  });

  it('reads an opened message, keeps Mark as Unread while it stays open, and recovers after the view remounts', async () => {
    expect.hasAssertions();
    const app = await render(<InboxJourney />);
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Unread. Maya Chen. A little more room to think',
      }),
    );
    await fireEvent.press(
      await screen.findByRole('button', { name: 'Mark as Unread' }),
    );
    await expect(
      screen.findByRole('button', {
        name: 'Unread. Maya Chen. A little more room to think',
      }),
    ).resolves.toBeVisible();
    await fireEvent.press(screen.getByRole('button', { name: 'Mark as Read' }));
    await expect(
      screen.findByRole('button', { name: 'Mark as Unread' }),
    ).resolves.toBeVisible();
    const readRow = screen.getByRole('button', {
      name: 'Maya Chen. A little more room to think',
    });
    expect(within(readRow).getByText('Maya Chen')).toHaveStyle({
      fontWeight: '400',
    });
    expect(
      within(readRow).getByText('A little more room to think'),
    ).toHaveStyle({ fontWeight: '400' });
    await app.unmount();
    await render(<InboxJourney />);
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Maya Chen. A little more room to think',
      }),
    );
    expect(
      screen.getByRole('button', { name: 'Mark as Unread' }),
    ).toBeVisible();
  });

  it('offers recovery from locked storage on the compact message screen', async () => {
    expect.hasAssertions();
    const storage = makeMockInboxStorage();
    let currentOpen: () => Promise<unknown> = () =>
      Promise.reject(Object.assign(new Error('locked'), { code: 'locked' }));
    const store = createPersistentInbox({
      ...storage,
      open: () => currentOpen(),
    });
    await render(
      <InboxProvider mailboxes={singleMailbox(store, preview)}>
        <MessageDetail
          id="studio-review"
          mailbox={preview}
        />
      </InboxProvider>,
    );
    await expect(screen.findByRole('alert')).resolves.toHaveTextContent(
      /Private storage is locked/u,
    );
    expect(screen.queryByText('maya@example.com')).toBeNull();
    currentOpen = () => storage.open('[]');
    await fireEvent.press(screen.getByRole('button', { name: 'Try Again' }));
    await expect(screen.findByText('maya@example.com')).resolves.toBeVisible();
  });
});

// The connected Inbox and reader, as the app composes them, over a controlled Gmail mailbox.
function connectedMessage(store: ReturnType<typeof createInboxStore>) {
  const state = store.getSnapshot();
  if (state.kind !== 'ready' || state.messages[0] === undefined) {
    throw new Error('Expected connected mail');
  }
  return state.messages[0];
}

async function renderConnected(
  native: NativeGmailMailbox,
  provider: 'gmail' | 'microsoft-graph' = 'gmail',
  {
    windowBar,
    pinsFor,
  }: Readonly<{
    windowBar?: ReturnType<typeof createWindowBar>;
    // Pin storage for the registered Product Account, instead of the host's.
    pinsFor?: (registration: Registration) => Pins;
  }> = {},
) {
  const synthetic = await createRegistrationScenario('registration-success');
  // The mailbox connections the person authorizes, by connection.
  const authorized: Array<string | null> = [];
  const registration = createRegistration({
    ...synthetic.vault,
    signInMailbox: (connection, suggest, grant) => {
      authorized.push(connection);
      return synthetic.vault.signInMailbox(connection, suggest, grant);
    },
  });
  if (provider === 'gmail') {
    await registration.register('google');
    await registration.addMailbox();
  } else {
    await registration.register('apple');
    await registration.addMailbox('microsoft-graph');
  }
  // A confirmed Recovery Key lets the gate open the Inbox.
  await registration.confirmRecoveryKey(
    synthetic.device.productSync.vault?.recoveryKey?.slice(-4) ?? '',
  );
  const id =
    provider === 'gmail' ? alex : syntheticMailboxes['casey@example.invalid'];
  // As the app composes them: the Inbox hands a removal to the registration store.
  const mailboxes = createMailboxes(
    syntheticConnections({ [id]: { native } }),
    registration,
    {
      removed: () => {
        void registration.deviceRemoved();
      },
    },
  );
  const store = started(registration);
  const pins = pinsFor?.(registration);
  function Connected() {
    const [selected, setSelected] = useState<Selection>();
    const [view, setView] = useState<MailboxView>({});
    const gate = (
      <RegistrationGate
        store={store}
        preview={false}>
        <InboxProvider mailboxes={mailboxes}>
          <CommandPaletteProvider>
            <Mailboxes
              view={view}
              onView={setView}
              onProfile={() => undefined}
            />
            <Inbox
              onClose={() => {
                setSelected(undefined);
              }}
              onSelect={setSelected}
              onView={setView}
              selected={selected}
              view={view}
            />
            <MessageDetail
              id={selected?.id}
              mailbox={selected?.mailbox}
              folder={selected?.folder}
              onClose={() => {
                setSelected(undefined);
              }}
            />
          </CommandPaletteProvider>
        </InboxProvider>
      </RegistrationGate>
    );
    return pins === undefined ? (
      gate
    ) : (
      <PinsContext value={pins}>{gate}</PinsContext>
    );
  }
  await render(
    <WindowBarContext value={windowBar}>
      <View testID="list-column">
        <Connected />
      </View>
      {windowBar === undefined ? null : (
        <WindowBarHost
          windowBar={windowBar}
          readerWidth={500}
          bottom={20}
          keyboardLift={0}
        />
      )}
    </WindowBarContext>,
  );
  return {
    synthetic,
    authorized,
    // The connected mailbox's Gmail Inbox, once registration has opened it.
    store: () => {
      const inbox = mailboxes.getSnapshot()[0]?.inbox;
      if (inbox === undefined) {
        throw new Error('Expected the connected mailbox');
      }
      return inbox;
    },
  };
}

// Holds one listing page until the journey releases it.
function holdingPage(
  native: ReturnType<typeof createSyntheticGmail>['native'],
  pageToken: string,
) {
  let release: () => void = () => undefined;
  // oxlint-disable-next-line promise/avoid-new -- Explicit provider suspension, released by the journey.
  const held = new Promise<void>((resolve) => {
    release = resolve;
  });
  return {
    release,
    native: {
      ...native,
      gmailRequest: async (...args: Parameters<typeof native.gmailRequest>) => {
        if (
          args[1].some(
            ([name, value]) => name === 'pageToken' && value === pageToken,
          )
        ) {
          await held;
        }
        return native.gmailRequest(...args);
      },
    },
  };
}

function holdingListing(
  native: ReturnType<typeof createSyntheticGmail>['native'],
) {
  let cacheOnly = false;
  let release: () => void = () => undefined;
  // oxlint-disable-next-line promise/avoid-new -- Explicit provider suspension, released by the journey.
  const listing = new Promise<void>((resolve) => {
    release = resolve;
  });
  return {
    release,
    becomeCacheOnly: () => {
      cacheOnly = true;
    },
    native: {
      ...native,
      openMailbox: async () => ({
        ...(await native.openMailbox()),
        ...(cacheOnly ? { availability: 'retry' } : {}),
      }),
      gmailRequest: async (...args: Parameters<typeof native.gmailRequest>) => {
        if (args[0] === 'messages') {
          await listing;
        }
        return native.gmailRequest(...args);
      },
    },
  };
}

// The native context menu around a rendered control, and what choosing an item sends back.
type MenuNode = ReturnType<typeof screen.getByText>;
interface RenderedMenuItem {
  readonly id: string;
  readonly title: string;
  readonly items?: readonly RenderedMenuItem[];
}
const contextMenuOf = (element: MenuNode) => {
  let node = element.parent;
  while (node !== null && node.type !== 'UnwiredContextMenu') {
    node = node.parent;
  }
  if (node === null) {
    throw new Error('Expected a context menu');
  }
  return node;
};
const menuSections = (menu: MenuNode) => {
  const sections: ReadonlyArray<{ items: readonly RenderedMenuItem[] }> =
    menu.props.sections;
  const titles = ({ title, items }: RenderedMenuItem) =>
    items === undefined ? title : [title, items.map((each) => each.title)];
  return sections.map(({ items }) => items.map(titles));
};
const chooseFromMenu = async (menu: MenuNode, ...path: readonly string[]) => {
  const sections: ReadonlyArray<{ items: readonly RenderedMenuItem[] }> =
    menu.props.sections;
  let items: readonly RenderedMenuItem[] = sections.flatMap(
    (section) => section.items,
  );
  let chosen: RenderedMenuItem | undefined = undefined;
  for (const title of path) {
    chosen = items.find((item) => item.title === title);
    items = chosen?.items ?? [];
  }
  if (chosen === undefined) {
    throw new Error(`Expected ${path.join(' › ')} in the menu`);
  }
  const { id } = chosen;
  await act(async () => {
    await fireEvent(menu, 'select', { nativeEvent: { id } });
  });
};

// Opens the palette as VoiceOver does, through the header's accessibility action.
const openPalette = (header: ReturnType<typeof screen.getByRole>) =>
  fireEvent(header, 'accessibilityAction', {
    nativeEvent: { actionName: 'openCommandPalette' },
  });
// The open palette, apart from the reader's own buttons beneath it.
const openedPalette = () => within(screen.getByTestId('command-palette'));

describe('connected Gmail Inbox', () => {
  it('keeps synchronization attention over the list column beside a window-wide bar', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({ subject: 'Saved mail remains available' });
    const connected = await renderConnected(gmail.native, 'gmail', {
      windowBar: createWindowBar(),
    });
    await screen.findByText('Saved mail remains available');
    gmail.fail({ code: 'unavailable' });
    await act(connected.store().load);
    const list = within(screen.getByTestId('list-column'));
    expect(list.getByText('1 account needs attention')).toBeVisible();
    expect(list.getByRole('button', { name: 'Try Again' })).toBeVisible();
    expect(
      within(screen.getByTestId('window-bar')).getByLabelText(
        'Search senders and subjects',
      ),
    ).toBeVisible();
    await fireEvent.press(list.getByRole('button', { name: 'Try Again' }));
    await waitFor(() => {
      expect(list.queryByText('1 account needs attention')).toBeNull();
    });
  });

  it('says saved mail can’t be shown when the mailbox fails to open, and Try Again shows it', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({ subject: 'Saved mail remains available' });
    const connected = await renderConnected(gmail.native);
    await screen.findByText('Saved mail remains available');
    gmail.failOpen('unavailable');
    await act(connected.store().load);
    expect(
      screen.getByRole('alert', {
        name: /Mail saved on this device can’t be shown\. It has been kept\. Choose Try Again to show it again\.$/u,
      }),
    ).toBeVisible();
    expect(screen.queryByText('Saved mail remains available')).toBeNull();
    await fireEvent.press(screen.getByRole('button', { name: 'Try Again' }));
    await expect(
      screen.findByText('Saved mail remains available'),
    ).resolves.toBeVisible();
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it.each([
    { isPad: false, subtitle: /^alex@example\.invalid · 1 unread$/u },
    {
      isPad: true,
      subtitle: /^alex@example\.invalid · 1 unread · Updated just now$/u,
    },
  ])(
    'shows the last successful update in the idle heading only on iPad (isPad=$isPad)',
    async ({ isPad, subtitle }) => {
      expect.hasAssertions();
      const platform = jest.replaceProperty(
        jest.requireActual<{ ipad: typeof ipad }>('../src/inbox-styles.ts'),
        'ipad',
        isPad,
      );
      const clock = jest
        .spyOn(Date, 'now')
        .mockReturnValue(Date.parse('2026-10-27T09:41:00Z'));
      try {
        const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
        gmail.deliver({ subject: 'Saved Inbox message' });
        await renderConnected(gmail.native);
        await expect(screen.findByText(subtitle)).resolves.toBeVisible();
      } finally {
        clock.mockRestore();
        platform.restore();
      }
    },
  );

  it.each([
    { isPad: false, subtitle: /^alex@example\.invalid · All read$/u },
    {
      isPad: true,
      subtitle:
        /^alex@example\.invalid · No unread messages · Updated just now$/u,
    },
  ])(
    'says All read in the iPhone heading when nothing is unread (isPad=$isPad)',
    async ({ isPad, subtitle }) => {
      expect.hasAssertions();
      const platform = jest.replaceProperty(
        jest.requireActual<{ ipad: typeof ipad }>('../src/inbox-styles.ts'),
        'ipad',
        isPad,
      );
      const clock = jest
        .spyOn(Date, 'now')
        .mockReturnValue(Date.parse('2026-10-27T09:41:00Z'));
      try {
        const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
        gmail.deliver({ subject: 'Saved Inbox message', unread: false });
        await renderConnected(gmail.native);
        await expect(screen.findByText(subtitle)).resolves.toBeVisible();
      } finally {
        clock.mockRestore();
        platform.restore();
      }
    },
  );

  it('leaves the last update out of iPad label and unified headings, which the Inbox synchronization did not refresh', async () => {
    expect.hasAssertions();
    const platform = jest.replaceProperty(
      jest.requireActual<{ ipad: typeof ipad }>('../src/inbox-styles.ts'),
      'ipad',
      true,
    );
    const clock = jest
      .spyOn(Date, 'now')
      .mockReturnValue(Date.parse('2026-10-27T09:41:00Z'));
    try {
      const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
      const travel = gmail.createLabel('Travel');
      const message = gmail.deliver({ subject: 'Flight to Zagreb' });
      gmail.setLabel(message, travel, true);
      gmail.setLabel(message, 'SENT', true);
      await renderConnected(gmail.native);
      await expect(
        screen.findByText(/ · Updated just now$/u),
      ).resolves.toBeVisible();
      await act(async () => {
        await fireEvent.press(
          screen.getByRole('button', {
            name: 'Travel. In alex@example.invalid',
          }),
        );
      });
      await expect(
        screen.findByRole('button', { name: /Flight to Zagreb/u }),
      ).resolves.toBeVisible();
      expect(
        screen.getByText(/^alex@example\.invalid · 1 unread$/u),
      ).toBeVisible();
      await act(async () => {
        await fireEvent.press(
          screen.getByRole('button', { name: 'Sent. In All Mailboxes' }),
        );
      });
      await screen.findByRole('button', { name: /Flight to Zagreb/u });
      expect(screen.getByText(/^All Mailboxes · 1 unread$/u)).toBeVisible();
      await act(async () => {
        await fireEvent.press(
          screen.getByRole('button', { name: 'All Inboxes' }),
        );
      });
      await expect(
        screen.findByText(
          /^alex@example\.invalid · 1 unread · Updated just now$/u,
        ),
      ).resolves.toBeVisible();
    } finally {
      clock.mockRestore();
      platform.restore();
    }
  });

  it.each([false, true])(
    'shows one Top Results header for provider-only matches (isPad=%s)',
    async (isPad) => {
      expect.hasAssertions();
      const platform = jest.replaceProperty(
        jest.requireActual<{ ipad: typeof ipad }>('../src/inbox-styles.ts'),
        'ipad',
        isPad,
      );
      try {
        const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
        gmail.deliver({ subject: 'Saved Inbox message' });
        const archived = gmail.deliver({ subject: 'Studio archive' });
        gmail.archive(archived);
        await renderConnected(gmail.native);
        await screen.findByRole('button', { name: /Saved Inbox message/u });
        const field = screen.getByLabelText('Search senders and subjects');
        await fireEvent(field, 'focus');
        await fireEvent.changeText(field, 'Studio archive');
        await screen.findByRole('header', { name: 'No Results' });
        await fireEvent.press(
          screen.getByRole('button', {
            name: 'Search Mail Servers for “Studio archive”',
          }),
        );
        await expect(
          screen.findByRole('header', { name: /Top Results\. 1 result/u }),
        ).resolves.toBeVisible();
        expect(screen.getAllByText('Top Results')).toHaveLength(1);
        expect(
          screen.getByRole('button', { name: /Studio archive/u }),
        ).toBeVisible();
        // A server result offers Pin alone, which needs no Gmail access.
        expect(
          screen.getByRole('button', { name: /Studio archive/u }),
        ).toHaveProp('accessibilityActions', [{ name: 'pin', label: 'Pin' }]);
      } finally {
        platform.restore();
      }
    },
  );

  it('says what stays shown when a mail server search fails for an unnamed reason, and Try Again searches again', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({ subject: 'Saved Inbox message' });
    gmail.archive(gmail.deliver({ subject: 'Saved in archive' }));
    await renderConnected(gmail.native);
    await screen.findByRole('button', { name: /Saved Inbox message/u });
    const field = screen.getByLabelText('Search senders and subjects');
    await fireEvent(field, 'focus');
    await fireEvent.changeText(field, 'Saved');
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
    ).resolves.toBeVisible();
    // The saved result stays above the failure.
    expect(
      screen.getByRole('button', { name: /Saved Inbox message/u }),
    ).toBeVisible();
    await fireEvent.press(screen.getByRole('button', { name: 'Try Again' }));
    await expect(
      screen.findByRole('button', { name: /\. Saved in archive/u }),
    ).resolves.toBeVisible();
  });

  it('announces No Results once, and a failed mail server search replaces it until Try Again answers', async () => {
    expect.hasAssertions();
    const announced = () =>
      jest
        .mocked(AccessibilityInfo.announceForAccessibilityWithOptions)
        .mock.calls.filter(([words]) => words === 'No Results');
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({ subject: 'Saved Inbox message' });
    await renderConnected(gmail.native);
    await screen.findByRole('button', { name: /Saved Inbox message/u });
    const field = screen.getByLabelText('Search senders and subjects');
    await fireEvent(field, 'focus');
    const before = announced().length;
    await fireEvent.changeText(field, 'Lisbon ferry');
    await screen.findByRole('header', { name: 'No Results' });
    expect(announced()).toHaveLength(before + 1);
    // Gmail's failure is no answer, so No Results gives way to it.
    gmail.fail({ status: 404 });
    await fireEvent.press(
      screen.getByRole('button', {
        name: 'Search Mail Servers for “Lisbon ferry”',
      }),
    );
    await screen.findByRole('button', { name: 'Try Again' });
    expect(screen.queryByRole('header', { name: 'No Results' })).toBeNull();
    await fireEvent.press(screen.getByRole('button', { name: 'Try Again' }));
    await expect(
      screen.findByText('Mail servers found no mail matching “Lisbon ferry”.'),
    ).resolves.toBeVisible();
    expect(screen.getByRole('header', { name: 'No Results' })).toBeVisible();
  });

  it('shows Searching and an empty mail server answer without the From mail servers heading', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({ subject: 'Saved Inbox message' });
    await renderConnected(gmail.native);
    await screen.findByRole('button', { name: /Saved Inbox message/u });
    const field = screen.getByLabelText('Search senders and subjects');
    await fireEvent(field, 'focus');
    await fireEvent.changeText(field, 'Lisbon ferry');
    const request = gmail.native.gmailRequest;
    let release: () => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Hold Gmail's answer while Searching shows.
    const held = new Promise<void>((resolve) => {
      release = resolve;
    });
    gmail.native.gmailRequest = async (...args) => {
      await held;
      return request(...args);
    };
    await fireEvent.press(
      screen.getByRole('button', {
        name: 'Search Mail Servers for “Lisbon ferry”',
      }),
    );
    // Searching, then No Results, stand directly beneath the search, as the iPad frames place them.
    expect(screen.getByText('Searching alex@example.invalid…')).toBeVisible();
    expect(
      screen.queryByRole('header', { name: 'From mail servers' }),
    ).toBeNull();
    await act(async () => {
      release();
    });
    await expect(
      screen.findByRole('header', { name: 'No Results' }),
    ).resolves.toBeVisible();
    expect(
      screen.queryByRole('header', { name: 'From mail servers' }),
    ).toBeNull();
  });

  it('never shows a delayed online answer for a query the person has since replaced', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({ subject: 'Saved Inbox message' });
    gmail.archive(gmail.deliver({ subject: 'Studio archive' }));
    gmail.archive(gmail.deliver({ subject: 'Studio budget' }));
    await renderConnected(gmail.native);
    await screen.findByRole('button', { name: /Saved Inbox message/u });
    const field = screen.getByLabelText('Search senders and subjects');
    await fireEvent(field, 'focus');
    await fireEvent.changeText(field, 'Studio archive');
    const request = gmail.native.gmailRequest;
    let release: () => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Hold Gmail's answer until the query has changed.
    const held = new Promise<void>((resolve) => {
      release = resolve;
    });
    // Every answer, so the late search has fully arrived before the list is checked.
    const answers: Array<Promise<unknown>> = [];
    gmail.native.gmailRequest = async (...args) => {
      const answer = (async () => {
        await held;
        return request(...args);
      })();
      answers.push(answer);
      return answer;
    };
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Search Mail Servers for “Studio archive”',
      }),
    );
    expect(screen.getByText('Searching alex@example.invalid…')).toBeVisible();
    await fireEvent.changeText(field, 'Studio budget');
    await act(async () => {
      release();
      // Later requests join the list while earlier ones settle.
      for (const answer of answers) {
        await answer;
      }
    });
    // The late answer belongs to the replaced query, so the current one still offers its own search.
    await expect(
      screen.findByRole('button', {
        name: 'Search Mail Servers for “Studio budget”',
      }),
    ).resolves.toBeVisible();
    expect(
      screen.queryByRole('button', { name: /\. Studio archive/u }),
    ).toBeNull();
    expect(screen.queryByText('Top Results')).toBeNull();
    await fireEvent.press(
      screen.getByRole('button', {
        name: 'Search Mail Servers for “Studio budget”',
      }),
    );
    await expect(
      screen.findByRole('button', { name: /\. Studio budget/u }),
    ).resolves.toBeVisible();
  });

  /* oxlint-disable vitest/max-expects -- One journey proves the synchronized list and its recovery states. */
  it('shows synchronized metadata and recovers from lost Gmail permission and connectivity', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
      snippet: 'Coffee first, then the long way home?',
    });
    const connected = await renderConnected(gmail.native);
    const store = connected.store();
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    );
    expect(screen.getByText(/^alex@example\.invalid ·/u)).toBeVisible();
    expect(screen.getByText('oliver@example.invalid')).toBeVisible();
    // The detail downloads the body; the row keeps Gmail's snippet.
    await expect(screen.findByText('Synthetic body.')).resolves.toBeVisible();
    expect(
      screen.getAllByText('Coffee first, then the long way home?'),
    ).toHaveLength(2);

    gmail.fail({ status: 401 });
    gmail.deliver({ subject: 'Arrives after permission returns' });
    await act(store.load);
    // The notice arrives while the list is shown and retains its live-region semantics.
    expect(
      screen.getByText('Gmail needs your permission again to show new mail.'),
    ).toBeVisible();
    expect(
      screen.getByText('Gmail needs your permission again to show new mail.'),
    ).toHaveProp('accessibilityLiveRegion', 'polite');
    expect(screen.queryByText(/Arrives after permission/u)).toBeNull();
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Allow Gmail Access' }),
      );
    });
    expect(connected.authorized).toContain(alex);
    await expect(
      screen.findByText('Arrives after permission returns'),
    ).resolves.toBeVisible();

    // Automatic synchronization shows its progress only after a second.
    const request = gmail.native.gmailRequest;
    let release: () => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Hold Gmail until the capsule has been checked.
    const held = new Promise<void>((resolve) => {
      release = resolve;
    });
    gmail.native.gmailRequest = async (...args) => {
      await held;
      return request(...args);
    };
    let synchronized = Promise.resolve();
    await act(async () => {
      synchronized = store.load();
      await Promise.resolve();
    });
    expect(screen.queryByRole('button', { name: /^Updating/u })).toBeNull();
    // The capsule mounts transparent and fades in once its motion starts.
    await waitFor(
      () => {
        expect(
          screen.getByRole('button', { name: 'Updating 1 account' }),
        ).toBeVisible();
      },
      { timeout: 3000 },
    );
    gmail.native.gmailRequest = request;
    await act(async () => {
      release();
      await synchronized;
    });

    // A failure replaces the progress with Try Again, above the saved mail.
    gmail.fail({ code: 'unavailable' });
    await act(store.load);
    expect(screen.getByText('1 account needs attention')).toBeVisible();
    expect(screen.queryByRole('button', { name: /^Updating/u })).toBeNull();
    expect(
      screen.getByRole('header', { name: 'Saturday, by the river?' }),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Try Again' }));
    });
    expect(screen.queryByText('1 account needs attention')).toBeNull();
  });

  it('lists each connection’s sync status from the capsule, where it is authorized or tried again on its own', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({ subject: 'Saturday, by the river?' });
    const connected = await renderConnected(gmail.native);
    const store = connected.store();
    await screen.findByRole('button', { name: /Saturday, by the river\?/u });
    const openDetails = async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: '1 account needs attention' }),
      );
      return within(screen.getByTestId('sync-status-details'));
    };

    // On iPhone the details are a sheet with Done, naming the connection and why it failed.
    gmail.fail({ status: 401 });
    await act(store.load);
    let details = await openDetails();
    expect(screen.getByTestId('bottom-sheet')).toBeVisible();
    expect(details.getByRole('header', { name: 'Sync Status' })).toBeVisible();
    expect(details.getByText('Gmail · alex@example.invalid')).toBeVisible();
    expect(
      details.getByText('Gmail needs your permission again to show new mail.'),
    ).toBeVisible();
    expect(details.getByText(/Pull down to refresh$/u)).toBeVisible();
    await fireEvent.press(details.getByRole('button', { name: 'Done' }));
    await waitFor(() => {
      expect(screen.queryByTestId('sync-status-details')).toBeNull();
    });
    details = await openDetails();
    // A refused connection offers the Inbox's authorization, which closes the sheet first.
    await act(async () => {
      await fireEvent.press(
        details.getByRole('button', {
          name: 'Allow Gmail Access for alex@example.invalid',
        }),
      );
    });
    expect(connected.authorized).toContain(alex);
    await waitFor(() => {
      expect(screen.queryByTestId('sync-status-details')).toBeNull();
    });

    // A connection that could not be reached is tried again on its own.
    gmail.fail({ code: 'unavailable' });
    await act(store.load);
    details = await openDetails();
    expect(
      details.getByText(
        'Gmail could not be reached. Showing mail saved on this device.',
      ),
    ).toBeVisible();
    gmail.deliver({ subject: 'Arrives after Try Again' });
    await act(async () => {
      await fireEvent.press(
        details.getByRole('button', {
          name: 'Try Again for Gmail · alex@example.invalid',
        }),
      );
    });
    await expect(
      screen.findByText('Arrives after Try Again'),
    ).resolves.toBeVisible();
    // The details close with the capsule.
    await waitFor(() => {
      expect(screen.queryByTestId('sync-status-details')).toBeNull();
    });
    expect(screen.queryByText('1 account needs attention')).toBeNull();
  });

  it('opens the sync status details in a popover on the capsule in a regular-width window', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({ subject: 'Saturday, by the river?' });
    const connected = await renderConnected(gmail.native, 'gmail', {
      windowBar: createWindowBar(),
    });
    await screen.findByRole('button', { name: /Saturday, by the river\?/u });
    gmail.fail({ code: 'unavailable' });
    await act(connected.store().load);
    await fireEvent.press(
      screen.getByRole('button', { name: '1 account needs attention' }),
    );
    const details = within(screen.getByTestId('popover'));
    expect(details.getByRole('header', { name: 'Sync Status' })).toBeVisible();
    // The popover closes by tapping outside it, so it has no Done.
    expect(details.queryByRole('button', { name: 'Done' })).toBeNull();
    expect(details.getByText('Gmail · alex@example.invalid')).toBeVisible();
    expect(screen.queryByTestId('bottom-sheet')).toBeNull();
  });

  it('refreshes the shown Inbox when the list is pulled down and settles the indicator after a failure', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({ subject: 'Saturday, by the river?' });
    await renderConnected(gmail.native);
    await screen.findByRole('button', { name: /Saturday, by the river\?/u });
    gmail.deliver({ subject: 'Arrives with the pull' });
    const request = gmail.native.gmailRequest;
    let release: () => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Hold Gmail until the indicator has been checked.
    const held = new Promise<void>((resolve) => {
      release = resolve;
    });
    gmail.native.gmailRequest = async (...args) => {
      await held;
      return request(...args);
    };
    const pull = () =>
      act(async () => {
        fireEvent(screen.getByLabelText('Inbox messages'), 'refresh');
        await Promise.resolve();
      });
    const indicator = () => screen.getByLabelText('Inbox messages').props;
    await pull();
    expect(indicator()).toMatchObject({ refreshing: true });
    // A refresh the person started shows its progress at once.
    expect(
      screen.getByRole('button', { name: 'Updating 1 account' }),
    ).toBeVisible();
    expect(screen.queryByText('Arrives with the pull')).toBeNull();
    await act(async () => {
      release();
    });
    await expect(
      screen.findByText('Arrives with the pull'),
    ).resolves.toBeVisible();
    await waitFor(() => {
      expect(indicator()).toMatchObject({ refreshing: false });
    });

    // Offline, the pull ends with the cached list and the documented retry.
    gmail.fail({ code: 'unavailable' });
    await pull();
    await expect(
      screen.findByText('1 account needs attention'),
    ).resolves.toBeVisible();
    expect(screen.getByText('Arrives with the pull')).toBeVisible();
    expect(screen.getByRole('button', { name: 'Try Again' })).toBeVisible();
    await waitFor(() => {
      expect(indicator()).toMatchObject({ refreshing: false });
    });
  });

  it('clears an IMAP connection’s attention when a pull or Try Again succeeds while another folder is listed', async () => {
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
      const fail = async () => {
        imap.server.failure = 'offline';
        await act(inbox.load);
        expect(screen.getByText('1 account needs attention')).toBeVisible();
        imap.server.failure = undefined;
      };

      await fail();
      imap.deliver('Archive', { subject: 'Filed with the pull' });
      await act(async () => {
        fireEvent(screen.getByLabelText('Inbox messages'), 'refresh');
        await Promise.resolve();
      });
      await expect(
        screen.findByText('Filed with the pull'),
      ).resolves.toBeVisible();
      await waitFor(() => {
        expect(screen.queryByText('1 account needs attention')).toBeNull();
      });

      await fail();
      imap.deliver('Archive', { subject: 'Filed after Try Again' });
      await act(async () => {
        await fireEvent.press(
          screen.getByRole('button', { name: 'Try Again' }),
        );
      });
      await expect(
        screen.findByText('Filed after Try Again'),
      ).resolves.toBeVisible();
      await waitFor(() => {
        expect(screen.queryByText('1 account needs attention')).toBeNull();
      });
    } finally {
      await cleanup();
      inbox.forget();
    }
  });

  it('keeps the saved body of a listed folder the cache evicted when the list is pulled down', async () => {
    expect.hasAssertions();
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
        fireEvent(screen.getByLabelText('Inbox messages'), 'refresh');
        await Promise.resolve();
      });
      // The folder was already current, so wait for the refresh itself to settle.
      await waitFor(() => {
        expect(imap.server.reads.slice(readsBefore)).toStrictEqual(
          expect.arrayContaining(['examine INBOX', 'examine Folder 0']),
        );
        expect(screen.getByLabelText('Inbox messages')).toHaveProp(
          'refreshing',
          false,
        );
        expect(inbox.folder('Folder 0')).toMatchObject({ status: 'current' });
      });
      expect(imap.bodies.has(shown.id)).toBe(true);
    } finally {
      await cleanup();
      inbox.forget();
    }
  });

  it('organizes mail from the reader and the row, keeping an offline archive until Undo', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const travel = gmail.createLabel('Travel');
    gmail.createLabel('INBOX/Receipts');
    const other = gmail.deliver({ subject: 'Tickets for Lisbon' });
    const oliver = gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
    });
    // The legacy cache stays readable while its missing labels are fetched again.
    await createInboxStore(gmail.native).load();
    await gmail.native.commitMailbox(
      { address: 'alex@example.invalid', generation: '0' },
      gmail.commits.length,
      String(gmail.commits.at(-1)).replaceAll(/,"labels":\[[^\]]*\]/gu, ''),
    );
    const held = holdingListing(gmail.native);
    const connected = await renderConnected(held.native);
    const store = connected.store();
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    );
    expect(screen.getByText('oliver@example.invalid')).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Mark as Read' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Folders' })).toBeNull();
    // Pin is product state, so it does not wait for Gmail access.
    expect(
      screen.getByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    ).toHaveProp('accessibilityActions', [{ name: 'pin', label: 'Pin' }]);
    // Local search still reports no match while the cached Inbox is synchronizing.
    await fireEvent.changeText(
      screen.getByLabelText('Search senders and subjects'),
      'No saved match',
    );
    expect(
      screen.getByText(
        'No mail saved on this device matches “No saved match”.',
      ),
    ).toBeVisible();
    await fireEvent.changeText(
      screen.getByLabelText('Search senders and subjects'),
      '',
    );
    await act(async () => {
      held.release();
      await store.load();
    });
    expect(screen.getByRole('button', { name: 'Folders' })).toBeVisible();
    // Once Gmail access verifies, the open message is read, without announcing it.
    await expect(
      screen.findByRole('button', {
        name: 'Oliver Park. Saturday, by the river?',
      }),
    ).resolves.toBeVisible();
    expect(
      screen.queryByText('Marked as read: “Saturday, by the river?”.'),
    ).toBeNull();
    // On iPhone, More is the system menu iPad's frames draw, starting with Pin and ending with
    // Delete.
    expect(menuSections(screen.getByLabelText('More'))).toStrictEqual([
      ['Pin', 'Mark as Unread', 'Move to…'],
      ['Move to Spam', 'Labels'],
      ['Delete'],
    ]);
    // The provider's star is offered only by the Command Palette (#2084).
    await openPalette(
      screen.getByRole('header', { name: 'Saturday, by the river?' }),
    );
    await act(async () => {
      await fireEvent.press(
        openedPalette().getByRole('button', { name: 'Star' }),
      );
    });
    // Every outcome is stated, not only removals that can be undone.
    expect(
      screen.getByText('Starred: “Saturday, by the river?”.'),
    ).toBeVisible();
    // On iPhone, More's Labels opens the labels to add or remove, since Move is a picker.
    await chooseFromMenu(screen.getByLabelText('More'), 'Labels');
    expect(screen.getByRole('header', { name: 'Labels' })).toBeVisible();
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('checkbox', { name: 'Travel', checked: false }),
      );
    });
    expect(
      screen.getByRole('checkbox', { name: 'Travel', checked: true }),
    ).toBeVisible();
    expect(screen.getByText('Labels: Travel')).toBeVisible();
    expect(gmail.labelsOf(oliver)).toStrictEqual(['INBOX', 'STARRED', travel]);
    // On iPhone, Gmail moves through the same picker as other mail; applied labels are its own.
    await fireEvent.press(screen.getByRole('button', { name: 'Folders' }));
    expect(
      within(screen.getByTestId('move-sheet')).getByRole('button', {
        name: 'Travel',
        selected: true,
      }),
    ).toBeDisabled();
    // A user label's first segment is its name, not the system Inbox's identity.
    expect(
      within(
        screen.getByRole('button', { name: 'Move to INBOX / Receipts' }),
      ).getByText('INBOX / Receipts'),
    ).toBeVisible();
    await fireEvent(screen.getByTestId('move-sheet'), 'accessibilityEscape');
    expect(gmail.labelsOf(oliver)).toStrictEqual(['INBOX', 'STARRED', travel]);

    // Offline, the archive shows at once and closes the reader; Undo puts the message back.
    gmail.failModify({ code: 'unavailable' });
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Archive' }));
    });
    expect(screen.queryByText('Saturday, by the river?')).toBeNull();
    expect(
      screen.getByText('Archived: “Saturday, by the river?”.'),
    ).toBeVisible();
    expect(
      screen.getByText(
        'One change is saved on this device and waits for Gmail.',
      ),
    ).toBeVisible();
    expect(gmail.labelsOf(oliver)).toContain('INBOX');
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Undo' }));
    });
    await waitFor(() => {
      expect(
        screen.getByRole('button', {
          name: 'Oliver Park. Saturday, by the river?',
        }),
      ).toBeVisible();
    });
    expect(gmail.labelsOf(oliver).toSorted()).toStrictEqual(
      ['STARRED', travel, 'INBOX'].toSorted(),
    );
    expect(screen.queryByText(/waits for Gmail/u)).toBeNull();

    // VoiceOver offers the same actions on each row; removing the open message closes the reader.
    const lisbon = screen.getByRole('button', {
      name: 'Unread. Maya Chen. Tickets for Lisbon',
    });
    await fireEvent.press(lisbon);
    expect(
      screen.getByRole('header', { name: 'Tickets for Lisbon' }),
    ).toBeVisible();
    await act(async () => {
      await fireEvent(lisbon, 'accessibilityAction', {
        nativeEvent: { actionName: 'trash' },
      });
    });
    expect(screen.queryByText('Tickets for Lisbon')).toBeNull();
    expect(
      screen.getByText('Select a message to start reading.'),
    ).toBeVisible();
    expect(
      screen.getByText('Moved to Trash: “Tickets for Lisbon”.'),
    ).toBeVisible();
    // Opening it read it first.
    await waitFor(() => {
      expect(gmail.labelsOf(other)).toStrictEqual(['TRASH']);
    });
    expect(
      screen.getByText('Moved to Trash: “Tickets for Lisbon”.'),
    ).toHaveProp('accessibilityRole', 'text');
    expect(
      screen.getByText('Moved to Trash: “Tickets for Lisbon”.'),
    ).not.toHaveProp('accessibilityLiveRegion');

    // Refusal semantics survive the single explicit announcement path on mobile too.
    gmail.failModify({ status: 400 });
    await act(async () => {
      await fireEvent(
        screen.getByRole('button', {
          name: 'Oliver Park. Saturday, by the river?',
        }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'archive' } },
      );
    });
    const refusal =
      'Gmail could not archive “Saturday, by the river?”. The Inbox shows it as Gmail has it.';
    const status = screen.getByRole('alert', { name: refusal });
    expect(status).toBeVisible();
    expect(status).not.toHaveProp('accessibilityLiveRegion');
    expect(
      jest
        .mocked(AccessibilityInfo.announceForAccessibility)
        .mock.calls.filter(([message]) => message === refusal),
    ).toStrictEqual([[refusal]]);

    // Foreground verification can close saving after the reader offered Archive.
    await fireEvent.press(
      screen.getByRole('button', {
        name: 'Oliver Park. Saturday, by the river?',
      }),
    );
    held.becomeCacheOnly();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Archive' }));
    });
    const unsaved =
      'The request to archive “Saturday, by the river?” could not be saved. Showing mail saved on this device. Try again to reconnect, then repeat the change.';
    expect(screen.getByRole('alert', { name: unsaved })).toBeVisible();
    expect(
      screen.getByText('Select a message to start reading.'),
    ).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Undo' })).toBeNull();
    expect(
      jest
        .mocked(AccessibilityInfo.announceForAccessibility)
        .mock.calls.filter(([message]) => message === unsaved),
    ).toStrictEqual([[unsaved]]);
  });

  it.each([
    { title: 'Archive', label: 'STARRED' },
    { title: 'Sent', label: 'SENT' },
  ])(
    'keeps Gmail reader actions available from unified $title',
    async ({ title, label }) => {
      expect.hasAssertions();
      const gmail = createSyntheticGmail();
      const id = gmail.deliver({
        subject: 'Saved receipt',
        content: { text: 'Paid in full.' },
      });
      gmail.archive(id);
      gmail.setLabel(id, label, true);
      await renderConnected(gmail.native);
      await fireEvent.press(
        await screen.findByRole('button', {
          name: `${title}. In All Mailboxes`,
        }),
      );
      const receipt = await screen.findByRole('button', {
        name: /Saved receipt\..* In alex@example\.invalid/u,
      });
      expect(
        within(receipt).getByText('In alex@example.invalid'),
      ).toBeVisible();
      await fireEvent.press(receipt);
      await expect(screen.findByText('Paid in full.')).resolves.toBeVisible();
      expect(menuSections(screen.getByLabelText('More')).flat()).toContain(
        'Delete',
      );
    },
  );

  it('creates a nested Gmail label from Labels, applies an existing name, offers one differing in case and explains a refusal', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.createLabel('Clients');
    const northwind = gmail.createLabel('Clients/Northwind');
    const receipts = gmail.createLabel('Receipts');
    const invoice = gmail.deliver({
      from: 'Acme Studio <billing@example.invalid>',
      subject: 'Invoice 2026-114 for October',
    });
    // Gmail answers once released, to show Labels while it creates.
    const answers = Promise.withResolvers<undefined>();
    await renderConnected({
      ...gmail.native,
      gmailCreateLabel: async (name, owner) => {
        await answers.promise;
        return gmail.native.gmailCreateLabel(name, owner);
      },
    });
    await fireEvent.press(
      await screen.findByRole('button', {
        name: /Invoice 2026-114 for October/u,
      }),
    );
    await screen.findByRole('button', { name: 'Folders' });
    const alert = jest.spyOn(Alert, 'alert').mockReturnValue(undefined);
    const openLabels = async () => {
      await chooseFromMenu(screen.getByLabelText('More'), 'Labels');
      await fireEvent.press(screen.getByRole('button', { name: 'New Label…' }));
      return within(screen.getByTestId('new-label'));
    };

    // A slash nests the new label; it is created in Gmail, then applied.
    let labels = await openLabels();
    expect(labels.getByRole('header', { name: 'Labels' })).toBeVisible();
    expect(labels.getByText('Gmail · alex@example.invalid')).toBeVisible();
    expect(labels.getByRole('button', { name: 'Apply' })).toBeDisabled();
    await fireEvent.changeText(
      labels.getByLabelText('Label name'),
      'Clients/Acme',
    );
    expect(
      labels.getByRole('button', {
        name: 'Create “Acme” inside “Clients”, Created in Gmail, then applied',
      }),
    ).toBeVisible();
    expect(
      labels.getByRole('header', { name: 'Matching labels' }),
    ).toBeVisible();
    expect(
      labels.getByRole('button', { name: 'Clients/Northwind' }),
    ).toBeVisible();
    expect(labels.getByRole('button', { name: 'Receipts' })).toBeVisible();
    await fireEvent.press(labels.getByRole('button', { name: 'Apply' }));
    // While Gmail creates the label, which is then applied, Labels cannot be cancelled.
    expect(labels.getByRole('button', { name: 'Cancel' })).toBeDisabled();
    await act(async () => {
      answers.resolve(undefined);
    });
    expect(screen.queryByTestId('new-label')).toBeNull();
    expect(screen.getByText('Labels: Clients/Acme')).toBeVisible();
    // The fake numbers labels as Gmail's `Label_` identifiers, after the three above.
    expect(gmail.labelsOf(invoice)).toContain('Label_4');

    // A name another label already has applies that label without creating one.
    labels = await openLabels();
    await fireEvent.changeText(
      labels.getByLabelText('Label name'),
      'Clients/Northwind',
    );
    expect(labels.queryByRole('button', { name: /^Create/u })).toBeNull();
    await act(async () => {
      await fireEvent(labels.getByLabelText('Label name'), 'submitEditing');
    });
    expect(gmail.labelsOf(invoice)).toContain(northwind);

    // The same name in a different case offers the existing label; nothing is applied until chosen.
    labels = await openLabels();
    await fireEvent.changeText(labels.getByLabelText('Label name'), 'receipts');
    expect(labels.queryByRole('button', { name: /^Create/u })).toBeNull();
    await fireEvent.press(labels.getByRole('button', { name: 'Apply' }));
    expect(alert).toHaveBeenLastCalledWith(
      '“receipts” wasn’t created',
      'Gmail already has a label with this name in a different case. Nothing was applied.',
      [
        expect.objectContaining({ text: 'Use “Receipts”', isPreferred: true }),
        expect.objectContaining({ text: 'Edit Name', style: 'cancel' }),
      ],
    );
    expect(gmail.labelsOf(invoice)).not.toContain(receipts);
    await act(async () => {
      alert.mock.lastCall?.[2]?.[0]?.onPress?.();
    });
    expect(screen.queryByTestId('new-label')).toBeNull();
    expect(gmail.labelsOf(invoice)).toContain(receipts);

    // A name Gmail refuses applies nothing and is explained, leaving the name to edit.
    gmail.failCreateLabel({ status: 403 });
    const before = gmail.labelsOf(invoice);
    labels = await openLabels();
    await fireEvent.changeText(labels.getByLabelText('Label name'), 'Travel');
    await act(async () => {
      await fireEvent.press(
        labels.getByRole('button', {
          name: 'Create “Travel”, Created in Gmail, then applied',
        }),
      );
    });
    expect(alert).toHaveBeenLastCalledWith(
      '“Travel” could not be created in Gmail',
      'Gmail may already have a label with this name, or it could not be reached. Try another name, or try again later.',
    );
    expect(labels.getByLabelText('Label name')).toHaveProp('value', 'Travel');
    expect(gmail.labelsOf(invoice)).toStrictEqual(before);
    await fireEvent.press(labels.getByRole('button', { name: 'Cancel' }));
    expect(screen.queryByTestId('new-label')).toBeNull();
  });

  it('browses a Gmail label and Trash from Mailboxes and moves trashed mail back to the Inbox', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const travel = gmail.createLabel('Travel');
    const flight = gmail.deliver({ subject: 'Flight to Zagreb' });
    gmail.setLabel(flight, travel, true);
    gmail.archive(flight);
    gmail.deliver({ subject: 'Lunch on Friday' });
    const receipt = gmail.deliver({ subject: 'Old receipt' });
    gmail.setLabel(receipt, 'TRASH', true);
    gmail.setLabel(receipt, 'INBOX', false);
    await renderConnected(gmail.native);
    await screen.findByRole('button', { name: /Lunch on Friday/u });
    // Each label follows the Inbox, then All Mail, Spam and Trash.
    expect(
      screen.getByRole('button', { name: 'All Mail. In alex@example.invalid' }),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Travel. In alex@example.invalid' }),
      );
    });
    // An archived message stays in its label.
    await expect(
      screen.findByRole('button', { name: /Flight to Zagreb/u }),
    ).resolves.toBeVisible();
    expect(screen.getByRole('header', { name: 'Travel' })).toBeVisible();
    expect(screen.queryByText('Lunch on Friday')).toBeNull();
    // Archived mail in a label has nothing for Archive to remove.
    await fireEvent.press(
      screen.getByRole('button', { name: /Flight to Zagreb/u }),
    );
    expect(screen.queryByRole('button', { name: 'Archive' })).toBeNull();

    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Trash. In alex@example.invalid' }),
      );
    });
    const trashed = await screen.findByRole('button', { name: /Old receipt/u });
    // Downloaded history leaves out Spam and Trash, so their older mail stays in Gmail.
    expect(
      screen.getByText(
        'Only the newest mail here is saved on this device. Older mail stays in Gmail.',
      ),
    ).toBeVisible();
    await fireEvent.press(trashed);
    // Trashed mail moves back to the Inbox instead of being archived again.
    expect(screen.queryByRole('button', { name: 'Archive' })).toBeNull();
    await chooseFromMenu(screen.getByLabelText('More'), 'Move to Inbox');
    expect(
      screen.getByText('Moved back to the Inbox: “Old receipt”.'),
    ).toBeVisible();
    expect(screen.queryByRole('button', { name: /Old receipt/u })).toBeNull();
    expect(gmail.labelsOf(receipt)).toContain('INBOX');
    expect(gmail.labelsOf(receipt)).not.toContain('TRASH');

    // Online search from Trash still returns ordinary Inbox mail with Inbox actions.
    const field = screen.getByLabelText('Search senders and subjects');
    await fireEvent(field, 'focus');
    await fireEvent.changeText(field, 'Lunch');
    await fireEvent.press(
      screen.getByRole('button', { name: 'Search Mail Servers for “Lunch”' }),
    );
    await fireEvent.press(
      await screen.findByRole('button', { name: /Lunch on Friday/u }),
    );
    expect(screen.getByRole('button', { name: 'Archive' })).toBeVisible();

    // Search widened from Trash to every Inbox opens Inbox mail with Inbox actions.
    await act(async () => {
      await fireEvent.press(screen.getByRole('tab', { name: 'All Mailboxes' }));
    });
    await fireEvent.press(
      await screen.findByRole('button', { name: /Lunch on Friday/u }),
    );
    expect(screen.getByRole('button', { name: 'Archive' })).toBeVisible();
    expect(menuSections(screen.getByLabelText('More')).flat()).not.toContain(
      'Move to Inbox',
    );

    // A cached label-only message found online still has no Inbox organizing actions; More
    // offers only Pin, which needs no Gmail access.
    await fireEvent.changeText(field, 'Flight');
    await fireEvent.press(
      screen.getByRole('button', { name: 'Search Mail Servers for “Flight”' }),
    );
    await fireEvent.press(
      await screen.findByRole('button', { name: /Flight to Zagreb/u }),
    );
    expect(screen.queryByRole('button', { name: 'Archive' })).toBeNull();
    expect(menuSections(screen.getByLabelText('More'))).toStrictEqual([
      ['Pin'],
    ]);
  });

  it('shows how much of All Mail has downloaded and asks to try again when its download pauses', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    for (const index of Array.from({ length: 250 }, (_, at) => at)) {
      gmail.archive(gmail.deliver({ subject: `Message ${index}` }));
    }
    gmail.deliver({ subject: 'Lunch on Friday' });
    // Gmail holds, then refuses, the third history page.
    gmail.failPage('200', { code: 'unavailable' });
    const { native, release } = holdingPage(gmail.native, '200');
    await renderConnected(native);
    await screen.findByRole('button', { name: /Lunch on Friday/u });
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', {
          name: 'All Mail. In alex@example.invalid',
        }),
      );
    });
    await expect(
      screen.findByText('alex@example.invalid · 200 of 251 downloaded'),
    ).resolves.toBeVisible();
    expect(
      screen.getByRole('progressbar', {
        name: /^Downloading older mail… Mail from before \S.* appears here as it arrives\./u,
      }),
    ).toBeVisible();
    expect(
      screen.queryByText(
        'Only the newest mail here is saved on this device. Older mail stays in Gmail.',
      ),
    ).toBeNull();
    // The capsule measures the same download.
    await expect(
      screen.findByRole(
        'button',
        { name: 'Updating 1 account · 79%' },
        { timeout: 3000 },
      ),
    ).resolves.toHaveProp('accessibilityValue', { min: 0, max: 100, now: 79 });
    // The failed read pauses the download, so the capsule asks for attention instead of progress.
    await act(async () => {
      release();
      await Promise.resolve();
    });
    await expect(
      screen.findByText('1 account needs attention'),
    ).resolves.toBeVisible();
    expect(screen.queryByRole('button', { name: /^Updating/u })).toBeNull();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Try Again' }));
    });
    // Try Again resumes the download, which finishes the older mail.
    await waitFor(
      () => {
        expect(
          screen.queryByRole('progressbar', {
            name: /^Downloading older mail/u,
          }),
        ).toBeNull();
      },
      { timeout: 3000 },
    );
    expect(screen.queryByText('1 account needs attention')).toBeNull();
  });

  it('keeps a paused history download in Attention when metadata refresh loses authorization', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    for (const index of Array.from({ length: 250 }, (_, at) => at)) {
      gmail.archive(gmail.deliver({ subject: `Message ${index}` }));
    }
    gmail.deliver({ subject: 'Cached Inbox message' });
    gmail.failPage('200', { code: 'unavailable' });
    const connected = await renderConnected(gmail.native);
    await screen.findByText('1 account needs attention');
    gmail.fail({ status: 401 });
    await act(connected.store().load);
    expect(screen.getByText('1 account needs attention')).toBeVisible();
    expect(
      screen.getByRole('button', { name: 'Allow Gmail Access' }),
    ).toBeVisible();
    await fireEvent.press(
      screen.getByRole('button', { name: 'Allow Gmail Access' }),
    );
    await waitFor(() => {
      expect(screen.queryByText('1 account needs attention')).toBeNull();
    });
    expect(screen.getByText('Cached Inbox message')).toBeVisible();
  });

  it('keeps a label-only message open while the person browses more views than the cache keeps', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const [first] = Array.from({ length: 10 }, (_, index) =>
      gmail.createLabel(`Label ${index}`),
    );
    const kept = gmail.deliver({ subject: 'Only in its label' });
    gmail.setLabel(kept, String(first), true);
    gmail.archive(kept);
    await renderConnected(gmail.native);
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Label 0. In alex@example.invalid',
        }),
      );
    });
    await fireEvent.press(
      await screen.findByRole('button', { name: /Only in its label/u }),
    );
    // Nine other views are more than the eight the mailbox keeps beside its Inbox.
    for (const index of [1, 2, 3, 4, 5, 6, 7, 8, 9]) {
      await act(async () => {
        await fireEvent.press(
          screen.getByRole('button', {
            name: `Label ${index}. In alex@example.invalid`,
          }),
        );
      });
    }
    expect(
      screen.getByRole('header', { name: 'Only in its label' }),
    ).toBeVisible();
  });

  it('keeps organizing a message whose label Gmail removed while it was open', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const travel = gmail.createLabel('Travel');
    const flight = gmail.deliver({ subject: 'Flight to Zagreb' });
    gmail.setLabel(flight, travel, true);
    const connected = await renderConnected(gmail.native);
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Travel. In alex@example.invalid',
        }),
      );
    });
    await fireEvent.press(
      await screen.findByRole('button', { name: /Flight to Zagreb/u }),
    );
    gmail.deleteLabel(travel);
    await act(connected.store().load);
    // The message is still in the Inbox, so the reader keeps the Inbox's actions.
    expect(
      screen.getByRole('header', { name: 'Flight to Zagreb' }),
    ).toBeVisible();
    expect(screen.getByRole('button', { name: 'Archive' })).toBeVisible();
  });

  it.each([
    ['Travel', 'Inbox', true],
    ['Inbox', 'Travel', false],
  ] as const)(
    'keeps the %s reader according to its own view when archiving from %s',
    async (opened, browsing, remains) => {
      expect.hasAssertions();
      const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
      const travel = gmail.createLabel('Travel');
      const flight = gmail.deliver({ subject: 'Flight to Zagreb' });
      gmail.setLabel(flight, travel, true);
      await renderConnected(gmail.native);
      await act(async () => {
        await fireEvent.press(
          await screen.findByRole('button', {
            name: `${opened}. In alex@example.invalid`,
          }),
        );
      });
      await fireEvent.press(
        await screen.findByRole('button', { name: /Flight to Zagreb/u }),
      );
      await act(async () => {
        await fireEvent.press(
          screen.getByRole('button', {
            name: `${browsing}. In alex@example.invalid`,
          }),
        );
      });
      await act(async () => {
        await fireEvent(
          await screen.findByRole('button', { name: /Flight to Zagreb/u }),
          'accessibilityAction',
          { nativeEvent: { actionName: 'archive' } },
        );
      });
      const reader = screen.queryByRole('header', { name: 'Flight to Zagreb' });
      expect(reader !== null).toBe(remains);
    },
  );

  it('hides Archive from Microsoft reader and row actions when its folder is absent', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({
      address: 'casey@example.invalid',
      messages: 1,
    });
    graph.withoutFolder('archive');
    await renderConnected(graph.native, 'microsoft-graph');
    const row = await screen.findByRole('button', {
      name: /Synthetic message 0/u,
    });
    expect(row.props.accessibilityActions).not.toContainEqual(
      expect.objectContaining({ name: 'archive' }),
    );
    await fireEvent.press(row);
    expect(screen.queryByRole('button', { name: 'Archive' })).toBeNull();
    expect(menuSections(screen.getByLabelText('More')).flat()).toContain(
      'Delete',
    );
    await fireEvent.press(screen.getByRole('button', { name: 'Folders' }));
    expect(
      screen.getByText('This Microsoft mailbox has no folders of its own yet.'),
    ).toBeVisible();
  });

  it('runs only the action chosen from More, which opens no panel', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ address: 'casey@example.invalid' });
    const plans = graph.deliver({ subject: 'Garden plans' });
    await renderConnected(graph.native, 'microsoft-graph');
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Unread. Rowan Hale. Garden plans',
      }),
    );
    // The system menu owns its presentation and dismissal; no reader panel opens behind it.
    expect(screen.queryByTestId('reader-panel-dismissal')).toBeNull();
    // Only opening the message changed it: it is read.
    expect(graph.modifies).toStrictEqual([{ message: plans, read: true }]);
    await chooseFromMenu(screen.getByLabelText('More'), 'Mark as Unread');
    expect(graph.modifies).toStrictEqual([
      { message: plans, read: true },
      { message: plans, read: false },
    ]);
    expect(graph.folderOf(plans)).toBe('inbox');
  });

  it('organizes Microsoft mail with its folders, without Gmail labels or star', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({
      address: 'casey@example.invalid',
      inboxName: 'Posteingang',
    });
    const travel = graph.createFolder('Travel');
    graph.createFolder('Lisbon', travel);
    graph.createFolder('Receipts', 'inbox');
    const literalInbox = graph.createFolder('INBOX');
    graph.createFolder('Taxes', literalInbox);
    const namedInbox = graph.createFolder('Inbox');
    graph.createFolder('Statements', namedInbox);
    const year = graph.createFolder('Travel / 2026');
    graph.createFolder('Porto', year);
    const gone = graph.deliver({ subject: 'Old notes' });
    const plans = graph.deliver({
      from: { name: 'Rowan Hale', address: 'rowan@example.invalid' },
      subject: 'Garden plans',
    });
    await renderConnected(graph.native, 'microsoft-graph');
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Unread. Rowan Hale. Garden plans',
      }),
    );
    expect(
      ['Archive', 'Folders'].map((name) =>
        screen.getByRole('button', { name }),
      ),
    ).toHaveLength(2);
    expect(screen.queryByRole('button', { name: 'Labels' })).toBeNull();
    expect(menuSections(screen.getByLabelText('More'))).toStrictEqual([
      ['Pin', 'Mark as Unread', 'Move to…'],
      ['Move to Spam'],
      ['Delete'],
    ]);

    // A Microsoft message is in one folder: it moves, with no label to add.
    await fireEvent.press(screen.getByRole('button', { name: 'Folders' }));
    expect(
      within(screen.getByTestId('move-sheet')).getByRole('header', {
        name: 'casey@example.invalid',
      }),
    ).toBeVisible();
    expect(
      within(screen.getByTestId('move-sheet')).getByRole('button', {
        name: 'Inbox',
        selected: true,
      }),
    ).toBeDisabled();
    expect(screen.queryByRole('checkbox', { name: 'Travel' })).toBeNull();
    await fireEvent.changeText(
      within(screen.getByTestId('move-sheet')).getByLabelText('Search'),
      'no such folder',
    );
    expect(screen.getByText('No folders match your search.')).toBeVisible();
    await fireEvent(screen.getByTestId('move-sheet'), 'accessibilityEscape');
    expect(screen.queryByTestId('move-sheet')).toBeNull();
    expect(graph.folderOf(plans)).toBe('inbox');
    await fireEvent.press(screen.getByRole('button', { name: 'Folders' }));
    // A nested folder sits under its parent, named on its own and announced with its path.
    expect(
      within(
        screen.getByRole('button', { name: 'Move to Travel / Lisbon' }),
      ).getByText('Lisbon'),
    ).toBeVisible();
    // A slash in Graph's display name does not create another level of nesting.
    expect(
      within(
        screen.getByRole('button', { name: 'Move to Travel / 2026' }),
      ).getByText('Travel / 2026'),
    ).toBeVisible();
    expect(
      within(
        screen.getByRole('button', { name: 'Move to Travel / 2026 / Porto' }),
      ).getByText('Porto'),
    ).toBeVisible();
    // A folder inside the Inbox nests beneath the Inbox row, whatever Graph calls the Inbox.
    expect(
      within(
        screen.getByRole('button', { name: 'Move to Inbox / Receipts' }),
      ).getByText('Receipts'),
    ).toBeVisible();
    // A custom Graph folder named INBOX is not the well-known Inbox, nor are its children.
    expect(
      within(screen.getByRole('button', { name: 'Move to INBOX' })).getByText(
        'INBOX',
      ),
    ).toBeVisible();
    expect(
      within(
        screen.getByRole('button', { name: 'Move to INBOX / Taxes' }),
      ).getByText('Taxes'),
    ).toBeVisible();
    const sheet = within(screen.getByTestId('move-sheet'));
    // Equal display names must not attach a custom folder's child to the system Inbox.
    const rows = sheet.getAllByRole('button');
    expect(
      rows.indexOf(sheet.getByRole('button', { name: 'Move to Inbox' })),
    ).toBeLessThan(
      rows.indexOf(
        sheet.getByRole('button', { name: 'Move to Inbox / Statements' }),
      ),
    );
    // Back lists only this account, since mail moves within it; Cancel moves nothing.
    await fireEvent.press(sheet.getByRole('button', { name: 'Back' }));
    expect(sheet.getByRole('header', { name: 'Accounts' })).toBeVisible();
    await fireEvent.press(
      sheet.getByRole('button', { name: 'casey@example.invalid' }),
    );
    expect(
      sheet.getByRole('header', { name: 'casey@example.invalid' }),
    ).toBeVisible();
    await fireEvent.press(sheet.getByRole('button', { name: 'Back' }));
    await fireEvent.press(sheet.getByRole('button', { name: 'Cancel' }));
    expect(screen.queryByTestId('move-sheet')).toBeNull();
    expect(graph.folderOf(plans)).toBe('inbox');
    await fireEvent.press(screen.getByRole('button', { name: 'Folders' }));
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Move to Travel' }),
      );
    });
    expect(graph.folderOf(plans)).toBe(travel);
    expect(screen.getByText('Moved: “Garden plans”.')).toBeVisible();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Undo' }));
    });
    expect(graph.folderOf(plans)).toBe('inbox');

    // Copy names Microsoft, not Gmail.
    graph.purge(gone);
    await act(async () => {
      await fireEvent(
        screen.getByRole('button', { name: 'Unread. Rowan Hale. Old notes' }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'read' } },
      );
    });
    expect(
      screen.getByRole('alert', {
        name: 'Microsoft could not mark as read “Old notes”. The Inbox shows it as Microsoft has it.',
      }),
    ).toBeVisible();
  });

  it('names the exhausted action and resolves it through Retry and Discard controls', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 1 });
    const connected = await renderConnected(gmail.native);
    const store = connected.store();
    const target = connectedMessage(store);
    gmail.failModify(
      ...Array.from({ length: 5 }, () => ({ code: 'unavailable' })),
    );
    await act(async () => {
      await store.organize(target, gmailAction.star);
    });
    for (const ignored of [0, 1, 2, 3]) {
      void ignored;
      await act(store.load);
    }
    expect(
      screen.getByText(
        /request to star “Synthetic message 0” after five attempts/u,
      ),
    ).toBeVisible();
    // The change's Try Again comes before the sync status's for the unreachable mailbox.
    const change = screen.getAllByRole('button', { name: 'Try Again' }).at(0);
    ok(change);
    await act(async () => {
      await fireEvent.press(change);
    });
    await waitFor(() => {
      expect(gmail.labelsOf(target.id)).toContain('STARRED');
    });
    expect(screen.queryByRole('button', { name: 'Try Again' })).toBeNull();
    gmail.failModify(
      ...Array.from({ length: 5 }, () => ({ code: 'unavailable' })),
    );
    const starred = connectedMessage(store);
    await act(async () => {
      await store.organize(starred, gmailAction.unstar);
    });
    for (const ignored of [0, 1, 2, 3]) {
      void ignored;
      await act(store.load);
    }
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Discard Change' }),
      );
    });
    await waitFor(() => {
      expect(
        screen.queryByRole('button', { name: 'Discard Change' }),
      ).toBeNull();
    });
    expect(gmail.labelsOf(target.id)).toContain('STARRED');
  });

  it('hands a device found removed while organizing to the account page explanation', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
    });
    const { synthetic } = await renderConnected(gmail.native);
    const row = await screen.findByRole('button', {
      name: 'Unread. Oliver Park. Saturday, by the river?',
    });
    // Native code purges this device when the write's Trusted Device check finds it removed.
    await synthetic.vault.purge('revoked');
    gmail.failModify({ code: 'mailbox-revoked' });
    await act(async () => {
      await fireEvent(row, 'accessibilityAction', {
        nativeEvent: { actionName: 'archive' },
      });
    });
    await expect(
      screen.findByText('This device was removed'),
    ).resolves.toBeVisible();
    expect(screen.queryByText('Saturday, by the river?')).toBeNull();
    expect(screen.queryByText(/can’t be shown\. It has been kept/u)).toBeNull();
  });

  it('reads message bodies from Gmail or this device and opens links only after confirmation', async () => {
    expect.hasAssertions();
    const openURL = jest.spyOn(Linking, 'openURL').mockResolvedValue(undefined);
    const gmail = createSyntheticGmail();
    gmail.deliver({
      from: 'Maya Chen <maya@example.invalid>',
      subject: 'Garden plan',
      content: {
        html: '<p>See <a href="https://example.invalid/plan">the plan</a>.</p><img src="https://example.invalid/pixel.gif">',
      },
    });
    const store = createInboxStore(gmail.native);
    const mailboxes = singleMailbox(store, alex);
    function Journey() {
      const [selected, setSelected] = useState<Selection>();
      return (
        <InboxProvider mailboxes={mailboxes}>
          <Inbox
            onSelect={setSelected}
            selected={selected}
          />
          <MessageDetail
            id={selected?.id}
            mailbox={selected?.mailbox}
          />
        </InboxProvider>
      );
    }
    await render(<Journey />);
    await fireEvent.press(
      await screen.findByRole('button', { name: /Garden plan/u }),
    );
    // The sanitized document renders in an isolated WebKit view, hidden until measured.
    const webview = await screen.findByTestId('message-webview');
    expect(webview.props).toMatchObject({
      javaScriptEnabled: false,
      incognito: true,
      allowsLinkPreview: false,
      cacheEnabled: false,
      originWhitelist: ['*'],
      setSupportMultipleWindows: false,
    });
    expect(webview.props.source.html).toContain("default-src 'none'");
    expect(screen.getByLabelText('Opening message')).toBeVisible();
    await act(async () => {
      fireEvent(webview, 'contentSizeChange', {
        nativeEvent: { contentSize: { width: 320, height: 480 } },
      });
      await Promise.resolve();
    });
    expect(screen.queryByLabelText('Opening message')).toBeNull();
    expect(webview.props).toMatchObject({ scrollEnabled: false });
    // Content wider than its view, such as unwrappable text, scrolls sideways instead of being
    // clipped, even when WebKit measures it before the view's first layout; without bounce, the
    // normal-height document stays pinned to the reader's scroll.
    await act(async () => {
      fireEvent(webview, 'contentSizeChange', {
        nativeEvent: { contentSize: { width: 686, height: 480 } },
      });
      await Promise.resolve();
    });
    expect(webview.props).toMatchObject({ scrollEnabled: false });
    await act(async () => {
      fireEvent(webview, 'layout', { nativeEvent: { layout: { width: 320 } } });
      await Promise.resolve();
    });
    expect(webview.props).toMatchObject({
      scrollEnabled: true,
      bounces: false,
    });
    // The remote image waits for consent, which the notice explains before offering to load it.
    expect(
      screen.getByText(
        "Images in this message are not loaded. Loading them shows the sender your device's IP address and when you opened this message.",
      ),
    ).toBeVisible();
    expect(screen.getByRole('button', { name: 'Load Images' })).toBeVisible();
    // Only the app's own initial document loads; a chosen link is cancelled and confirmed.
    expect(
      webview.props.onShouldStartLoadWithRequest({
        url: 'about:blank',
        navigationType: 'other',
      }),
    ).toBe(true);
    let started: unknown = undefined;
    await act(async () => {
      started = webview.props.onShouldStartLoadWithRequest({
        url: 'about:blank#unwired-link-0',
        navigationType: 'click',
      });
      await Promise.resolve();
    });
    expect([started]).toStrictEqual([false]);
    expect(screen.getByText('Open this link in your browser?')).toBeVisible();
    expect(screen.getByText('https://example.invalid/plan')).toBeVisible();
    expect(openURL).not.toHaveBeenCalled();
    await fireEvent.press(screen.getByRole('button', { name: 'Open Link' }));
    expect(openURL).toHaveBeenCalledWith('https://example.invalid/plan');
    expect(screen.queryByText('Open this link in your browser?')).toBeNull();
    // Keyboard access reaches the same confirmation.
    const keyboardLink = screen.getByRole('link', {
      name: 'the plan',
    });
    expect(keyboardLink.props.focusable).toBe(true);
    await fireEvent.press(keyboardLink);
    expect(screen.getByText('Open this link in your browser?')).toBeVisible();
    await fireEvent.press(screen.getByRole('button', { name: 'Cancel' }));
    // Its context menu opens the same confirmation, or copies the destination.
    const linkMenu = contextMenuOf(keyboardLink);
    expect(menuSections(linkMenu)).toStrictEqual([['Open Link', 'Copy Link']]);
    await chooseFromMenu(linkMenu, 'Copy Link');
    expect(setStringAsync).toHaveBeenLastCalledWith(
      'https://example.invalid/plan',
    );
    await chooseFromMenu(linkMenu, 'Open Link');
    expect(screen.getByText('Open this link in your browser?')).toBeVisible();
    expect(openURL.mock.calls).toStrictEqual([
      ['https://example.invalid/plan'],
    ]);
    await fireEvent.press(screen.getByRole('button', { name: 'Cancel' }));
    // A WebKit failure falls back to the readable text, never to unsanitized HTML.
    await act(async () => {
      fireEvent(webview, 'error', { nativeEvent: {} });
      await Promise.resolve();
    });
    expect(screen.queryByTestId('message-webview')).toBeNull();
    // The readable text's link and its keyboard control share the link's name.
    expect(screen.getAllByRole('link', { name: 'the plan' })).toHaveLength(2);

    // Without Gmail, a saved body still opens and another one says it needs downloading.
    gmail.deliver({ subject: 'Not downloaded yet' });
    await act(store.load);
    // Opening it also tries to send its read change.
    gmail.fail(
      { code: 'unavailable' },
      { code: 'unavailable' },
      { code: 'unavailable' },
    );
    await fireEvent.press(
      screen.getByRole('button', { name: /Not downloaded yet/u }),
    );
    await expect(
      screen.findByText(
        'It’s still in Gmail. Check your connection, then try again.',
      ),
    ).resolves.toBeVisible();
    await fireEvent.press(screen.getByRole('button', { name: /Garden plan/u }));
    await expect(
      screen.findByTestId('message-webview'),
    ).resolves.toBeOnTheScreen();
    await fireEvent.press(
      screen.getByRole('button', { name: /Not downloaded yet/u }),
    );
    // The reader's Try Again follows the list notice's.
    const reader = screen.getAllByRole('button', { name: 'Try Again' }).at(-1);
    ok(reader);
    await act(async () => {
      await fireEvent.press(reader);
    });
    await expect(screen.findByText('Synthetic body.')).resolves.toBeVisible();

    // A queued confirmation must not hand off the previous owner's destination.
    await fireEvent.press(screen.getByRole('button', { name: /Garden plan/u }));
    await fireEvent.press(screen.getByRole('link', { name: 'the plan' }));
    const previousOwnerConfirmation = screen.getByRole('button', {
      name: 'Open Link',
    });
    openURL.mockClear();
    await act(async () => {
      store.forget();
      await fireEvent.press(previousOwnerConfirmation);
    });
    expect(openURL).not.toHaveBeenCalled();

    // Input queued for one message and delivered after another opens reveals nothing, and a
    // confirmation hides when its message is replaced.
    await act(store.load);
    await fireEvent.press(
      await screen.findByRole('button', { name: /Garden plan/u }),
    );
    const gardenView = await screen.findByTestId('message-webview');
    const queuedChoice = gardenView.props.onShouldStartLoadWithRequest;
    await fireEvent.press(
      await screen.findByRole('link', { name: 'the plan' }),
    );
    expect(screen.getByText('https://example.invalid/plan')).toBeVisible();
    await fireEvent.press(
      screen.getByRole('button', { name: /Not downloaded yet/u }),
    );
    await expect(screen.findByText('Synthetic body.')).resolves.toBeVisible();
    expect(screen.queryByText('https://example.invalid/plan')).toBeNull();
    await act(async () => {
      queuedChoice({
        url: 'about:blank#unwired-link-0',
        navigationType: 'click',
      });
      await Promise.resolve();
    });
    expect(screen.queryByText('Open this link in your browser?')).toBeNull();
    expect(screen.queryByText('https://example.invalid/plan')).toBeNull();
  });

  it('explains a deceptive link and offers copying it instead of opening it', async () => {
    expect.hasAssertions();
    const openURL = jest.spyOn(Linking, 'openURL').mockResolvedValue(undefined);
    const copy = jest.mocked(setStringAsync).mockResolvedValue(true);
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      subject: 'Account notice',
      content: {
        html: '<p>Sign in at <a href="https://PHISH.invalid:443">https://bank.invalid</a></p>',
      },
    });
    const store = createInboxStore(gmail.native);
    await render(
      <InboxProvider mailboxes={singleMailbox(store, alex)}>
        <MessageDetail
          id={id}
          mailbox={alex}
        />
      </InboxProvider>,
    );
    await act(store.load);
    const webview = await screen.findByTestId('message-webview');
    await act(async () => {
      webview.props.onShouldStartLoadWithRequest({
        url: 'about:blank#unwired-link-0',
        navigationType: 'click',
      });
      await Promise.resolve();
    });
    // The system alert's message lists every warning above the full destination.
    expect(
      within(screen.getByTestId('link-confirmation')).getByRole('header', {
        name: 'This link may not be what it seems',
      }),
    ).toBeVisible();
    expect(
      screen.getByText(
        'Check this link before opening it:\n• The link text shows a different address.\n\nhttps://PHISH.invalid:443',
      ),
    ).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Open Link' })).toBeNull();
    await fireEvent.press(screen.getByRole('button', { name: 'Copy Link' }));
    expect(copy).toHaveBeenCalledWith('https://PHISH.invalid:443');
    expect(openURL).not.toHaveBeenCalled();
  });
  /* oxlint-enable vitest/max-expects */
});

// The title the system navigation bar shows over the pushed Settings page, once it is pushed.
const pushedSettings = async () => {
  const page = await screen.findByTestId('settings-destination');
  const bar = page.children.find(
    (child) => typeof child !== 'string' && child.props.title !== undefined,
  );
  return typeof bar === 'string' ? undefined : bar?.props.title;
};

// A message the connected Inbox lists, as the reader's actions receive it.
const listedMessage = (
  store: ReturnType<Awaited<ReturnType<typeof renderConnected>>['store']>,
  id: string,
) => {
  const state = store.getSnapshot();
  const message =
    state.kind === 'ready'
      ? state.messages.find((item) => item.id === id)
      : undefined;
  if (message === undefined) {
    throw new Error(`Expected ${id} to be listed`);
  }
  return message;
};

describe('organizing motion', () => {
  // Rows still on screen only while they leave, hidden from VoiceOver and touch.
  const leavingRows = (subject: string) =>
    screen.queryAllByText(subject, { includeHiddenElements: true }).length -
    screen.queryAllByText(subject).length;
  const archive = async (subject: string) => {
    await act(async () => {
      await fireEvent(
        screen.getByRole('button', { name: new RegExp(subject, 'u') }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'archive' } },
      );
    });
  };

  const undo = async () => {
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Undo' }));
    });
  };

  // These journeys inspect unfinished motion, so animation frames must not finish it between
  // inputs. The list unmounts before frames return, so no animation outlives the journey.
  const holdingFrames = async (journey: () => Promise<void>) => {
    const frames = jest
      .spyOn(globalThis, 'requestAnimationFrame')
      .mockReturnValue(0);
    try {
      await journey();
    } finally {
      await cleanup();
      frames.mockRestore();
    }
  };

  // A row's content, the view around it that holds the row's height while it moves, and the list
  // cell around that, which a row keeps while it leaves and returns.
  const rowContent = (subject: string) => {
    let node = screen.getByText(subject, { includeHiddenElements: true });
    while (
      node.parent !== null &&
      StyleSheet.flatten(node.parent.props.style)?.overflow !== 'hidden'
    ) {
      node = node.parent;
    }
    return node;
  };
  const rowFrame = (subject: string) => rowContent(subject).parent;

  it('keeps a row leaving for an action and returns it with Undo, never for synchronization', async () => {
    expect.hasAssertions();
    await holdingFrames(async () => {
      const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
      const elsewhere = gmail.deliver({ subject: 'Archived elsewhere' });
      const lunch = gmail.deliver({ subject: 'Lunch on Friday' });
      const connected = await renderConnected(gmail.native);
      await screen.findByRole('button', { name: /Lunch on Friday/u });

      // Synchronization adds and removes rows without keeping any.
      gmail.archive(elsewhere);
      gmail.deliver({ subject: 'Arrives quietly' });
      await act(connected.store().load);
      await screen.findByText('Arrives quietly');
      const synchronized = leavingRows('Archived elsewhere');

      await archive('Lunch on Friday');
      const archived = [
        leavingRows('Lunch on Friday'),
        screen.queryByText('Lunch on Friday'),
      ];
      const leaving = rowFrame('Lunch on Friday')?.parent;
      // Undo brings the same row back, reversing from where it is.
      await undo();
      const restored = rowFrame('Lunch on Friday')?.parent;

      expect({
        synchronized,
        archived,
        restored: [leavingRows('Lunch on Friday'), restored === leaving],
      }).toStrictEqual({
        synchronized: 0,
        archived: [1, null],
        restored: [0, true],
      });

      // The Undo notice stays visible, but does not attribute a later server-side removal.
      gmail.archive(lunch);
      await act(connected.store().load);
      expect(leavingRows('Lunch on Friday')).toBe(0);
    });
  });

  it('keeps the last row in its date section mounted through removal and Undo', async () => {
    expect.hasAssertions();
    await holdingFrames(async () => {
      const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
      gmail.deliver({ subject: 'Only message today' });
      await renderConnected(gmail.native);
      await screen.findByText('Only message today');
      const original = rowFrame('Only message today')?.parent;

      await archive('Only message today');
      const leaving = rowFrame('Only message today')?.parent;
      await undo();

      expect([
        leaving === original,
        rowFrame('Only message today')?.parent === original,
      ]).toStrictEqual([true, true]);
    });
  });

  it('lets a restored row lay out at its own height once its motion ends', async () => {
    expect.hasAssertions();
    await holdingFrames(async () => {
      const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
      gmail.deliver({ subject: 'Lunch on Friday' });
      gmail.deliver({ subject: 'Dinner on Saturday' });
      await renderConnected(gmail.native);
      await screen.findByRole('button', { name: /Lunch on Friday/u });

      await archive('Lunch on Friday');
      const moving = rowFrame('Lunch on Friday');
      await fireEvent(rowContent('Lunch on Friday'), 'layout', {
        nativeEvent: { layout: { x: 0, y: 0, width: 390, height: 76 } },
      });
      const held = StyleSheet.flatten(rowFrame('Lunch on Friday')?.props.style);
      // Undo before the row has collapsed returns it whole at once.
      await undo();
      const resting = rowFrame('Lunch on Friday');

      expect([
        held.height,
        resting === moving,
        StyleSheet.flatten(resting?.props.style),
      ]).toStrictEqual([76, false, { overflow: 'hidden' }]);
    });
  });

  it('ignores an exit completion delivered after Undo has reversed the row', async () => {
    expect.hasAssertions();
    await holdingFrames(async () => {
      const jobs: Array<() => void> = [];
      const scheduled = jest
        .mocked(scheduleOnRN)
        .mockImplementation((fun, ...args) => {
          jobs.push(() => fun(...args));
        });
      const timings = jest.mocked(withTiming).mockClear();
      try {
        const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
        gmail.deliver({ subject: 'Lunch on Friday' });
        await renderConnected(gmail.native);
        await screen.findByText('Lunch on Friday');
        await archive('Lunch on Friday');
        const completed = timings.mock.calls.findLast(
          (call) => call[2] !== undefined,
        )?.[2];
        await act(() => completed?.(true));
        const [exitJob] = jobs;
        await undo();
        const reversing = rowFrame('Lunch on Friday');
        await act(() => exitJob?.());

        expect(completed).toBeDefined();
        expect(exitJob).toBeDefined();
        expect(rowFrame('Lunch on Friday')).toBe(reversing);
      } finally {
        await cleanup();
        scheduled.mockImplementation(
          jest.requireActual<{ scheduleOnRN: typeof scheduleOnRN }>(
            'react-native-worklets',
          ).scheduleOnRN,
        );
      }
    });
  });

  it('finishes a leaving row at once when a scroll or a selection interrupts it', async () => {
    expect.hasAssertions();
    await holdingFrames(async () => {
      const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
      gmail.deliver({ subject: 'Lunch on Friday' });
      gmail.deliver({ subject: 'Dinner on Saturday' });
      gmail.deliver({ subject: 'Breakfast on Sunday' });
      await renderConnected(gmail.native);
      await screen.findByRole('button', { name: /Lunch on Friday/u });

      await archive('Lunch on Friday');
      const beforeScroll = leavingRows('Lunch on Friday');
      await fireEvent(
        screen.getByLabelText('Inbox messages'),
        'scrollBeginDrag',
      );
      const scrolled = leavingRows('Lunch on Friday');
      await archive('Dinner on Saturday');
      const beforeSelection = leavingRows('Dinner on Saturday');
      await fireEvent.press(
        screen.getByRole('button', { name: /Breakfast on Sunday/u }),
      );

      expect([
        beforeScroll,
        scrolled,
        beforeSelection,
        leavingRows('Dinner on Saturday'),
      ]).toStrictEqual([1, 0, 1, 0]);
    });
  });

  it('removes a leaving row at once under Reduce Motion', async () => {
    expect.hasAssertions();
    const reduced = jest
      .spyOn(AccessibilityInfo, 'isReduceMotionEnabled')
      .mockResolvedValue(true);
    try {
      const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
      gmail.deliver({ subject: 'Lunch on Friday' });
      await renderConnected(gmail.native);
      await screen.findByRole('button', { name: /Lunch on Friday/u });

      await archive('Lunch on Friday');
      expect(leavingRows('Lunch on Friday')).toBe(0);
    } finally {
      reduced.mockRestore();
    }
  });

  it('retires leaving rows when search replaces the list', async () => {
    expect.hasAssertions();
    await holdingFrames(async () => {
      const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
      gmail.deliver({ subject: 'Lunch on Friday' });
      gmail.deliver({ subject: 'Dinner on Saturday' });
      await renderConnected(gmail.native);
      await screen.findByRole('button', { name: /Lunch on Friday/u });
      await archive('Lunch on Friday');
      expect(leavingRows('Lunch on Friday')).toBe(1);

      await fireEvent(
        screen.getByLabelText('Search senders and subjects'),
        'focus',
      );
      expect(
        screen.queryByText('Lunch on Friday', { includeHiddenElements: true }),
      ).toBeNull();
    });
  });
});

describe('command palette', () => {
  it('opens by swipe and accessibility action while search replaces the Inbox heading', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
    });
    await renderConnected(gmail.native);
    const field = await screen.findByLabelText('Search senders and subjects');
    await act(async () => {
      await fireEvent(field, 'focus');
    });
    expect(screen.queryByRole('header', { name: 'Inbox' })).toBeNull();
    await fireEvent(field, 'touchStart', {
      nativeEvent: { pageX: 10, pageY: 10 },
    });
    await expect(
      fireEvent(field, 'moveShouldSetResponder', {
        nativeEvent: { pageX: 14, pageY: 60 },
      }),
    ).resolves.toBe(true);
    await fireEvent(field, 'responderGrant');
    expect(
      openedPalette().getByRole('button', { name: 'Search Mail' }),
    ).toBeVisible();
    await fireEvent.press(
      openedPalette().getByRole('button', { name: 'Cancel' }),
    );
    await openPalette(field);
    expect(
      openedPalette().getByRole('button', { name: 'Search Mail' }),
    ).toBeVisible();
  });

  it('makes the one-time hint text one accessibility element, and Dismiss removes the hint', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    await renderConnected(gmail.native);
    await expect(
      screen.findByLabelText(
        'Swipe down on the header for commands, Reply, archive, move or go anywhere without leaving this screen.',
      ),
    ).resolves.toHaveProp('accessible', true);
    await fireEvent.press(screen.getByRole('button', { name: 'Dismiss hint' }));
    expect(screen.queryByRole('button', { name: 'Dismiss hint' })).toBeNull();
  });

  it('keeps the search field palette action when private storage locks', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const connected = await renderConnected(gmail.native);
    const field = await screen.findByLabelText('Search senders and subjects');
    await act(async () => {
      await fireEvent(field, 'focus');
    });
    gmail.failOpen('locked');
    await act(async () => {
      await connected.store().load();
    });
    await openPalette(screen.getByLabelText('Search senders and subjects'));
    expect(
      openedPalette().getByRole('button', { name: 'Cancel' }),
    ).toBeVisible();
  });

  /* oxlint-disable vitest/max-expects -- One held exit proves the closing input gates and fresh reopening. */
  it('keeps a closing palette out of reach while it fades and reopens it empty', async () => {
    expect.hasAssertions();
    await renderConnected(
      createSyntheticGmail({ address: 'alex@example.invalid' }).native,
    );
    // The exit never finishes here, so the closed palette is still leaving when it reopens.
    const timing = jest.spyOn(Animated, 'timing').mockReturnValue({
      start: () => undefined,
      stop: () => undefined,
      reset: () => undefined,
    });
    try {
      const header = await screen.findByRole('header', { name: 'Inbox' });
      await openPalette(header);
      const input = screen.getByPlaceholderText('Type a command');
      await fireEvent.changeText(input, 'se');
      await fireEvent.press(
        openedPalette().getByRole('button', { name: 'Cancel' }),
      );
      // The leaving palette stays over the Inbox, hidden from VoiceOver and touch.
      expect(
        screen.getByTestId('command-palette', { includeHiddenElements: true }),
      ).toHaveProp('pointerEvents', 'none');
      expect(screen.queryByPlaceholderText('Type a command')).toBeNull();
      expect(input).toHaveProp('editable', false);
      // New input is disabled; a native Return already queued before closing must be ignored too.
      await fireEvent(input, 'submitEditing');
      await act(() => {
        input.props.onSubmitEditing();
      });
      expect(screen.getByRole('header', { name: 'Inbox' })).toBeOnTheScreen();
      await openPalette(header);
      expect(screen.getByPlaceholderText('Type a command')).toHaveDisplayValue(
        '',
      );
      expect(
        openedPalette().getByRole('button', {
          name: 'Reply. Select a Thread',
        }),
      ).toBeOnTheScreen();
    } finally {
      timing.mockRestore();
    }
  });
  /* oxlint-enable vitest/max-expects */

  /* oxlint-disable vitest/max-expects -- One journey proves each entry, the fixed order, narrowing and the picker. */
  it('lists contextual commands first, narrows by typing and moves the open message from its picker', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const travel = gmail.createLabel('Travel');
    const oliver = gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
    });
    await renderConnected(gmail.native);
    const row = await screen.findByRole('button', {
      name: 'Unread. Oliver Park. Saturday, by the river?',
    });
    // Nothing open: the mail commands stay listed, disabled, with the reason.
    await openPalette(screen.getByRole('header', { name: 'Inbox' }));
    expect(
      openedPalette().getByRole('button', {
        name: 'Reply. Select a Thread',
      }),
    ).toBeDisabled();
    expect(
      openedPalette().getByRole('button', { name: 'Search Mail' }),
    ).toBeVisible();
    await fireEvent.press(
      openedPalette().getByRole('button', { name: 'Cancel' }),
    );
    expect(screen.queryByPlaceholderText('Type a command')).toBeNull();

    // A downward swipe on the reader's header opens it for the open message, once the reader
    // offers its labels.
    await fireEvent.press(row);
    const subject = await screen.findByRole('header', {
      name: 'Saturday, by the river?',
    });
    await screen.findByRole('button', { name: 'Folders' });
    await fireEvent(subject, 'touchStart', {
      nativeEvent: { pageX: 10, pageY: 10 },
    });
    await expect(
      fireEvent(subject, 'moveShouldSetResponder', {
        nativeEvent: { pageX: 14, pageY: 60 },
      }),
    ).resolves.toBe(true);
    await fireEvent(subject, 'responderGrant');
    const headers = openedPalette()
      .getAllByRole('header')
      .map((item) => String(item.props.children));
    expect(
      headers.indexOf('Selected Message · Saturday, by the river?'),
    ).toBeLessThan(headers.indexOf('App'));
    expect(headers.indexOf('App')).toBeLessThan(headers.indexOf('Go To'));
    const input = screen.getByPlaceholderText('Type a command');
    await fireEvent.changeText(input, 'arch');
    expect(
      openedPalette().getByRole('button', { name: 'Archive' }),
    ).toBeVisible();
    expect(openedPalette().queryByRole('button', { name: 'Reply' })).toBeNull();
    await fireEvent.changeText(input, '');

    // Move to… chooses inside the palette; Back returns; nothing moves until chosen.
    await fireEvent.press(
      openedPalette().getByRole('button', { name: 'Move to…' }),
    );
    expect(openedPalette().getByText('Move 1 message')).toBeVisible();
    await fireEvent.press(
      openedPalette().getByRole('button', { name: 'Back to commands' }),
    );
    expect(openedPalette().queryByText('Move 1 message')).toBeNull();
    expect(gmail.labelsOf(oliver)).toContain('INBOX');
    await fireEvent.press(
      openedPalette().getByRole('button', { name: 'Move to…' }),
    );
    await fireEvent.changeText(
      screen.getByPlaceholderText('Choose a folder'),
      'tra',
    );
    await act(async () => {
      await fireEvent.press(
        openedPalette().getByRole('button', { name: 'Travel' }),
      );
    });
    expect(gmail.labelsOf(oliver)).toContain(travel);
    expect(gmail.labelsOf(oliver)).not.toContain('INBOX');
    expect(screen.queryByPlaceholderText('Type a command')).toBeNull();
    expect(screen.queryByText('Saturday, by the river?')).toBeNull();
  });

  it('never runs a command on a message that left the reader after the palette opened', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const lisbon = gmail.deliver({ subject: 'Tickets for Lisbon' });
    const oliver = gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
    });
    const connected = await renderConnected(gmail.native);
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    );
    await openPalette(
      await screen.findByRole('header', { name: 'Saturday, by the river?' }),
    );
    expect(
      openedPalette().getByRole('button', { name: 'Archive' }),
    ).toBeEnabled();
    // Meanwhile the message is archived elsewhere and the reader closes.
    const store = connected.store();
    await act(async () => {
      await store.organize(listedMessage(store, oliver), gmailAction.archive);
    });
    expect(screen.queryByText('oliver@example.invalid')).toBeNull();
    const organize = jest.spyOn(store, 'organize');
    await fireEvent.press(
      openedPalette().getByRole('button', { name: 'Archive' }),
    );
    expect(
      openedPalette().getByRole('button', {
        name: 'Archive. No longer available',
      }),
    ).toBeDisabled();
    expect(organize).not.toHaveBeenCalled();
    expect(gmail.labelsOf(lisbon)).toContain('INBOX');
    expect(screen.getByPlaceholderText('Type a command')).toBeVisible();
  });

  it('leaves the reader before Search Mail focuses the Inbox search field', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
    });
    await renderConnected(gmail.native);
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    );
    await openPalette(
      await screen.findByRole('header', { name: 'Saturday, by the river?' }),
    );
    await act(async () => {
      await fireEvent.press(
        openedPalette().getByRole('button', { name: 'Search Mail' }),
      );
    });
    expect(screen.queryByPlaceholderText('Type a command')).toBeNull();
    expect(screen.queryByText('oliver@example.invalid')).toBeNull();
    expect(screen.getByRole('search')).toBeVisible();
  });

  it('navigates Settings from the account page, keeps the palette there and returns to the Inbox from it', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
    });
    await renderConnected(gmail.native);
    await screen.findByRole('button', {
      name: 'Unread. Oliver Park. Saturday, by the river?',
    });
    const press = async (name: string) => {
      await act(async () => {
        await fireEvent.press(screen.getByRole('button', { name }));
      });
    };
    const destinations = [
      'Account & Devices',
      'Email Accounts',
      'Language',
      'Privacy & Data',
    ];
    // The account page opens on the list of Settings destinations.
    await press('Account');
    await expect(
      screen.findByRole('header', { name: 'Settings' }),
    ).resolves.toBeVisible();
    for (const name of destinations) {
      expect(screen.getByRole('button', { name })).toBeVisible();
    }
    expect(screen.getByRole('button', { name: 'Open Inbox' })).toBeVisible();
    // A destination pushes over the list, and the system Back returns to it.
    await press('Account & Devices');
    await expect(pushedSettings()).resolves.toBe('Account & Devices');
    expect(
      screen.getByText('alex@example.invalid is connected on this device.'),
    ).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Email Accounts' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Open Inbox' })).toBeVisible();
    await act(async () => {
      await fireEvent(screen.getByTestId('settings-destination'), 'dismissed', {
        nativeEvent: { dismissCount: 1 },
      });
    });
    expect(screen.getByRole('header', { name: 'Settings' })).toBeVisible();
    expect(screen.queryByTestId('settings-destination')).toBeNull();
    await press('Email Accounts');
    await expect(pushedSettings()).resolves.toBe('Email Accounts');
    expect(screen.getByRole('header', { name: 'Accounts' })).toBeVisible();
    // The pushed page's system title takes no palette swipe; the list's title keeps it.
    await act(async () => {
      await fireEvent(screen.getByTestId('settings-destination'), 'dismissed', {
        nativeEvent: { dismissCount: 1 },
      });
    });
    await openPalette(screen.getByRole('header', { name: 'Settings' }));
    expect(
      openedPalette().getByRole('button', {
        name: 'Reply. Select a Thread',
      }),
    ).toBeDisabled();
    await act(async () => {
      await fireEvent.press(
        openedPalette().getByRole('button', { name: 'Inbox' }),
      );
    });
    expect(screen.queryByPlaceholderText('Type a command')).toBeNull();
    expect(screen.queryByRole('header', { name: 'Settings' })).toBeNull();
    await expect(
      screen.findByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    ).resolves.toBeVisible();
    // The list's Back closes Settings over what it covered.
    await press('Account');
    await press('Back');
    expect(screen.queryByRole('header', { name: 'Settings' })).toBeNull();
    expect(
      screen.getByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    ).toBeVisible();
  });

  it('drops an open palette when the gate replaces the Inbox', async () => {
    expect.hasAssertions();
    const listenersBeforeRender = jest.mocked(AppState.addEventListener).mock
      .calls.length;
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const { synthetic } = await renderConnected(gmail.native);
    await openPalette(await screen.findByRole('header', { name: 'Inbox' }));
    expect(screen.getByPlaceholderText('Type a command')).toBeVisible();
    // Another device removed this one while the app was away with the palette open.
    await synthetic.vault.purge('revoked');
    await act(async () => {
      for (const [, activate] of jest
        .mocked(AppState.addEventListener)
        .mock.calls.slice(listenersBeforeRender)) {
        activate('active');
      }
      await Promise.resolve();
    });
    await expect(
      screen.findByRole('header', { name: 'Your mail,\non your devices.' }),
    ).resolves.toBeVisible();
    expect(screen.queryByPlaceholderText('Type a command')).toBeNull();
  });

  it("runs the preview reader's read state from the palette", async () => {
    expect.hasAssertions();
    const inbox = createPersistentInbox(
      makeMockInboxStorage(),
      createMockMailSession('open-read-relaunch').mail.list,
    );
    function PreviewJourney() {
      const [selected, setSelected] = useState<Selection>();
      return (
        <InboxProvider mailboxes={singleMailbox(inbox, preview)}>
          <CommandPaletteProvider>
            <Inbox
              onSelect={setSelected}
              selected={selected}
            />
            <MessageDetail
              id={selected?.id}
              mailbox={selected?.mailbox}
            />
          </CommandPaletteProvider>
        </InboxProvider>
      );
    }
    await render(<PreviewJourney />);
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    );
    await openPalette(
      screen.getByRole('header', { name: 'Saturday, by the river?' }),
    );
    // Opening it read it, so the palette offers to mark it unread, and that change stands.
    await act(async () => {
      await fireEvent.press(
        openedPalette().getByRole('button', { name: 'Mark as Unread' }),
      );
    });
    await expect(
      screen.findByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    ).resolves.toBeVisible();
  });

  it('opens the palette from a reader that shows no message', async () => {
    expect.hasAssertions();
    const inbox = createPersistentInbox(
      makeMockInboxStorage(),
      createMockMailSession('open-read-relaunch').mail.list,
    );
    await render(
      <InboxProvider mailboxes={singleMailbox(inbox, preview)}>
        <CommandPaletteProvider>
          <MessageDetail
            id="not-in-this-mailbox"
            mailbox={preview}
          />
        </CommandPaletteProvider>
      </InboxProvider>,
    );
    await openPalette(
      await screen.findByRole('header', { name: 'Message unavailable' }),
    );
    expect(
      openedPalette().getByRole('button', {
        name: 'Reply. Select a Thread',
      }),
    ).toBeDisabled();
  });

  it('opens the palette from a reader whose storage is still opening', async () => {
    expect.hasAssertions();
    const opening = Promise.withResolvers<[]>();
    const inbox = createPersistentInbox(
      makeMockInboxStorage(),
      () => opening.promise,
    );
    await render(
      <InboxProvider mailboxes={singleMailbox(inbox, preview)}>
        <CommandPaletteProvider>
          <MessageDetail
            id="opening"
            mailbox={preview}
          />
        </CommandPaletteProvider>
      </InboxProvider>,
    );
    const loading = screen.getByLabelText('Loading message');
    // VoiceOver offers the action only on an accessibility element; the spinner is not one by default.
    expect(loading).toHaveProp('accessible', true);
    await openPalette(loading);
    expect(
      openedPalette().getByRole('button', {
        name: 'Reply. Select a Thread',
      }),
    ).toBeDisabled();
  });

  it('opens the palette from a composer that cannot open its Draft', async () => {
    expect.hasAssertions();
    const inbox = createPersistentInbox(
      makeMockInboxStorage(),
      createMockMailSession('open-read-relaunch').mail.list,
    );
    await render(
      <InboxProvider mailboxes={singleMailbox(inbox, preview)}>
        <CommandPaletteProvider>
          <Composer
            id="not-a-draft"
            onClose={() => undefined}
            onRebind={() => undefined}
          />
        </CommandPaletteProvider>
      </InboxProvider>,
    );
    await openPalette(
      await screen.findByRole('alert', {
        name: 'This Draft is not available.',
      }),
    );
    expect(
      openedPalette().getByRole('button', {
        name: 'Reply. Select a Thread',
      }),
    ).toBeDisabled();
  });
  /* oxlint-enable vitest/max-expects */
});

describe('context menus', () => {
  it("offers a row's, the open message's and its sender's actions in their design order", async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const travel = gmail.createLabel('Travel');
    const oliver = gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
    });
    await renderConnected(gmail.native);
    const row = () =>
      screen.getByRole('button', { name: /Oliver Park\. Saturday/u });
    await screen.findByRole('button', { name: /Oliver Park\. Saturday/u });

    // A row offers its provider's actions, Delete last; Move to Spam stays a row action only.
    await waitFor(() => {
      const listed = contextMenuOf(row());
      expect(menuSections(listed)).toStrictEqual([
        ['Archive'],
        ['Mark as Read', 'Pin'],
        ['Delete'],
      ]);
    });
    // VoiceOver's row actions include Pin and Move to Spam but not the star, which only the
    // Command Palette offers (#2084).
    const rowActions: ReadonlyArray<{ name: string }> =
      row().props.accessibilityActions;
    expect(rowActions.map(({ name }) => name)).toStrictEqual([
      'pin',
      'read',
      'archive',
      'trash',
      'spam',
    ]);

    // The open message's header offers its reader's actions; its sender offers Copy Address
    // and Block Sender….
    await fireEvent.press(row());
    await screen.findByRole('button', { name: 'Folders' });
    const sender = contextMenuOf(screen.getByText('oliver@example.invalid'));
    const message = contextMenuOf(sender);
    expect({
      sender: menuSections(sender),
      message: menuSections(message),
    }).toStrictEqual({
      sender: [['Copy Address'], ['Block Sender…']],
      message: [
        ['Mark as Unread', 'Pin'],
        [['Move to…', ['Travel']], 'Delete'],
      ],
    });
    await chooseFromMenu(sender, 'Copy Address');
    expect(setStringAsync).toHaveBeenLastCalledWith('oliver@example.invalid');
    jest.mocked(setStringAsync).mockClear();
    await fireEvent(
      within(sender).getByText('Oliver Park'),
      'accessibilityAction',
      { nativeEvent: { actionName: 'copy' } },
    );
    expect(setStringAsync).toHaveBeenCalledWith('oliver@example.invalid');
    await chooseFromMenu(message, 'Move to…', 'Travel');
    expect({
      labels: gmail.labelsOf(oliver),
      shown: screen.queryByText('Saturday, by the river?') !== null,
    }).toStrictEqual({ labels: [travel], shown: false });
  });
});

describe('pinning', () => {
  const row = 'Oliver Park. Saturday, by the river?';
  const replyRow = 'Oliver Park. Re: Saturday, by the river?';

  // A Thread of two Gmail messages, its first open in the reader, with Pin storage on this device
  // that refuses the next write while `storage.refusing`. `another` writes that storage without
  // telling the reader's Pins, as storage that was locked for the reader's read.
  async function openThread() {
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const first = gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
      unread: false,
      at: Date.now() - 60_000,
    });
    const reply = gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Re: Saturday, by the river?',
      unread: false,
      thread: first,
    });
    const saved = { revision: 0, document: null as string | null };
    const storage = { refusing: false };
    let pins: Pins | undefined = undefined;
    let another: (() => Pins) | undefined = undefined;
    await renderConnected(gmail.native, 'gmail', {
      pinsFor: (registration) => {
        const native: NativePins = {
          openPins: () =>
            Promise.resolve({
              owner: ownerOf(registration.getSnapshot().snapshot),
              ...saved,
            }),
          commitPins: (owner, revision, document) => {
            if (storage.refusing) {
              storage.refusing = false;
              return Promise.reject(
                Object.assign(new Error('conflict'), { code: 'conflict' }),
              );
            }
            Object.assign(saved, { revision: revision + 1, document });
            return Promise.resolve({ owner, revision: saved.revision });
          },
        };
        pins = createPins(native, registration);
        another = () => createPins(native, registration);
        return pins;
      },
    });
    ok(pins !== undefined && another !== undefined);
    const stored: Pins = pins;
    const elsewhere: () => Pins = another;
    await fireEvent.press(await screen.findByRole('button', { name: row }));
    await screen.findByRole('button', { name: 'Folders' });
    return { gmail, first, reply, pins: stored, another: elsewhere, storage };
  }

  it('says when Pin storage refuses a Pin, and changes nothing', async () => {
    expect.hasAssertions();
    const failed = jest.spyOn(Alert, 'alert').mockReturnValue(undefined);
    const { pins, storage } = await openThread();
    storage.refusing = true;
    await chooseFromMenu(screen.getByLabelText('More'), 'Pin');
    await waitFor(() => {
      expect(failed).toHaveBeenCalledWith(
        'This Thread couldn’t be pinned',
        'The change wasn’t saved on this device, so nothing changed. Try again.',
        [{ text: 'OK' }],
      );
    });
    await expect(pins.pins([alex])).resolves.toStrictEqual([]);
    expect(screen.queryByRole('button', { name: `${row}. Pinned` })).toBeNull();
  });

  it('reads Pins again when the app becomes active', async () => {
    expect.hasAssertions();
    const listeners = jest.mocked(AppState.addEventListener).mock.calls.length;
    const { first, another } = await openThread();
    await act(async () => {
      await another().pin(alex, first);
    });
    expect(screen.queryByRole('button', { name: `${row}. Pinned` })).toBeNull();
    await act(async () => {
      for (const [, activate] of jest
        .mocked(AppState.addEventListener)
        .mock.calls.slice(listeners)) {
        activate('active');
      }
      await Promise.resolve();
    });
    await expect(
      screen.findByRole('button', { name: `${row}. Pinned` }),
    ).resolves.toBeVisible();
  });

  it('pins a Thread from the reader without changing the provider', async () => {
    expect.hasAssertions();
    const { gmail, first, reply, pins } = await openThread();
    await chooseFromMenu(screen.getByLabelText('More'), 'Pin');
    // Both its messages show the marker, and the reader offers Unpin.
    await screen.findByRole('button', { name: `${replyRow}. Pinned` });
    expect(
      screen.getByRole('button', { name: `${row}. Pinned` }),
    ).toBeVisible();
    await expect(pins.pins([alex])).resolves.toMatchObject([
      { connection: alex, thread: first },
    ]);
    expect(menuSections(screen.getByLabelText('More'))[0]).toStrictEqual([
      'Unpin',
      'Mark as Unread',
      'Move to…',
    ]);
    // The provider's star and labels stay as they were.
    expect([...gmail.labelsOf(first), ...gmail.labelsOf(reply)]).not.toContain(
      'STARRED',
    );
  });

  it('unpins the whole Thread from one of its rows', async () => {
    expect.hasAssertions();
    const { first, pins } = await openThread();
    await act(async () => {
      await pins.pin(alex, first);
    });
    const pinnedReply = await screen.findByRole('button', {
      name: `${replyRow}. Pinned`,
    });
    expect(menuSections(contextMenuOf(pinnedReply))).toStrictEqual([
      ['Archive'],
      ['Mark as Unread', 'Unpin'],
      ['Delete'],
    ]);
    await chooseFromMenu(contextMenuOf(pinnedReply), 'Unpin');
    await expect(
      screen.findByRole('button', { name: row }),
    ).resolves.toBeVisible();
    expect(screen.getByRole('button', { name: replyRow })).toBeVisible();
    await expect(pins.pins([alex])).resolves.toStrictEqual([]);
  });

  it('pins the open message’s Thread from the Command Palette', async () => {
    expect.hasAssertions();
    await openThread();
    await openPalette(
      screen.getByRole('header', { name: 'Saturday, by the river?' }),
    );
    await act(async () => {
      await fireEvent.press(
        openedPalette().getByRole('button', { name: 'Pin' }),
      );
    });
    await expect(
      screen.findByRole('button', { name: `${row}. Pinned` }),
    ).resolves.toBeVisible();
  });
});
