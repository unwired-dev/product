import { ok } from 'node:assert/strict';

import type { MailboxConnection } from '@private-email/mail-core/registration';
import type { ReactNode } from 'react';
import type { AppStateStatus, TurboModule } from 'react-native';

import { createBlockedSenders } from '@private-email/mail-core/blocked-senders';
import {
  createDrafts,
  draftOf,
  ownerOf,
} from '@private-email/mail-core/drafts';
import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { createInboxPreferences } from '@private-email/mail-core/inbox-preferences';
import { createInboxStore } from '@private-email/mail-core/inbox-store';
import {
  createMailboxes,
  singleMailbox,
} from '@private-email/mail-core/mailboxes';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createPins } from '@private-email/mail-core/pins';
import {
  createRegistration,
  mailboxesOf,
  profilesOf,
} from '@private-email/mail-core/registration';
import { defaultProfile } from '@private-email/mail-core/registration';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { makeMockInboxStorage } from '@private-email/mail-core/testing/mock-storage';
import {
  createRegistrationScenario,
  createTwoProfileRegistration,
} from '@private-email/mail-core/testing/registration-scenarios';
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
  Animated,
  AppState,
  DeviceEventEmitter,
  ScrollView,
  StyleSheet,
  TurboModuleRegistry,
  View,
} from 'react-native';

import type { mailboxes } from '../src/private-storage.ts';
import type { usePalette } from '../src/theme.ts';

import { BlockedSendersContext } from '../src/blocked-senders.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { PinsContext } from '../src/pins.tsx';
import { InboxPreferencesContext } from '../src/preview-lines.tsx';
import { profileChoices } from '../src/profile-choices.ts';
import { AccountContext, RegistrationGate } from '../src/registration-gate.tsx';
import {
  ComposerWindow,
  InboxWindow as RegisteredWindow,
  PreviewWindow as InboxWindow,
} from '../src/window.tsx';
import {
  chooseSheetButton,
  sheetShown,
  sheetsShown,
  unwiredAlert,
} from './native-alert.ts';
import { appleContacts } from './native-contacts.ts';
import {
  chooseMenuItem,
  chooseSubmenuItem,
  dismissMenu,
  menuItems,
  submenuItems,
} from './native-menu.ts';
import {
  blockDomainParent,
  blockDomainSheet,
  closedWindows,
  composerWindows,
  focusedWindows,
  MacWindows,
  openedInboxes,
  settingsWindow,
  toggledSidebars,
} from './settings-window.tsx';
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

// Several mailboxes in one list, as All Inboxes shows them.
type MailboxList = ReturnType<
  typeof singleMailbox<ReturnType<typeof createInboxStore>>
