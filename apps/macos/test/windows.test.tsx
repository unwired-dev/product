import { ok } from 'node:assert/strict';

import type { ReactNode } from 'react';
import type { AppStateStatus, TurboModule } from 'react-native';

import { createDrafts } from '@private-email/mail-core/drafts';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import {
  createMailboxes,
  singleMailbox,
} from '@private-email/mail-core/mailboxes';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createRegistration } from '@private-email/mail-core/registration';
import { defaultProfile } from '@private-email/mail-core/registration';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { makeMockInboxStorage } from '@private-email/mail-core/testing/mock-storage';
import { createRegistrationScenario } from '@private-email/mail-core/testing/registration-scenarios';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-vault';
import { palette } from '@private-email/mail-core/theme';
import Clipboard from '@react-native-clipboard/clipboard';
import {
  act,
  fireEvent,
  render,
  within,
  waitFor,
} from '@testing-library/react-native';
import {
  AccessibilityInfo,
  Alert,
  AppState,
  DeviceEventEmitter,
  ScrollView,
  TurboModuleRegistry,
  View,
} from 'react-native';

import type { mailboxes } from '../src/private-storage.ts';
import type { usePalette } from '../src/theme.ts';

import { InboxProvider } from '../src/mailbox.tsx';
import { AccountContext, RegistrationGate } from '../src/registration-gate.tsx';
import { PreviewWindow as InboxWindow } from '../src/window.tsx';
import { started } from './started.ts';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Inject a real Draft store through the app's singleton boundary.
jest.mock('../src/registration.ts', () => ({
  ...jest.requireActual('../src/registration.ts'),
}));

const alex = syntheticMailboxes['alex@example.invalid'];
const connectedMailboxes = JSON.stringify([
  { id: alex, address: 'alex@example.invalid', state: 'connected' },
]);
// Every window's Inbox reads this mailbox list, as the app's module does.
const showMailboxes = (list: typeof mailboxes) => {
  jest.replaceProperty(
    jest.requireMock<{ mailboxes: typeof mailboxes }>(
      '../src/private-storage.ts',
    ),
    'mailboxes',
    list,
  );
};

// Substitute only the native menu boundary; other native lookups keep their host behavior.
const commandModule = (menu: TurboModule) => {
  const get = TurboModuleRegistry.get.bind(TurboModuleRegistry);
  return jest
    .spyOn(TurboModuleRegistry, 'get')
    .mockImplementation((name) =>
      name === 'UnwiredCommands' ? menu : get(name),
    );
};

const maya = 'Unread. Maya Chen. A little more room to think';
const oliver = 'Unread. Oliver Park. Saturday, by the river?';

function Windows({
  first,
  second,
}: {
  readonly first: boolean;
  readonly second: boolean;
}) {
  return (
    <View>
      {first ? (
        <InboxWindow
          key="first"
          windowId="first"
        />
      ) : null}
      {second ? (
        <InboxWindow
          key="second"
          windowId="second"
        />
      ) : null}
    </View>
  );
}

// A palette command's row in the list, which native layout places, around its button.
const rowOf = (button: ReturnType<ReturnType<typeof within>['getByRole']>) => {
  const row = button.parent;
  if (row === null) {
    throw new Error('Expected the command row around its button');
  }
  return row;
};

// The native context menu around a rendered control, its item titles by section, and choosing one.
type MenuNode = ReturnType<ReturnType<typeof within>['getByText']>;
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

