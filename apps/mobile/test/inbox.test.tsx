import type { NativeGmailMailbox } from '@private-email/mail-core/gmail-inbox';

import { gmailAction } from '@private-email/mail-core/gmail-actions';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import {
  createMailboxes,
  singleMailbox,
} from '@private-email/mail-core/mailboxes';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import {
  createRegistration,
  defaultProfile,
} from '@private-email/mail-core/registration';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { makeMockInboxStorage } from '@private-email/mail-core/testing/mock-storage';
import { createRegistrationScenario } from '@private-email/mail-core/testing/registration-scenarios';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-vault';
import { palette } from '@private-email/mail-core/theme';
import {
  act,
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
  AppState,
  Dimensions,
  Linking,
  StyleSheet,
  View,
} from 'react-native';

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
import { RegistrationGate } from '../src/registration-gate.tsx';
import { Mailboxes } from '../src/sidebar.tsx';
import { started } from './started.ts';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires string module names.
jest.mock('expo-clipboard', () => ({ setStringAsync: jest.fn() }));

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

const modalFor = (panel: ReturnType<typeof screen.getByTestId>) => {
  let modal = panel.parent;
  while (modal !== null && modal.props.animationType === undefined) {
    modal = modal.parent;
  }
  return modal;
};

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

  it.each(['light', 'dark'] as const)(
    'keeps the selected row legible after focus leaves in %s appearance',
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
        await fireEvent(message, 'focus');
        expect(message).toHaveStyle({ borderColor: colors.accentOnFill });
        await fireEvent(message, 'blur');
        expect(message).toHaveStyle({
          backgroundColor: colors.accentFill,
          borderColor: 'transparent',
        });
        expect(within(message).getByText('Oliver Park')).toHaveStyle({
          color: colors.accentOnFill,
          fontWeight: '600',
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
    expect(
      within(row).getByText(
        'The forecast looks good. Coffee first, then the long way home.',
      ),
    ).toHaveProp('numberOfLines', 1);
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

  it.each([false, true])(
    'shows search day dividers only on iPad and one empty notice (isPad=%s)',
    async (isPad) => {
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
          expect(
            screen.getAllByText(
              'No mail saved on this device matches “no matching mail”.',
            ),
          ).toHaveLength(1);
        });
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
      const sheet = within(screen.getByTestId('filters-sheet'));
      expect(sheet.getByRole('header', { name: 'Filters' })).toBeVisible();
      // A single mailbox offers no mailboxes to leave out.
      expect(sheet.queryByText('Include Mail From')).toBeNull();
      const unread = sheet.getByRole('checkbox', { name: 'Unread' });
      expect(unread).toBeChecked();
      // Leaving the sheet discards its edits and restores the applied criterion.
      await fireEvent.press(unread);
      await fireEvent(
        screen.getByTestId('filters-sheet'),
        'accessibilityEscape',
      );
      expect(screen.queryByTestId('filters-sheet')).toBeNull();
      await fireEvent.press(
        screen.getByRole('button', { name: 'Filtered by Unread' }),
      );
      const reopened = within(screen.getByTestId('filters-sheet'));
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
      expect(screen.queryByTestId('filters-sheet')).toBeNull();
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
        within(screen.getByTestId('filters-sheet')).getByLabelText(
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

  it('spans a regular-width window with its bar and opens Filters as a popover above the Filter control', async () => {
    expect.hasAssertions();
    const window = Dimensions.get('window');
    // The Filter control's place in the window, which the test host cannot lay out.
    const measure = jest
      .spyOn(View.prototype, 'measureInWindow')
      .mockImplementation((measured) => {
        measured(240, 770, 124, 48);
      });
    function WindowJourney({
      keyboardLift = 0,
    }: {
      readonly keyboardLift?: number;
    }) {
      const windowBar = useMemo(() => createWindowBar(), []);
      return (
        <WindowBarContext value={windowBar}>
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
      expect(screen.queryByTestId('filters-sheet')).toBeNull();
      // jest-expo's window is 750 by 1334 points.
      expect(screen.getByTestId('filters-popover')).toHaveStyle({
        width: 420,
        left: 240,
        bottom: 1334 - 770 + 8,
      });
      // The popover fades on entry only; the native modal must not animate dismissal.
      expect(modalFor(screen.getByTestId('filters-popover'))).toHaveProp(
        'animationType',
        'none',
      );
      const popover = within(screen.getByTestId('filters-popover'));
      expect(popover.getByRole('header', { name: 'Filters' })).toBeVisible();
      await fireEvent.press(popover.getByRole('checkbox', { name: 'Unread' }));
      measure.mockImplementation((measured) => {
        measured(180, 700, 124, 48);
      });
      await act(() => {
        Dimensions.set({ window: { ...window, width: 1024, height: 768 } });
      });
      expect(screen.getByTestId('filters-popover')).toHaveStyle({
        left: 180,
        bottom: 768 - 700 + 8,
      });
      expect(popover.getByRole('checkbox', { name: 'Unread' })).toHaveProp(
        'accessibilityState',
        { checked: false },
      );
      await fireEvent(
        screen.getByTestId('filters-popover'),
        'accessibilityEscape',
      );
      expect(screen.queryByTestId('filters-popover')).toBeNull();
      await fireEvent(
        bar.getByLabelText('Search senders and subjects'),
        'focus',
      );
      await app.rerender(<WindowJourney keyboardLift={280} />);
      expect(screen.getByTestId('window-bar')).toHaveStyle({ bottom: 300 });
      const edge = screen
        .getAllByTestId('scroll-edge')
        .find((view) => StyleSheet.flatten(view.props.style)?.width === 500);
      expect(edge).toHaveStyle({ bottom: 280 });
    } finally {
      Dimensions.set({ window });
      measure.mockRestore();
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

  it('commits a read change and recovers it after the view remounts', async () => {
    expect.hasAssertions();
    const app = await render(<InboxJourney />);
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Unread. Maya Chen. A little more room to think',
      }),
    );
    await fireEvent.press(screen.getByRole('button', { name: 'Mark as read' }));
    await expect(
      screen.findByRole('button', { name: 'Mark as unread' }),
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
      screen.getByRole('button', { name: 'Mark as unread' }),
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
    await fireEvent.press(screen.getByRole('button', { name: 'Try again' }));
    await expect(screen.findByText('maya@example.com')).resolves.toBeVisible();
  });
});

// The connected Inbox and reader, as the app composes them, over a controlled Gmail mailbox.
function connectedMessage(store: ReturnType<typeof createGmailInbox>) {
  const state = store.getSnapshot();
  if (state.kind !== 'ready' || state.messages[0] === undefined) {
    throw new Error('Expected connected mail');
  }
  return state.messages[0];
}

async function renderConnected(
  native: NativeGmailMailbox,
  provider: 'gmail' | 'microsoft-graph' = 'gmail',
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
  function Connected() {
    const [selected, setSelected] = useState<Selection>();
    const [view, setView] = useState<MailboxView>({});
    return (
      <RegistrationGate
        store={store}
        preview={false}>
        <InboxProvider mailboxes={mailboxes}>
          <CommandPaletteProvider>
            <Mailboxes
              view={view}
              onView={setView}
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
  }
  await render(<Connected />);
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

describe('connected Gmail Inbox', () => {
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
        await screen.findAllByText(
          'No mail saved on this device matches “Studio archive”.',
        );
        await fireEvent.press(
          screen.getByRole('button', {
            name: 'Search mail servers for “Studio archive”',
          }),
        );
        await expect(
          screen.findByRole('header', { name: /Top Results\. 1 result/u }),
        ).resolves.toBeVisible();
        expect(screen.getAllByText('Top Results')).toHaveLength(1);
        expect(
          screen.getByRole('button', { name: /Studio archive/u }),
        ).toBeVisible();
      } finally {
        platform.restore();
      }
    },
  );

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
        name: 'Search mail servers for “Studio archive”',
      }),
    );
    expect(screen.getByLabelText('Searching mail servers')).toBeVisible();
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
        name: 'Search mail servers for “Studio budget”',
      }),
    ).resolves.toBeVisible();
    expect(
      screen.queryByRole('button', { name: /\. Studio archive/u }),
    ).toBeNull();
    expect(screen.queryByText('Top Results')).toBeNull();
    await fireEvent.press(
      screen.getByRole('button', {
        name: 'Search mail servers for “Studio budget”',
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
        screen.getByRole('button', { name: 'Allow Gmail access' }),
      );
    });
    expect(connected.authorized).toContain(alex);
    await expect(
      screen.findByText('Arrives after permission returns'),
    ).resolves.toBeVisible();

    gmail.fail({ code: 'unavailable' });
    await act(store.load);
    expect(
      screen.getByText(
        'Gmail could not be reached. Showing mail saved on this device.',
      ),
    ).toBeVisible();
    expect(
      screen.getByRole('header', { name: 'Saturday, by the river?' }),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Try again' }));
    });
    expect(screen.queryByText(/could not be reached/u)).toBeNull();
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
    await createGmailInbox(gmail.native).load();
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
    expect(screen.queryByRole('button', { name: 'Mark as read' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Folders' })).toBeNull();
    expect(
      screen.getByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    ).toHaveProp('accessibilityActions', []);
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
    await fireEvent.press(screen.getByRole('button', { name: 'More' }));
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Mark as read' }),
      );
    });
    expect(
      screen.getByRole('button', {
        name: 'Oliver Park. Saturday, by the river?',
      }),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Star' }));
    });
    expect(screen.getByRole('button', { name: 'Remove star' })).toBeVisible();
    // Every outcome is stated, not only removals that can be undone.
    expect(
      screen.getByText('Starred: “Saturday, by the river?”.'),
    ).toBeVisible();
    // On iPhone, More lists the labels to add or remove, since Move is a picker.
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
    expect(
      screen.getByRole('button', {
        name: 'Oliver Park. Saturday, by the river?. Flagged',
      }),
    ).toBeVisible();
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
    await waitFor(() => {
      expect(gmail.labelsOf(other)).toStrictEqual(['UNREAD', 'TRASH']);
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
          name: 'Oliver Park. Saturday, by the river?. Flagged',
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
        name: 'Oliver Park. Saturday, by the river?. Flagged',
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
    expect(
      screen.getByText(
        'Only the newest mail here is saved on this device. Older mail stays in Gmail.',
      ),
    ).toBeVisible();
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
    await fireEvent.press(
      await screen.findByRole('button', { name: /Old receipt/u }),
    );
    // Trashed mail moves back to the Inbox instead of being archived again.
    expect(screen.queryByRole('button', { name: 'Archive' })).toBeNull();
    await fireEvent.press(screen.getByRole('button', { name: 'More' }));
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Move to Inbox' }),
      );
    });
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
      screen.getByRole('button', { name: 'Search mail servers for “Lunch”' }),
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
    await fireEvent.press(screen.getByRole('button', { name: 'More' }));
    expect(screen.queryByRole('button', { name: 'Move to Inbox' })).toBeNull();

    // A cached label-only message found online still has no Inbox organizing actions.
    await fireEvent.changeText(field, 'Flight');
    await fireEvent.press(
      screen.getByRole('button', { name: 'Search mail servers for “Flight”' }),
    );
    await fireEvent.press(
      await screen.findByRole('button', { name: /Flight to Zagreb/u }),
    );
    expect(screen.queryByRole('button', { name: 'Archive' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'More' })).toBeNull();
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
    await fireEvent.press(screen.getByRole('button', { name: 'More' }));
    expect(screen.getByRole('button', { name: 'Move to Trash' })).toBeVisible();
    await fireEvent.press(screen.getByRole('button', { name: 'Folders' }));
    expect(
      screen.getByText('This Microsoft mailbox has no folders of its own yet.'),
    ).toBeVisible();
  });

  it('closes More on a tap outside it without running an action', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ address: 'casey@example.invalid' });
    const plans = graph.deliver({ subject: 'Garden plans' });
    await renderConnected(graph.native, 'microsoft-graph');
    await fireEvent.press(
      await screen.findByRole('button', {
        name: 'Unread. Rowan Hale. Garden plans',
      }),
    );
    await fireEvent.press(screen.getByRole('button', { name: 'More' }));
    expect(screen.getByRole('button', { name: 'Report spam' })).toBeVisible();
    await fireEvent.press(screen.getByTestId('reader-panel-dismissal'));
    expect(
      screen.getByRole('button', { name: 'More', expanded: false }),
    ).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Report spam' })).toBeNull();
    expect(screen.queryByTestId('reader-panel-dismissal')).toBeNull();
    expect(graph.modifies).toStrictEqual([]);
    expect(graph.folderOf(plans)).toBe('inbox');

    // More reopens, and its actions still work.
    await fireEvent.press(screen.getByRole('button', { name: 'More' }));
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Mark as read' }),
      );
    });
    expect(graph.modifies).toStrictEqual([
      expect.objectContaining({ message: plans }),
    ]);
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
      ['Archive', 'Folders', 'More'].map((name) =>
        screen.getByRole('button', { name }),
      ),
    ).toHaveLength(3);
    expect(screen.queryByRole('button', { name: 'Labels' })).toBeNull();
    await fireEvent.press(screen.getByRole('button', { name: 'More' }));
    expect(
      ['Mark as read', 'Move to Trash', 'Report spam'].map((name) =>
        screen.getByRole('button', { name }),
      ),
    ).toHaveLength(3);
    expect(screen.queryByRole('button', { name: 'Star' })).toBeNull();

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
    // Back lists only this account, since mail moves within it; Cancel moves nothing.
    const sheet = within(screen.getByTestId('move-sheet'));
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
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Retry change' }),
      );
    });
    await waitFor(() => {
      expect(gmail.labelsOf(target.id)).toContain('STARRED');
    });
    expect(screen.queryByRole('button', { name: 'Retry change' })).toBeNull();
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
        screen.getByRole('button', { name: 'Discard change' }),
      );
    });
    await waitFor(() => {
      expect(
        screen.queryByRole('button', { name: 'Discard change' }),
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
        nativeEvent: { actionName: 'star' },
      });
    });
    await expect(
      screen.findByText('This device was removed'),
    ).resolves.toBeVisible();
    expect(screen.queryByText('Saturday, by the river?')).toBeNull();
    expect(screen.queryByText(/stored data has been kept/u)).toBeNull();
  });

  it('reads message bodies from Gmail or this device and opens links only after confirmation', async () => {
    expect.hasAssertions();
    const openURL = jest.spyOn(Linking, 'openURL').mockResolvedValue(true);
    const gmail = createSyntheticGmail();
    gmail.deliver({
      from: 'Maya Chen <maya@example.invalid>',
      subject: 'Garden plan',
      content: {
        html: '<p>See <a href="https://example.invalid/plan">the plan</a>.</p><img src="https://example.invalid/pixel.gif">',
      },
    });
    const store = createGmailInbox(gmail.native);
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
    expect(screen.getByRole('button', { name: 'Load images' })).toBeVisible();
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
    await fireEvent.press(screen.getByRole('button', { name: 'Open link' }));
    expect(openURL).toHaveBeenCalledWith('https://example.invalid/plan');
    expect(screen.queryByText('Open this link in your browser?')).toBeNull();
    // Keyboard access reaches the same confirmation.
    const keyboardLink = screen.getByRole('link', {
      name: 'Open link: the plan',
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
    expect(screen.getByRole('link', { name: 'the plan' })).toBeVisible();

    // Without Gmail, a saved body still opens and another one says it needs downloading.
    gmail.deliver({ subject: 'Not downloaded yet' });
    await act(store.load);
    gmail.fail({ code: 'unavailable' }, { code: 'unavailable' });
    await fireEvent.press(
      screen.getByRole('button', { name: /Not downloaded yet/u }),
    );
    await expect(
      screen.findByText(
        'This message is not saved on this device, and Gmail could not be reached to download it.',
      ),
    ).resolves.toBeVisible();
    await fireEvent.press(screen.getByRole('button', { name: /Garden plan/u }));
    await expect(
      screen.findByTestId('message-webview'),
    ).resolves.toBeOnTheScreen();
    await fireEvent.press(
      screen.getByRole('button', { name: /Not downloaded yet/u }),
    );
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: 'Try again' }));
    });
    await expect(screen.findByText('Synthetic body.')).resolves.toBeVisible();

    // A queued confirmation must not hand off the previous owner's destination.
    await fireEvent.press(screen.getByRole('button', { name: /Garden plan/u }));
    await fireEvent.press(
      screen.getByRole('link', { name: 'Open link: the plan' }),
    );
    const previousOwnerConfirmation = screen.getByRole('button', {
      name: 'Open link',
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
      await screen.findByRole('link', { name: 'Open link: the plan' }),
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
    const openURL = jest.spyOn(Linking, 'openURL').mockResolvedValue(true);
    const copy = jest.mocked(setStringAsync).mockResolvedValue(true);
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      subject: 'Account notice',
      content: {
        html: '<p>Sign in at <a href="https://PHISH.invalid:443">https://bank.invalid</a></p>',
      },
    });
    const store = createGmailInbox(gmail.native);
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
    expect(
      screen.getByText('Check this link before opening it:'),
    ).toBeVisible();
    expect(
      screen.getByText('• The link text shows a different address.'),
    ).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Open link' })).toBeNull();
    await fireEvent.press(screen.getByRole('button', { name: 'Copy link' }));
    expect(copy).toHaveBeenCalledWith('https://PHISH.invalid:443');
    expect(openURL).not.toHaveBeenCalled();
  });
  /* oxlint-enable vitest/max-expects */
});