>;
const bothMailboxes = (lists: readonly MailboxList[]) => {
  let parts: ReadonlyArray<ReturnType<MailboxList['getSnapshot']>> = [];
  let shown: ReturnType<MailboxList['getSnapshot']> = [];
  return {
    getSnapshot: () => {
      const next = lists.map((list) => list.getSnapshot());
      if (next.some((part, index) => part !== parts[index])) {
        parts = next;
        shown = next.flat();
      }
      return shown;
    },
    subscribe: (listener: () => void) => {
      const stops = lists.map((list) => list.subscribe(listener));
      return () => {
        for (const stop of stops) {
          stop();
        }
      };
    },
    load: async () => {
      await Promise.all(lists.map(async (list) => list.load()));
    },
  };
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

// Opens a window's Profile Switcher and chooses a Profile Menu item, as a click would.
const chooseProfile = async (
  switcher: Parameters<typeof fireEvent.press>[0],
  title: string,
) => {
  await fireEvent.press(switcher);
  await chooseMenuItem(title);
};

const touch = {
  persist: () => undefined,
  currentTarget: 1,
  nativeEvent: { pageX: 0, pageY: 0, locationX: 0, locationY: 0, timestamp: 0 },
};

// The views inside `node` that take the pointer, such as an Edit Favorites row's drag handle.
type Node = Parameters<typeof fireEvent.press>[0];
function grabbed(node: Node): Node[] {
  return node.children.flatMap((child) => {
    if (typeof child === 'string') {
      return [];
    }
    return child.props.onResponderGrant === undefined
      ? grabbed(child)
      : [child];
  });
}
const handleOf = (node: Node) => grabbed(node).at(0) ?? node;

// Selection fills drawn in a Settings row: its own and any stacked over it.
function fills(row: Parameters<typeof fireEvent.press>[0]) {
  const filled = (node: typeof row) =>
    StyleSheet.flatten(node.props.style)?.backgroundColor ===
    palette.light.accentSelectionSubtle;
  return [row, ...row.queryAll(filled)].filter(filled).length;
}

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

  /* oxlint-disable vitest/max-expects -- One Draft crosses reader changes, Undo and Expand into its window. */
  it('keeps the open Draft and history beneath its overlay until Expand moves it into a New Message window', async () => {
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
    const accountActions = {
      mailboxes: [connection],
      openAccount: () => undefined,
      authorizeMailbox: () => Promise.resolve(),
      refreshInbox: (load: () => Promise<void>) => load(),
      account: 'synthetic-product-account',
      profiles: [{ id: 'work', name: 'Work' }],
      createProfile: () => Promise.resolve(undefined),
      chooseFolders: () => Promise.resolve(true),
    };
    const app = await render(
      <AccountContext value={accountActions}>
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
      // The overlay docks across the reader's full width at its bottom edge.
      await expect(app.findByTestId('composer-overlay')).resolves.toHaveStyle({
        height: 420,
        left: 0,
        right: 0,
        bottom: 0,
      });
      expect(app.queryByLabelText('Search senders and subjects')).toBeNull();
      expect(app.queryByRole('button', { name: 'New Message' })).toBeNull();
      await fireEvent.changeText(
        app.getByLabelText('Message body'),
        'Keep this draft.',
      );
      await fireEvent.changeText(app.getByLabelText('To'), 'unfinished');
      await chooseProfile(
        app.getByLabelText('Profile, Primary Profile'),
        'Work',
      );
      expect(app.getByLabelText('Profile, Primary Profile')).toBeVisible();
      expect(app.getByLabelText('To')).toHaveProp('value', 'unfinished');
      // The hidden floating bar retains its command, which still guards the current Draft.
      await fireEvent.press(
        app.getByRole('button', { name: 'Open Command Palette' }),
      );
      // The open Draft's commands lead, and each section names what its commands act on (#1578).
      expect(
        within(app.getByTestId('command-palette'))
          .getAllByRole('header')
          .map((item) => String(item.props.accessibilityLabel)),
      ).toStrictEqual([
        'Draft',
        'Selected Message · A little more room to think',
        'App',
        'Go To',
      ]);
      await fireEvent.press(
        within(app.getByTestId('command-palette')).getByRole('button', {
          name: 'New Message',
        }),
      );
      await act(async () => {
        chooseSheetButton('Cancel');
      });
      expect(app.getByLabelText('To')).toHaveProp('value', 'unfinished');
      await fireEvent.press(app.getByRole('button', { name: oliver }));
      expect(app.getByLabelText('Message body')).toHaveTextContent(
        'Keep this draft.',
      );
      expect(app.getByLabelText('To')).toHaveProp('value', 'unfinished');
      // The reader's toolbar above the overlay stays usable without closing the Draft (#1211).
      await fireEvent.press(
        app.getByRole('button', { name: 'Mark as Unread' }),
      );
      await expect(
        app.findByRole('button', { name: 'Mark as Read' }),
      ).resolves.toBeVisible();
      expect(app.getByLabelText('To')).toHaveProp('value', 'unfinished');
      await fireEvent.press(app.getByRole('button', { name: 'Close' }));
      await act(async () => {
        chooseSheetButton('Save');
      });
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
      await fireEvent.changeText(app.getByLabelText('To'), 'unfinished');
      // A concurrent storage writer wins the original identifier while Expand is saving.
      const before = drafts.getSnapshot();
      ok(before.kind === 'ready');
      const [original] = before.drafts;
      ok(original);
      const writer = createDrafts(storage.native, {
        subscribe: () => () => undefined,
        getSnapshot: () => account,
      });
      await writer.load();
      await writer.update({ ...original, subject: 'Other writer' }, original);
      storage.hold();
      try {
        await fireEvent.changeText(
          app.getByLabelText('Subject'),
          'Moving editor',
        );
        // Expand waits for saving, typed recipient text included, and follows its conflict copy.
        await fireEvent.press(app.getByRole('button', { name: 'Expand' }));
        expect(app.getByTestId('composer-overlay')).toBeVisible();
      } finally {
        storage.release();
      }
      await waitFor(() => {
        expect(app.queryByTestId('composer-overlay')).toBeNull();
      });
      await expect(app.findByText('oliver@example.com')).resolves.toBeVisible();
      const [opened] = composerWindows();
      ok(opened !== undefined);
      expect(opened.draft).not.toBe(original.id);
      expect(drafts.getSnapshot()).toMatchObject({
        drafts: expect.arrayContaining([
          {
            ...original,
            subject: 'Other writer',
            updatedAt: expect.any(Number),
          },
        ]),
      });
      expect(composerWindows()).toStrictEqual([
        {
          draft: opened.draft,
          profile: defaultProfile,
          origin: 'inbox-window-compose',
        },
      ]);
      // AppKit shows the New Message window beside the Inbox window.
      await app.rerender(
        <AccountContext value={accountActions}>
          <InboxWindow windowId="compose" />
          <View testID="composer-window">
            <ComposerWindow
              windowId="1"
              draft={opened.draft}
              profile={opened.profile}
              origin={opened.origin}
            />
          </View>
        </AccountContext>,
      );
      const window = within(app.getByTestId('composer-window'));
      await expect(
        window.findByLabelText('Message body'),
      ).resolves.toHaveTextContent('Keep this draft.');
      expect(window.getByLabelText('To')).toHaveProp('value', 'unfinished');
      expect(window.queryByRole('button', { name: 'Expand' })).toBeNull();
      // #1286: the toolbar row holds the Command Palette, From, the actions and Send; the window's
      // own controls close it.
      expect(window.queryByRole('button', { name: 'Close' })).toBeNull();
      expect(
        window.getByRole('button', { name: 'Open Command Palette' }),
      ).toBeVisible();
      expect(window.getByLabelText(/^Send from /u)).toBeVisible();
      expect(
        window.getByRole('button', { name: 'Compose actions' }),
      ).toBeVisible();
      expect(window.getAllByRole('button', { name: 'Send' })).toHaveLength(1);
      // #1578: the window's palette lists the Draft's commands, and no Selected Message section.
      const openPalette = async () => {
        await fireEvent.press(
          window.getByRole('button', { name: 'Open Command Palette' }),
        );
        return within(window.getByTestId('command-palette'));
      };
      let palette = await openPalette();
      expect(
        palette
          .getAllByRole('header')
          .map((item) => String(item.props.accessibilityLabel)),
      ).toStrictEqual([
        `Draft · ${String(window.getByLabelText('Subject').props.value)}`,
      ]);
      // Send waits for a recipient, so the palette does not offer it yet.
      expect(
        palette
          .getAllByRole('button')
          .map((item) => String(item.props.accessibilityLabel)),
      ).toStrictEqual(['Attach File…', 'Add Cc and Bcc', 'Discard Draft']);
      expect(window.queryByLabelText('Cc')).toBeNull();
      await fireEvent.press(
        palette.getByRole('button', { name: 'Add Cc and Bcc' }),
      );
      expect(window.getByLabelText('Cc')).toBeVisible();
      // Discard asks first, as the toolbar's Discard does.
      palette = await openPalette();
      expect(
        palette.queryByRole('button', { name: 'Add Cc and Bcc' }),
      ).toBeNull();
      await fireEvent.press(
        palette.getByRole('button', { name: 'Discard Draft' }),
      );
      expect(
        window.getByRole('alert', {
          name: 'Discard this Draft? It is deleted from this device.',
        }),
      ).toBeVisible();
      await fireEvent.press(
        window.getByRole('button', { name: 'Keep Editing' }),
      );
      // Native Close and Quit must reach this editor's leave guard, including unfinished entries.
      // Quit keeps the regular question, as the Draft stays in Drafts.
      await fireEvent.changeText(
        window.getByLabelText('Subject'),
        'In a window',
      );
      await act(async () => {
        DeviceEventEmitter.emit('windowShouldClose', {
          window: 'composer-window-1',
          quitting: true,
        });
      });
      expect(sheetShown()?.title).toBe(
        'Do you want to save this message as a draft?',
      );
      await act(async () => {
        chooseSheetButton('Save');
      });
      expect(
        window.getByRole('alert', {
          name: 'Correct or remove the invalid address to close this Draft.',
        }),
      ).toBeVisible();
      expect(closedWindows()).toStrictEqual([]);
      await fireEvent.changeText(window.getByLabelText('To'), '');
      storage.setLocked(true);
      await fireEvent.changeText(
        window.getByLabelText('Subject'),
        'Unsaved window edit',
      );
      // #1671: Close asks whether to save the Draft back to its Inbox window.
      await act(async () => {
        DeviceEventEmitter.emit('windowShouldClose', {
          window: 'composer-window-1',
        });
      });
      expect(sheetShown()).toStrictEqual({
        title: 'Save this Draft?',
        detail:
          '“Unsaved window edit” goes back to your Inbox window either way.',
        buttons: ['Save Draft', 'Discard Draft', 'Cancel'],
        symbol: { name: 'square.and.pencil', color: expect.anything() },
      });
      await act(async () => {
        chooseSheetButton('Save Draft');
      });
      expect(
        window.getByText(
          'This Draft could not be saved, so it stays open. Try again, or discard it.',
        ),
      ).toBeVisible();
      expect(app.queryByTestId('composer-overlay')).toBeNull();
      expect(closedWindows()).toStrictEqual([]);
      storage.setLocked(false);
      // Try Again returns the Draft too.
      await fireEvent.press(window.getByRole('button', { name: 'Try Again' }));
      await waitFor(() => {
        expect(closedWindows()).toContain('composer-window-1');
      });
      // The saved Draft opens again in the overlay of the Inbox window it came from, which comes
      // forward.
      expect(focusedWindows().at(-1)).toBe('inbox-window-compose');
      await app.rerender(
        <AccountContext value={accountActions}>
          <InboxWindow windowId="compose" />
        </AccountContext>,
      );
      const overlay = within(await app.findByTestId('composer-overlay'));
      await expect(overlay.findByLabelText('Subject')).resolves.toHaveProp(
        'value',
        'Unsaved window edit',
      );
      expect(overlay.getByLabelText('Message body')).toHaveTextContent(
        'Keep this draft.',
      );
      expect(overlay.getByRole('button', { name: 'Expand' })).toBeVisible();
      expect(app.queryByLabelText('Search senders and subjects')).toBeNull();
    } finally {
      await app.unmount();
      replacement.restore();
    }
  });
  /* oxlint-enable vitest/max-expects */

  /* oxlint-disable vitest/max-expects -- One Draft leaves and returns through each Close answer. */
  it('returns a New Message window’s Draft to its Inbox window, asking first when another Draft is open there (#1671)', async () => {
    expect.hasAssertions();
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
    const accountActions = {
      mailboxes: [
        {
          id: alex,
          address: 'alex@example.invalid',
          state: 'connected',
          profile: defaultProfile,
          provider: 'gmail',
        } as const,
      ],
      openAccount: () => undefined,
      authorizeMailbox: () => Promise.resolve(),
      refreshInbox: (load: () => Promise<void>) => load(),
      account: 'synthetic-product-account',
      profiles: [],
      createProfile: () => Promise.resolve(undefined),
      chooseFolders: () => Promise.resolve(true),
    };
    const subjects = () => {
      const state = drafts.getSnapshot();
      ok(state.kind === 'ready');
      return new Set(state.drafts.map((draft) => draft.subject));
    };
    const windows = (
      composer?: ReactNode,
      inbox: ReactNode = <InboxWindow windowId="origin" />,
    ) => (
      <AccountContext value={accountActions}>
        {inbox}
        <View testID="composer-window">{composer}</View>
      </AccountContext>
    );
    const app = await render(windows());
    const overlay = () => within(app.getByTestId('composer-overlay'));
    const window = () => within(app.getByTestId('composer-window'));
    const close = async (button: string) => {
      await act(async () => {
        DeviceEventEmitter.emit('windowShouldClose', {
          window: 'composer-window-1',
        });
      });
      await act(async () => {
        chooseSheetButton(button);
      });
    };
    // Starts a Draft in the Inbox window with `subject`.
    const start = async (subject: string) => {
      await waitFor(() => {
        expect(app.getByRole('button', { name: 'New Message' })).toBeEnabled();
      });
      await fireEvent.press(app.getByRole('button', { name: 'New Message' }));
      await fireEvent.changeText(
        await overlay().findByLabelText('Subject'),
        subject,
      );
    };
    const expand = async () => {
      await fireEvent.press(overlay().getByRole('button', { name: 'Expand' }));
      await waitFor(() => {
        expect(app.queryByTestId('composer-overlay')).toBeNull();
      });
    };
    try {
      await fireEvent(app.getByTestId('window-panes-origin'), 'layout', {
        nativeEvent: { layout: { width: 1000, height: 600 } },
      });
      await start('Returning');
      await expand();
      const [expanded] = composerWindows();
      ok(expanded !== undefined);
      const composer = (
        <ComposerWindow
          windowId="1"
          draft={expanded.draft}
          profile={expanded.profile}
          origin={expanded.origin}
        />
      );
      await app.rerender(windows(composer));
      await expect(window().findByLabelText('Subject')).resolves.toHaveProp(
        'value',
        'Returning',
      );
      await start('Other');
      // Cancel leaves both Drafts where they are, and the New Message window comes back forward.
      await close('Save Draft');
      expect(sheetShown()).toStrictEqual({
        title: 'The Inbox window already has a Draft open',
        detail:
          '“Other” is open there. Save it to Drafts to bring this Draft back.',
        buttons: ['Save Other Draft and Return', 'Cancel'],
        symbol: { name: 'square.and.pencil', color: expect.anything() },
      });
      await act(async () => {
        chooseSheetButton('Cancel');
      });
      expect(focusedWindows()).toStrictEqual([
        'inbox-window-origin',
        'composer-window-1',
      ]);
      expect(closedWindows()).toStrictEqual([]);
      expect(overlay().getByLabelText('Subject')).toHaveProp('value', 'Other');
      expect(window().getByLabelText('Subject')).toHaveProp(
        'value',
        'Returning',
      );
      // Save Other Draft and Return keeps that Draft in Drafts and brings this one in.
      await close('Save Draft');
      await act(async () => {
        chooseSheetButton('Save Other Draft and Return');
      });
      // The composer and its close guard both finish the close, as for any New Message window.
      await waitFor(() => {
        expect(closedWindows()).toStrictEqual([
          'composer-window-1',
          'composer-window-1',
        ]);
      });
      await app.rerender(windows());
      await expect(overlay().findByLabelText('Subject')).resolves.toHaveProp(
        'value',
        'Returning',
      );
      expect(subjects()).toStrictEqual(new Set(['Other', 'Returning']));
      // Discard Draft deletes the Draft and brings the Inbox window forward.
      await expand();
      await app.rerender(windows(composer));
      await expect(window().findByLabelText('Subject')).resolves.toHaveProp(
        'value',
        'Returning',
      );
      await close('Discard Draft');
      await waitFor(() => {
        expect(subjects()).toStrictEqual(new Set(['Other']));
      });
      expect(closedWindows()).toHaveLength(4);
      expect(focusedWindows().at(-1)).toBe('inbox-window-origin');
      // A Draft another window removed meanwhile is not handed back.
      await app.rerender(windows());
      await start('Removed');
      await expand();
      const removed = composerWindows().at(-1);
      ok(removed !== undefined);
      await app.rerender(
        windows(
          <ComposerWindow
            windowId="1"
            draft={removed.draft}
            profile={removed.profile}
            origin={removed.origin}
          />,
        ),
      );
      await expect(window().findByLabelText('Subject')).resolves.toHaveProp(
        'value',
        'Removed',
      );
      await act(async () => {
        await drafts.discard(removed.draft);
      });
      await close('Save Draft');
      await waitFor(() => {
        expect(closedWindows()).toHaveLength(6);
      });
      expect(app.queryByTestId('composer-overlay')).toBeNull();
      // With no Inbox window showing its Mail Profile, the Draft returns in a new one.
      await app.rerender(windows());
      await start('Alone');
      await expand();
      const alone = composerWindows().at(-1);
      ok(alone !== undefined);
      await app.rerender(
        windows(
          <ComposerWindow
            windowId="1"
            draft={alone.draft}
            profile={alone.profile}
            origin={alone.origin}
          />,
          null,
        ),
      );
      await expect(window().findByLabelText('Subject')).resolves.toHaveProp(
        'value',
        'Alone',
      );
      await close('Save Draft');
      await waitFor(() => {
        expect(openedInboxes()).toStrictEqual([
          { profile: defaultProfile, draft: alone.draft },
        ]);
      });
      await app.rerender(
        <AccountContext value={accountActions}>
          <InboxWindow
            windowId="returned"
            profile={alone.profile}
            draft={alone.draft}
          />
        </AccountContext>,
      );
      await expect(
        within(await app.findByTestId('composer-overlay')).findByLabelText(
          'Subject',
        ),
      ).resolves.toHaveProp('value', 'Alone');
      // That window opens the returned Draft once: switched to another Profile, it shows none.
      await app.rerender(
        <AccountContext
          value={{
            ...accountActions,
            profiles: [{ id: 'work', name: 'Work' }],
          }}>
          <InboxWindow
            windowId="returned"
            profile="work"
            draft={alone.draft}
          />
        </AccountContext>,
      );
      await waitFor(() => {
        expect(app.queryByTestId('composer-overlay')).toBeNull();
      });
      // Back in the Draft's Profile, as after a lock remounts the window's contents, it stays closed.
      await app.rerender(
        <AccountContext value={accountActions}>
          <InboxWindow
            windowId="returned"
            profile={alone.profile}
            draft={alone.draft}
          />
        </AccountContext>,
      );
      await expect(app.findByTestId('composer-overlay')).rejects.toThrow(
        'Unable to find an element with testID: composer-overlay',
      );
    } finally {
      await app.unmount();
      replacement.restore();
    }
  });
  /* oxlint-enable vitest/max-expects */

  it('offers each unsaved message the previous run kept, restoring or discarding it (#2329)', async () => {
    expect.hasAssertions();
    const connection = {
      id: alex,
      address: 'alex@example.invalid',
      state: 'connected',
      profile: defaultProfile,
      provider: 'gmail',
    } as const;
    const registration = {
      subscribe: () => () => undefined,
      getSnapshot: () =>
        ({
          snapshot: {
            kind: 'connected',
            productAccountId: 'synthetic-product-account',
            signInProvider: 'google',
            mailboxes: connectedMailboxes,
          },
          busy: false,
          failed: false,
        }) as const,
    };
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    // The previous run stored two Drafts and kept unsaved edits to both when it ended.
    const previous = createDrafts(storage.native, registration);
    await previous.load();
    const stored = async (subject: string) => {
      const id = await previous.create(connection);
      const created = draftOf(previous.getSnapshot(), id);
      ok(created !== undefined);
      const draft = { ...created, subject };
      await previous.update(draft, created);
      await expect(previous.save()).resolves.toBe(true);
      await expect(
        previous.journal({ ...draft, subject: `${subject}, unsaved` }),
      ).resolves.toBe(true);
      return draft.id;
    };
    const restored = await stored('Restored plan');
    const discarded = await stored('Discarded plan');
    const edited = await stored('Edited plan');
    const drafts = createDrafts(storage.native, registration);
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
          refreshInbox: (load: () => Promise<void>) => load(),
          account: 'synthetic-product-account',
          profiles: [],
          createProfile: () => Promise.resolve(undefined),
          chooseFolders: () => Promise.resolve(true),
        }}>
        <InboxWindow windowId="recover" />
      </AccountContext>,
    );
    const recover = {
      title: 'Recover unsaved message?',
      detail: 'Your unsaved changes were kept on this device.',
      buttons: ['Restore', 'Discard'],
      cancel: 0,
      destructive: 1,
    };
    const subjects = () => {
      const state = drafts.getSnapshot();
      ok(state.kind === 'ready');
      return state.drafts.map(({ id, subject }) => [id, subject]);
    };
    try {
      await waitFor(() => {
        expect(sheetsShown()).toStrictEqual([recover]);
      });
      // The Draft changes elsewhere while the alert is open.
      const opened = draftOf(drafts.getSnapshot(), restored);
      ok(opened !== undefined);
      await drafts.update({ ...opened, subject: 'Changed plan' }, opened);
      await act(async () => {
        chooseSheetButton('Restore');
      });
      await expect(app.findByLabelText('Subject')).resolves.toHaveProp(
        'value',
        'Restored plan, unsaved',
      );
      // The other record waits while the restored composer is open.
      expect(sheetsShown()).toStrictEqual([]);
      // An editor in another window journals the third Draft meanwhile, so its record is not offered.
      const elsewhere = draftOf(drafts.getSnapshot(), edited);
      ok(elsewhere !== undefined);
      ok(await drafts.journal({ ...elsewhere, subject: 'Edited elsewhere' }));
      // Close asks to save the restored edits, and Save keeps them as a conflicting copy.
      await fireEvent.press(app.getByRole('button', { name: 'Close' }));
      await act(async () => {
        chooseSheetButton('Save');
      });
      await waitFor(() => {
        expect(sheetsShown()).toStrictEqual([recover]);
      });
      expect(app.queryByLabelText('Subject')).toBeNull();
      await act(async () => {
        chooseSheetButton('Discard');
      });
      // Discard removes the record and keeps the stored version; the restored record went with Save.
      await waitFor(() => {
        expect([...storage.recoveryRecords().keys()]).toStrictEqual([edited]);
      });
      await act(async () => {
        await drafts.recovered();
      });
      expect(subjects()).toStrictEqual([
        [restored, 'Changed plan'],
        [discarded, 'Discarded plan'],
        [edited, 'Edited plan'],
        [`${restored}-conflict-1`, 'Restored plan, unsaved'],
      ]);
      expect(sheetsShown()).toStrictEqual([]);
    } finally {
      await app.unmount();
      replacement.restore();
    }
  });

  it('restores an unsaved message against the version its edits started from (#2332)', async () => {
    expect.hasAssertions();
    const connection = {
      id: alex,
      address: 'alex@example.invalid',
      state: 'connected',
      profile: defaultProfile,
      provider: 'gmail',
    } as const;
    const account = 'synthetic-product-account';
    const registration = {
      subscribe: () => () => undefined,
      getSnapshot: () =>
        ({
          snapshot: {
            kind: 'connected',
            productAccountId: account,
            signInProvider: 'google',
            mailboxes: connectedMailboxes,
          },
          busy: false,
          failed: false,
        }) as const,
    };
    const context = {
      mailboxes: [connection],
      openAccount: () => undefined,
      authorizeMailbox: () => Promise.resolve(),
      refreshInbox: (load: () => Promise<void>) => load(),
      account,
      profiles: [],
      createProfile: () => Promise.resolve(undefined),
      chooseFolders: () => Promise.resolve(true),
    };
    const registrationModule = jest.requireMock<{
      drafts: ReturnType<typeof createDrafts>;
    }>('../src/registration.ts');
    const storage = createSyntheticDrafts(() => account);
    // In the previous run, a composer journals its edits to a stored Draft, another composer saves
    // that Draft and closes, and the app ends before the first composer closes.
    const previous = createDrafts(storage.native, registration);
    await previous.load();
    const id = await previous.create(connection);
    ok(id !== undefined);
    const created = draftOf(previous.getSnapshot(), id);
    ok(created !== undefined);
    await previous.update({ ...created, subject: 'Plan' }, created);
    await expect(previous.save()).resolves.toBe(true);
    const ended = jest.replaceProperty(registrationModule, 'drafts', previous);
    const composer = await render(
      <AccountContext value={context}>
        <ComposerWindow
          windowId="1"
          draft={id}
          profile={defaultProfile}
        />
      </AccountContext>,
    );
    try {
      await fireEvent.changeText(
        await composer.findByLabelText('Subject'),
        'Plan, unsaved',
      );
      await waitFor(
        () => {
          expect(storage.recoveryRecords().size).toBe(1);
        },
        { timeout: 4000 },
      );
      const opened = draftOf(previous.getSnapshot(), id);
      ok(opened !== undefined);
      await previous.update({ ...opened, subject: 'Plan, saved' }, opened);
      await expect(previous.save()).resolves.toBe(true);
    } finally {
      await composer.unmount();
      ended.restore();
    }
    const drafts = createDrafts(storage.native, registration);
    const replacement = jest.replaceProperty(
      registrationModule,
      'drafts',
      drafts,
    );
    const app = await render(
      <AccountContext value={context}>
        <InboxWindow windowId="recover" />
      </AccountContext>,
    );
    try {
      await waitFor(() => {
        expect(sheetsShown()).toHaveLength(1);
      });
      await act(async () => {
        chooseSheetButton('Restore');
      });
      await expect(app.findByLabelText('Subject')).resolves.toHaveProp(
        'value',
        'Plan, unsaved',
      );
      // Save keeps the restored edits as a conflicting copy of the version saved since.
      await fireEvent.press(app.getByRole('button', { name: 'Close' }));
      await act(async () => {
        chooseSheetButton('Save');
      });
      await waitFor(() => {
        expect(storage.recoveryRecords().size).toBe(0);
      });
      const state = drafts.getSnapshot();
      ok(state.kind === 'ready');
      expect(
        state.drafts.map((draft) => [draft.id, draft.subject]),
      ).toStrictEqual([
        [id, 'Plan, saved'],
        [`${id}-conflict-1`, 'Plan, unsaved'],
      ]);
    } finally {
      await app.unmount();
      replacement.restore();
    }
  });

  it('offers only the previous run’s records after a notification launch (#2329, #2334)', async () => {
    expect.hasAssertions();
    const connection = {
      id: alex,
      address: 'alex@example.invalid',
      state: 'connected',
      profile: defaultProfile,
      provider: 'gmail',
    } as const;
    const account = 'synthetic-product-account';
    const registration = {
      subscribe: () => () => undefined,
      getSnapshot: () =>
        ({
          snapshot: {
            kind: 'connected',
            productAccountId: account,
            signInProvider: 'google',
            mailboxes: connectedMailboxes,
          },
          busy: false,
          failed: false,
        }) as const,
    };
    const storage = createSyntheticDrafts(() => account);
    // The previous run kept unsaved edits to one stored Draft and none to the other.
    const previous = createDrafts(storage.native, registration);
    await previous.load();
    const stored = async (subject: string) => {
      const id = await previous.create(connection);
      const created = draftOf(previous.getSnapshot(), id);
      ok(created !== undefined);
      await previous.update({ ...created, subject }, created);
      await expect(previous.save()).resolves.toBe(true);
      return id;
    };
    const kept = await stored('Kept plan');
    const current = await stored('Current plan');
    ok(current !== undefined);
    const keptDraft = draftOf(previous.getSnapshot(), kept);
    ok(keptDraft !== undefined);
    await expect(
      previous.journal({ ...keptDraft, subject: 'Kept plan, unsaved' }),
    ).resolves.toBe(true);
    const drafts = createDrafts(storage.native, registration);
    const replacement = jest.replaceProperty(
      jest.requireMock<{ drafts: typeof drafts }>('../src/registration.ts'),
      'drafts',
      drafts,
    );
    const context = (productAccount: string) => ({
      mailboxes: [connection],
      openAccount: () => undefined,
      authorizeMailbox: () => Promise.resolve(),
      refreshInbox: (load: () => Promise<void>) => load(),
      account: productAccount,
      profiles: [],
      createProfile: () => Promise.resolve(undefined),
      chooseFolders: () => Promise.resolve(true),
    });
    const inbox = (productAccount: string) => (
      <AccountContext value={context(productAccount)}>
        <InboxWindow windowId="recover" />
      </AccountContext>
    );
    // Notifications open New Message windows before any Inbox window: one journals an edit, and
    // the other closes its Draft unchanged, which keeps the record not yet offered (#2334).
    const app = await render(
      <AccountContext value={context(account)}>
        <View testID="current">
          <ComposerWindow
            windowId="1"
            draft={current}
            profile={defaultProfile}
          />
        </View>
        <ComposerWindow
          windowId="2"
          draft={keptDraft.id}
          profile={defaultProfile}
        />
      </AccountContext>,
    );
    try {
      await fireEvent.changeText(
        await within(app.getByTestId('current')).findByLabelText('Subject'),
        'Current plan, unsaved',
      );
      await act(async () => {
        DeviceEventEmitter.emit('windowShouldClose', {
          window: 'composer-window-2',
        });
      });
      await waitFor(() => {
        expect(closedWindows()).toContain('composer-window-2');
      });
      await waitFor(
        () => {
          expect(storage.recoveryRecords().size).toBe(2);
        },
        { timeout: 4000 },
      );
      // The Inbox window offers the previous run's record only.
      await app.rerender(inbox(account));
      await waitFor(() => {
        expect(sheetsShown()).toHaveLength(1);
      });
      await act(async () => {
        chooseSheetButton('Discard');
      });
      await waitFor(() => {
        expect([...storage.recoveryRecords().keys()]).toStrictEqual([current]);
      });
      await act(async () => {
        await drafts.recovered();
      });
      expect(sheetsShown()).toStrictEqual([]);
    } finally {
      await app.unmount();
      replacement.restore();
    }
  });

  const connection = {
    id: alex,
    address: 'alex@example.invalid',
    state: 'connected',
    profile: defaultProfile,
    provider: 'gmail',
  } as const;
  // The previous run kept unsaved edits to a Draft sending from `record`, which `inbox`
  // windows of `profile` may offer.
  async function previousRunRecord(
    record: MailboxConnection,
    profile?: string,
  ) {
    const account = 'synthetic-product-account';
    const registration = {
      subscribe: () => () => undefined,
      getSnapshot: () =>
        ({
          snapshot: {
            kind: 'connected',
            productAccountId: account,
            signInProvider: 'google',
            mailboxes: JSON.stringify(
              record.id === connection.id ? [record] : [connection, record],
            ),
          },
          busy: false,
          failed: false,
        }) as const,
    };
    const storage = createSyntheticDrafts(() => account);
    const previous = createDrafts(storage.native, registration);
    await previous.load();
    const id = await previous.create(record);
    const created = draftOf(previous.getSnapshot(), id);
    ok(created !== undefined);
    await expect(
      previous.journal({ ...created, subject: 'Plan, unsaved' }),
    ).resolves.toBe(true);
    const drafts = createDrafts(storage.native, registration);
    const replacement = jest.replaceProperty(
      jest.requireMock<{ drafts: typeof drafts }>('../src/registration.ts'),
      'drafts',
      drafts,
    );
    const inbox = (mailboxes: readonly MailboxConnection[]) => (
      <AccountContext
        value={{
          mailboxes,
          openAccount: () => undefined,
          authorizeMailbox: () => Promise.resolve(),
          refreshInbox: (load: () => Promise<void>) => load(),
          account,
          profiles: [
            { id: 'work', name: 'Work', color: 'teal', icon: 'laptop' },
          ],
          createProfile: () => Promise.resolve(undefined),
          chooseFolders: () => Promise.resolve(true),
        }}>
        <InboxWindow
          windowId="recover"
          {...(profile === undefined ? {} : { profile })}
        />
      </AccountContext>
    );
    return { storage, drafts, replacement, inbox };
  }

  it('offers a record once its mailbox moves into an idle window’s Profile (#2373)', async () => {
    expect.hasAssertions();
    const { storage, drafts, replacement, inbox } = await previousRunRecord(
      connection,
      'work',
    );
    const app = await render(inbox([connection]));
    try {
      // The Work window has nothing of its own to offer.
      await act(async () => {
        await drafts.recovered();
      });
      expect(sheetsShown()).toStrictEqual([]);
      // Once the mailbox moves into Work, the idle window offers its record.
      const moved = { ...connection, profile: 'work' };
      await app.rerender(inbox([moved]));
      await waitFor(() => {
        expect(sheetsShown()).toHaveLength(1);
      });
      // Other mailbox updates leave the open alert alone rather than asking again.
      const asked = jest.spyOn(unwiredAlert, 'show');
      await app.rerender(inbox([{ ...moved, provider: 'gmail' }]));
      await act(async () => {
        await drafts.recovered();
      });
      expect(asked).not.toHaveBeenCalled();
      expect(sheetsShown()).toHaveLength(1);
      await act(async () => {
        chooseSheetButton('Discard');
      });
      await waitFor(() => {
        expect(storage.recoveryRecords().size).toBe(0);
      });
    } finally {
      await app.unmount();
      replacement.restore();
      jest.restoreAllMocks();
    }
  });

  it('keeps an alert offered after a window went idle open when a mailbox later leaves its Profile (#2373)', async () => {
    expect.hasAssertions();
    const work = {
      id: 'synthetic-connection-work',
      address: 'work@example.invalid',
      state: 'connected',
      profile: 'work',
      provider: 'gmail',
    } as const;
    const { drafts, replacement, inbox } = await previousRunRecord(work);
    const app = await render(inbox([connection, work]));
    try {
      // The Default Profile window has nothing of its own to offer.
      await act(async () => {
        await drafts.recovered();
      });
      expect(sheetsShown()).toStrictEqual([]);
      // Once the Work mailbox is removed, its Draft counts as the Default Profile's, so the idle
      // window looks again.
      await app.rerender(inbox([connection]));
      await waitFor(() => {
        expect(sheetsShown()).toHaveLength(1);
      });
      // A mailbox moving out of the Profile afterwards leaves that alert open.
      const asked = jest.spyOn(unwiredAlert, 'show');
      await app.rerender(inbox([{ ...connection, profile: 'work' }]));
      await act(async () => {
        await drafts.recovered();
      });
      expect(asked).not.toHaveBeenCalled();
      expect(sheetsShown()).toHaveLength(1);
      await act(async () => {
        chooseSheetButton('Discard');
      });
    } finally {
      await app.unmount();
      replacement.restore();
      jest.restoreAllMocks();
    }
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
        // Opening the message read it.
        expect(within(message).getByText('Maya Chen')).toHaveStyle({
          color: colors.accentOnFill,
          fontWeight: '400',
        });
      } finally {
        paletteSpy.mockRestore();
      }
    },
  );

  it('collapses and expands a sidebar section from its header', async () => {
    expect.hasAssertions();
    const app = await render(
      <Windows
        first
        second={false}
      />,
    );
    await app.findByRole('button', { name: 'All Inboxes' });
    const favorites = app.getByRole('button', { name: 'Favorites' });
    expect(favorites).toBeExpanded();
    await fireEvent.press(favorites);
    expect(app.queryByRole('button', { name: 'All Inboxes' })).toBeNull();
    expect(
      app.getByRole('button', { name: 'Favorites', expanded: false }),
    ).toHaveAccessibilityValue({
      text: 'Collapsed',
    });
    await fireEvent.press(app.getByRole('button', { name: 'Favorites' }));
    expect(app.getByRole('button', { name: 'All Inboxes' })).toBeVisible();
    expect(
      app.getByRole('button', { name: 'Favorites', expanded: true }),
    ).not.toHaveAccessibilityValue({
      text: 'Collapsed',
    });
  });

  it('edits Favorites: hides the selected mailbox, reorders rows and keeps them across a relaunch', async () => {
    expect.hasAssertions();
    // Inbox preferences kept in memory for one signed-in Product Account, without Private Sync.
    const kept = { revision: 0, document: null as string | null };
    const store = () =>
      createInboxPreferences(
        {
          openInboxPreferences: () =>
            Promise.resolve({ owner: 'account-1', ...kept }),
          commitInboxPreferences: (owner, revision, document) => {
            Object.assign(kept, { revision: revision + 1, document });
            return Promise.resolve({ owner, revision: kept.revision });
          },
        },
        {
          getSnapshot: () => ({
            snapshot: {
              kind: 'connected',
              productAccountId: 'account-1',
              signInProvider: 'google',
              mailboxes: '[]',
            },
            busy: false,
            failed: false,
          }),
        },
      );
    const launch = (preferences: ReturnType<typeof store>) =>
      render(
        <InboxPreferencesContext value={preferences}>
          <Windows
            first
            second={false}
          />
        </InboxPreferencesContext>,
      );
    const names = new Set([
      'All Inboxes',
      'Sent',
      'Archive',
      'All Mail',
      'Spam',
      'Trash',
    ]);
    // The Favorites rows in order, by name.
    const favorites = (app: Awaited<ReturnType<typeof launch>>) =>
      app
        .getAllByRole('button')
        .map((button) =>
          String(button.props.accessibilityLabel).replace(
            '. In All Mailboxes',
            '',
          ),
        )
        .filter((label) => names.has(label));
    const app = await launch(store());
    await app.findByRole('button', { name: 'All Inboxes' });
    await fireEvent.press(
      app.getByRole('button', { name: 'Spam. In All Mailboxes' }),
    );
    // Edit Favorites… in the Favorites header's menu.
    const menu = contextMenuOf(app.getByRole('button', { name: 'Favorites' }));
    expect(menuSections(menu)).toStrictEqual([
      ['Edit Favorites…'],
      ['Collapse Favorites'],
    ]);
    await chooseFromMenu(menu, 'Edit Favorites…');
    // The Edit rows in order, with whether each is shown.
    const editRows = () =>
      app
        .getAllByRole('button')
        .filter(({ props }) => names.has(String(props.accessibilityLabel)))
        .map(
          ({ props }) =>
            `${String(props.accessibilityLabel)} ${String(props.accessibilityValue.text)}`,
        );
    const edited = [
      'All Inboxes Shown',
      'Sent Shown',
      'Archive Shown',
      'All Mail Shown',
      'Trash Shown',
      'Spam Hidden',
    ];
    await fireEvent.press(app.getByRole('button', { name: 'Spam' }));
    // All Inboxes stays shown.
    await fireEvent.press(app.getByRole('button', { name: 'All Inboxes' }));
    await fireEvent(
      app.getByRole('button', { name: 'Trash' }),
      'accessibilityAction',
      { nativeEvent: { actionName: 'Move Up' } },
    );
    await waitFor(() => {
      expect(editRows()).toStrictEqual(edited);
    });
    // From the keyboard, Command-Option-Down and Up move a row two places and back; Down alone
    // does not.
    const keys = async (direction: string, times: number, modifiers = true) => {
      for (let pressed = 0; pressed < times; pressed += 1) {
        await fireEvent(app.getByRole('button', { name: 'Sent' }), 'keyDown', {
          nativeEvent: {
            key: direction,
            altKey: modifiers,
            metaKey: modifiers,
          },
        });
      }
    };
    await keys('ArrowDown', 1, false);
    expect(editRows()).toStrictEqual(edited);
    await keys('ArrowDown', 2);
    await waitFor(() => {
      expect(editRows().slice(0, 4)).toStrictEqual([
        'All Inboxes Shown',
        'Archive Shown',
        'All Mail Shown',
        'Sent Shown',
      ]);
    });
    await keys('ArrowUp', 2);
    await waitFor(() => {
      expect(editRows()).toStrictEqual(edited);
    });
    // Pressing Trash's drag handle and letting go without moving it leaves it in place.
    const handle = handleOf(app.getByRole('button', { name: 'Trash' }));
    await fireEvent(handle, 'responderGrant', touch);
    await fireEvent(handle, 'responderRelease', touch);
    // Also when the press and release arrive in one event batch, away from the last press.
    const below = {
      ...touch,
      nativeEvent: { ...touch.nativeEvent, pageY: 240 },
    };
    await act(() => {
      handle.props.onResponderGrant(below);
      handle.props.onResponderRelease(below);
    });
    expect(editRows()).toStrictEqual(edited);
    // A drag keeps the place it started from when another window reorders the rows before the
    // first move: Trash, grabbed fifth, dragged one row up lands fourth.
    const up = { ...touch, nativeEvent: { ...touch.nativeEvent, pageY: -28 } };
    const moveAllMail = (actionName: string) =>
      fireEvent(
        app.getByRole('button', { name: 'All Mail' }),
        'accessibilityAction',
        { nativeEvent: { actionName } },
      );
    await fireEvent(handle, 'responderGrant', touch);
    await moveAllMail('Move Down');
    await fireEvent(
      handleOf(app.getByRole('button', { name: 'Trash' })),
      'responderMove',
      up,
    );
    await fireEvent(
      handleOf(app.getByRole('button', { name: 'Trash' })),
      'responderRelease',
      up,
    );
    await waitFor(() => {
      expect(editRows().slice(2, 5)).toStrictEqual([
        'Archive Shown',
        'Trash Shown',
        'All Mail Shown',
      ]);
    });
    await moveAllMail('Move Up');
    await waitFor(() => {
      expect(editRows()).toStrictEqual(edited);
    });
    await fireEvent.press(app.getByRole('button', { name: 'Done' }));
    // Hiding the selected Spam selected the first row still shown.
    expect({
      favorites: favorites(app),
      selected: app.getByRole('button', { name: 'All Inboxes' }).props
        .accessibilityState?.selected,
    }).toStrictEqual({
      favorites: ['All Inboxes', 'Sent', 'Archive', 'All Mail', 'Trash'],
      selected: true,
    });
    await app.unmount();

    const relaunched = store();
    await relaunched.load();
    const again = await launch(relaunched);
    await again.findByRole('button', { name: 'All Inboxes' });
    expect(favorites(again)).toStrictEqual([
      'All Inboxes',
      'Sent',
      'Archive',
      'All Mail',
      'Trash',
    ]);
    await again.unmount();
  });

  it("asks AppKit to show or hide the window's sidebar and names the toggle after its collapse", async () => {
    expect.hasAssertions();
    const app = await render(
      <Windows
        first
        second={false}
      />,
    );
    const allInboxes = await app.findByRole('button', { name: 'All Inboxes' });
    await fireEvent.press(app.getByRole('button', { name: 'Hide Sidebar' }));
    expect(toggledSidebars()).toStrictEqual(['inbox-window-first']);
    // AppKit reports each collapse, including one a narrowing window causes.
    await fireEvent(allInboxes, 'collapse', {
      nativeEvent: { collapsed: true },
    });
    await fireEvent.press(app.getByRole('button', { name: 'Show Sidebar' }));
    expect(toggledSidebars()).toStrictEqual([
      'inbox-window-first',
      'inbox-window-first',
    ]);
    await fireEvent(allInboxes, 'collapse', {
      nativeEvent: { collapsed: false },
    });
    expect(app.getByRole('button', { name: 'Hide Sidebar' })).toBeVisible();
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
    // Opening a message in one window reads it in the other.
    await fireEvent.press(await first.findByRole('button', { name: maya }));
    await second.findByRole('button', {
      name: 'Maya Chen. A little more room to think',
    });
    await fireEvent.press(await second.findByRole('button', { name: oliver }));
    expect(first.getByText('maya@example.com')).toBeVisible();
    expect(second.getByText('oliver@example.com')).toBeVisible();
    await fireEvent.press(
      second.getByRole('button', { name: 'Mark as Unread' }),
    );
    await expect(
      first.findByRole('button', { name: oliver }),
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
        'Mark as Unread',
        'Search Mail',
        'Edit Favorites',
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
      for (let step = 0; step < 3; step += 1) {
        await fireEvent(input, 'keyDown', {
          nativeEvent: { key: 'ArrowDown' },
        });
      }
      expect(palette.getByRole('button', { name: 'Inbox' })).toBeSelected();
      // Inbox ends at 320pt, below the visible 80pt, so the list scrolls until it is the last row.
      expect(scrollTo).toHaveBeenLastCalledWith({ y: 240, animated: false });
      // The wheel then scrolls Edit Favorites, which starts at 240pt, out of view above.
      await fireEvent(list, 'scroll', {
        nativeEvent: { contentOffset: { y: 280 } },
      });
      // Up scrolls until each row above is the first; the first enabled command then brings back
      // the top, with its header and the unavailable commands.
      scrollTo.mockClear();
      for (let step = 0; step < 3; step += 1) {
        await fireEvent(input, 'keyDown', { nativeEvent: { key: 'ArrowUp' } });
      }
      expect(scrollTo.mock.calls).toStrictEqual([
        [{ y: 240, animated: false }],
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
    // Opening it read it, so the palette offers to mark it unread, and that change stands.
    await act(async () => {
      await fireEvent.press(
        within(app.getByTestId('command-palette')).getByRole('button', {
          name: 'Mark as Unread',
        }),
      );
    });
    await expect(
      app.findByRole('button', { name: oliver }),
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
      app.getByRole('button', { name: 'Reply. Select a Thread' }),
    ).toBeDisabled();
    const headers = app
      .getAllByRole('header')
      .map((item) => String(item.props.accessibilityLabel));
    expect(headers.indexOf('Selected Message')).toBeLessThan(
      headers.indexOf('App'),
    );
    expect(headers.indexOf('App')).toBeLessThan(headers.indexOf('Go To'));
    await fireEvent.changeText(input, 'se');
    expect(app.getByRole('button', { name: 'Search Mail' })).toBeOnTheScreen();
    expect(app.queryByRole('button', { name: 'Inbox' })).toBeNull();
    await fireEvent.changeText(input, '');
    // Down selects the next command that can run; Return runs it and closes the palette.
    await fireEvent(input, 'keyDown', { nativeEvent: { key: 'ArrowDown' } });
    expect(app.getByRole('button', { name: 'Edit Favorites' })).toBeSelected();
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
    // AppKit shows the sidebar beside the bar's parent, so it has a layer of its own.
    expect(app.queryByTestId('palette-outside-click')).toBeNull();
    await fireEvent.press(
      app.getByRole('button', { name: 'Open Command Palette' }),
    );
    await fireEvent.press(app.getByTestId('palette-outside-click'));
    expect(app.queryByPlaceholderText('Type a command')).toBeNull();
    expect(app.queryByTestId('palette-outside-click')).toBeNull();
  });

  it('keeps a closing Command Palette out of reach while it fades and reopens it empty', async () => {
    expect.hasAssertions();
    // The exit never finishes here, so the closed panel is still leaving when the palette reopens.
    const timing = jest.spyOn(Animated, 'timing').mockReturnValue({
      start: () => undefined,
      stop: () => undefined,
      reset: () => undefined,
    });
    try {
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
      await fireEvent.changeText(input, 'se');
      await fireEvent(input, 'keyPress', { nativeEvent: { key: 'Escape' } });
      // The leaving panel stays beneath the returned button, hidden from VoiceOver and the pointer.
      expect(
        app.getByTestId('command-palette', { includeHiddenElements: true }),
      ).toHaveProp('pointerEvents', 'none');
      expect(app.queryByRole('button', { name: 'Search Mail' })).toBeNull();
      await fireEvent.press(
        app.getByRole('button', { name: 'Open Command Palette' }),
      );
      expect(app.getByPlaceholderText('Type a command')).toHaveDisplayValue('');
      expect(app.getByRole('button', { name: 'Inbox' })).toBeOnTheScreen();
    } finally {
      timing.mockRestore();
    }
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
      showMailboxes(singleMailbox(createInboxStore(gmail.native), alex));
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
    showMailboxes(singleMailbox(createInboxStore(gmail.native), alex));
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
        await second.findByRole('button', {
          name: /^Trash\. In (?!All Mailboxes)/u,
        }),
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

  it('reads an IMAP Archive again in the unified Archive each time its Inbox synchronizes', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.addFolder('Archive', ['archive']);
    imap.deliver('Archive', { subject: 'Filed invoice' });
    const inbox = createImapInbox(imap.native);
    showMailboxes(singleMailbox(inbox, alex));
    const app = await render(
      <Windows
        first
        second={false}
      />,
    );
    try {
      const first = within(app.getByTestId('inbox-window-first'));
      await fireEvent.press(
        await first.findByRole('button', {
          name: 'Archive. In All Mailboxes',
        }),
      );
      await expect(
        first.findByRole('button', { name: /Filed invoice/u }),
      ).resolves.toBeVisible();
      imap.deliver('Archive', { subject: 'Filed elsewhere' });
      await act(() => inbox.load());
      await expect(
        first.findByRole('button', { name: /Filed elsewhere/u }),
      ).resolves.toBeVisible();
    } finally {
      await app.unmount();
    }
  });

  it.each([
    {
      title: 'All Mail',
      folder: 'Everything',
      roles: ['all'],
      detail:
        'Its server’s All Mail folder can also hold Spam and Trash. Its folders are still listed under it in the sidebar.',
    },
    {
      title: 'Archive',
      folder: 'Archive',
      roles: ['archive', 'all'],
      detail:
        'Its server doesn’t identify a folder that can be used for Archive. Its folders are still listed under it in the sidebar.',
    },
  ])(
    'explains an IMAP connection excluded from $title and keeps its own folder readable',
    async ({ title, folder, roles, detail }) => {
      expect.hasAssertions();
      const imap = createSyntheticImap();
      imap.addFolder(folder, roles);
      imap.deliver(folder, { subject: 'Only in the excluded folder' });
      const inbox = createImapInbox(imap.native);
      showMailboxes(singleMailbox(inbox, alex));
      const app = await render(
        <Windows
          first
          second={false}
        />,
      );
      try {
        const first = within(app.getByTestId('inbox-window-first'));
        await fireEvent.press(
          await first.findByRole('button', {
            name: `${title}. In All Mailboxes`,
          }),
        );
        await expect(
          first.findByText(/isn’t included/u),
        ).resolves.toBeVisible();
        expect(first.getByText(detail)).toBeVisible();
        expect(
          first.queryByRole('button', { name: /Only in the excluded folder/u }),
        ).toBeNull();
        await fireEvent.press(
          first.getByRole('button', {
            name: new RegExp(`^${folder}\\. In (?!All Mailboxes)`, 'u'),
          }),
        );
        await expect(
          first.findByRole('button', { name: /Only in the excluded folder/u }),
        ).resolves.toBeVisible();
      } finally {
        await app.unmount();
      }
    },
  );

  // A Gmail mailbox with archived mail and Trash, listed in one window from the given Favorites row.
  const showUnified = async (favorite: string) => {
    const { registration } = await connectedRegistration();
    const gmail = createSyntheticGmail();
    const kept = gmail.deliver({
      subject: 'Kept receipt',
      content: { text: 'Paid in full.' },
    });
    gmail.archive(kept);
    gmail.deliver({ subject: 'Lunch on Friday' });
    const old = gmail.deliver({ subject: 'Old newsletter' });
    gmail.setLabel(old, 'TRASH', true);
    gmail.setLabel(old, 'INBOX', false);
    const list = createMailboxes(
      syntheticConnections({ [alex]: { native: gmail.native } }),
      registration,
    );
    showMailboxes(list);
    const app = await render(
      <Windows
        first
        second={false}
      />,
    );
    const first = within(app.getByTestId('inbox-window-first'));
    await fireEvent.press(
      await first.findByRole('button', {
        name: `${favorite}. In All Mailboxes`,
      }),
    );
    return { gmail, old, list, app, first };
  };

  it('lists archived Gmail mail in the unified Archive and keeps its open message as newer mail arrives', async () => {
    expect.hasAssertions();
    const { gmail, list, app, first } = await showUnified('Archive');
    try {
      expect(first.getByRole('header', { name: 'Archive' })).toBeVisible();
      // The row names its connection even when the Profile has only one.
      const receipt = await first.findByRole('button', {
        name: /Kept receipt\. In alex@example\.invalid/u,
      });
      expect(
        within(receipt).getByText('In alex@example.invalid'),
      ).toBeVisible();
      await fireEvent.press(receipt);
      await first.findByText('Paid in full.');
      expect(first.getByRole('button', { name: 'Delete' })).toBeVisible();
      gmail.archive(gmail.deliver({ subject: 'Newer receipt' }));
      await act(() => list.load());
      await expect(
        first.findByRole('button', { name: /Newer receipt/u }),
      ).resolves.toBeVisible();
      expect(first.getByText('Paid in full.')).toBeVisible();
    } finally {
      await app.unmount();
      jest.mocked(AccessibilityInfo.announceForAccessibility).mockClear();
    }
  });

  it('restores mail from the unified Trash to its Inbox', async () => {
    expect.hasAssertions();
    const { gmail, old, app, first } = await showUnified('Trash');
    try {
      await fireEvent.press(
        await first.findByRole('button', { name: /Old newsletter/u }),
      );
      await fireEvent.press(
        first.getByRole('button', { name: 'Move to Inbox' }),
      );
      await waitFor(() => {
        expect(gmail.labelsOf(old)).toContain('INBOX');
      });
    } finally {
      await app.unmount();
      jest.mocked(AccessibilityInfo.announceForAccessibility).mockClear();
    }
  });

  it('keeps a removed row leaving in each window until Undo or a scroll there, never for synchronization', async () => {
    expect.hasAssertions();
    // These assertions inspect unfinished motion; native frames must not finish it between inputs.
    const frames = jest
      .spyOn(globalThis, 'requestAnimationFrame')
      .mockReturnValue(0);
    const timing = jest.spyOn(Animated, 'timing');
    const stopListening: Array<() => void> = [];
    const gmail = createSyntheticGmail();
    const elsewhere = gmail.deliver({ subject: 'Archived elsewhere' });
    gmail.deliver({ subject: 'Lunch on Friday' });
    const inbox = createInboxStore(gmail.native);
    showMailboxes(singleMailbox(inbox, alex));
    const app = await render(
      <Windows
        first
        second
      />,
    );
    try {
      const first = within(app.getByTestId('inbox-window-first'));
      const second = within(app.getByTestId('inbox-window-second'));
      await first.findByRole('button', { name: /Lunch on Friday/u });
      // Each window's rows that stay on screen only while they leave, hidden from VoiceOver.
      const leaving = (subject: string) =>
        [first, second].map(
          (window) =>
            window.queryAllByText(subject, { includeHiddenElements: true })
              .length - window.queryAllByText(subject).length,
        );

      gmail.archive(elsewhere);
      gmail.deliver({ subject: 'Arrives quietly' });
      await act(inbox.load);
      await first.findByRole('button', { name: /Arrives quietly/u });
      const synchronized = leaving('Archived elsewhere');

      await act(async () => {
        await fireEvent(
          second.getByRole('button', { name: /Lunch on Friday/u }),
          'accessibilityAction',
          { nativeEvent: { actionName: 'archive' } },
        );
      });
      const archived = leaving('Lunch on Friday');
      // A scroll finishes the rows still leaving in its own window.
      await fireEvent.scroll(first.getByLabelText('Inbox messages'), {
        nativeEvent: { contentOffset: { x: 0, y: 0 } },
      });
      const scrolled = leaving('Lunch on Friday');
      await act(async () => {
        await fireEvent.press(second.getByRole('button', { name: 'Undo' }));
      });
      await first.findByRole('button', { name: /Lunch on Friday/u });

      // Supply an unfinished animation frame at the native boundary. Another action must leave
      // the restored row fully visible, rather than freezing its height and opacity halfway.
      const restoredFrames = new Map<Animated.Value, number>();
      await act(() => {
        for (const [value] of timing.mock.calls.filter(
          ([, config]) => config.toValue === 1,
        )) {
          ok(value instanceof Animated.Value);
          const listener = value.addListener(({ value: frame }) => {
            restoredFrames.set(value, frame);
          });
          stopListening.push(() => {
            value.removeListener(listener);
          });
          value.setValue(0.5);
        }
      });
      expect({
        synchronized,
        archived,
        scrolled,
        undone: leaving('Lunch on Friday'),
      }).toStrictEqual({
        synchronized: [0, 0],
        archived: [1, 1],
        scrolled: [0, 1],
        undone: [0, 0],
      });
      await act(async () => {
        await fireEvent(
          first.getByRole('button', { name: /Arrives quietly/u }),
          'accessibilityAction',
          { nativeEvent: { actionName: 'archive' } },
        );
      });
      expect([...restoredFrames.values()]).toStrictEqual([1, 1, 1, 1]);
      await fireEvent.changeText(
        first.getByLabelText('Search senders and subjects'),
        'Lunch on Friday',
      );
      // Replacing a query retires its old rows only in that window.
      expect(leaving('Arrives quietly')).toStrictEqual([0, 1]);
    } finally {
      await app.unmount();
      for (const stop of stopListening) {
        stop();
      }
      timing.mockRestore();
      frames.mockRestore();
      jest.mocked(AccessibilityInfo.announceForAccessibility).mockClear();
    }
  });

  it('undoes the latest organizing action when Edit › Undo is chosen in a window', async () => {
    expect.hasAssertions();
    const host: TurboModule &
      Readonly<{
        addListener: () => void;
        removeListeners: () => void;
        setWindowProfile: () => void;
      }> = {
      addListener: () => undefined,
      removeListeners: () => undefined,
      setWindowProfile: () => undefined,
    };
    const module = commandModule(host);
    const gmail = createSyntheticGmail();
    gmail.deliver({ subject: 'Lunch on Friday' });
    showMailboxes(singleMailbox(createInboxStore(gmail.native), alex));
    const app = await render(
      <Windows
        first
        second
      />,
    );
    const choose = async (window: string) => {
      await act(async () => {
        DeviceEventEmitter.emit('undo', { window });
        await Promise.resolve();
      });
    };
    try {
      const first = within(app.getByTestId('inbox-window-first'));
      const second = within(app.getByTestId('inbox-window-second'));
      const lunch = /Lunch on Friday/u;
      await first.findByRole('button', { name: lunch });
      // With no Undo notice, Command-Z changes nothing.
      await choose('inbox-window-first');
      await act(async () => {
        await fireEvent(
          second.getByRole('button', { name: lunch }),
          'accessibilityAction',
          { nativeEvent: { actionName: 'archive' } },
        );
      });
      expect(first.queryByRole('button', { name: lunch })).toBeNull();
      // Chosen in another window, it leaves these alone; here it presses this window's Undo, once.
      await choose('inbox-window-other');
      expect(first.getByRole('button', { name: 'Undo' })).toBeVisible();
      await choose('inbox-window-first');
      await first.findByRole('button', { name: lunch });
      await expect(
        second.findByRole('button', { name: lunch }),
      ).resolves.toBeVisible();
      await choose('inbox-window-second');
      expect(
        gmail.modifies.map(({ add, remove }) => [add, remove]),
      ).toStrictEqual([
        [[], ['INBOX']],
        [['INBOX'], []],
      ]);
    } finally {
      await app.unmount();
      module.mockRestore();
      jest.mocked(AccessibilityInfo.announceForAccessibility).mockClear();
    }
  });

  it('undoes only the latest of two mailboxes’ organizing actions when Edit › Undo is chosen after navigation', async () => {
    expect.hasAssertions();
    const host: TurboModule &
      Readonly<{
        addListener: () => void;
        removeListeners: () => void;
        setWindowProfile: () => void;
      }> = {
      addListener: () => undefined,
      removeListeners: () => undefined,
      setWindowProfile: () => undefined,
    };
    const module = commandModule(host);
    const alexGmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const otherGmail = createSyntheticGmail({
      address: 'other@example.invalid',
    });
    alexGmail.deliver({ subject: 'Lunch on Friday' });
    otherGmail.deliver({ subject: 'Dinner on Saturday' });
    const lists = [
      singleMailbox(createInboxStore(alexGmail.native), alex),
      singleMailbox(
        createInboxStore(otherGmail.native),
        syntheticMailboxes['other@example.invalid'],
      ),
    ];
    showMailboxes(bothMailboxes(lists));
    const app = await render(
      <Windows
        first
        second={false}
      />,
    );
    try {
      const first = within(app.getByTestId('inbox-window-first'));
      // The latest action is in the first mailbox listed, not the last.
      for (const subject of [/Dinner on Saturday/u, /Lunch on Friday/u]) {
        await act(async () => {
          await fireEvent(
            await first.findByRole('button', { name: subject }),
            'accessibilityAction',
            { nativeEvent: { actionName: 'archive' } },
          );
        });
      }
      expect(first.getAllByRole('button', { name: 'Undo' })).toHaveLength(2);
      // Showing the older notice again after navigation keeps the newer action the latest.
      for (const row of [
        'Inbox. In synthetic-connection-alex',
        'All Inboxes',
      ]) {
        await fireEvent.press(await first.findByRole('button', { name: row }));
      }
      expect(first.getAllByRole('button', { name: 'Undo' })).toHaveLength(2);
      await act(async () => {
        DeviceEventEmitter.emit('undo', { window: 'inbox-window-first' });
        await Promise.resolve();
      });
      await first.findByRole('button', { name: /Lunch on Friday/u });
      expect(
        [alexGmail, otherGmail].map(({ modifies }) =>
          modifies.map(({ add, remove }) => [add, remove]),
        ),
      ).toStrictEqual([
        [
          [[], ['INBOX']],
          [['INBOX'], []],
        ],
        [[[], ['INBOX']]],
      ]);
    } finally {
      await app.unmount();
      module.mockRestore();
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
    showMailboxes(singleMailbox(createInboxStore(gmail.native), alex));
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
        await second.findByRole('button', {
          name: /^Trash\. In (?!All Mailboxes)/u,
        }),
      );
      // Online results come from the mailbox, independently of this window's Trash view.
      const field = second.getByLabelText('Search senders and subjects');
      await fireEvent.changeText(field, 'Lunch');
      await fireEvent.press(
        second.getByRole('button', { name: 'Search Mail Servers for “Lunch”' }),
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
          name: 'Search Mail Servers for “Archived”',
        }),
      );
      await fireEvent.press(
        await second.findByRole('button', { name: /Archived flight/u }),
      );
      expect(second.queryByRole('button', { name: 'Archive' })).toBeNull();
      expect(second.queryByRole('button', { name: 'Folders' })).toBeNull();
    } finally {
      await app.unmount();
      jest.mocked(AccessibilityInfo.announceForAccessibility).mockClear();
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
    showMailboxes(singleMailbox(createInboxStore(gmail.native), alex));
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
    await fireEvent.press(await first.findByRole('link', { name: 'the plan' }));
    expect(sheetsShown().map(({ passage }) => passage)).toStrictEqual([
      'https://example.invalid/plan',
    ]);
    await act(() => {
      chooseSheetButton('Cancel');
    });
    expect(sheetsShown()).toStrictEqual([]);
    await fireEvent.press(first.getByRole('link', { name: 'the plan' }));
    await fireEvent.press(
      await second.findByRole('button', { name: /Other window/u }),
    );
    await fireEvent.press(
      await second.findByRole('link', { name: 'other plan' }),
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
    expect(sheetsShown().map(({ passage }) => passage)).toStrictEqual([
      'https://example.invalid/other',
    ]);
    await app.rerender(
      <Windows
        first={false}
        second
      />,
    );
    expect(sheetsShown().map(({ passage }) => passage)).toStrictEqual([
      'https://example.invalid/other',
    ]);
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
    await createInboxStore(gmail.native).load();
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
      first.getByText(/^No saved mail in .+ matches “No saved match”\./u),
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
      expect(window.queryByRole('button', { name: 'Folders' })).toBeNull();
      // Pin is product state, so it does not wait for Gmail access.
      expect(window.getByRole('button', { name: maya })).toHaveProp(
        'accessibilityActions',
        [{ name: 'pin', label: 'Pin' }],
      );
      expect(window.getByRole('button', { name: 'Pin' })).toBeVisible();
    }
    await act(async () => {
      held.release();
      await list.load();
    });
    // Once Gmail access verifies, each window's open message is read.
    const readMaya = 'Maya Chen. A little more room to think';
    const readOliver = 'Oliver Park. Saturday, by the river?';
    expect(first.getByRole('button', { name: 'Folders' })).toBeVisible();
    expect(second.getByRole('button', { name: 'Folders' })).toBeVisible();
    // Archiving in one window closes its reader and updates the other, which keeps its selection;
    // Undo from either window brings the message back to both.
    await act(async () => {
      await fireEvent.press(first.getByRole('button', { name: 'Archive' }));
    });
    expect(first.getByText('Select a message to start reading.')).toBeVisible();
    expect(second.queryByRole('button', { name: readMaya })).toBeNull();
    expect(second.getByText('oliver@example.invalid')).toBeVisible();
    expect(
      second.getByLabelText('Archived: “A little more room to think”.'),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(second.getByRole('button', { name: 'Undo' }));
    });
    expect(first.getByRole('button', { name: readMaya })).toBeVisible();
    expect(second.getByRole('button', { name: readMaya })).toBeVisible();
    expect(
      gmail.modifies.map(({ add, remove }) => [add, remove]),
    ).toStrictEqual([
      [[], ['UNREAD']],
      [[], ['UNREAD']],
      [[], ['INBOX']],
      [['INBOX'], []],
    ]);

    // A VoiceOver row action that removes the selected message closes that reader too; Undo keeps
    // it closed, the other window keeps its selection, and the outcome is announced once.
    const announce = jest.mocked(AccessibilityInfo.announceForAccessibility);
    await fireEvent.press(first.getByRole('button', { name: readMaya }));
    expect(first.getByText('maya@example.invalid')).toBeVisible();
    await act(async () => {
      await fireEvent(
        first.getByRole('button', { name: readMaya }),
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
    expect(first.getByRole('button', { name: readMaya })).toBeVisible();
    expect(first.getByText('Select a message to start reading.')).toBeVisible();
    expect(second.getByText('oliver@example.invalid')).toBeVisible();
    // The same action again is a new outcome with the same words, and is announced again.
    await act(async () => {
      await fireEvent(
        second.getByRole('button', { name: readMaya }),
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
    expect(second.getByRole('button', { name: readMaya })).toBeVisible();

    // A refusal keeps its alert semantics while sharing one explicit announcement.
    gmail.failModify({ status: 400 });
    await act(async () => {
      await fireEvent(
        second.getByRole('button', { name: readOliver }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'unread' } },
      );
    });
    const refusal =
      'Gmail could not mark as unread “Saturday, by the river?”. The Inbox shows it as Gmail has it.';
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
      second.getByRole('button', { name: 'Allow Gmail Access' }),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(
        first.getByRole('button', { name: 'Allow Gmail Access' }),
      );
      await Promise.resolve();
    });
    expect(authorized).toContain(alex);
    gmail.fail({ code: 'unavailable' });
    await act(list.load);
    // Each window's Sync Status Capsule reports the unreachable mailbox.
    for (const window of [first, second]) {
      expect(
        window.getByRole('button', { name: '1 account needs attention' }),
      ).toBeOnTheScreen();
    }
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
        ['Mark as Read', 'Pin'],
        ['Delete'],
      ]);
      await fireEvent.press(row);
      await window.findByRole('button', { name: 'Folders' });
      const sender = contextMenuOf(window.getByText('oliver@example.invalid'));
      expect(menuSections(sender)).toStrictEqual([
        ['Copy Address'],
        ['Block Sender…', 'Block Domain…'],
      ]);
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
      // VoiceOver reads the full date; the header shows the short one.
      const received = within(message).getByLabelText(/\d{4} at \d/u);
      // Selectable native date text consumes secondary clicks before the message menu.
      expect({
        selectableDate:
          within(received).getByText(/\d:\d\d/u).props.selectable === true,
      }).toStrictEqual({ selectableDate: false });
      expect(menuSections(message)).toStrictEqual([
        ['Mark as Unread', 'Pin'],
        [['Move to…', ['Travel']], 'Delete'],
      ]);
      await chooseFromMenu(message, 'Delete');
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

  it('moves an open message to Yesterday in its row and its header on the same midnight tick', async () => {
    expect.hasAssertions();
    jest.useFakeTimers({
      now: Date.parse('2026-10-13T23:59:30Z'),
      advanceTimers: true,
    });
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
      at: Date.parse('2026-10-13T08:12:00Z'),
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
      await fireEvent.press(
        await window.findByRole('button', { name: oliver }),
      );
      // Opening the message marks it read, which renames its row.
      const day = () => ({
        divider: window.queryByRole('header', { name: 'Yesterday' }) !== null,
        row: ['8:12 AM', 'Yesterday'].find(
          (label) =>
            within(
              window.getByRole('button', { name: /Oliver Park\. Saturday/u }),
            ).queryByText(label) !== null,
        ),
        header: window.queryByText('Yesterday, 8:12 AM') !== null,
      });
      await window.findByText('Today, 8:12 AM');
      expect(day()).toStrictEqual({
        divider: false,
        row: '8:12 AM',
        header: false,
      });
      await act(() => jest.advanceTimersByTimeAsync(30_000));
      expect(day()).toStrictEqual({
        divider: true,
        row: 'Yesterday',
        header: true,
      });
    } finally {
      await app.unmount();
      jest.useRealTimers();
    }
  });

  it('blocks a sender’s exact address for the Profile from the sender menu after confirming', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({
      from: 'Oliver Park <Oliver@Example.invalid>',
      subject: 'Saturday, by the river?',
    });
    const { registration } = await connectedRegistration();
    // Blocked Sender storage on this device, which refuses the first write and accepts the rest.
    const saved = { revision: 0, document: null as string | null };
    const commitBlockedSenders = jest
      .fn<
        Promise<{ owner: string; revision: number }>,
        [string, number, string]
      >()
      .mockRejectedValueOnce(
        Object.assign(new Error('locked'), { code: 'locked' }),
      )
      .mockImplementation((owner, revision, document) => {
        Object.assign(saved, { revision: revision + 1, document });
        return Promise.resolve({ owner, revision: saved.revision });
      });
    const blocked = createBlockedSenders(
      {
        openBlockedSenders: () =>
          Promise.resolve({
            owner: ownerOf(registration.getSnapshot().snapshot),
            ...saved,
          }),
        commitBlockedSenders,
      },
      registration,
    );
    showMailboxes(
      createMailboxes(
        syntheticConnections({ [alex]: { native: gmail.native } }),
        registration,
      ),
    );
    const app = await render(
      <BlockedSendersContext value={blocked}>
        <RegistrationGate
          store={started(registration)}
          preview={false}>
          <InboxWindow windowId="first" />
        </RegistrationGate>
      </BlockedSendersContext>,
    );
    try {
      const window = within(await app.findByTestId('inbox-window-first'));
      await fireEvent.press(
        await window.findByRole('button', { name: oliver }),
      );
      const sender = contextMenuOf(
        await window.findByText('Oliver@Example.invalid'),
      );
      const block = async () => {
        await chooseFromMenu(sender, 'Block Sender…');
        await waitFor(() => {
          ok(sheetShown());
        });
      };
      await block();
      expect(sheetShown()).toMatchObject({
        title: 'Block oliver@example.invalid?',
        detail:
          'New mail from this address goes to Trash in your Primary Profile. The 1 message you have now stays where it is, and the sender isn’t told.',
        // As the approved frame shows, Block Sender is the default action and Escape cancels.
        buttons: ['Block Sender', 'Cancel'],
        cancel: 1,
      });
      expect(sheetShown()).not.toHaveProperty('destructive');
      await act(async () => {
        chooseSheetButton('Cancel');
      });
      await block();
      await act(async () => {
        chooseSheetButton('Block Sender');
      });
      await waitFor(() => {
        expect(sheetShown()).toMatchObject({
          title: 'oliver@example.invalid couldn’t be blocked',
          detail:
            'The block wasn’t saved on this device, so new mail from this address still arrives as usual. Try again.',
        });
      });
      await act(async () => {
        chooseSheetButton('OK');
      });
      await block();
      await act(async () => {
        chooseSheetButton('Block Sender');
      });
      await waitFor(async () => {
        await expect(
          blocked.blockedSenders(defaultProfile),
        ).resolves.toMatchObject([{ address: 'oliver@example.invalid' }]);
      });
      expect(sheetShown()).toBeUndefined();
      // Blocking leaves the mail already here in place.
      expect(window.getByText('Oliver@Example.invalid')).toBeVisible();
    } finally {
      await app.unmount();
    }
  });

  it('blocks a sender’s exact domain for the Profile from the sender menu in a sheet with its choices', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    gmail.deliver({
      from: 'Northwind Deals <Offers@Mail.NW-Deals.com>',
      subject: '48-hour flash sale',
    });
    gmail.deliver({
      from: 'Key Club <eva@\u212Aey.example>',
      subject: 'Members only',
    });
    const { registration } = await connectedRegistration();
    // Blocked Sender storage on this device, which refuses the first write and accepts the rest.
    const saved = { revision: 0, document: null as string | null };
    const commitBlockedSenders = jest
      .fn<
        Promise<{ owner: string; revision: number }>,
        [string, number, string]
      >()
      .mockRejectedValueOnce(
        Object.assign(new Error('locked'), { code: 'locked' }),
      )
      .mockImplementation((owner, revision, document) => {
        Object.assign(saved, { revision: revision + 1, document });
        return Promise.resolve({ owner, revision: saved.revision });
      });
    const blocked = createBlockedSenders(
      {
        openBlockedSenders: () =>
          Promise.resolve({
            owner: ownerOf(registration.getSnapshot().snapshot),
            ...saved,
          }),
        commitBlockedSenders,
      },
      registration,
    );
    showMailboxes(
      createMailboxes(
        syntheticConnections({ [alex]: { native: gmail.native } }),
        registration,
      ),
    );
    // A readable contact at the domain, and one at its parent, which the block leaves alone.
    Object.assign(appleContacts, {
      granted: true,
      addresses: [
        { sender: 'Eva', address: 'Eva@mail.nw-deals.com' },
        { sender: 'Ivan', address: 'ivan@nw-deals.com' },
      ],
    });
    const app = await render(
      <BlockedSendersContext value={blocked}>
        <MacWindows store={registration}>
          <RegistrationGate
            store={started(registration)}
            preview={false}>
            <InboxWindow windowId="first" />
          </RegistrationGate>
        </MacWindows>
      </BlockedSendersContext>,
    );
    try {
      const window = within(await app.findByTestId('inbox-window-first'));
      // A domain that arrived as a folded lookalike is offered Block Sender… alone.
      await fireEvent.press(
        await window.findByRole('button', { name: /Key Club/u }),
      );
      const lookalike = menuSections(
        contextMenuOf(await window.findByText('eva@\u212Aey.example')),
      ).flat();
      expect(lookalike).toContain('Block Sender…');
      expect(lookalike).not.toContain('Block Domain…');
      await fireEvent.press(
        await window.findByRole('button', { name: /Northwind Deals/u }),
      );
      const sender = contextMenuOf(
        await window.findByText('Offers@Mail.NW-Deals.com'),
      );
      const open = async () => {
        await chooseFromMenu(sender, 'Block Domain…');
        const node = await waitFor(() => {
          const found = blockDomainSheet();
          ok(found);
          return found;
        });
        return within(node);
      };
      // Block Domain… sits directly under Block Sender….
      expect(menuSections(sender).flat().slice(-2)).toStrictEqual([
        'Block Sender…',
        'Block Domain…',
      ]);
      let sheet = await open();
      expect(blockDomainParent()).toBe('inbox-window-first');
      expect(
        sheet.getByRole('header', { name: 'Block mail.nw-deals.com' }),
      ).toBeVisible();
      for (const text of [
        'From “Northwind Deals” <offers@mail.nw-deals.com>',
        'Blocks @mail.nw-deals.com and every subdomain',
        'Doesn’t block nw-deals.com, other domains or names that look alike',
      ]) {
        expect(sheet.getByText(text)).toBeVisible();
      }
      expect(
        sheet.getByRole('radio', {
          name: 'mail.nw-deals.com and its subdomains',
        }),
      ).toBeChecked();
      await expect(
        sheet.findByText('eva@mail.nw-deals.com'),
      ).resolves.toBeVisible();
      // Cancel blocks nothing.
      await fireEvent.press(sheet.getByRole('button', { name: 'Cancel' }));
      expect(blockDomainSheet()).toBeNull();
      await expect(
        blocked.blockedDomains(defaultProfile),
      ).resolves.toStrictEqual([]);
      sheet = await open();
      // Each opening starts from the frames' choices; “only” and no exemption are stored as chosen.
      await fireEvent.press(
        sheet.getByRole('radio', { name: 'mail.nw-deals.com only' }),
      );
      expect(sheet.getByText('Blocks @mail.nw-deals.com only')).toBeVisible();
      await fireEvent(
        await sheet.findByRole('switch', { name: 'Contacts at this domain' }),
        'valueChange',
        false,
      );
      const block = sheet.getByRole('button', {
        name: 'Block mail.nw-deals.com',
      });
      await waitFor(() => {
        expect(block).toBeEnabled();
      });
      // A refused write says so and keeps the sheet open.
      await act(async () => {
        await fireEvent.press(block);
      });
      await expect(
        sheet.findByText('mail.nw-deals.com couldn’t be blocked'),
      ).resolves.toBeVisible();
      ok(blockDomainSheet());
      await act(async () => {
        await fireEvent.press(block);
      });
      await waitFor(() => {
        expect(blockDomainSheet()).toBeNull();
      });
      await expect(
        blocked.blockedDomains(defaultProfile),
      ).resolves.toMatchObject([
        { domain: 'mail.nw-deals.com', subdomains: false, exempt: [] },
      ]);
      // With the frames' choices, the contact at the domain is exempt.
      sheet = await open();
      await act(async () => {
        await fireEvent.press(
          sheet.getByRole('button', { name: 'Block mail.nw-deals.com' }),
        );
      });
      await waitFor(() => {
        expect(blockDomainSheet()).toBeNull();
      });
      await expect(
        blocked.blockedDomains(defaultProfile),
      ).resolves.toMatchObject([
        {
          domain: 'mail.nw-deals.com',
          subdomains: true,
          exempt: ['eva@mail.nw-deals.com'],
        },
      ]);
      // Blocking leaves the mail already here in place.
      expect(window.getByText('Offers@Mail.NW-Deals.com')).toBeVisible();
      // Unreadable Contacts are named before Block, which then asks, and Try Again reads them again.
      appleContacts.unreadable = true;
      sheet = await open();
      await expect(
        sheet.findByText(
          'Contacts couldn’t be read, so new mail from your contacts at mail.nw-deals.com and its subdomains would go to Trash too. To read them again, choose Block, then Try Again.',
        ),
      ).resolves.toBeVisible();
      await act(async () => {
        await fireEvent.press(
          sheet.getByRole('button', { name: 'Block mail.nw-deals.com' }),
        );
      });
      expect(sheetShown()).toMatchObject({
        title: 'Block mail.nw-deals.com without exempting contacts?',
        buttons: ['Try Again', 'Block mail.nw-deals.com', 'Cancel'],
        cancel: 2,
        destructive: 1,
      });
      appleContacts.unreadable = false;
      await act(async () => {
        chooseSheetButton('Try Again');
      });
      await expect(
        sheet.findByRole('switch', { name: 'Contacts at this domain' }),
      ).resolves.toBeVisible();
      expect(blockDomainSheet()).not.toBeNull();
    } finally {
      Object.assign(appleContacts, {
        granted: false,
        unreadable: false,
        addresses: [],
      });
      await app.unmount();
    }
  });

  it('pins and unpins a Thread from the reader, its rows and the Command Palette without changing the provider', async () => {
    expect.hasAssertions();
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
    const { registration } = await connectedRegistration();
    // Pin storage on this device, which refuses the first write and accepts the rest.
    const saved = { revision: 0, document: null as string | null };
    const commitPins = jest
      .fn<
        Promise<{ owner: string; revision: number }>,
        [string, number, string]
      >()
      .mockRejectedValueOnce(
        Object.assign(new Error('conflict'), { code: 'conflict' }),
      )
      .mockImplementation((owner, revision, document) => {
        Object.assign(saved, { revision: revision + 1, document });
        return Promise.resolve({ owner, revision: saved.revision });
      });
    const pins = createPins(
      {
        openPins: () =>
          Promise.resolve({
            owner: ownerOf(registration.getSnapshot().snapshot),
            ...saved,
          }),
        commitPins,
      },
      registration,
    );
    showMailboxes(
      createMailboxes(
        syntheticConnections({ [alex]: { native: gmail.native } }),
        registration,
      ),
    );
    const app = await render(
      <PinsContext value={pins}>
        <RegistrationGate
          store={started(registration)}
          preview={false}>
          <InboxWindow windowId="first" />
        </RegistrationGate>
      </PinsContext>,
    );
    const row = 'Oliver Park. Saturday, by the river?';
    const replyRow = 'Oliver Park. Re: Saturday, by the river?';
    try {
      const window = within(await app.findByTestId('inbox-window-first'));
      const press = async (name: string) => {
        await act(async () => {
          await fireEvent.press(await window.findByRole('button', { name }));
        });
      };
      const listed = await window.findByRole('button', { name: row });
      expect(menuSections(contextMenuOf(listed))).toStrictEqual([
        ['Archive'],
        ['Mark as Unread', 'Pin'],
        ['Delete'],
      ]);
      await press(row);
      // A Pin storage refuses changes nothing and says so.
      await press('Pin');
      await waitFor(() => {
        expect(sheetShown()).toMatchObject({
          title: 'This Thread couldn’t be pinned',
          detail:
            'The change wasn’t saved on this device, so nothing changed. Try again.',
        });
      });
      await act(async () => {
        chooseSheetButton('OK');
      });
      await expect(pins.pins([alex])).resolves.toStrictEqual([]);
      expect(
        window.queryByRole('button', { name: `${row}. Pinned` }),
      ).toBeNull();

      // Pin pins the Thread: both its messages show the marker, and the reader offers Unpin.
      await press('Pin');
      await expect(
        window.findByRole('button', { name: `${replyRow}. Pinned` }),
      ).resolves.toBeVisible();
      expect(
        window.getByRole('button', { name: `${row}. Pinned` }),
      ).toBeVisible();
      await expect(pins.pins([alex])).resolves.toMatchObject([
        { connection: alex, thread: first },
      ]);
      expect(window.getByRole('button', { name: 'Unpin' })).toBeVisible();
      const pinnedReply = window.getByRole('button', {
        name: `${replyRow}. Pinned`,
      });
      expect(menuSections(contextMenuOf(pinnedReply))).toStrictEqual([
        ['Archive'],
        ['Mark as Unread', 'Unpin'],
        ['Delete'],
      ]);
      // The provider's star and labels stay as they were.
      expect([
        ...gmail.labelsOf(first),
        ...gmail.labelsOf(reply),
      ]).not.toContain('STARRED');

      // Unpin from the reply's row unpins the whole Thread.
      await chooseFromMenu(
        contextMenuOf(
          window.getByRole('button', { name: `${replyRow}. Pinned` }),
        ),
        'Unpin',
      );
      await expect(
        window.findByRole('button', { name: row }),
      ).resolves.toBeVisible();
      expect(window.getByRole('button', { name: replyRow })).toBeVisible();
      await expect(pins.pins([alex])).resolves.toStrictEqual([]);

      // The Command Palette pins the open message's Thread too.
      await press('Open Command Palette');
      await act(async () => {
        await fireEvent.press(
          within(window.getByTestId('command-palette')).getByRole('button', {
            name: 'Pin',
          }),
        );
      });
      await expect(
        window.findByRole('button', { name: `${row}. Pinned` }),
      ).resolves.toBeVisible();
    } finally {
      await app.unmount();
    }
  });

  it('adds and removes Gmail labels from the reader’s More menu and moves from its folder menu', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const travel = gmail.createLabel('Travel');
    const receipts = gmail.createLabel('Receipts');
    const id = gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
    });
    gmail.setLabel(id, travel, true);
    const { registration } = await connectedRegistration();
    const list = createMailboxes(
      syntheticConnections({ [alex]: { native: gmail.native } }),
      registration,
    );
    showMailboxes(list);
    const app = await render(
      <RegistrationGate
        store={started(registration)}
        preview={false}>
        <InboxWindow windowId="first" />
      </RegistrationGate>,
    );
    try {
      const window = within(await app.findByTestId('inbox-window-first'));
      await fireEvent.press(
        await window.findByRole('button', { name: oliver }),
      );
      const more = await window.findByRole('button', { name: 'More' });
      expect(window.queryByRole('button', { name: 'Labels' })).toBeNull();
      await fireEvent.press(more);
      // Mark as Read and Move to are the toolbar's own buttons, so More holds only Labels.
      expect(menuItems()).toMatchObject([
        {
          title: 'Labels',
          sections: [
            {
              items: [
                { title: 'Receipts', checked: false },
                { title: 'Travel', checked: true },
              ],
            },
            { items: [{ title: 'New Label…' }] },
          ],
        },
      ]);
      await chooseSubmenuItem('Labels', 'Receipts');
      await waitFor(() => {
        expect(gmail.labelsOf(id)).toContain(receipts);
      });
      await fireEvent.press(more);
      expect(submenuItems('Labels')).toMatchObject([
        { title: 'Receipts', checked: true },
        { title: 'Travel', checked: true },
        { title: 'New Label…' },
      ]);
      await chooseSubmenuItem('Labels', 'Travel');
      await waitFor(() => {
        expect(gmail.labelsOf(id)).not.toContain(travel);
      });
      expect(gmail.labelsOf(id)).toContain('INBOX');
      // The folder button's Move menu moves the message out of the Inbox, closing the reader.
      await fireEvent.press(window.getByRole('button', { name: 'Folders' }));
      await chooseMenuItem('Travel');
      await waitFor(() => {
        expect(gmail.labelsOf(id)).not.toContain('INBOX');
      });
      expect(gmail.labelsOf(id)).toContain(travel);
      expect(
        window.getByText('Select a message to start reading.'),
      ).toBeVisible();
    } finally {
      await app.unmount();
    }
  });

  it('creates and applies a Gmail label from the reader’s Labels popover', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
    const travel = gmail.createLabel('Travel');
    const receipts = gmail.createLabel('Receipts');
    const clients = gmail.createLabel('Clients');
    const id = gmail.deliver({
      from: 'Oliver Park <oliver@example.invalid>',
      subject: 'Saturday, by the river?',
    });
    // Label creation requests, whose Gmail answer the test may hold.
    const creating = jest.spyOn(gmail.native, 'gmailCreateLabel');
    const created = () => creating.mock.calls.map(([name]) => name);
    let refuse: (answer: { status: number; body: string }) => void = () =>
      undefined;
    // oxlint-disable-next-line promise/avoid-new -- A Gmail answer the test releases.
    const held = new Promise<{ status: number; body: string }>((resolve) => {
      refuse = resolve;
    });
    let refuseLate: typeof refuse = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- A Gmail answer the test releases.
    const heldLate = new Promise<{ status: number; body: string }>(
      (resolve) => {
        refuseLate = resolve;
      },
    );
    const { registration } = await connectedRegistration();
    const list = createMailboxes(
      syntheticConnections({ [alex]: { native: gmail.native } }),
      registration,
    );
    showMailboxes(list);
    const app = await render(
      <RegistrationGate
        store={started(registration)}
        preview={false}>
        <InboxWindow windowId="first" />
      </RegistrationGate>,
    );
    const paletteSpy = jest
      .spyOn(
        jest.requireActual<{ usePalette: typeof usePalette }>(
          '../src/theme.ts',
        ),
        'usePalette',
      )
      .mockReturnValue(palette.light);
    try {
      const window = within(await app.findByTestId('inbox-window-first'));
      await fireEvent.press(
        await window.findByRole('button', { name: oliver }),
      );
      const more = await window.findByRole('button', { name: 'More' });
      // New Label… opens Labels below the toolbar; Apply creates the label in Gmail and applies it.
      // AppKit shows the popover once its content has a size; Jest lays out nothing.
      const labelsPopover = async () => {
        const panel = window.getByTestId('new-label');
        await fireEvent(panel, 'layout', {
          nativeEvent: { layout: { width: 360, height: 432 } },
        });
        let popover = panel;
        while (popover.type !== 'UnwiredPopover') {
          popover = popover.parent!;
        }
        return popover;
      };
      const newLabel = async () => {
        await fireEvent.press(
          await window.findByRole('button', { name: 'More' }),
        );
        await chooseSubmenuItem('Labels', 'New Label…');
        await expect(labelsPopover()).resolves.toHaveProp('shown', true);
        return within(window.getByTestId('new-label'));
      };
      let labels = await newLabel();
      expect(labels.getByRole('header', { name: 'Labels' })).toBeVisible();
      expect(labels.getByText('Gmail · alex@example.invalid')).toBeVisible();
      expect(
        labels.queryByRole('header', { name: 'Matching labels' }),
      ).toBeNull();
      expect(labels.getByRole('button', { name: 'Apply' })).toBeDisabled();
      // A slash nests the label in the one named before it.
      await fireEvent.changeText(
        labels.getByLabelText('Label name'),
        '  Travel/Lisbon  ',
      );
      expect(
        labels.getByRole('button', {
          name: 'Create “Lisbon” inside “Travel”, Created in Gmail, then applied',
        }),
      ).toBeVisible();
      expect(
        labels.getByRole('header', { name: 'Matching labels' }),
      ).toBeVisible();
      // Appearance changes keep the name already typed.
      paletteSpy.mockReturnValue(palette.dark);
      await app.rerender(
        <RegistrationGate
          store={started(registration)}
          preview={false}>
          <InboxWindow windowId="first" />
        </RegistrationGate>,
      );
      labels = within(window.getByTestId('new-label'));
      expect(labels.getByLabelText('Label name')).toHaveDisplayValue(
        '  Travel/Lisbon  ',
      );
      await fireEvent.press(
        labels.getByRole('button', {
          name: 'Create “Lisbon” inside “Travel”, Created in Gmail, then applied',
        }),
      );
      await expect(labelsPopover()).resolves.toHaveProp('shown', false);
      expect(created()).toStrictEqual(['Travel/Lisbon']);
      await fireEvent(await labelsPopover(), 'close');
      await fireEvent.press(more);
      await waitFor(() => {
        expect(submenuItems('Labels')).toContainEqual(
          expect.objectContaining({ title: 'Travel/Lisbon', checked: true }),
        );
      });
      // Cancel closes Labels without a change.
      await chooseSubmenuItem('Labels', 'New Label…');
      labels = within(window.getByTestId('new-label'));
      await fireEvent.changeText(labels.getByLabelText('Label name'), 'Work');
      await fireEvent.press(labels.getByRole('button', { name: 'Cancel' }));
      await expect(labelsPopover()).resolves.toHaveProp('shown', false);
      // A name another label has in another case creates nothing: Edit Name returns to it, and
      // Use applies that label.
      labels = await newLabel();
      await fireEvent.changeText(labels.getByLabelText('Label name'), 'travel');
      expect(labels.queryByRole('button', { name: /^Create/u })).toBeNull();
      await fireEvent(labels.getByLabelText('Label name'), 'submitEditing');
      expect(sheetShown()).toStrictEqual({
        title: '“travel” wasn’t created',
        detail:
          'Gmail already has a label with this name in a different case. Nothing was applied.',
        buttons: ['Use “Travel”', 'Edit Name'],
      });
      await expect(labelsPopover()).resolves.toHaveProp('shown', false);
      await act(async () => {
        chooseSheetButton('Edit Name');
      });
      await expect(labelsPopover()).resolves.toHaveProp('shown', true);
      labels = within(window.getByTestId('new-label'));
      expect(labels.getByLabelText('Label name')).toHaveDisplayValue('travel');
      await fireEvent.press(labels.getByRole('button', { name: 'Apply' }));
      await act(async () => {
        chooseSheetButton('Use “Travel”');
      });
      await waitFor(() => {
        expect(gmail.labelsOf(id)).toContain(travel);
      });
      // A label's exact name applies it without creating one, as choosing it in the list does.
      labels = await newLabel();
      await fireEvent.changeText(
        labels.getByLabelText('Label name'),
        'Receipts',
      );
      await fireEvent(labels.getByLabelText('Label name'), 'submitEditing');
      await expect(labelsPopover()).resolves.toHaveProp('shown', false);
      await waitFor(() => {
        expect(gmail.labelsOf(id)).toContain(receipts);
      });
      // Choosing New Label… again before AppKit reports the last popover closed keeps Labels open.
      const closing = await labelsPopover();
      labels = await newLabel();
      await fireEvent(closing, 'close');
      await expect(labelsPopover()).resolves.toHaveProp('shown', true);
      await fireEvent.press(labels.getByRole('button', { name: 'Clients' }));
      await expect(labelsPopover()).resolves.toHaveProp('shown', false);
      await waitFor(() => {
        expect(gmail.labelsOf(id)).toContain(clients);
      });
      expect(created()).toStrictEqual(['Travel/Lisbon']);
      // A name Gmail refuses is explained and nothing is applied. Closing and reopening Labels
      // while Gmail answers keeps the name, and OK returns to it.
      const applied = gmail.labelsOf(id);
      creating.mockImplementationOnce(async () => held);
      labels = await newLabel();
      await fireEvent.changeText(labels.getByLabelText('Label name'), 'Work');
      await fireEvent.press(labels.getByRole('button', { name: 'Apply' }));
      expect(labels.getByRole('button', { name: 'Cancel' })).toBeDisabled();
      // A click outside closes the AppKit popover.
      await fireEvent(await labelsPopover(), 'close');
      expect(window.queryByTestId('new-label')).toBeNull();
      labels = await newLabel();
      expect(labels.getByLabelText('Label name')).toHaveDisplayValue('Work');
      expect(labels.getByRole('button', { name: 'Apply' })).toBeDisabled();
      await act(async () => {
        refuse({ status: 409, body: '{}' });
      });
      await waitFor(() => {
        expect(sheetShown()).toMatchObject({
          title: '“Work” could not be created in Gmail',
          buttons: ['OK'],
        });
      });
      await expect(labelsPopover()).resolves.toHaveProp('shown', false);
      await act(async () => {
        chooseSheetButton('OK');
      });
      await expect(labelsPopover()).resolves.toHaveProp('shown', true);
      labels = within(window.getByTestId('new-label'));
      expect(labels.getByLabelText('Label name')).toHaveDisplayValue('Work');
      expect(gmail.labelsOf(id)).toStrictEqual(applied);
      gmail.failCreateLabel({ status: 409 });
      await fireEvent.press(labels.getByRole('button', { name: 'Apply' }));
      await waitFor(() => {
        expect(sheetShown()).toMatchObject({
          title: '“Work” could not be created in Gmail',
        });
      });
      // Locking the Inbox retires its failure sheet before the reader can reopen.
      gmail.failOpen('locked');
      await act(async () => {
        await list.load();
      });
      expect(sheetsShown()).toStrictEqual([]);
      await act(async () => {
        await list.load();
      });
      expect(gmail.labelsOf(id)).toStrictEqual(applied);
      // A refusal arriving after the reader closed Labels asks nothing.
      creating.mockImplementationOnce(async () => heldLate);
      labels = await newLabel();
      await fireEvent.changeText(labels.getByLabelText('Label name'), 'Work');
      await fireEvent.press(labels.getByRole('button', { name: 'Apply' }));
      // Saved mail stays in the reader, without organizing actions.
      const open = gmail.native.openMailbox.bind(gmail.native);
      jest
        .spyOn(gmail.native, 'openMailbox')
        .mockImplementation(async (...request) => ({
          ...(await open(...request)),
          availability: 'retry',
        }));
      await act(async () => {
        await list.load();
      });
      expect(window.queryByTestId('new-label')).toBeNull();
      await act(async () => {
        refuseLate({ status: 409, body: '{}' });
      });
      expect(sheetsShown()).toStrictEqual([]);
    } finally {
      await app.unmount();
      paletteSpy.mockRestore();
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
        nativeEvent: { actionName: 'archive' },
      });
    });
    await expect(
      app.findByText('This device was removed'),
    ).resolves.toBeVisible();
    expect(app.queryByText('A little more room to think')).toBeNull();
    expect(app.queryByText(/can’t be shown\. It has been kept/u)).toBeNull();
  });
  /* oxlint-enable vitest/max-expects */
});