describe('mac window selection with the shared mock mailbox', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Each test owns a fresh native-boundary store.
  beforeEach(() => {
    const fixture = createPersistentInbox(
      makeMockInboxStorage(),
      createMockMailSession('open-read-relaunch').mail.list,
    );
    showMailboxes(singleMailbox(fixture, 'preview'));
  });

  /* oxlint-disable vitest/max-expects -- One editor crosses expansion, reader changes and durable Close. */
  it('keeps the open Draft and history while selecting the reader beneath its overlay', async () => {
    expect.hasAssertions();
    const connection = {
      id: alex,
      address: 'alex@example.invalid',
      state: 'connected',
      profile: defaultProfile,
      provider: 'gmail',
    } as const;
    const account = {
      snapshot: {
        kind: 'connected',
        productAccountId: 'synthetic-product-account',
        signInProvider: 'google',
        mailboxes: connectedMailboxes,
      },
      busy: false,
      failed: false,
    } as const;
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, {
      subscribe: () => () => undefined,
      getSnapshot: () => account,
    });
    const replacement = jest.replaceProperty(
      jest.requireMock<{ drafts: typeof drafts }>('../src/registration.ts'),
      'drafts',
      drafts,
    );
    const app = await render(
      <AccountContext
        value={{
          mailboxes: [connection],
          openAccount: () => undefined,
          authorizeMailbox: () => Promise.resolve(),
          refreshInbox: (load) => load(),
          profiles: [{ id: 'work', name: 'Work' }],
          createProfile: () => Promise.resolve(undefined),
        }}>
        <InboxWindow windowId="compose" />
      </AccountContext>,
    );
    try {
      await fireEvent(app.getByTestId('window-panes-compose'), 'layout', {
        nativeEvent: { layout: { width: 1000, height: 600 } },
      });
      await fireEvent.press(await app.findByRole('button', { name: maya }));
      await waitFor(() => {
        expect(app.getByRole('button', { name: 'New Message' })).toBeEnabled();
      });
      await fireEvent.press(
        await app.findByRole('button', { name: 'New Message' }),
      );
      await expect(app.findByTestId('composer-overlay')).resolves.toHaveStyle({
        height: 420,
        left: 604,
      });
      expect(app.queryByLabelText('Search senders and subjects')).toBeNull();
      expect(app.queryByRole('button', { name: 'New Message' })).toBeNull();
      await fireEvent.press(app.getByRole('button', { name: 'Hide Sidebar' }));
      expect(app.getByTestId('composer-overlay')).toHaveStyle({ left: 352 });
      await fireEvent.press(app.getByRole('button', { name: 'Show Sidebar' }));
      expect(app.getByTestId('composer-overlay')).toHaveStyle({ left: 604 });
      await fireEvent.changeText(
        app.getByLabelText('Message body'),
        'Keep this draft.',
      );
      await fireEvent.changeText(app.getByLabelText('To'), 'unfinished');
      await fireEvent(
        app.getByLabelText('Mail Profile, Primary Profile'),
        'select',
        { nativeEvent: { id: 'profile\nwork' } },
      );
      expect(app.getByLabelText('Mail Profile, Primary Profile')).toBeVisible();
      expect(app.getByLabelText('To')).toHaveProp('value', 'unfinished');
      // The hidden floating bar retains its command, which still guards the current Draft.
      await fireEvent.press(
        app.getByRole('button', { name: 'Open Command Palette' }),
      );
      await fireEvent.press(
        within(app.getByTestId('command-palette')).getByRole('button', {
          name: 'New Message',
        }),
      );
      expect(app.getByLabelText('To')).toHaveProp('value', 'unfinished');
      await fireEvent.press(app.getByRole('button', { name: 'Expand' }));
      expect(app.queryByLabelText('Search senders and subjects')).toBeNull();
      // Search Mail collapses the expanded composer to reveal the Inbox search field, keeping the Draft.
      await fireEvent.press(
        app.getByRole('button', { name: 'Open Command Palette' }),
      );
      await act(async () => {
        await fireEvent.press(
          within(app.getByTestId('command-palette')).getByRole('button', {
            name: 'Search Mail',
          }),
        );
      });
      expect(app.getByLabelText('Search senders and subjects')).toBeVisible();
      expect(app.getByRole('button', { name: 'Expand' })).toBeVisible();
      await fireEvent.press(app.getByRole('button', { name: oliver }));
      expect(app.getByLabelText('Message body')).toHaveTextContent(
        'Keep this draft.',
      );
      expect(app.getByLabelText('To')).toHaveProp('value', 'unfinished');
      await fireEvent.press(app.getByRole('button', { name: 'Close' }));
      expect(
        app.getByRole('alert', {
          name: 'Correct or remove the invalid address to close this Draft.',
        }),
      ).toBeVisible();
      await fireEvent.press(app.getByRole('button', { name: 'Undo' }));
      await fireEvent.press(app.getByRole('button', { name: 'Undo' }));
      expect(app.getByLabelText('Message body')).not.toHaveTextContent(
        'Keep this draft.',
      );
      await fireEvent.press(app.getByRole('button', { name: 'Redo' }));
      await fireEvent.press(app.getByRole('button', { name: 'Close' }));
      await expect(app.findByText('oliver@example.com')).resolves.toBeVisible();
      expect(app.queryByLabelText('Message body')).toBeNull();
      await fireEvent.press(app.getByRole('button', { name: 'New Message' }));
      expect(app.getByRole('button', { name: 'Expand' })).toBeVisible();
      expect(app.queryByLabelText('Search senders and subjects')).toBeNull();
    } finally {
      await app.unmount();
      replacement.restore();
    }
  });
  /* oxlint-enable vitest/max-expects */

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
        const app = await render(
          <Windows
            first
            second={false}
          />,
        );
        const message = await app.findByRole('button', { name: maya });
        expect(message).toHaveStyle({ backgroundColor: 'transparent' });
        expect(
          within(message).getByText('A little more room to think'),
        ).toHaveStyle({ fontWeight: '600' });
        await fireEvent.press(message);
        await fireEvent(message, 'focus');
        expect(message).toHaveStyle({ borderColor: colors.accentOnFill });
        await fireEvent(message, 'blur');
        expect(message).toHaveStyle({
          backgroundColor: colors.accentFill,
          borderColor: 'transparent',
        });
        expect(within(message).getByText('Maya Chen')).toHaveStyle({
          color: colors.accentOnFill,
          fontWeight: '600',
        });
      } finally {
        paletteSpy.mockRestore();
      }
    },
  );

  it('hides the Mailboxes sidebar in a narrow window until its toggle shows it', async () => {
    expect.hasAssertions();
    const app = await render(
      <Windows
        first
        second={false}
      />,
    );
    const window = app.getByTestId('inbox-window-first');
    await expect(
      app.findByRole('button', { name: 'All inboxes' }),
    ).resolves.toBeVisible();
    await fireEvent(window, 'layout', {
      nativeEvent: { layout: { width: 900 } },
    });
    expect(app.queryByRole('button', { name: 'All inboxes' })).toBeNull();
    await fireEvent.press(app.getByRole('button', { name: 'Show Sidebar' }));
    expect(app.getByRole('button', { name: 'All inboxes' })).toBeVisible();
    // The toggle's choice outlives later resizing.
    await fireEvent(window, 'layout', {
      nativeEvent: { layout: { width: 1280 } },
    });
    await fireEvent.press(app.getByRole('button', { name: 'Hide Sidebar' }));
    expect(app.queryByRole('button', { name: 'All inboxes' })).toBeNull();
  });

  it('shows saved search matches with the default row preview and result count', async () => {
    expect.hasAssertions();
    const app = await render(
      <Windows
        first
        second={false}
      />,
    );
    const row = await app.findByRole('button', { name: maya });
    expect(
      within(row).getByText(
        'I put together a few notes for our studio review on Thursday.',
      ),
    ).toHaveProp('numberOfLines', 1);
    await fireEvent.changeText(
      app.getByLabelText('Search senders and subjects'),
      'Maya',
    );
    expect(
      app.getByRole('header', { name: 'Search. 1 message · Preview mailbox' }),
    ).toBeVisible();
    expect(app.getByText('1 message · Preview mailbox')).toBeVisible();
  });

  it('keeps selections independent and preserves the remaining window when another closes', async () => {
    expect.hasAssertions();
    const app = await render(
      <Windows
        first
        second
      />,
    );
    const first = within(app.getByTestId('inbox-window-first'));
    const second = within(app.getByTestId('inbox-window-second'));
    await fireEvent.press(await first.findByRole('button', { name: maya }));
    await fireEvent.press(await second.findByRole('button', { name: oliver }));
    expect(first.getByText('maya@example.com')).toBeVisible();
    expect(second.getByText('oliver@example.com')).toBeVisible();
    await app.rerender(
      <Windows
        first={false}
        second
      />,
    );
    expect(app.getByText('oliver@example.com')).toBeVisible();
    await app.rerender(
      <Windows
        first
        second
      />,
    );
    const reopened = within(app.getByTestId('inbox-window-first'));
    await expect(
      reopened.findByText('Select a message to start reading.'),
    ).resolves.toBeVisible();
    expect(
      within(app.getByTestId('inbox-window-second')).getByText(
        'oliver@example.com',
      ),
    ).toBeVisible();
  });

  it('can read the same fixture after all views unmount, without carrying a closed selection', async () => {
    expect.hasAssertions();
    const app = await render(
      <Windows
        first
        second={false}
      />,
    );
    await fireEvent.press(await app.findByRole('button', { name: maya }));
    expect(app.getByText('maya@example.com')).toBeVisible();
    await app.rerender(
      <Windows
        first={false}
        second={false}
      />,
    );
    await app.rerender(
      <Windows
        first={false}
        second
      />,
    );
    await expect(
      app.findByText('Select a message to start reading.'),
    ).resolves.toBeVisible();
    await fireEvent.press(await app.findByRole('button', { name: oliver }));
    expect(app.getByText('oliver@example.com')).toBeVisible();
    expect(app.queryByText('maya@example.com')).toBeNull();
  });

  it('shares committed read state while each window keeps its selection', async () => {
    expect.hasAssertions();
    const app = await render(
      <Windows
        first
        second
      />,
    );
    const first = within(app.getByTestId('inbox-window-first'));
    const second = within(app.getByTestId('inbox-window-second'));
    await fireEvent.press(await first.findByRole('button', { name: maya }));
    await fireEvent.press(await second.findByRole('button', { name: oliver }));
    await fireEvent.press(first.getByRole('button', { name: 'Mark as read' }));
    await second.findByRole('button', {
      name: 'Maya Chen. A little more room to think',
    });
    expect(first.getByText('maya@example.com')).toBeVisible();
    expect(second.getByText('oliver@example.com')).toBeVisible();
    await fireEvent.press(second.getByRole('button', { name: 'Mark as read' }));
    await expect(
      first.findByRole('button', {
        name: 'Oliver Park. Saturday, by the river?',
      }),
    ).resolves.toBeVisible();
    await app.rerender(
      <Windows
        first={false}
        second={false}
      />,
    );
    await app.rerender(
      <Windows
        first
        second={false}
      />,
    );
    await expect(
      app.findByRole('button', {
        name: 'Maya Chen. A little more room to think',
      }),
    ).resolves.toBeVisible();
    expect(app.getByText('Select a message to start reading.')).toBeVisible();
  });

  it('scrolls the keyboard-highlighted command into view', async () => {
    expect.hasAssertions();
    const scrollTo = jest
      .spyOn(ScrollView.prototype, 'scrollTo')
      .mockReturnValue(undefined);
    try {
      const app = await render(
        <Windows
          first
          second={false}
        />,
      );
      await fireEvent.press(await app.findByRole('button', { name: oliver }));
      await fireEvent.press(
        app.getByRole('button', { name: 'Open Command Palette' }),
      );
      const palette = within(app.getByTestId('command-palette'));
      // Every row is 40pt tall and the list shows two of them, as native layout would report.
      const names = [
        'Reply. Not available for this message',
        'Forward. Not available for this message',
        'Archive. Not available for this message',
        'Move to…. Not available for this message',
        'Mark as read',
        'Search Mail',
        'Inbox',
      ];
      for (const [index, name] of names.entries()) {
        await fireEvent(
          rowOf(palette.getByRole('button', { name })),
          'layout',
          {
            nativeEvent: { layout: { y: index * 40, height: 40 } },
          },
        );
      }
      const list = app.getByTestId('command-list');
      await fireEvent(list, 'layout', {
        nativeEvent: { layout: { y: 0, height: 80 } },
      });
      const input = app.getByPlaceholderText('Type a command');
      await fireEvent(input, 'keyDown', { nativeEvent: { key: 'ArrowDown' } });
      await fireEvent(input, 'keyDown', { nativeEvent: { key: 'ArrowDown' } });
      expect(palette.getByRole('button', { name: 'Inbox' })).toBeSelected();
      // Inbox ends at 280pt, below the visible 80pt, so the list scrolls until it is the last row.
      expect(scrollTo).toHaveBeenLastCalledWith({ y: 200, animated: false });
      // The wheel then scrolls Search Mail, which starts at 200pt, out of view above.
      await fireEvent(list, 'scroll', {
        nativeEvent: { contentOffset: { y: 240 } },
      });
      // Up scrolls until Search Mail is the first row; the first enabled command then brings back
      // the top, with its header and the unavailable commands.
      scrollTo.mockClear();
      await fireEvent(input, 'keyDown', { nativeEvent: { key: 'ArrowUp' } });
      await fireEvent(input, 'keyDown', { nativeEvent: { key: 'ArrowUp' } });
      expect(scrollTo.mock.calls).toStrictEqual([
        [{ y: 200, animated: false }],
        [{ y: 0, animated: false }],
      ]);
      // A new query highlights its first match, so the list returns to the top to show it.
      scrollTo.mockClear();
      await fireEvent.changeText(input, 'in');
      expect(scrollTo).toHaveBeenLastCalledWith({ y: 0, animated: false });
      expect(palette.getByRole('button', { name: 'Inbox' })).toBeSelected();
    } finally {
      scrollTo.mockRestore();
    }
  });

  it("runs the preview reader's read state from the palette", async () => {
    expect.hasAssertions();
    const app = await render(
      <Windows
        first
        second={false}
      />,
    );
    await fireEvent.press(await app.findByRole('button', { name: oliver }));
    await fireEvent.press(
      app.getByRole('button', { name: 'Open Command Palette' }),
    );
    await act(async () => {
      await fireEvent.press(
        within(app.getByTestId('command-palette')).getByRole('button', {
          name: 'Mark as read',
        }),
      );
    });
    await expect(
      app.findByRole('button', {
        name: 'Oliver Park. Saturday, by the river?',
      }),
    ).resolves.toBeVisible();
  });

  /* oxlint-disable vitest/max-expects -- One journey proves the bar, the fixed order, narrowing and the keys. */
  it('opens the Command Palette from the window bar and drives it with the keyboard', async () => {
    expect.hasAssertions();
    const app = await render(
      <Windows
        first
        second={false}
      />,
    );
    await app.findByRole('button', { name: maya });
    await fireEvent.press(
      app.getByRole('button', { name: 'Open Command Palette' }),
    );
    const input = app.getByPlaceholderText('Type a command');
    // Nothing open: mail commands stay listed, disabled, before App and Go To.
    expect(
      app.getByRole('button', { name: 'Reply. Select a conversation' }),
    ).toBeDisabled();
    const headers = app
      .getAllByRole('header')
      .map((item) => String(item.props.accessibilityLabel));
    expect(headers.indexOf('Selected Message')).toBeLessThan(
      headers.indexOf('App'),
    );
    expect(headers.indexOf('App')).toBeLessThan(headers.indexOf('Go To'));
    await fireEvent.changeText(input, 'se');
    expect(app.getByRole('button', { name: 'Search Mail' })).toBeVisible();
    expect(app.queryByRole('button', { name: 'Inbox' })).toBeNull();
    await fireEvent.changeText(input, '');
    // Down selects the next command that can run; Return runs it and closes the palette.
    await fireEvent(input, 'keyDown', { nativeEvent: { key: 'ArrowDown' } });
    expect(app.getByRole('button', { name: 'Inbox' })).toBeSelected();
    await fireEvent(input, 'submitEditing');
    expect(app.queryByPlaceholderText('Type a command')).toBeNull();
    // Escape closes it too, back to the visible input.
    await fireEvent.press(
      app.getByRole('button', { name: 'Open Command Palette' }),
    );
    await fireEvent(app.getByPlaceholderText('Type a command'), 'keyPress', {
      nativeEvent: { key: 'Escape' },
    });
    expect(app.queryByPlaceholderText('Type a command')).toBeNull();
    // So does a click anywhere outside the bar and its panel.
    await fireEvent.press(
      app.getByRole('button', { name: 'Open Command Palette' }),
    );
    await fireEvent.press(app.getByRole('button', { name: 'Close commands' }));
    expect(app.queryByPlaceholderText('Type a command')).toBeNull();
    expect(
      app.getByRole('button', { name: 'Open Command Palette' }),
    ).toBeVisible();
  });
  /* oxlint-enable vitest/max-expects */
});

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