// Opens the palette as VoiceOver does, through the header's accessibility action.
const openPalette = (header: ReturnType<typeof screen.getByRole>) =>
  fireEvent(header, 'accessibilityAction', {
    nativeEvent: { actionName: 'openCommandPalette' },
  });
// The open palette, apart from the reader's own buttons beneath it.
const openedPalette = () => within(screen.getByTestId('command-palette'));
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
        name: 'Reply. Select a conversation',
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
    // A destination pushes over the list, and the way back returns to it.
    await press('Account & Devices');
    expect(
      screen.getByRole('header', { name: 'Account & Devices' }),
    ).toBeVisible();
    expect(
      screen.getByText('alex@example.invalid is connected on this device.'),
    ).toBeVisible();
    expect(screen.queryByRole('button', { name: 'Email Accounts' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Open Inbox' })).toBeVisible();
    await press('Back to Settings');
    expect(screen.getByRole('header', { name: 'Settings' })).toBeVisible();
    expect(
      screen.queryByRole('header', { name: 'Account & Devices' }),
    ).toBeNull();
    await press('Email Accounts');
    expect(
      screen.getByRole('header', { name: 'Mailbox Connections' }),
    ).toBeVisible();
    await openPalette(screen.getByRole('header', { name: 'Email Accounts' }));
    expect(
      openedPalette().getByRole('button', {
        name: 'Reply. Select a conversation',
      }),
    ).toBeDisabled();
    await act(async () => {
      await fireEvent.press(
        openedPalette().getByRole('button', { name: 'Inbox' }),
      );
    });
    expect(screen.queryByPlaceholderText('Type a command')).toBeNull();
    expect(screen.queryByRole('header', { name: 'Email Accounts' })).toBeNull();
    await expect(
      screen.findByRole('button', {
        name: 'Unread. Oliver Park. Saturday, by the river?',
      }),
    ).resolves.toBeVisible();
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
    await act(async () => {
      await fireEvent.press(
        openedPalette().getByRole('button', { name: 'Mark as read' }),
      );
    });
    await expect(
      screen.findByRole('button', {
        name: 'Oliver Park. Saturday, by the river?',
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
        name: 'Reply. Select a conversation',
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
        name: 'Reply. Select a conversation',
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
        name: 'Reply. Select a conversation',
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

    // A row offers its provider's actions, Delete last; Report Spam stays a row action only.
    await waitFor(() => {
      const listed = contextMenuOf(row());
      expect(menuSections(listed)).toStrictEqual([
        ['Archive'],
        ['Flag', 'Mark as Read'],
        ['Delete'],
      ]);
    });
    await chooseFromMenu(contextMenuOf(row()), 'Flag');
    const rowActions: ReadonlyArray<{ name: string }> =
      row().props.accessibilityActions;
    const flagged = contextMenuOf(row());
    expect({
      starred: gmail.labelsOf(oliver).includes('STARRED'),
      menu: menuSections(flagged)[1],
      spam: rowActions.some(({ name }) => name === 'spam'),
    }).toStrictEqual({
      starred: true,
      menu: ['Unflag', 'Mark as Read'],
      spam: true,
    });

    // The open message's header offers its reader's actions; its sender offers Copy Address.
    await fireEvent.press(row());
    await screen.findByRole('button', { name: 'Folders' });
    const sender = contextMenuOf(screen.getByText('oliver@example.invalid'));
    const message = contextMenuOf(sender);
    expect({
      sender: menuSections(sender),
      message: menuSections(message),
    }).toStrictEqual({
      sender: [['Copy Address']],
      message: [
        ['Mark as Read', 'Unflag'],
        [['Move Message', ['Travel']], 'Delete Message'],
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
    await chooseFromMenu(message, 'Move Message', 'Travel');
    expect({
      labels: gmail.labelsOf(oliver),
      shown: screen.queryByText('Saturday, by the river?') !== null,
    }).toStrictEqual({ labels: ['UNREAD', 'STARRED', travel], shown: false });
  });
});