describe('mac windows of different Mail Profiles', () => {
  // The account lists the Work Profile, so a window AppKit restored with it keeps it.
  function WithWork({
    children,
    account = 'synthetic-product-account',
  }: {
    readonly children: ReactNode;
    readonly account?: string;
  }) {
    return (
      <AccountContext
        value={{
          mailboxes: [],
          openAccount: () => undefined,
          authorizeMailbox: () => Promise.resolve(),
          refreshInbox: (load) => load(),
          account,
          profiles:
            account === 'synthetic-product-account'
              ? [{ id: 'work', name: 'Work', color: 'teal', icon: 'laptop' }]
              : [],
          createProfile: () => Promise.resolve(undefined),
          chooseFolders: () => Promise.resolve(true),
        }}>
        {children}
      </AccountContext>
    );
  }

  it('shows each Profile’s monogram in the Profile Switcher and Profile Menu', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    showMailboxes(singleMailbox(createInboxStore(gmail.native), alex));
    const app = await render(
      <WithWork>
        <InboxWindow windowId="primary" />
      </WithWork>,
    );
    // The Default Profile keeps Graphite and its name's first letter.
    const switcher = await app.findByLabelText('Profile, Primary Profile');
    expect(
      within(switcher).getByText('P', { includeHiddenElements: true }),
    ).toHaveStyle({ color: palette.light.brandOnDeep });
    await fireEvent.press(switcher);
    expect(
      menuItems().map(({ title, monogram }) => [title, monogram]),
    ).toStrictEqual([
      [
        'Primary Profile',
        { color: palette.light.brandMonogram, symbol: '', letter: 'P' },
      ],
      ['Work', { color: '#0E7490', symbol: 'laptopcomputer', letter: 'W' }],
      ['New Profile…', undefined],
      ['Manage Profiles…', undefined],
    ]);
    await dismissMenu();
  });

  it('clears selection and search when a reused window leaves and returns to its Profile', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    gmail.deliver({
      subject: 'Garden plan',
      content: { text: 'Synthetic garden body.' },
    });
    showMailboxes(singleMailbox(createInboxStore(gmail.native), alex));
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
      showMailboxes(singleMailbox(createInboxStore(gmail.native), alex));
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
      await chooseProfile(
        first.getByLabelText('Profile, Primary Profile'),
        'Work',
      );
      // The switched window remounts its contents for the new Profile.
      const switched = within(app.getByTestId('inbox-window-first'));
      await expect(
        switched.findByLabelText('Profile, Work'),
      ).resolves.toBeVisible();
      expect(
        switched.queryByRole('button', { name: /Garden plan/u }),
      ).toBeNull();
      expect(
        second.getByRole('button', { name: /Garden plan/u }),
      ).toBeVisible();
      expect(second.getByLabelText('Profile, Primary Profile')).toBeVisible();
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

  it('drops a window’s switched Profile once another Product Account signs in', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    gmail.deliver({ subject: 'Garden plan' });
    showMailboxes(singleMailbox(createInboxStore(gmail.native), alex));
    const app = await render(
      <WithWork>
        <InboxWindow windowId="account" />
      </WithWork>,
    );
    await chooseProfile(
      await app.findByLabelText('Profile, Primary Profile'),
      'Work',
    );
    await expect(app.findByLabelText('Profile, Work')).resolves.toBeVisible();
    await app.rerender(
      <WithWork account="another-product-account">
        <InboxWindow windowId="account" />
      </WithWork>,
    );
    await expect(
      app.findByLabelText('Profile, Primary Profile'),
    ).resolves.toBeVisible();
  });

  it('opens a new window in the Startup Profile and a restored window in its own', async () => {
    expect.hasAssertions();
    const nativeRegistration = TurboModuleRegistry.getEnforcing<
      TurboModule & { preference: (key: string) => Promise<unknown> }
    >('UnwiredRegistration');
    const preference = jest
      .spyOn(nativeRegistration, 'preference')
      .mockImplementation((key) =>
        Promise.resolve({
          value:
            // oxlint-disable-next-line vitest/no-conditional-in-test -- Only the Startup Profile is saved.
            key === 'startup-profile:synthetic-product-account' ? 'work' : null,
        }),
      );
    try {
      const gmail = createSyntheticGmail();
      gmail.deliver({ subject: 'Garden plan' });
      showMailboxes(singleMailbox(createInboxStore(gmail.native), alex));
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
        opened.findByLabelText('Profile, Work'),
      ).resolves.toBeVisible();
      expect(opened.queryByRole('button', { name: /Garden plan/u })).toBeNull();
      await expect(
        restored.findByRole('button', { name: /Garden plan/u }),
      ).resolves.toBeVisible();
    } finally {
      preference.mockRestore();
      // The shared store keeps the last choices it read; read the device's again.
      await act(async () => {
        await profileChoices.load('synthetic-product-account');
      });
    }
  });

  it('keeps the window’s chosen Profile and retires its open menu when registration locks', async () => {
    expect.hasAssertions();
    const { vault } = await createTwoProfileRegistration();
    const store = createRegistration({
      ...vault,
      registration: () => vault.registration(),
    });
    await store.restore();
    const registrationModule = jest.requireMock<{
      registration: typeof store;
    }>('../src/registration.ts');
    const replaced = jest.replaceProperty(
      registrationModule,
      'registration',
      store,
    );
    const inbox = createInboxStore(createSyntheticGmail().native);
    showMailboxes(singleMailbox(inbox, alex));
    const read = jest.spyOn(vault, 'registration');
    const prompt = jest.spyOn(Alert, 'promptMacOS').mockReturnValue(undefined);
    try {
      const app = await render(<RegisteredWindow windowId="locked" />);
      await chooseProfile(
        await app.findByLabelText('Profile, Primary Profile'),
        'Work',
      );
      await expect(app.findByLabelText('Profile, Work')).resolves.toBeVisible();
      await fireEvent.press(app.getByLabelText('Profile, Work'));
      read.mockRejectedValue(
        Object.assign(new Error('locked'), { code: 'locked' }),
      );
      await act(async () => {
        await store.restore();
      });
      expect(
        app.getByRole('header', { name: 'Unlock your device' }),
      ).toBeVisible();
      expect(app.queryByLabelText('Profile, Work')).toBeNull();
      await chooseMenuItem('New Profile…');
      expect(prompt).not.toHaveBeenCalled();
      read.mockRestore();
      await act(async () => {
        await store.restore();
      });
      await expect(app.findByLabelText('Profile, Work')).resolves.toBeVisible();
    } finally {
      prompt.mockRestore();
      read.mockRestore();
      replaced.restore();
    }
  });

  /* oxlint-disable vitest/max-expects -- One journey opens, renames, adds and picks the Startup Profile. */
  it('manages Mail Profiles in the Settings window through the real registration', async () => {
    expect.hasAssertions();
    const { vault, work: workId } = await createTwoProfileRegistration();
    const store = createRegistration({
      ...vault,
      registration: () => vault.registration(),
    });
    await store.restore();
    const { snapshot } = store.getSnapshot();
    ok(snapshot.kind !== 'signed-out');
    const owner = snapshot.productAccountId;
    const replaced = jest.replaceProperty(
      jest.requireMock<{ registration: typeof store }>(
        '../src/registration.ts',
      ),
      'registration',
      store,
    );
    const inbox = createInboxStore(createSyntheticGmail().native);
    showMailboxes(singleMailbox(inbox, alex));
    const nativeRegistration = TurboModuleRegistry.getEnforcing<
      TurboModule & {
        preference: (key: string) => Promise<unknown>;
        setPreference: (key: string, value: string) => Promise<unknown>;
      }
    >('UnwiredRegistration');
    const saved = new Map<string, string>();
    const reading = jest
      .spyOn(nativeRegistration, 'preference')
      .mockImplementation((key) =>
        // oxlint-disable-next-line vitest/no-conditional-in-test -- An unsaved preference reads as null.
        Promise.resolve({ value: saved.get(key) ?? null }),
      );
    const saving = jest
      .spyOn(nativeRegistration, 'setPreference')
      .mockImplementation((key, value) => {
        saved.set(key, value);
        return Promise.resolve({});
      });
    const prompt = jest.spyOn(Alert, 'promptMacOS').mockReturnValue(undefined);
    const renaming = jest.spyOn(store, 'renameProfile');
    try {
      const app = await render(
        <MacWindows store={store}>
          <RegisteredWindow windowId="manage" />
        </MacWindows>,
      );
      await chooseProfile(
        await app.findByLabelText('Profile, Primary Profile'),
        'Manage Profiles…',
      );
      await settingsWindow().findAllByRole('header', { name: 'Profiles' });
      const settings = settingsWindow();
      const work = await settings.findByRole('button', { name: 'Work' });
      expect(work.props.accessibilityHint).toBe('Gmail');
      expect(
        settings.getByRole('button', { name: 'Primary Profile' }),
      ).toHaveAccessibilityValue({ text: 'Startup Profile' });
      // The Primary Profile keeps its name.
      expect(settings.queryByDisplayValue('Primary Profile')).toBeNull();
      await fireEvent.press(work);
      // The selected Profile keeps the subtle fill; a press stacks a second until release or cancel.
      const primary = settings.getByRole('button', { name: 'Primary Profile' });
      expect([fills(work), fills(primary)]).toStrictEqual([1, 0]);
      expect(work).toBeSelected();
      await fireEvent(work, 'responderGrant', touch);
      expect(fills(work)).toBe(2);
      await fireEvent(work, 'responderRelease', touch);
      await waitFor(() => {
        expect(fills(work)).toBe(1);
      });
      await fireEvent(primary, 'responderGrant', touch);
      expect(fills(primary)).toBe(1);
      await fireEvent(primary, 'responderTerminate', touch);
      await waitFor(() => {
        expect(fills(primary)).toBe(0);
      });
      const name = settings.getByDisplayValue('Work');
      expect(name).toHaveProp('accessibilityLabel', 'Name');
      await fireEvent.changeText(name, 'Office');
      // Return submits, ends editing and blurs before the renamed name renders.
      await act(async () => {
        await fireEvent(name, 'submitEditing');
        await fireEvent(name, 'endEditing');
        await fireEvent(name, 'blur');
      });
      await expect(
        settings.findByRole('header', { name: 'Office' }),
      ).resolves.toBeVisible();
      expect(renaming.mock.calls).toStrictEqual([[workId, 'Office']]);
      await fireEvent.press(
        settings.getByRole('button', { name: 'Startup Profile' }),
      );
      await chooseMenuItem('Office');
      expect(saving).toHaveBeenCalledWith(`startup-profile:${owner}`, workId);
      expect(
        settings.getByRole('button', { name: 'Office' }),
      ).toHaveAccessibilityValue({ text: 'Startup Profile' });
      // Startup Profile is only for a new window, not this open one.
      expect(app.getByLabelText('Profile, Primary Profile')).toBeVisible();
      // The window's Profile Menu names the renamed Profile too.
      await chooseProfile(
        app.getByLabelText('Profile, Primary Profile'),
        'Office',
      );
      await expect(
        app.findByLabelText('Profile, Office'),
      ).resolves.toBeVisible();
      await fireEvent.press(
        settings.getByRole('button', { name: 'Add Profile…' }),
      );
      const buttons = prompt.mock.lastCall?.[2];
      ok(Array.isArray(buttons));
      await act(async () => {
        // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- React Native types the value per prompt type.
        const create = buttons.find(({ text }) => text === 'Create')
          ?.onPress as ((value: string) => void) | undefined;
        create?.('Family');
        await Promise.resolve();
      });
      const family = await settings.findByRole('button', { name: 'Family' });
      expect(family.props.accessibilityHint).toBe('No mailboxes');
      await app.unmount();
      const opened = await render(
        <MacWindows store={store}>
          <RegisteredWindow windowId="new-manage" />
        </MacWindows>,
      );
      await expect(
        opened.findByLabelText('Profile, Office'),
      ).resolves.toBeVisible();
    } finally {
      renaming.mockRestore();
      prompt.mockRestore();
      saving.mockRestore();
      reading.mockRestore();
      replaced.restore();
      // The shared store keeps the last choices it read; read the device's again.
      await act(async () => {
        await profileChoices.load(owner);
      });
    }
  });
  /* oxlint-enable vitest/max-expects */

  it('names a Mail Profile with no mailboxes in its Inbox and offers Manage Mail Profiles…', async () => {
    expect.hasAssertions();
    const { vault } = await createTwoProfileRegistration();
    const store = createRegistration({
      ...vault,
      registration: () => vault.registration(),
    });
    await store.restore();
    await store.createProfile('Travel');
    const replaced = jest.replaceProperty(
      jest.requireMock<{ registration: typeof store }>(
        '../src/registration.ts',
      ),
      'registration',
      store,
    );
    const inbox = createInboxStore(createSyntheticGmail().native);
    showMailboxes(singleMailbox(inbox, alex));
    try {
      const app = await render(
        <MacWindows store={store}>
          <RegisteredWindow windowId="travel" />
        </MacWindows>,
      );
      await chooseProfile(
        await app.findByLabelText('Profile, Primary Profile'),
        'Travel',
      );
      // The subtitle names the empty scope alone, without Gmail or a synchronization status.
      await expect(
        app.findByRole('header', { name: 'All Inboxes. No mailboxes' }),
      ).resolves.toBeVisible();
      expect(app.getByText('No Mailboxes')).toBeVisible();
      expect(
        app.getByText('Move a mailbox into Travel from its current Profile.'),
      ).toBeVisible();
      // No synchronization footer, and the sidebar keeps Favorites with no mailbox section.
      expect([
        app.queryByText('Encrypted on this device'),
        app.queryByText(/^Gmail · /u),
      ]).toStrictEqual([null, null]);
      await fireEvent.press(
        app.getByRole('button', { name: 'Manage Profiles…' }),
      );
      await settingsWindow().findAllByRole('header', { name: 'Profiles' });
      await expect(
        settingsWindow().findByRole('button', { name: 'Travel' }),
      ).resolves.toBeVisible();
    } finally {
      replaced.restore();
    }
  });

  it('duplicates a Mail Profile into a selected copy with its style, without its mailboxes', async () => {
    expect.hasAssertions();
    const { vault, work } = await createTwoProfileRegistration();
    const store = createRegistration({
      ...vault,
      registration: () => vault.registration(),
      recordProfiles: (next) => vault.recordProfiles(next),
    });
    await store.restore();
    await store.restyleProfile(work, { color: 'teal', icon: 'laptop' });
    const replaced = jest.replaceProperty(
      jest.requireMock<{ registration: typeof store }>(
        '../src/registration.ts',
      ),
      'registration',
      store,
    );
    const inbox = createInboxStore(createSyntheticGmail().native);
    showMailboxes(singleMailbox(inbox, alex));
    try {
      const app = await render(
        <MacWindows store={store}>
          <RegisteredWindow windowId="duplicate" />
        </MacWindows>,
      );
      await chooseProfile(
        await app.findByLabelText('Profile, Primary Profile'),
        'Manage Profiles…',
      );
      const settings = settingsWindow();
      await fireEvent.press(
        await settings.findByRole('button', { name: 'Work' }),
      );
      const { recordProfiles } = vault;
      let release: () => void = () => undefined;
      let started: () => void = () => undefined;
      // oxlint-disable-next-line promise/avoid-new -- Controlled native persistence and its admission signal.
      const held = new Promise<void>((resolve) => {
        release = resolve;
      });
      // oxlint-disable-next-line promise/avoid-new -- Controlled native persistence and its admission signal.
      const admitted = new Promise<void>((resolve) => {
        started = resolve;
      });
      jest
        .spyOn(vault, 'recordProfiles')
        .mockImplementationOnce(async (next) => {
          started();
          await held;
          return recordProfiles(next);
        });
      // Another window's New Mail Profile… finishes ahead of Duplicate.
      const family = store.createProfile('Family');
      await admitted;
      await fireEvent.press(
        settings.getByRole('button', { name: 'Duplicate Profile' }),
      );
      release();
      await family;
      // The copy, not the Profile created elsewhere, is selected and its page opens for renaming.
      await expect(
        settings.findByRole('header', { name: 'Work Copy' }),
      ).resolves.toBeVisible();
      expect(settings.getByDisplayValue('Work Copy')).toBeVisible();
      expect(settings.getByRole('button', { name: 'Work Copy' })).toHaveProp(
        'accessibilityHint',
        'No mailboxes',
      );
      expect(settings.getByText('No mailboxes in this Profile')).toBeVisible();
      const { snapshot } = store.getSnapshot();
      const [created, copy] = profilesOf(snapshot).filter(
        ({ id }) => id !== work,
      );
      // Published through Private Sync; the mailbox stays with Work.
      expect({
        created: created?.name,
        copy,
        owners: mailboxesOf(snapshot).map(({ address, profile }) => [
          address,
          profile,
        ]),
      }).toStrictEqual({
        created: 'Family',
        copy: {
          id: copy?.id,
          name: 'Work Copy',
          color: 'teal',
          icon: 'laptop',
        },
        owners: [
          ['alex@example.invalid', defaultProfile],
          ['other@example.invalid', work],
        ],
      });
    } finally {
      replaced.restore();
      jest.restoreAllMocks();
    }
  });

  /* oxlint-disable vitest/max-expects -- One journey proves both pop-ups and that each keeps the other choice. */
  it('chooses a Mail Profile’s Color and Icon in Settings, keeping the other choice', async () => {
    expect.hasAssertions();
    const { vault, work } = await createTwoProfileRegistration();
    const store = createRegistration({
      ...vault,
      registration: () => vault.registration(),
      recordProfiles: (next) => vault.recordProfiles(next),
    });
    await store.restore();
    const replaced = jest.replaceProperty(
      jest.requireMock<{ registration: typeof store }>(
        '../src/registration.ts',
      ),
      'registration',
      store,
    );
    const inbox = createInboxStore(createSyntheticGmail().native);
    showMailboxes(singleMailbox(inbox, alex));
    const styleOf = () =>
      profilesOf(store.getSnapshot().snapshot)
        .filter(({ id }) => id === work)
        .map(({ color, icon }) => ({ color, icon }));
    try {
      const app = await render(
        <MacWindows store={store}>
          <RegisteredWindow windowId="restyle" />
        </MacWindows>,
      );
      await chooseProfile(
        await app.findByLabelText('Profile, Primary Profile'),
        'Manage Profiles…',
      );
      const settings = settingsWindow();
      // The Primary Profile has no record to style; it shows the defaults.
      await expect(settings.findByText('Graphite')).resolves.toBeVisible();
      expect(settings.getByText('First Letter')).toBeVisible();
      expect(settings.queryByRole('button', { name: 'Color' })).toBeNull();
      await fireEvent.press(settings.getByRole('button', { name: 'Work' }));
      const color = settings.getByRole('button', { name: 'Color' });
      expect(color).toHaveAccessibilityValue({ text: 'Graphite' });
      await fireEvent.press(color);
      expect(
        menuItems().map(({ title, checked }) => [title, checked]),
      ).toStrictEqual([
        ['Graphite', true],
        ['Blue', false],
        ['Indigo', false],
        ['Purple', false],
        ['Pink', false],
        ['Teal', false],
        ['Green', false],
        ['Brown', false],
      ]);
      await chooseMenuItem('Blue');
      await waitFor(() => {
        expect(styleOf()).toStrictEqual([{ color: 'blue', icon: undefined }]);
      });
      await fireEvent.press(settings.getByRole('button', { name: 'Icon' }));
      expect(
        menuItems().map(({ title, checked }) => [title, checked]),
      ).toStrictEqual([
        ['First Letter', true],
        ['Person', false],
        ['People', false],
        ['Laptop', false],
        ['Book', false],
        ['Airplane', false],
        ['Cart', false],
        ['Paintbrush', false],
        ['Star', false],
      ]);
      await chooseMenuItem('Laptop');
      await waitFor(() => {
        expect(styleOf()).toStrictEqual([{ color: 'blue', icon: 'laptop' }]);
      });
      expect(
        settings.getByRole('button', { name: 'Color' }),
      ).toHaveAccessibilityValue({ text: 'Blue' });
      expect(
        settings.getByRole('button', { name: 'Icon' }),
      ).toHaveAccessibilityValue({ text: 'Laptop' });
      // First Letter clears the Icon and keeps the Color.
      await fireEvent.press(settings.getByRole('button', { name: 'Icon' }));
      await chooseMenuItem('First Letter');
      await waitFor(() => {
        expect(styleOf()).toStrictEqual([{ color: 'blue', icon: undefined }]);
      });
    } finally {
      replaced.restore();
      jest.restoreAllMocks();
    }
  }); /* oxlint-enable vitest/max-expects */

  /* oxlint-disable vitest/max-expects -- One journey edits, refuses, relaunches and clears a signature. */
  it('edits each Sending Identity’s signature in Settings through Product Sync', async () => {
    expect.hasAssertions();
    const { vault, sync, relaunch } = await createTwoProfileRegistration();
    const store = createRegistration({
      ...vault,
      registration: () => vault.registration(),
    });
    await store.restore();
    const replaced = jest.replaceProperty(
      jest.requireMock<{ registration: typeof store }>(
        '../src/registration.ts',
      ),
      'registration',
      store,
    );
    const inbox = createInboxStore(createSyntheticGmail().native);
    showMailboxes(singleMailbox(inbox, alex));
    const signatures = (snapshot = store.getSnapshot().snapshot) =>
      mailboxesOf(snapshot).map(({ address, signature }) => [
        address,
        signature,
      ]);
    try {
      const app = await render(
        <MacWindows store={store}>
          <RegisteredWindow windowId="signatures" />
        </MacWindows>,
      );
      await chooseProfile(
        await app.findByLabelText('Profile, Primary Profile'),
        'Manage Profiles…',
      );
      const settings = settingsWindow();
      await fireEvent.press(
        await settings.findByRole('button', { name: 'Signatures' }),
      );
      const row = (address: string) =>
        settings.getByRole('button', { name: address });
      expect(row('alex@example.invalid')).toHaveAccessibilityValue({
        text: 'None',
      });
      expect(row('other@example.invalid')).toHaveAccessibilityValue({
        text: 'None',
      });
      expect(row('alex@example.invalid')).toBeSelected();
      const editor = () =>
        settings.getByLabelText('Signature for alex@example.invalid');
      const type = async (text: string) => {
        await fireEvent(editor(), 'focus');
        await fireEvent.changeText(editor(), text);
      };
      const leave = async () => {
        await act(async () => {
          await fireEvent(editor(), 'blur');
        });
      };

      // Bold stores the signature at once, though the editor keeps focus; the other identity
      // keeps none.
      await type('Alex Example');
      await fireEvent(editor(), 'selectionChange', {
        nativeEvent: { selection: { start: 0, end: 4 } },
      });
      await fireEvent.press(settings.getByRole('button', { name: 'Bold' }));
      const signed = [
        {
          kind: 'paragraph',
          spans: [{ text: 'Alex', marks: ['bold'] }, { text: ' Example' }],
        },
      ];
      await waitFor(() => {
        expect(signatures()).toStrictEqual([
          ['alex@example.invalid', signed],
          ['other@example.invalid', undefined],
        ]);
      });
      await leave();
      expect(row('alex@example.invalid')).toHaveAccessibilityValue({
        text: 'Alex Example',
      });
      const relaunched = createRegistration(relaunch());
      await relaunched.restore();
      expect(signatures(relaunched.getSnapshot().snapshot)).toStrictEqual(
        signatures(),
      );

      // A signature another device stores closes a Link Editor opened on the replaced text.
      const storeElsewhere = async (text: string) => {
        await act(async () => {
          await store.chooseSignature(
            mailboxesOf(store.getSnapshot().snapshot)[0]!.id,
            [{ kind: 'paragraph', spans: [{ text }] }],
          );
        });
      };
      // AppKit shows the popover once its content has a size; Jest lays out nothing.
      const linkEditor = async () => {
        await fireEvent(settings.getByLabelText('Link'), 'layout', {
          nativeEvent: { layout: { width: 320, height: 160 } },
        });
        let popover = settings.getByLabelText('Link');
        while (popover.type !== 'UnwiredPopover') {
          popover = popover.parent!;
        }
        return popover;
      };
      await fireEvent(editor(), 'selectionChange', {
        nativeEvent: { selection: { start: 0, end: 4 } },
      });
      await fireEvent.press(settings.getByRole('button', { name: 'Add Link' }));
      await expect(linkEditor()).resolves.toHaveProp('shown', true);
      await storeElsewhere('Dr. Alex Example');
      await expect(linkEditor()).resolves.toHaveProp('shown', false);
      await fireEvent(await linkEditor(), 'close');
      // So does one stored while the editor has focus, once opening the Link Editor leaves it.
      await fireEvent(editor(), 'focus');
      await storeElsewhere('Prof. Alex Example');
      await fireEvent.press(settings.getByRole('button', { name: 'Add Link' }));
      await expect(linkEditor()).resolves.toHaveProp('shown', true);
      await leave();
      expect(within(editor()).getByText('Prof. Alex Example')).toBeVisible();
      await expect(linkEditor()).resolves.toHaveProp('shown', false);
      await fireEvent(await linkEditor(), 'close');

      // Leaving without an edit keeps a signature stored meanwhile, as by another device.
      const elsewhere = [
        { kind: 'paragraph', spans: [{ text: 'Elsewhere' }] },
      ] as const;
      await fireEvent(editor(), 'focus');
      await act(async () => {
        await store.chooseSignature(
          mailboxesOf(store.getSnapshot().snapshot)[0]!.id,
          elsewhere,
        );
      });
      await leave();
      expect(signatures()[0]).toStrictEqual([
        'alex@example.invalid',
        elsewhere,
      ]);
      expect(within(editor()).getByText('Elsewhere')).toBeVisible();
      await type('Alex Example');
      await fireEvent(editor(), 'selectionChange', {
        nativeEvent: { selection: { start: 0, end: 4 } },
      });
      await fireEvent.press(settings.getByRole('button', { name: 'Bold' }));
      await leave();
      await waitFor(() => {
        expect(signatures()[0]).toStrictEqual(['alex@example.invalid', signed]);
      });

      // A save that stores nothing, as when authentication is cancelled, shows the stored one.
      jest.spyOn(store, 'chooseSignature').mockResolvedValueOnce(undefined);
      await type('Cancelled');
      await leave();
      expect(within(editor()).getByText('Alex')).toBeVisible();
      expect(within(editor()).queryByText('Cancelled')).toBeNull();

      // A refused edit keeps the stored signature, shows it again and says so.
      sync.offline = true;
      await type('Offline');
      await leave();
      await expect(
        settings.findByText(
          'Your signature change wasn’t saved. Check your connection and try again.',
        ),
      ).resolves.toBeVisible();
      expect(within(editor()).getByText('Alex')).toBeVisible();
      expect(signatures()[0]).toStrictEqual(['alex@example.invalid', signed]);
      // A refused Delete shows the stored signature again, though the editor keeps focus.
      await fireEvent(editor(), 'focus');
      await act(async () => {
        await fireEvent.press(settings.getByRole('button', { name: 'Delete' }));
      });
      expect(within(editor()).getByText('Alex')).toBeVisible();
      // After a refused format change, leaving without an edit keeps a signature stored meanwhile.
      await fireEvent(editor(), 'selectionChange', {
        nativeEvent: { selection: { start: 0, end: 4 } },
      });
      await act(async () => {
        await fireEvent.press(settings.getByRole('button', { name: 'Italic' }));
      });
      sync.offline = false;
      await storeElsewhere('Alex Meanwhile');
      await leave();
      expect(signatures()[0]).toStrictEqual([
        'alex@example.invalid',
        [{ kind: 'paragraph', spans: [{ text: 'Alex Meanwhile' }] }],
      ]);
      expect(within(editor()).getByText('Alex Meanwhile')).toBeVisible();

      // Emptying the editor clears the signature, and so does Delete.
      await type('');
      await leave();
      await waitFor(() => {
        expect(signatures()[0]).toStrictEqual([
          'alex@example.invalid',
          undefined,
        ]);
      });
      await type('Alex');
      await leave();
      await waitFor(() => {
        expect(row('alex@example.invalid')).toHaveAccessibilityValue({
          text: 'Alex',
        });
      });
      await act(async () => {
        await fireEvent.press(settings.getByRole('button', { name: 'Delete' }));
      });
      await waitFor(() => {
        expect(row('alex@example.invalid')).toHaveAccessibilityValue({
          text: 'None',
        });
      });
      expect(signatures()[0]).toStrictEqual([
        'alex@example.invalid',
        undefined,
      ]);

      // Closing Settings after another Product Account replaced this one stores nothing, though
      // it can hold the same mailbox under the same connection.
      await type('Replaced');
      const choose = jest.spyOn(store, 'chooseSignature');
      choose.mockClear();
      const current = store.getSnapshot();
      const replacement = {
        ...current.snapshot,
        productAccountId: 'replacement',
      };
      jest
        .spyOn(store, 'getSnapshot')
        .mockReturnValue({ ...current, snapshot: replacement });
      await app.unmount();
      expect(choose).not.toHaveBeenCalled();
    } finally {
      replaced.restore();
      jest.restoreAllMocks();
    }
  }); /* oxlint-enable vitest/max-expects */

  /* oxlint-disable vitest/max-expects -- One journey moves a mailbox both ways, then removes its Profile. */
  it('moves a mailbox between Profiles and removes a Profile with its mailboxes in Settings', async () => {
    expect.hasAssertions();
    const { vault } = await createTwoProfileRegistration();
    const store = createRegistration({
      ...vault,
      registration: () => vault.registration(),
      recordProfiles: (next) => vault.recordProfiles(next),
    });
    await store.restore();
    const replaced = jest.replaceProperty(
      jest.requireMock<{ registration: typeof store }>(
        '../src/registration.ts',
      ),
      'registration',
      store,
    );
    const inbox = createInboxStore(createSyntheticGmail().native);
    showMailboxes(singleMailbox(inbox, alex));
    const alert = jest.spyOn(Alert, 'alert').mockReturnValue(undefined);
    try {
      const app = await render(
        <MacWindows store={store}>
          <RegisteredWindow windowId="remove" />
        </MacWindows>,
      );
      await chooseProfile(
        await app.findByLabelText('Profile, Primary Profile'),
        'Manage Profiles…',
      );
      const settings = settingsWindow();
      await fireEvent.press(
        await settings.findByRole('button', { name: 'Work' }),
      );
      const moving = 'Profile for other@example.invalid';
      await fireEvent.changeText(settings.getByDisplayValue('Work'), 'Office');
      const { recordProfiles } = vault;
      let releaseRename: () => void = () => undefined;
      let startedRename: () => void = () => undefined;
      let release: () => void = () => undefined;
      // oxlint-disable-next-line promise/avoid-new -- Controlled native persistence and its admission signal.
      const renaming = new Promise<void>((resolve) => {
        releaseRename = resolve;
      });
      // oxlint-disable-next-line promise/avoid-new -- Controlled native persistence and its admission signal.
      const renameStarted = new Promise<void>((resolve) => {
        startedRename = resolve;
      });
      // oxlint-disable-next-line promise/avoid-new -- Controlled native persistence and its admission signal.
      const movingMailbox = new Promise<void>((resolve) => {
        release = resolve;
      });
      // Hold native persistence while the real store serializes the move and editing completion.
      jest
        .spyOn(vault, 'recordProfiles')
        .mockImplementationOnce(async (next) => {
          await movingMailbox;
          return recordProfiles(next);
        })
        .mockImplementation(async (next) => {
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Refuse only the queued rename at the native persistence boundary.
          if (next.profiles.some(({ pending }) => pending === 'Office')) {
            startedRename();
            await renaming;
            throw Object.assign(new Error('Synthetic rename refused'), {
              code: 'profile-changed',
            });
          }
          return recordProfiles(next);
        });
      await fireEvent.press(settings.getByRole('button', { name: moving }));
      await chooseMenuItem('Primary Profile');
      // The pop-up reads the move's progress; the other Profile changes wait for it.
      const pending = settings.getByRole('button', { name: moving });
      expect(pending).toHaveAccessibilityValue({
        text: 'Moving to Primary Profile…',
      });
      expect(pending).toBeDisabled();
      for (const name of [
        'Add Profile…',
        'Duplicate Profile',
        'Remove Profile…',
      ]) {
        expect(settings.getByRole('button', { name })).toBeDisabled();
      }
      expect(settings.getByDisplayValue('Office')).toHaveProp(
        'editable',
        false,
      );
      expect(
        settings.getByRole('button', { name: 'Primary Profile' }),
      ).toBeEnabled();
      // Disabling the edited native field can deliver its queued editing completion.
      await act(() => {
        settings.getByDisplayValue('Office').props.onEndEditing();
      });
      await act(async () => {
        release();
        await renameStarted;
      });
      await waitFor(() => {
        expect(
          settings.getByRole('button', { name: 'Work' }).props
            .accessibilityHint,
        ).toBe('No mailboxes');
      });
      expect(settings.queryByRole('button', { name: moving })).toBeNull();
      expect(
        settings.getByRole('button', { name: 'Add Profile…' }),
      ).toBeDisabled();
      await act(async () => {
        releaseRename();
        await Promise.resolve();
      });
      await waitFor(() => {
        expect(settings.getByDisplayValue('Work')).toBeVisible();
      });
      expect(alert).toHaveBeenCalledWith(
        'Rename Profile',
        'Another device changed these Profiles first. Check them, then try again.',
        [{ text: 'OK' }],
      );
      alert.mockClear();
      expect(
        settings.getByRole('button', { name: 'Add Profile…' }),
      ).toBeEnabled();
      // The Primary Profile lists both mailboxes and cannot be removed.
      await fireEvent.press(
        settings.getByRole('button', { name: 'Primary Profile' }),
      );
      expect(
        settings.queryByRole('button', { name: 'Remove Profile…' }),
      ).toBeNull();
      await fireEvent.press(settings.getByRole('button', { name: moving }));
      await chooseMenuItem('Work');
      await waitFor(() => {
        expect(
          settings.getByRole('button', { name: 'Work' }).props
            .accessibilityHint,
        ).toBe('Gmail');
      });
      expect(alert).not.toHaveBeenCalled();

      await fireEvent.press(settings.getByRole('button', { name: 'Work' }));
      await fireEvent.press(
        settings.getByRole('button', { name: 'Remove Profile…' }),
      );
      // Cancel is the default button that Return and Escape answer.
      expect(sheetShown()).toStrictEqual({
        title: 'Remove “Work” and Its Mailboxes?',
        detail:
          'other@example.invalid is also removed from Unwired Mail on all your devices. Its mail stays with Gmail.',
        buttons: ['Cancel', 'Remove'],
        cancel: 0,
        destructive: 1,
      });
      await act(async () => {
        chooseSheetButton('Remove');
        await Promise.resolve();
      });
      await waitFor(() => {
        expect(settings.queryByRole('button', { name: 'Work' })).toBeNull();
      });
      expect(
        settings.getByRole('header', { name: 'Primary Profile' }),
      ).toBeVisible();
      expect(
        mailboxesOf(store.getSnapshot().snapshot).map(({ address }) => address),
      ).toStrictEqual(['alex@example.invalid']);
      // No refusal followed the question.
      expect(alert).not.toHaveBeenCalled();
    } finally {
      alert.mockRestore();
      replaced.restore();
    }
  });
  /* oxlint-enable vitest/max-expects */

  it('names a new Mail Profile and explains a failed creation', async () => {
    expect.hasAssertions();
    const prompt = jest.spyOn(Alert, 'promptMacOS').mockReturnValue(undefined);
    const alert = jest.spyOn(Alert, 'alert').mockReturnValue(undefined);
    const createProfile = jest.fn((_name: string) =>
      Promise.resolve('failed' as const),
    );
    try {
      const inbox = createInboxStore(createSyntheticGmail().native);
      showMailboxes(singleMailbox(inbox, alex));
      const app = await render(
        <AccountContext
          value={{
            mailboxes: [],
            openAccount: () => undefined,
            authorizeMailbox: () => Promise.resolve(),
            refreshInbox: (load) => load(),
            account: 'synthetic-product-account',
            profiles: [],
            createProfile,
            chooseFolders: () => Promise.resolve(true),
          }}>
          <InboxWindow windowId="create" />
        </AccountContext>,
      );
      await chooseProfile(
        await app.findByLabelText('Profile, Primary Profile'),
        'New Profile…',
      );
      expect(prompt.mock.lastCall?.[4]).toStrictEqual([
        { placeholder: 'Name' },
      ]);
      const buttons = prompt.mock.lastCall?.[2];
      ok(Array.isArray(buttons));
      await act(async () => {
        // A plain-text prompt hands its button the entered text.
        // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- React Native types the value per prompt type.
        const create = buttons.find(({ text }) => text === 'Create')
          ?.onPress as ((value: string) => void) | undefined;
        create?.('Family');
        await Promise.resolve();
      });
      expect(createProfile.mock.calls).toStrictEqual([['Family']]);
      await waitFor(() => {
        expect(alert).toHaveBeenCalledWith(
          'New Profile',
          'Couldn’t create the Profile. Check your Profiles, then try again.',
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
    showMailboxes(singleMailbox(createInboxStore(gmail.native), alex));
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