// A Google Product Account connected to alex@example.invalid over the synthetic vault, with its
// Recovery Key confirmed so the gate opens the Inbox; `authorized` lists each mailbox authorization.
async function connectedRegistration() {
  const synthetic = await createRegistrationScenario('registration-success');
  const authorized: Array<string | null> = [];
  const registration = createRegistration({
    ...synthetic.vault,
    signInMailbox: (connection, suggest, provider) => {
      authorized.push(connection);
      return synthetic.vault.signInMailbox(connection, suggest, provider);
    },
  });
  await registration.register('google');
  await registration.addMailbox();
  await registration.confirmRecoveryKey(
    synthetic.device.productSync.vault?.recoveryKey?.slice(-4) ?? '',
  );
  return { synthetic, registration, authorized };
}

describe('mac windows over a connected Gmail mailbox', () => {
  it.each([
    ['Travel', 'Inbox', true],
    ['Inbox', 'Travel', false],
  ] as const)(
    'keeps the %s reader according to its own view when archiving from %s',
    async (opened, browsing, remains) => {
      expect.hasAssertions();
      const gmail = createSyntheticGmail();
      const travel = gmail.createLabel('Travel');
      const flight = gmail.deliver({ subject: 'Flight to Zagreb' });
      gmail.setLabel(flight, travel, true);
      showMailboxes(singleMailbox(createGmailInbox(gmail.native), alex));
      const app = await render(
        <Windows
          first
          second={false}
        />,
      );
      await fireEvent.press(
        await app.findByRole('button', {
          name: new RegExp(`^${opened}\\. In`, 'u'),
        }),
      );
      await fireEvent.press(
        await app.findByRole('button', { name: /Flight to Zagreb/u }),
      );
      await fireEvent.press(
        await app.findByRole('button', {
          name: new RegExp(`^${browsing}\\. In`, 'u'),
        }),
      );
      await act(async () => {
        await fireEvent(
          await app.findByRole('button', { name: /Flight to Zagreb/u }),
          'accessibilityAction',
          { nativeEvent: { actionName: 'archive' } },
        );
      });
      const reader = app.queryByRole('header', { name: 'Flight to Zagreb' });
      expect(reader !== null).toBe(remains);
    },
  );

  it('keeps Gmail view selection independent across windows and restores Trash mail', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const travel = gmail.createLabel('Travel');
    const flight = gmail.deliver({
      subject: 'Archived flight',
      content: { text: 'Your seat is booked.' },
    });
    gmail.setLabel(flight, travel, true);
    gmail.archive(flight);
    const receipt = gmail.deliver({ subject: 'Old receipt' });
    gmail.setLabel(receipt, 'TRASH', true);
    gmail.setLabel(receipt, 'INBOX', false);
    showMailboxes(singleMailbox(createGmailInbox(gmail.native), alex));
    const app = await render(
      <Windows
        first
        second
      />,
    );
    try {
      const first = within(app.getByTestId('inbox-window-first'));
      const second = within(app.getByTestId('inbox-window-second'));
      await fireEvent.press(
        await first.findByRole('button', { name: /^Travel\. In/u }),
      );
      await fireEvent.press(
        await first.findByRole('button', { name: /Archived flight/u }),
      );
      await expect(
        first.findByText('Your seat is booked.'),
      ).resolves.toBeVisible();
      await fireEvent.press(
        await second.findByRole('button', { name: /^Trash\. In/u }),
      );
      await fireEvent.press(
        await second.findByRole('button', { name: /Old receipt/u }),
      );
      expect(first.getByRole('header', { name: 'Travel' })).toBeVisible();
      expect(first.getByText('Your seat is booked.')).toBeVisible();
      await fireEvent.press(
        second.getByRole('button', { name: 'Move to Inbox' }),
      );
      await waitFor(() => {
        expect(gmail.labelsOf(receipt)).toContain('INBOX');
      });
      expect(second.queryByRole('button', { name: /Old receipt/u })).toBeNull();
      expect(gmail.labelsOf(receipt)).not.toContain('TRASH');
    } finally {
      await app.unmount();
      jest.mocked(AccessibilityInfo.announceForAccessibility).mockClear();
    }
  });

  it('uses Inbox actions for online results while another window caches a Gmail label', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const travel = gmail.createLabel('Travel');
    const flight = gmail.deliver({ subject: 'Archived flight' });
    gmail.setLabel(flight, travel, true);
    gmail.archive(flight);
    gmail.deliver({ subject: 'Lunch on Friday' });
    showMailboxes(singleMailbox(createGmailInbox(gmail.native), alex));
    const app = await render(
      <Windows
        first
        second
      />,
    );
    try {
      const first = within(app.getByTestId('inbox-window-first'));
      const second = within(app.getByTestId('inbox-window-second'));
      await fireEvent.press(
        await first.findByRole('button', { name: /^Travel\. In/u }),
      );
      await first.findByRole('button', { name: /Archived flight/u });
      await fireEvent.press(
        await second.findByRole('button', { name: /^Trash\. In/u }),
      );
      // Online results come from the mailbox, independently of this window's Trash view.
      const field = second.getByLabelText('Search senders and subjects');
      await fireEvent.changeText(field, 'Lunch');
      await fireEvent.press(
        second.getByRole('button', { name: 'Search mail servers for “Lunch”' }),
      );
      await fireEvent.press(
        await second.findByRole('button', { name: /Lunch on Friday/u }),
      );
      expect(second.getByRole('button', { name: 'Archive' })).toBeVisible();
      expect(
        second.queryByRole('button', { name: 'Move to Inbox' }),
      ).toBeNull();

      // The other window's cached label does not grant this online result Inbox actions.
      await fireEvent.changeText(field, 'Archived');
      await fireEvent.press(
        second.getByRole('button', {
          name: 'Search mail servers for “Archived”',
        }),
      );
      await fireEvent.press(
        await second.findByRole('button', { name: /Archived flight/u }),
      );
      expect(second.queryByRole('button', { name: 'Archive' })).toBeNull();
      expect(second.queryByRole('button', { name: 'Show labels' })).toBeNull();
    } finally {
      await app.unmount();
      jest.mocked(AccessibilityInfo.announceForAccessibility).mockClear();
    }
  });

  it('keeps Command-P from opening behind a link confirmation in its window', async () => {
    expect.hasAssertions();
    const menu: TurboModule &
      Readonly<{
        addListener: () => void;
        removeListeners: () => void;
        saveFocus: ReturnType<typeof jest.fn>;
        restoreFocus: () => void;
        setWindowProfile: () => void;
      }> = {
      addListener: () => undefined,
      removeListeners: () => undefined,
      saveFocus: jest.fn(),
      restoreFocus: () => undefined,
      setWindowProfile: () => undefined,
    };
    const module = commandModule(menu);
    try {
      const gmail = createSyntheticGmail();
      gmail.deliver({
        subject: 'Garden plan',
        content: {
          html: '<a href="https://example.invalid/plan">the plan</a>',
        },
      });
      showMailboxes(singleMailbox(createGmailInbox(gmail.native), alex));
      const app = await render(
        <Windows
          first
          second
        />,
      );
      const first = within(app.getByTestId('inbox-window-first'));
      const second = within(app.getByTestId('inbox-window-second'));
      await fireEvent.press(
        await first.findByRole('button', { name: /Garden plan/u }),
      );
      await fireEvent.press(
        await first.findByRole('link', { name: 'Open link: the plan' }),
      );
      await act(() => {
        DeviceEventEmitter.emit('openCommandPalette', {
          window: 'inbox-window-first',
        });
      });
      expect(
        first.queryByPlaceholderText('Type a command', {
          includeHiddenElements: true,
        }),
      ).toBeNull();
      expect(menu.saveFocus).not.toHaveBeenCalled();
      await act(() => {
        DeviceEventEmitter.emit('openCommandPalette', {
          window: 'inbox-window-second',
        });
      });
      expect(second.getByPlaceholderText('Type a command')).toBeVisible();
      await fireEvent.press(first.getByRole('button', { name: 'Cancel' }));
      await act(() => {
        DeviceEventEmitter.emit('openCommandPalette', {
          window: 'inbox-window-first',
        });
      });
      expect(first.getByPlaceholderText('Type a command')).toBeVisible();
    } finally {
      module.mockRestore();
    }
  });

  it('keeps confirmations window-local and rejects queued links after replacing a message', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    gmail.deliver({
      subject: 'Garden plan',
      content: { html: '<a href="https://example.invalid/plan">the plan</a>' },
    });
    gmail.deliver({
      subject: 'Not downloaded yet',
      content: { text: 'Synthetic body.' },
    });
    gmail.deliver({
      subject: 'Other window',
      content: {
        html: '<a href="https://example.invalid/other">other plan</a>',
      },
    });
    showMailboxes(singleMailbox(createGmailInbox(gmail.native), alex));
    const app = await render(
      <Windows
        first
        second
      />,
    );
    const first = within(app.getByTestId('inbox-window-first'));
    const second = within(app.getByTestId('inbox-window-second'));
    await fireEvent.press(
      await first.findByRole('button', { name: /Garden plan/u }),
    );
    const gardenView = await first.findByTestId('message-webview');
    const queuedChoice = gardenView.props.onShouldStartLoadWithRequest;
    await fireEvent.press(
      await first.findByRole('link', { name: 'Open link: the plan' }),
    );
    expect({
      firstDestination:
        first.queryByText('https://example.invalid/plan') !== null,
      secondDestination: second.queryByText('https://example.invalid/plan'),
      backgroundRow: first.queryByRole('button', {
        name: /Not downloaded yet/u,
      }),
    }).toStrictEqual({
      firstDestination: true,
      secondDestination: null,
      backgroundRow: null,
    });
    await fireEvent(first.getByRole('button', { name: 'Cancel' }), 'keyDown', {
      nativeEvent: { key: 'Escape' },
    });
    expect(
      first.getByRole('button', { name: /Not downloaded yet/u }),
    ).toBeVisible();
    await fireEvent.press(
      first.getByRole('link', { name: 'Open link: the plan' }),
    );
    await fireEvent.press(
      await second.findByRole('button', { name: /Other window/u }),
    );
    await fireEvent.press(
      await second.findByRole('link', { name: 'Open link: other plan' }),
    );
    await fireEvent.press(
      first.getByRole('button', {
        name: /Not downloaded yet/u,
        includeHiddenElements: true,
      }),
    );
    await expect(first.findByText('Synthetic body.')).resolves.toBeVisible();
    await act(() => {
      queuedChoice({
        url: 'about:blank#unwired-link-0',
        navigationType: 'click',
      });
    });
    expect({
      firstDestination: first.queryByText('https://example.invalid/plan'),
      firstConfirmation: first.queryByText('Open this link in your browser?'),
    }).toStrictEqual({ firstDestination: null, firstConfirmation: null });
    await app.rerender(
      <Windows
        first={false}
        second
      />,
    );
    expect(
      within(app.getByTestId('inbox-window-second')).getByText(
        'https://example.invalid/other',
      ),
    ).toBeVisible();
  });

  /* oxlint-disable vitest/max-expects -- One journey proves both windows across the synchronization states. */
  it('shares the synchronized Inbox and its recovery states while each window keeps its selection', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({
      from: 'Maya Chen <maya@example.invalid>',
      subject: 'A little more room to think',
      snippet: 'Notes for Thursday',
    });
    gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
      snippet: 'Coffee first',
    });
    // Both windows can read the legacy cache while its missing labels are fetched again.
    await createGmailInbox(gmail.native).load();
    await gmail.native.commitMailbox(
      { address: 'alex@example.invalid', generation: '0' },
      gmail.commits.length,
      String(gmail.commits.at(-1)).replaceAll(/,"labels":\[[^\]]*\]/gu, ''),
    );
    const held = holdingListing(gmail.native);
    const { registration, authorized } = await connectedRegistration();
    const list = createMailboxes(
      syntheticConnections({ [alex]: { native: held.native } }),
      registration,
    );
    showMailboxes(list);
    const app = await render(
      <View>
        {['first', 'second'].map((windowId) => (
          <RegistrationGate
            key={windowId}
            store={registration}
            preview={false}>
            <InboxWindow windowId={windowId} />
          </RegistrationGate>
        ))}
      </View>,
    );
    const first = within(await app.findByTestId('inbox-window-first'));
    const second = within(app.getByTestId('inbox-window-second'));
    await fireEvent.press(await first.findByRole('button', { name: maya }));
    await fireEvent.press(await second.findByRole('button', { name: oliver }));
    expect(first.getByText('maya@example.invalid')).toBeVisible();
    expect(second.getByText('oliver@example.invalid')).toBeVisible();
    // Searching one window does not wait for the shared provider listing.
    await fireEvent.changeText(
      first.getByLabelText('Search senders and subjects'),
      'No saved match',
    );
    expect(
      first.getByText('No mail saved on this device matches “No saved match”.'),
    ).toBeVisible();
    expect(second.getByRole('button', { name: oliver })).toBeVisible();
    await fireEvent.changeText(
      first.getByLabelText('Search senders and subjects'),
      '',
    );

    // Each window reads its own message's body; a body another window opened is not read again.
    await expect(first.findByText('Synthetic body.')).resolves.toBeVisible();
    await expect(second.findByText('Synthetic body.')).resolves.toBeVisible();
    await fireEvent.press(second.getByRole('button', { name: maya }));
    expect(second.getByText('maya@example.invalid')).toBeVisible();
    expect(second.getByText('Synthetic body.')).toBeVisible();
    expect(
      gmail.requests.filter(({ query }) => query.get('format') === 'full'),
    ).toHaveLength(2);
    await fireEvent.press(second.getByRole('button', { name: oliver }));
    for (const window of [first, second]) {
      expect(window.queryByRole('button', { name: 'Archive' })).toBeNull();
      expect(window.queryByRole('button', { name: 'Labels' })).toBeNull();
      expect(window.getByRole('button', { name: maya })).toHaveProp(
        'accessibilityActions',
        [],
      );
    }
    await act(async () => {
      held.release();
      await list.load();
    });
    expect(first.getByRole('button', { name: 'Labels' })).toBeVisible();
    expect(second.getByRole('button', { name: 'Labels' })).toBeVisible();
    // Archiving in one window closes its reader and updates the other, which keeps its selection;
    // Undo from either window brings the message back to both.
    await act(async () => {
      await fireEvent.press(first.getByRole('button', { name: 'Archive' }));
    });
    expect(first.getByText('Select a message to start reading.')).toBeVisible();
    expect(second.queryByRole('button', { name: maya })).toBeNull();
    expect(second.getByText('oliver@example.invalid')).toBeVisible();
    expect(
      second.getByLabelText('Archived: “A little more room to think”.'),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(second.getByRole('button', { name: 'Undo' }));
    });
    expect(first.getByRole('button', { name: maya })).toBeVisible();
    expect(second.getByRole('button', { name: maya })).toBeVisible();
    expect(
      gmail.modifies.map(({ add, remove }) => [add, remove]),
    ).toStrictEqual([
      [[], ['INBOX']],
      [['INBOX'], []],
    ]);

    // A VoiceOver row action that removes the selected message closes that reader too; Undo keeps
    // it closed, the other window keeps its selection, and the outcome is announced once.
    const announce = jest.mocked(AccessibilityInfo.announceForAccessibility);
    await fireEvent.press(first.getByRole('button', { name: maya }));
    expect(first.getByText('maya@example.invalid')).toBeVisible();
    await act(async () => {
      await fireEvent(
        first.getByRole('button', { name: maya }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'trash' } },
      );
    });
    expect(first.getByText('Select a message to start reading.')).toBeVisible();
    expect(second.getByText('oliver@example.invalid')).toBeVisible();
    // Each outcome is announced once although both windows show it.
    expect(announce.mock.calls).toStrictEqual([
      ['Archived: “A little more room to think”.'],
      ['Moved back to the Inbox: “A little more room to think”.'],
      ['Moved to Trash: “A little more room to think”.'],
    ]);
    // Each successful notice is text and requests no separate live-region announcement.
    for (const window of [first, second]) {
      const status = window.getByLabelText(
        'Moved to Trash: “A little more room to think”.',
      );
      expect(status).toHaveProp('accessibilityRole', 'text');
      expect(status).not.toHaveProp('accessibilityLiveRegion');
    }
    await act(async () => {
      await fireEvent.press(first.getByRole('button', { name: 'Undo' }));
    });
    expect(first.getByRole('button', { name: maya })).toBeVisible();
    expect(first.getByText('Select a message to start reading.')).toBeVisible();
    expect(second.getByText('oliver@example.invalid')).toBeVisible();
    // The same action again is a new outcome with the same words, and is announced again.
    await act(async () => {
      await fireEvent(
        second.getByRole('button', { name: maya }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'trash' } },
      );
    });
    expect(second.getByText('oliver@example.invalid')).toBeVisible();
    expect(announce).toHaveBeenCalledTimes(5);
    expect(announce).toHaveBeenLastCalledWith(
      'Moved to Trash: “A little more room to think”.',
    );
    await act(async () => {
      await fireEvent.press(second.getByRole('button', { name: 'Undo' }));
    });
    expect(second.getByRole('button', { name: maya })).toBeVisible();

    // A refusal keeps its alert semantics while sharing one explicit announcement.
    gmail.failModify({ status: 400 });
    await act(async () => {
      await fireEvent(
        second.getByRole('button', { name: oliver }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'star' } },
      );
    });
    const refusal =
      'Gmail could not star “Saturday, by the river?”. The Inbox shows it as Gmail has it.';
    for (const window of [first, second]) {
      const status = window.getByRole('alert', { name: refusal });
      expect(status).toBeVisible();
      expect(status).not.toHaveProp('accessibilityLiveRegion');
    }
    expect(
      announce.mock.calls.filter(([message]) => message === refusal),
    ).toStrictEqual([[refusal]]);

    gmail.fail({ status: 401 });
    await act(list.load);
    expect(
      second.getByRole('button', { name: 'Allow Gmail access' }),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(
        first.getByRole('button', { name: 'Allow Gmail access' }),
      );
      await Promise.resolve();
    });
    expect(authorized).toContain(alex);
    gmail.fail({ code: 'unavailable' });
    await act(list.load);
    expect(
      first.getByLabelText(
        'Gmail could not be reached. Showing mail saved on this device.',
      ),
    ).toBeVisible();
    expect(second.getByText('oliver@example.invalid')).toBeVisible();
    // The failed save is visible in both windows after Archive closes its reader, announced once.
    held.becomeCacheOnly();
    await act(async () => {
      await fireEvent.press(second.getByRole('button', { name: 'Archive' }));
    });
    const unsaved =
      'The request to archive “Saturday, by the river?” could not be saved. Showing mail saved on this device. Try again to reconnect, then repeat the change.';
    for (const window of [first, second]) {
      expect(window.getByRole('alert', { name: unsaved })).toBeVisible();
      expect(window.queryByRole('button', { name: 'Undo' })).toBeNull();
    }
    expect(
      second.getByText('Select a message to start reading.'),
    ).toBeVisible();
    expect(
      announce.mock.calls.filter(([message]) => message === unsaved),
    ).toStrictEqual([[unsaved]]);
  });

  it('dispatches a row, the open message and sender context menu actions in their design order', async () => {
    expect.hasAssertions();
    const copy = jest.spyOn(Clipboard, 'setString').mockReturnValue(undefined);
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const travel = gmail.createLabel('Travel');
    const id = gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
    });
    const { registration } = await connectedRegistration();
    showMailboxes(
      createMailboxes(
        syntheticConnections({ [alex]: { native: gmail.native } }),
        registration,
      ),
    );
    const app = await render(
      <RegistrationGate
        store={started(registration)}
        preview={false}>
        <InboxWindow windowId="first" />
      </RegistrationGate>,
    );
    try {
      const window = within(await app.findByTestId('inbox-window-first'));
      const row = await window.findByRole('button', { name: oliver });
      // Issue #905 requires destructive actions last, superseding the Mac frame's grouping.
      expect(menuSections(contextMenuOf(row))).toStrictEqual([
        ['Archive'],
        ['Flag', 'Mark as Read'],
        ['Delete'],
      ]);
      await fireEvent.press(row);
      await window.findByRole('button', { name: 'Labels' });
      const sender = contextMenuOf(window.getByText('oliver@example.invalid'));
      expect(menuSections(sender)).toStrictEqual([['Copy Address']]);
      await chooseFromMenu(sender, 'Copy Address');
      expect(copy).toHaveBeenCalledWith('oliver@example.invalid');
      const senderText = window.getByRole('text', {
        name: 'Oliver Park, oliver@example.invalid',
      });
      copy.mockClear();
      await fireEvent(senderText, 'accessibilityAction', {
        nativeEvent: { actionName: 'copy' },
      });
      expect(copy).toHaveBeenCalledWith('oliver@example.invalid');
      const message = contextMenuOf(sender);
      const received = within(message).getByLabelText(/UTC$/u);
      // Selectable native date text consumes secondary clicks before the message menu.
      expect({
        selectableDate:
          within(received).getByText(/UTC$/u).props.selectable === true,
      }).toStrictEqual({ selectableDate: false });
      expect(menuSections(message)).toStrictEqual([
        ['Mark as Read', 'Flag'],
        [['Move Message', ['Travel']], 'Delete Message'],
      ]);
      await chooseFromMenu(message, 'Delete Message');
      expect(gmail.labelsOf(id)).toContain('TRASH');
      expect(
        window.getByText('Select a message to start reading.'),
      ).toBeVisible();
      expect(gmail.labelsOf(id)).not.toContain(travel);
    } finally {
      await app.unmount();
      copy.mockRestore();
    }
  });

  it('hands a device found removed while organizing to the account page explanation', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({
      from: 'Maya Chen <maya@example.invalid>',
      subject: 'A little more room to think',
    });
    const { registration, synthetic } = await connectedRegistration();
    // As the app composes them: the Inbox hands a removal to the registration store.
    showMailboxes(
      createMailboxes(syntheticConnections({ [alex]: gmail }), registration, {
        removed: () => {
          void registration.deviceRemoved();
        },
      }),
    );
    const app = await render(
      <RegistrationGate
        store={started(registration)}
        preview={false}>
        <InboxWindow windowId="first" />
      </RegistrationGate>,
    );
    const row = await app.findByRole('button', { name: maya });
    // Native code purges this device when the write's Trusted Device check finds it removed.
    await synthetic.vault.purge('revoked');
    gmail.failModify({ code: 'mailbox-revoked' });
    await act(async () => {
      await fireEvent(row, 'accessibilityAction', {
        nativeEvent: { actionName: 'star' },
      });
    });
    await expect(
      app.findByText('This device was removed'),
    ).resolves.toBeVisible();
    expect(app.queryByText('A little more room to think')).toBeNull();
    expect(app.queryByText(/stored data has been kept/u)).toBeNull();
  });
  /* oxlint-enable vitest/max-expects */
});

describe('mac windows of different Mail Profiles', () => {
  // The account lists the Work Profile, so a window AppKit restored with it keeps it.
  function WithWork({ children }: { readonly children: ReactNode }) {
    return (
      <AccountContext
        value={{
          mailboxes: [],
          openAccount: () => undefined,
          authorizeMailbox: () => Promise.resolve(),
          refreshInbox: (load) => load(),
          profiles: [{ id: 'work', name: 'Work' }],
          createProfile: () => Promise.resolve(undefined),
        }}>
        {children}
      </AccountContext>
    );
  }

  it('clears selection and search when a reused window leaves and returns to its Profile', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    gmail.deliver({
      subject: 'Garden plan',
      content: { text: 'Synthetic garden body.' },
    });
    showMailboxes(singleMailbox(createGmailInbox(gmail.native), alex));
    const app = await render(
      <WithWork>
        <InboxWindow windowId="same" />
      </WithWork>,
    );
    await fireEvent.press(
      await app.findByRole('button', { name: /Garden plan/u }),
    );
    await expect(
      app.findByText('Synthetic garden body.'),
    ).resolves.toBeVisible();
    await fireEvent.changeText(
      await app.findByLabelText('Search senders and subjects'),
      'personal search',
    );
    await app.rerender(
      <WithWork>
        <InboxWindow
          windowId="same"
          profile="work"
        />
      </WithWork>,
    );
    expect(app.queryByLabelText('Search senders and subjects')).toBeNull();
    await app.rerender(
      <WithWork>
        <InboxWindow windowId="same" />
      </WithWork>,
    );
    await expect(
      app.findByLabelText('Search senders and subjects'),
    ).resolves.toHaveProp('value', '');
    await expect(
      app.findByRole('button', { name: /Garden plan/u }),
    ).resolves.toBeVisible();
    expect(app.queryByText('Synthetic garden body.')).toBeNull();
  });

  /* oxlint-disable vitest/max-expects -- One journey proves both windows after one switch. */
  it('switches only the window whose Profile Switcher was used, and saves it with that window', async () => {
    expect.hasAssertions();
    const host: TurboModule &
      Readonly<{
        addListener: () => void;
        removeListeners: () => void;
        setWindowProfile: ReturnType<typeof jest.fn>;
      }> = {
      addListener: () => undefined,
      removeListeners: () => undefined,
      setWindowProfile: jest.fn(),
    };
    const module = commandModule(host);
    try {
      const gmail = createSyntheticGmail();
      gmail.deliver({ subject: 'Garden plan' });
      showMailboxes(singleMailbox(createGmailInbox(gmail.native), alex));
      const app = await render(
        <WithWork>
          <Windows
            first
            second
          />
        </WithWork>,
      );
      const first = within(app.getByTestId('inbox-window-first'));
      const second = within(app.getByTestId('inbox-window-second'));
      await first.findByRole('button', { name: /Garden plan/u });
      await fireEvent(
        first.getByLabelText('Mail Profile, Primary Profile'),
        'select',
        { nativeEvent: { id: 'profile\nwork' } },
      );
      // The switched window remounts its contents for the new Profile.
      const switched = within(app.getByTestId('inbox-window-first'));
      await expect(
        switched.findByLabelText('Mail Profile, Work'),
      ).resolves.toBeVisible();
      expect(
        switched.queryByRole('button', { name: /Garden plan/u }),
      ).toBeNull();
      expect(
        second.getByRole('button', { name: /Garden plan/u }),
      ).toBeVisible();
      expect(
        second.getByLabelText('Mail Profile, Primary Profile'),
      ).toBeVisible();
      expect(host.setWindowProfile).toHaveBeenLastCalledWith(
        'inbox-window-first',
        'work',
      );
      expect(host.setWindowProfile).toHaveBeenCalledWith(
        'inbox-window-second',
        defaultProfile,
      );
    } finally {
      module.mockRestore();
    }
  }); /* oxlint-enable vitest/max-expects */

  it('opens a new window in the Startup Profile and a restored window in its own', async () => {
    expect.hasAssertions();
    const nativeRegistration = TurboModuleRegistry.getEnforcing<
      TurboModule & { preference: (key: string) => Promise<unknown> }
    >('UnwiredRegistration');
    const preference = jest
      .spyOn(nativeRegistration, 'preference')
      .mockImplementation((key) =>
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Only the Startup Profile is saved.
        Promise.resolve({ value: key === 'startup-profile' ? 'work' : null }),
      );
    try {
      const gmail = createSyntheticGmail();
      gmail.deliver({ subject: 'Garden plan' });
      showMailboxes(singleMailbox(createGmailInbox(gmail.native), alex));
      const app = await render(
        <WithWork>
          <View>
            <InboxWindow windowId="new" />
            <InboxWindow
              windowId="restored"
              profile={defaultProfile}
            />
          </View>
        </WithWork>,
      );
      const opened = within(app.getByTestId('inbox-window-new'));
      const restored = within(app.getByTestId('inbox-window-restored'));
      await expect(
        opened.findByLabelText('Mail Profile, Work'),
      ).resolves.toBeVisible();
      expect(opened.queryByRole('button', { name: /Garden plan/u })).toBeNull();
      await expect(
        restored.findByRole('button', { name: /Garden plan/u }),
      ).resolves.toBeVisible();
    } finally {
      preference.mockRestore();
    }
  });

  it('names a new Mail Profile and explains a failed creation', async () => {
    expect.hasAssertions();
    const prompt = jest.spyOn(Alert, 'prompt').mockReturnValue(undefined);
    const alert = jest.spyOn(Alert, 'alert').mockReturnValue(undefined);
    const createProfile = jest.fn((_name: string) =>
      Promise.resolve('failed' as const),
    );
    try {
      const inbox = createGmailInbox(createSyntheticGmail().native);
      showMailboxes(singleMailbox(inbox, alex));
      const app = await render(
        <AccountContext
          value={{
            mailboxes: [],
            openAccount: () => undefined,
            authorizeMailbox: () => Promise.resolve(),
            refreshInbox: (load) => load(),
            profiles: [],
            createProfile,
          }}>
          <InboxWindow windowId="create" />
        </AccountContext>,
      );
      await fireEvent(
        await app.findByLabelText('Mail Profile, Primary Profile'),
        'select',
        { nativeEvent: { id: 'profile\nnew' } },
      );
      const buttons = prompt.mock.lastCall?.[2];
      ok(Array.isArray(buttons));
      await act(async () => {
        // A plain-text prompt hands its button the entered text.
        const create = buttons.find(({ text }) => text === 'Create')
          // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- React Native types the value per prompt type.
          ?.onPress as ((value: string) => void) | undefined;
        create?.('Family');
        await Promise.resolve();
      });
      expect(createProfile.mock.calls).toStrictEqual([['Family']]);
      await waitFor(() => {
        expect(alert).toHaveBeenCalledWith(
          'New Mail Profile',
          'The Mail Profile could not be created. Try again.',
          [{ text: 'OK' }],
        );
      });
    } finally {
      prompt.mockRestore();
      alert.mockRestore();
    }
  });

  it('shows each window only its own Profile’s mail from the shared mailbox list', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    gmail.deliver({
      subject: 'Garden plan',
      content: { text: 'Synthetic body.' },
    });
    // A Mailbox Connection listed before Profiles belongs to the Default Profile.
    showMailboxes(singleMailbox(createGmailInbox(gmail.native), alex));
    const app = await render(
      <WithWork>
        <View>
          <InboxWindow windowId="default" />
          <InboxWindow
            profile="work"
            windowId="work"
          />
        </View>
      </WithWork>,
    );
    const shown = within(app.getByTestId('inbox-window-default'));
    const work = within(app.getByTestId('inbox-window-work'));
    await fireEvent.press(
      await shown.findByRole('button', { name: /Garden plan/u }),
    );
    await expect(shown.findByText('Synthetic body.')).resolves.toBeVisible();
    // Another Profile's window reuses the same views and stores yet shows none of that mail.
    expect(work.queryByLabelText('Search senders and subjects')).toBeNull();
    expect(work.queryByRole('button', { name: /Garden plan/u })).toBeNull();
    expect(work.queryByText('Synthetic body.')).toBeNull();
  });
});

describe('mac windows sharing the mailbox list', () => {
  it('opens the mailboxes once per app activation however many windows are open', async () => {
    expect.hasAssertions();
    // Substitute only the platform's dispatch/removal boundary.
    const listeners = new Set<(state: AppStateStatus) => void>();
    const lifecycle = jest
      .spyOn(AppState, 'addEventListener')
      .mockImplementation((_event, listener) => {
        listeners.add(listener);
        return {
          remove: () => {
            listeners.delete(listener);
          },
        };
      });
    const list = singleMailbox(
      createPersistentInbox(makeMockInboxStorage()),
      'preview',
    );
    const load = jest.spyOn(list, 'load');
    const window = () => (
      <InboxProvider mailboxes={list}>
        <View />
      </InboxProvider>
    );
    const activate = () =>
      act(async () => {
        for (const listener of listeners) {
          listener('active');
        }
      });
    const first = await render(window());
    const second = await render(window());
    try {
      // oxlint-disable-next-line vitest/prefer-called-once -- Jest has no toHaveBeenCalledOnce matcher.
      expect(load).toHaveBeenCalledTimes(1);
      await activate();
      expect(load).toHaveBeenCalledTimes(2);
      await first.unmount();
      await activate();
      expect(load).toHaveBeenCalledTimes(3);
      await second.unmount();
      expect(listeners.size).toBe(0);
    } finally {
      await first.unmount();
      await second.unmount();
      load.mockRestore();
      lifecycle.mockRestore();
    }
  });
});
