import { ok } from 'node:assert/strict';

import type { CommandRegistry } from '@private-email/mail-core/commands';
import type { router as ExpoRouter } from 'expo-router';
import type {
  createElement as ReactCreateElement,
  ReactNode,
  Ref,
  useImperativeHandle as ReactUseImperativeHandle,
  useLayoutEffect as ReactUseLayoutEffect,
  useSyncExternalStore as ReactUseSyncExternalStore,
} from 'react';
import type {
  KeyboardEvent,
  View as NativeView,
  TurboModule,
} from 'react-native';
import type { useWindowDimensions } from 'react-native';

import {
  commandTarget,
  runWhenOffered,
} from '@private-email/mail-core/commands';
import { createDrafts, draftOf } from '@private-email/mail-core/drafts';
import { createInboxPreferences } from '@private-email/mail-core/inbox-preferences';
import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import {
  defaultProfile,
  mailboxesOf,
  profilesOf,
} from '@private-email/mail-core/registration';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createTwoProfileRegistration } from '@private-email/mail-core/testing/registration-scenarios';
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
import {
  Alert,
  DeviceEventEmitter,
  Linking,
  StyleSheet,
  TurboModuleRegistry,
} from 'react-native';
import { withTiming } from 'react-native-reanimated';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import type ComposeRoute from '../app/compose/[draft].tsx';
import type MessageRoute from '../app/message/[id].tsx';
import type ThreadRoute from '../app/thread/[id].tsx';
import type { useCommandRegistry as UseCommandRegistry } from '../src/command-palette.tsx';
import type { MailboxList } from '../src/private-storage.ts';

import RootLayout from '../app/_layout.tsx';
import { InboxPreferencesContext } from '../src/list-density.tsx';
import { AccountContext } from '../src/registration-gate.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Observe only the external animation boundary; the shell, Inbox and stores stay real.
jest.mock('react-native-reanimated', () => {
  const actual = jest.requireActual('react-native-reanimated');
  return {
    ...actual,
    __esModule: true,
    withTiming: jest.fn(actual.withTiming),
  };
});

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Replace only the singleton with a real store over synthetic native storage.
jest.mock('../src/registration.ts', () => ({
  ...jest.requireActual('../src/registration.ts'),
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's native storage boundary.
jest.mock('../src/private-storage.ts', () => ({ mailboxes: undefined }));
// oxlint-disable-next-line vitest/prefer-import-in-mock -- The packaged preview bypasses provider sign-in.
jest.mock('@private-email/mail-core/registration-mode', () => ({
  previewInbox: true,
}));
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Native background execution is outside this routing test.
jest.mock('../src/freshness.ts', () => ({
  followOpenedDrafts: () => () => undefined,
  pollGmailWhileActive: jest.fn(),
  scheduleGmailFreshness: jest.fn(),
}));
jest.mock(
  // oxlint-disable-next-line vitest/prefer-import-in-mock -- The library's Jest stand-in for the native inset provider.
  'react-native-safe-area-context',
  () =>
    jest.requireActual<{ default: object }>(
      'react-native-safe-area-context/jest/mock',
    ).default,
);
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Substitute the native split host and keep its column appearance events for the test to deliver.
jest.mock('react-native-screens/experimental', () => {
  const { createElement } = jest.requireActual<{
    createElement: typeof ReactCreateElement;
  }>('react');
  const { View } = jest.requireActual<{ View: typeof NativeView }>(
    'react-native',
  );
  const { useImperativeHandle, useLayoutEffect } = jest.requireActual<{
    useLayoutEffect: typeof ReactUseLayoutEffect;
    useImperativeHandle: typeof ReactUseImperativeHandle;
  }>('react');
  // The columns the shell asked the split view to show, in order.
  const shown: string[] = [];
  const commands: { registry?: CommandRegistry } = {};
  const { useCommandRegistry } = jest.requireActual<{
    useCommandRegistry: typeof UseCommandRegistry;
  }>('../src/command-palette.tsx');
  function Host({
    children,
    ref,
    ...props
  }: {
    readonly children: ReactNode;
    readonly ref: Ref<Readonly<{ show: (column: string) => void }>>;
  }) {
    useImperativeHandle(ref, () => ({
      show: (column) => {
        shown.push(column);
      },
    }));
    const registry = useCommandRegistry();
    useLayoutEffect(() => {
      commands.registry = registry;
    }, [registry]);
    return createElement(View, props, children);
  }
  return {
    // The native safe-area wrapper supplies no routing behavior.
    SafeAreaView: View,
    Split: { Host, Column: View },
    shown,
    commands,
  };
});
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Router state stands in for native URL delivery; views and stores are real.
jest.mock('expo-router', () => {
  const { createElement, useSyncExternalStore } = jest.requireActual<{
    createElement: typeof ReactCreateElement;
    useSyncExternalStore: typeof ReactUseSyncExternalStore;
  }>('react');
  let params: Readonly<Record<string, unknown>> = {};
  let pathname = '/';
  const listeners = new Set<() => void>();
  const setParams = (next: typeof params) => {
    params = next;
    for (const listener of listeners) {
      listener();
    }
  };
  const subscribe = (listener: () => void) => {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  };
  const getSnapshot = () => params;
  const useParams = () => useSyncExternalStore(subscribe, getSnapshot);
  // The secondary column's route. Routes load on first render, once this mock exists for them.
  function Slot() {
    const { draft } = useParams();
    if (draft !== undefined) {
      return createElement(
        jest.requireActual<{ default: typeof ComposeRoute }>(
          '../app/compose/[draft].tsx',
        ).default,
      );
    }
    return createElement(
      pathname === '/thread/[id]'
        ? jest.requireActual<{ default: typeof ThreadRoute }>(
            '../app/thread/[id].tsx',
          ).default
        : jest.requireActual<{ default: typeof MessageRoute }>(
            '../app/message/[id].tsx',
          ).default,
    );
  }
  return {
    Slot,
    params: getSnapshot,
    setParams: (next: typeof params) => {
      pathname = '/';
      setParams(next);
    },
    usePathname: () => {
      useParams();
      return pathname;
    },
    useGlobalSearchParams: useParams,
    useLocalSearchParams: useParams,
    router: {
      setParams: (next: typeof params) => setParams({ ...params, ...next }),
      replace: ({
        pathname: nextPath,
        params: next,
      }: {
        readonly pathname: string;
        readonly params?: typeof params;
      }) => {
        pathname = nextPath;
        setParams(next ?? {});
      },
    },
  };
});

const route = jest.requireMock<{
  params: () => Readonly<Record<string, unknown>>;
  setParams: (params: Readonly<Record<string, unknown>>) => void;
  router: typeof ExpoRouter;
}>('expo-router');
const split = jest.requireMock<{
  shown: string[];
  commands: { registry?: CommandRegistry };
}>('react-native-screens/experimental');

const touch = {
  persist: () => undefined,
  currentTarget: 1,
  nativeEvent: { pageX: 0, pageY: 0, locationX: 0, locationY: 0, timestamp: 0 },
};

// Selection fills drawn in a row: its own and any stacked over it.
function fills(row: ReturnType<typeof screen.getByRole>) {
  const filled = (node: typeof row) =>
    StyleSheet.flatten(node.props.style)?.backgroundColor ===
    palette.light.accentSelectionSubtle;
  return [row, ...row.queryAll(filled)].filter(filled).length;
}

function showMail(profile: string) {
  const gmail = createSyntheticGmail();
  const id = gmail.deliver({
    subject: 'Garden plan',
    content: { text: 'Synthetic garden body.' },
  });
  gmail.deliver({
    subject: 'River plan',
    content: { text: 'Synthetic river body.' },
  });
  const original = singleMailbox(createInboxStore(gmail.native), 'garden');
  let previous: ReturnType<typeof original.getSnapshot> | undefined = undefined;
  let snapshot: ReturnType<MailboxList['getSnapshot']> = [];
  const mailboxes: MailboxList = {
    ...original,
    getSnapshot: () => {
      const next = original.getSnapshot();
      if (next !== previous) {
        previous = next;
        snapshot = next.map((mailbox) => ({ ...mailbox, profile }));
      }
      return snapshot;
    },
  };
  jest.replaceProperty(
    jest.requireMock<{ mailboxes: MailboxList }>('../src/private-storage.ts'),
    'mailboxes',
    mailboxes,
  );
  return id;
}

// The Inbox bar's New Message, which renders before the reader toolbar's own New Message.
const inboxNewMessage = () => {
  const [button] = screen.getAllByRole('button', { name: 'New Message' });
  ok(button);
  return button;
};

describe('profile-scoped mobile routes', () => {
  it('waits for the native Inbox column to appear before a reader action removes its row', async () => {
    expect.hasAssertions();
    const frames = jest
      .spyOn(globalThis, 'requestAnimationFrame')
      .mockReturnValue(0);
    try {
      showMail(defaultProfile);
      route.setParams({});
      await render(<RootLayout />);
      await fireEvent(screen.getByTestId('mail-split'), 'collapse');
      await fireEvent(screen.getByTestId('inbox-column'), 'didAppear');
      await fireEvent.press(
        await screen.findByRole('button', { name: /Garden plan/u }),
      );
      await act(() => {
        screen.getByTestId('inbox-column').props.onWillDisappear?.();
      });
      const timings = jest.mocked(withTiming).mockClear();
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Archive' }),
      );
      await screen.findByRole('button', { name: 'Undo' });
      const beforeAppearance = timings.mock.calls.length;
      const retained = screen.queryByText('Garden plan', {
        includeHiddenElements: true,
      });
      await fireEvent(screen.getByTestId('inbox-column'), 'didAppear');
      expect({
        beforeAppearance,
        retained: retained !== null,
        started: timings.mock.calls.some(([target]) => target === 0),
        reader: screen.queryByText('Synthetic garden body.'),
      }).toStrictEqual({
        beforeAppearance: 0,
        retained: true,
        started: true,
        reader: null,
      });
      const { mailboxes } = jest.requireMock<{ mailboxes: MailboxList }>(
        '../src/private-storage.ts',
      );
      const [mailbox] = mailboxes.getSnapshot();
      ok(mailbox?.state.kind === 'ready');
      const river = mailbox.state.messages.find(
        (message) => message.subject === 'River plan',
      );
      ok(river !== undefined);
      // Notification navigation selects directly, without the Inbox's row handler.
      await act(() => {
        route.router.replace({
          pathname: '/message/[id]',
          params: {
            profileId: defaultProfile,
            mailbox: 'garden',
            id: river.id,
          },
        });
      });
      expect(
        screen.queryByText('Garden plan', { includeHiddenElements: true }),
      ).toBeNull();
      await expect(
        screen.findByText('Synthetic river body.'),
      ).resolves.toBeVisible();
    } finally {
      await cleanup();
      frames.mockRestore();
    }
  });

  it('restores a cold-launch link after preferences finish loading', async () => {
    expect.hasAssertions();
    const nativeRegistration = TurboModuleRegistry.getEnforcing<
      TurboModule & {
        preference: (key: string) => Promise<unknown>;
        setPreference: (key: string, value: string) => Promise<unknown>;
      }
    >('UnwiredRegistration');
    const saved = new Map<string, string>();
    // Hold the native read until the linked Profile is visible.
    const reading = Promise.withResolvers<undefined>();
    const preference = jest
      .spyOn(nativeRegistration, 'preference')
      .mockImplementation(async (key) => {
        await reading.promise;
        // oxlint-disable-next-line vitest/no-conditional-in-test -- An unsaved preference reads as null.
        return { value: saved.get(key) ?? null };
      });
    const saving = jest
      .spyOn(nativeRegistration, 'setPreference')
      .mockImplementation((key, value) => {
        saved.set(key, value);
        return Promise.resolve({});
      });
    const view = () => (
      <AccountContext
        value={{
          mailboxes: [],
          openAccount: () => undefined,
          authorizeMailbox: () => Promise.resolve(),
          refreshInbox: (load) => load(),
          account: 'synthetic-product-account',
          profiles: [{ id: 'work', name: 'Work' }],
          createProfile: () => Promise.resolve(undefined),
          chooseFolders: () => Promise.resolve(true),
        }}>
        <RootLayout />
      </AccountContext>
    );
    try {
      showMail('work');
      route.setParams({ profileId: 'work' });
      const app = await render(view());
      await screen.findByLabelText('Profile, Work');
      await act(async () => {
        reading.resolve(undefined);
        await reading.promise;
      });
      await waitFor(() => {
        expect(saved.get('window-profile')).toBe('work');
      });
      await app.unmount();
      route.setParams({});
      await render(view());
      await expect(
        screen.findByRole('button', { name: /Garden plan/u }),
      ).resolves.toBeVisible();
      expect(screen.getByLabelText('Profile, Work')).toBeVisible();
    } finally {
      reading.resolve(undefined);
      preference.mockRestore();
      saving.mockRestore();
    }
  });

  it('retains the routed reader view when archiving its row from the Inbox', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const travel = gmail.createLabel('Travel');
    const id = gmail.deliver({ subject: 'Flight to Zagreb' });
    gmail.setLabel(id, travel, true);
    const inbox = createInboxStore(gmail.native);
    await inbox.load();
    await inbox.openView(travel);
    jest.replaceProperty(
      jest.requireMock<{ mailboxes: MailboxList }>('../src/private-storage.ts'),
      'mailboxes',
      singleMailbox(inbox, 'garden'),
    );
    route.setParams({ mailbox: 'garden', id, folder: travel });
    await render(<RootLayout />);
    await act(async () => {
      await fireEvent(
        await screen.findByRole('button', { name: /Flight to Zagreb/u }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'archive' } },
      );
    });
    expect(
      screen.getByRole('header', { name: 'Flight to Zagreb' }),
    ).toBeVisible();
    expect(route.params()).toMatchObject({ id, folder: travel });
  });

  /* oxlint-disable vitest/max-expects -- One composition session crosses reader, expansion and adaptive-layout transitions. */
  it('keeps the same Draft and history through iPad expansion, reader selection and compact layout', async () => {
    expect.hasAssertions();
    const dimensions = jest
      .spyOn(
        jest.requireActual<{ useWindowDimensions: typeof useWindowDimensions }>(
          'react-native',
        ),
        'useWindowDimensions',
      )
      .mockReturnValue({ width: 834, height: 1194, scale: 2, fontScale: 1 });
    const connection = {
      id: syntheticMailboxes['alex@example.invalid'],
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
        mailboxes: JSON.stringify([connection]),
      },
      busy: false,
      failed: false,
    } as const;
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    let waitingForSave = Promise.resolve();
    let releaseSave: () => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Release the native commit explicitly after reader selection races Close.
    const pendingSave = new Promise<void>((resolve) => {
      releaseSave = resolve;
    });
    const drafts = createDrafts(
      {
        ...storage.native,
        commitDrafts: async (
          ...args: Parameters<typeof storage.native.commitDrafts>
        ) => {
          await waitingForSave;
          return storage.native.commitDrafts(...args);
        },
      },
      {
        subscribe: () => () => undefined,
        getSnapshot: () => account,
      },
    );
    jest.replaceProperty(
      jest.requireMock<{ drafts: typeof drafts }>('../src/registration.ts'),
      'drafts',
      drafts,
    );
    showMail(defaultProfile);
    route.setParams({});
    const insets = { top: 59, bottom: 34, left: 0, right: 0 };
    const view = () => (
      <SafeAreaProvider
        initialMetrics={{
          frame: { x: 0, y: 0, width: 393, height: 852 },
          insets,
        }}>
        <AccountContext
          value={{
            mailboxes: [connection],
            openAccount: () => undefined,
            authorizeMailbox: () => Promise.resolve(),
            refreshInbox: (load) => load(),
            account: 'synthetic-product-account',
            profiles: [{ id: 'work', name: 'Work' }],
            createProfile: () => Promise.resolve(undefined),
            chooseFolders: () => Promise.resolve(true),
          }}>
          <RootLayout />
        </AccountContext>
      </SafeAreaProvider>
    );
    // Delivers a native keyboard notification to the current subscribers of that event.
    const keyboard = (
      type: 'keyboardWillChangeFrame' | 'keyboardWillHide',
      screenY: number,
      keyboardHeight: number,
    ) => {
      const event: KeyboardEvent = {
        duration: 0,
        easing: 'keyboard',
        isEventFromThisApp: true,
        startCoordinates: { screenX: 0, screenY: 1194, width: 834, height: 0 },
        endCoordinates: {
          screenX: 0,
          screenY,
          width: 834,
          height: keyboardHeight,
        },
      };
      DeviceEventEmitter.emit(type, event);
    };
    const app = await render(view());
    try {
      await fireEvent.press(
        await screen.findByRole('button', { name: /Garden plan/u }),
      );
      await waitFor(() => {
        expect(inboxNewMessage()).toBeEnabled();
      });
      // Native route rendering can follow a row press after New Message has already opened.
      const replace = jest
        .spyOn(route.router, 'replace')
        .mockReturnValueOnce(undefined);
      try {
        await fireEvent.press(
          screen.getByRole('button', { name: /River plan/u }),
        );
        await fireEvent.press(inboxNewMessage());
        await screen.findByLabelText('Message body');
        await fireEvent.press(screen.getByRole('button', { name: 'Close' }));
        await expect(
          screen.findByText('Synthetic river body.'),
        ).resolves.toBeVisible();
      } finally {
        replace.mockRestore();
      }
      await fireEvent.press(
        screen.getByRole('button', { name: /Garden plan/u }),
      );
      // Every reading-column route sizes the window bar's scroll edge to its own column.
      await fireEvent(
        await screen.findByTestId('reader-pane', {
          includeHiddenElements: true,
        }),
        'layout',
        { nativeEvent: { layout: { x: 0, y: 0, width: 494, height: 1194 } } },
      );
      expect(
        screen
          .getAllByTestId('scroll-edge', { includeHiddenElements: true })
          .map((edge) => StyleSheet.flatten(edge.props.style)?.width),
      ).toContain(494);
      // The window bar's search rises above a docked keyboard.
      await fireEvent(
        screen.getByTestId('mail-shell', { includeHiddenElements: true }),
        'layout',
        { nativeEvent: { layout: { x: 0, y: 0, width: 834, height: 1194 } } },
      );
      await act(() => {
        keyboard('keyboardWillChangeFrame', 794, 400);
      });
      expect(screen.getByTestId('window-bar')).toHaveStyle({
        bottom: insets.bottom + 400,
      });
      await act(() => {
        keyboard('keyboardWillHide', 1194, 0);
      });
      expect(screen.getByTestId('window-bar')).toHaveStyle({
        bottom: insets.bottom,
      });
      await fireEvent.press(inboxNewMessage());
      expect(screen.queryByLabelText('Search senders and subjects')).toBeNull();
      // The hidden window bar keeps New Message among the commands while composing.
      await fireEvent(
        await screen.findByRole('header', { name: 'New Message' }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'openCommandPalette' } },
      );
      const commands = within(screen.getByTestId('command-palette'));
      expect(
        commands.getByRole('button', { name: 'New Message' }),
      ).toBeVisible();
      await fireEvent.press(
        commands.getByRole('button', { name: 'Close commands' }),
      );
      await fireEvent(
        screen.getByTestId('mail-shell', { includeHiddenElements: true }),
        'layout',
        { nativeEvent: { layout: { x: 0, y: 0, width: 834, height: 1194 } } },
      );
      const overlay = () =>
        screen.getByTestId('composer-overlay', { includeHiddenElements: true });
      const readerPane = screen.getByTestId('compose-reader-pane', {
        includeHiddenElements: true,
      });
      // New Message is a card centred on the window, whatever width UIKit gives the reader.
      const card = {
        left: 40,
        width: 834 - 80,
        top: insets.top + 40,
        bottom: 32,
      };
      await fireEvent(readerPane, 'layout', {
        nativeEvent: { layout: { x: 0, y: 0, width: 258, height: 1194 } },
      });
      expect(overlay()).toHaveStyle(card);
      await fireEvent(readerPane, 'layout', {
        nativeEvent: { layout: { x: 0, y: 0, width: 834, height: 1194 } },
      });
      expect(overlay()).toHaveStyle(card);
      // A docked software keyboard raises the card's bottom edge above it.
      await act(() => {
        keyboard('keyboardWillChangeFrame', 794, 400);
      });
      expect(overlay()).toHaveStyle({ ...card, bottom: 432 });
      await act(() => {
        keyboard('keyboardWillChangeFrame', 450, 744);
      });
      expect(overlay()).toHaveStyle({ ...card, bottom: 776 });
      // A regular window keeps listening, so a composer closed with its keyboard up hears its hide
      // and reopens unraised.
      const { draft: open } = route.params();
      ok(typeof open === 'string');
      await act(() => {
        route.router.setParams({ draft: undefined });
      });
      await act(() => {
        keyboard('keyboardWillHide', 1194, 0);
      });
      await act(() => {
        route.router.setParams({ draft: open });
      });
      expect(overlay()).toHaveStyle(card);
      // A conflict copy rebinds the open composer in place; its keyboard stays raised.
      await act(() => {
        keyboard('keyboardWillChangeFrame', 794, 400);
      });
      await act(() => {
        route.router.setParams({ draft: `${open}-copy` });
      });
      expect(overlay()).toHaveStyle({ bottom: 432 });
      await act(() => {
        route.router.setParams({ draft: open });
      });
      await act(() => {
        keyboard('keyboardWillHide', 1194, 0);
      });
      expect(overlay()).toHaveStyle(card);
      await fireEvent.changeText(
        await screen.findByLabelText('Message body'),
        'Keep this draft.',
      );
      await fireEvent.changeText(screen.getByLabelText('To'), 'unfinished');
      await fireEvent(
        screen.getByLabelText('Profile, Primary Profile'),
        'select',
        { nativeEvent: { id: 'profile\nwork' } },
      );
      expect(screen.getByLabelText('Profile, Primary Profile')).toBeVisible();
      expect(screen.getByLabelText('To')).toHaveProp('value', 'unfinished');
      await fireEvent.press(screen.getByRole('button', { name: 'Expand' }));
      expect(screen.queryByLabelText('Search senders and subjects')).toBeNull();
      await fireEvent.press(screen.getByRole('button', { name: 'Collapse' }));
      // A landscape phone can be wide while UIKit still collapses its split view.
      await fireEvent(
        screen.getByTestId('mail-split', { includeHiddenElements: true }),
        'collapse',
      );
      // A column appearing beneath the composer is no Back from the reader; the Draft stays open.
      await act(() => {
        screen
          .getByTestId('inbox-column', { includeHiddenElements: true })
          .props.onDidAppear();
      });
      expect(screen.queryByRole('button', { name: 'Expand' })).toBeNull();
      // The compact composer trades the format bar for the floating pill.
      expect(screen.queryByRole('button', { name: 'Text style' })).toBeNull();
      expect(screen.getByRole('button', { name: 'Format' })).toBeVisible();
      await fireEvent(
        screen.getByTestId('mail-split', { includeHiddenElements: true }),
        'expand',
      );
      await fireEvent.press(
        screen.getByRole('button', { name: /River plan/u }),
      );
      expect(screen.getByLabelText('To')).toHaveProp('value', 'unfinished');
      expect(screen.getByLabelText('Message body')).toHaveTextContent(
        'Keep this draft.',
      );
      // Selecting a message asks about the changed Draft; its unfinished recipient keeps it open.
      await fireEvent.press(screen.getByRole('button', { name: 'Save Draft' }));
      expect(
        screen.getByText(
          'Correct or remove the invalid address to close this Draft.',
        ),
      ).toBeVisible();
      dimensions.mockReturnValue({
        width: 393,
        height: 852,
        scale: 3,
        fontScale: 1,
      });
      await app.rerender(view());
      expect(screen.queryByRole('button', { name: 'Expand' })).toBeNull();
      // The composer's own safe area clears the system bars; padding the overlay too would apply
      // the insets twice and leave the format bar behind the keyboard (#1165).
      expect(
        screen.getByTestId('composer-overlay', { includeHiddenElements: true }),
      ).not.toHaveStyle({ paddingTop: insets.top });
      expect(
        screen.getByTestId('composer-overlay', { includeHiddenElements: true }),
      ).not.toHaveStyle({ paddingBottom: insets.bottom });
      await fireEvent.press(screen.getByRole('button', { name: 'Format' }));
      await fireEvent.press(screen.getByRole('button', { name: 'Undo' }));
      expect(screen.getByLabelText('To')).toHaveProp('value', '');
      await fireEvent.press(screen.getByRole('button', { name: 'Undo' }));
      expect(screen.getByLabelText('Message body')).not.toHaveTextContent(
        'Keep this draft.',
      );
      dimensions.mockReturnValue({
        width: 834,
        height: 1194,
        scale: 2,
        fontScale: 1,
      });
      await app.rerender(view());
      await fireEvent(
        screen.getByTestId('mail-split', { includeHiddenElements: true }),
        'expand',
      );
      waitingForSave = pendingSave;
      await fireEvent.press(screen.getByRole('button', { name: 'Redo' }));
      await fireEvent.press(screen.getByRole('button', { name: 'Close' }));
      await fireEvent.press(screen.getByRole('button', { name: 'Save Draft' }));
      // Reader input and native save completion can arrive before the next render.
      await act(async () => {
        await fireEvent.press(
          screen.getByRole('button', { name: /Garden plan/u }),
        );
        waitingForSave = Promise.resolve();
        releaseSave();
      });
      await expect(
        screen.findByText('Synthetic garden body.'),
      ).resolves.toBeVisible();
      expect(screen.queryByLabelText('Message body')).toBeNull();
    } finally {
      releaseSave();
      await app.unmount();
      dimensions.mockRestore();
      jest.replaceProperty(
        jest.requireMock<{ drafts: typeof drafts }>('../src/registration.ts'),
        'drafts',
        jest.requireActual<{ drafts: typeof drafts }>('../src/registration.ts')
          .drafts,
      );
    }
  });
  /* oxlint-enable vitest/max-expects */

  // A Draft with content asks before leaving; leaving removes an untouched one at once.
  it.each([
    {
      draft: 'with content',
      body: 'Keep this draft.',
      command: 'Inbox',
      answers: ['Save Draft'],
    },
    // Leaving removes the empty Draft, which unmounts its editor before it finishes closing.
    { draft: 'untouched', body: '', command: 'Inbox', answers: [] },
    {
      draft: 'expanded via Search Mail',
      body: 'Keep this draft.',
      command: 'Search Mail',
      answers: ['Save Draft'],
    },
  ])(
    'leaves an expanded iPad composer $draft for the Inbox from the Command Palette',
    async ({ body, command, answers }) => {
      expect.hasAssertions();
      split.shown.length = 0;
      const dimensions = jest
        .spyOn(
          jest.requireActual<{
            useWindowDimensions: typeof useWindowDimensions;
          }>('react-native'),
          'useWindowDimensions',
        )
        .mockReturnValue({ width: 834, height: 1194, scale: 2, fontScale: 1 });
      const connection = {
        id: syntheticMailboxes['alex@example.invalid'],
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
          mailboxes: JSON.stringify([connection]),
        },
        busy: false,
        failed: false,
      } as const;
      const drafts = createDrafts(
        createSyntheticDrafts(() => 'synthetic-product-account').native,
        {
          subscribe: () => () => undefined,
          getSnapshot: () => account,
        },
      );
      jest.replaceProperty(
        jest.requireMock<{ drafts: typeof drafts }>('../src/registration.ts'),
        'drafts',
        drafts,
      );
      showMail(defaultProfile);
      route.setParams({});
      const app = await render(
        <AccountContext
          value={{
            mailboxes: [connection],
            openAccount: () => undefined,
            authorizeMailbox: () => Promise.resolve(),
            refreshInbox: (load) => load(),
            account: 'synthetic-product-account',
            profiles: [],
            createProfile: () => Promise.resolve(undefined),
            chooseFolders: () => Promise.resolve(true),
          }}>
          <RootLayout />
        </AccountContext>,
      );
      try {
        await fireEvent.press(
          await screen.findByRole('button', { name: /Garden plan/u }),
        );
        await waitFor(() => {
          expect(inboxNewMessage()).toBeEnabled();
        });
        await fireEvent.press(inboxNewMessage());
        await fireEvent.changeText(
          await screen.findByLabelText('Message body'),
          body,
        );
        await fireEvent.press(screen.getByRole('button', { name: 'Expand' }));
        await fireEvent(
          screen.getByRole('header', {
            name: 'New Message',
          }),
          'accessibilityAction',
          { nativeEvent: { actionName: 'openCommandPalette' } },
        );
        await act(async () => {
          await fireEvent.press(
            within(screen.getByTestId('command-palette')).getByRole('button', {
              name: command,
            }),
          );
        });
        for (const name of answers) {
          await act(async () => {
            await fireEvent.press(screen.getByRole('button', { name }));
          });
        }
        expect(screen.queryByLabelText('Message body')).toBeNull();
        expect(screen.queryByText('This Draft is not available.')).toBeNull();
        expect(screen.queryByText('Synthetic garden body.')).toBeNull();
        expect(
          screen.getByLabelText('Search senders and subjects'),
        ).toBeVisible();
        // A collapsed split view, as on iPhone, returns to the Inbox column rather than an empty reader.
        expect(split.shown.at(-1)).toBe('supplementary');
      } finally {
        await app.unmount();
        dimensions.mockRestore();
        jest.replaceProperty(
          jest.requireMock<{ drafts: typeof drafts }>('../src/registration.ts'),
          'drafts',
          jest.requireActual<{ drafts: typeof drafts }>(
            '../src/registration.ts',
          ).drafts,
        );
      }
    },
  );

  it('starts a waited-for notification Reply after navigation replaces the current Profile', async () => {
    expect.hasAssertions();
    const connection = {
      id: 'garden',
      address: 'alex@example.invalid',
      state: 'connected',
      profile: 'work',
      provider: 'gmail',
    } as const;
    const account = {
      snapshot: {
        kind: 'connected',
        productAccountId: 'synthetic-product-account',
        signInProvider: 'google',
        mailboxes: JSON.stringify([connection]),
      },
      busy: false,
      failed: false,
    } as const;
    const drafts = createDrafts(
      createSyntheticDrafts(() => 'synthetic-product-account').native,
      { subscribe: () => () => undefined, getSnapshot: () => account },
    );
    jest.replaceProperty(
      jest.requireMock<{ drafts: typeof drafts }>('../src/registration.ts'),
      'drafts',
      drafts,
    );
    const id = showMail('work');
    route.setParams({});
    const app = await render(
      <AccountContext
        value={{
          mailboxes: [connection],
          openAccount: () => undefined,
          authorizeMailbox: () => Promise.resolve(),
          refreshInbox: (load) => load(),
          account: 'synthetic-product-account',
          profiles: [],
          createProfile: () => Promise.resolve(undefined),
          chooseFolders: () => Promise.resolve(true),
        }}>
        <RootLayout />
      </AccountContext>,
    );
    try {
      const { registry } = split.commands;
      ok(registry);
      // The notification requests Reply before its destination reader has mounted.
      await act(() => {
        runWhenOffered(registry, {
          id: 'reply',
          target: commandTarget('garden', { id, subject: '' }).id,
        });
        route.router.replace({
          pathname: '/message/[id]',
          params: { profileId: 'work', mailbox: 'garden', id },
        });
      });
      await expect(
        screen.findByLabelText('Message body'),
      ).resolves.toBeVisible();
      expect(drafts.getSnapshot()).toMatchObject({
        kind: 'ready',
        drafts: [
          expect.objectContaining({
            connection: 'garden',
            response: expect.objectContaining({ kind: 'reply', message: id }),
          }),
        ],
      });
    } finally {
      await app.unmount();
      jest.replaceProperty(
        jest.requireMock<{ drafts: typeof drafts }>('../src/registration.ts'),
        'drafts',
        jest.requireActual<{ drafts: typeof drafts }>('../src/registration.ts')
          .drafts,
      );
    }
  });

  it('leaves a cold-opened Work Profile Thread for its Inbox once a collapsed split view pops it', async () => {
    expect.hasAssertions();
    const id = showMail('work');
    route.setParams({});
    route.router.replace({
      pathname: '/thread/[id]',
      params: { profileId: 'work', mailbox: 'garden', id },
    });
    await render(<RootLayout />);
    await expect(
      screen.findByText('Synthetic garden body.'),
    ).resolves.toBeVisible();
    const appear = async (column: string) => {
      await act(() => {
        screen
          .getByTestId(column, { includeHiddenElements: true })
          .props.onDidAppear();
      });
    };
    // Beside the reader, a sidebar appearing in an expanded split view leaves the Thread open.
    await appear('mailboxes-column');
    expect(screen.getByText('Synthetic garden body.')).toBeVisible();
    await act(() => {
      screen.getByTestId('mail-split').props.onCollapse();
    });
    split.shown.length = 0;
    // Collapsed, the system Back pops this Thread, whose link left Mailboxes beneath it.
    await appear('mailboxes-column');
    expect(split.shown.at(-1)).toBe('supplementary');
    expect(route.params()).toStrictEqual({ profileId: 'work' });
    expect(screen.queryByText('Synthetic garden body.')).toBeNull();
  });

  it.each([
    { name: 'legacy Default', profile: defaultProfile, params: {} },
    { name: 'Work', profile: 'work', params: { profileId: 'work' } },
  ])(
    'retains $name ownership through selection and reader close',
    async ({ profile, params }) => {
      expect.hasAssertions();
      showMail(profile);
      route.setParams(params);
      split.shown.length = 0;
      await render(<RootLayout />);
      expect(split.shown).toStrictEqual(['supplementary']);
      await fireEvent.press(
        await screen.findByRole('button', { name: /Garden plan/u }),
      );
      await expect(
        screen.findByText('Synthetic garden body.'),
      ).resolves.toBeVisible();
      split.shown.length = 0;
      await fireEvent.press(screen.getByRole('button', { name: 'Archive' }));
      // On iPhone the closed reader returns to the message list, not Mailboxes.
      expect(split.shown).toStrictEqual(['supplementary']);
      // Reader close must leave the same Profile's search control visible, rather than a Default fallback.
      expect(
        screen.queryByRole('header', { name: 'Message unavailable' }),
      ).toBeNull();
      expect(
        screen.getByLabelText('Search senders and subjects'),
      ).toBeVisible();
    },
  );

  it.each([
    { name: 'empty', profileId: '' },
    { name: 'null', profileId: null },
    { name: 'repeated', profileId: [defaultProfile, 'work'] },
  ])(
    'rejects $name profileId instead of reading the Default mailbox',
    async ({ profileId }) => {
      expect.hasAssertions();
      showMail(defaultProfile);
      route.setParams({
        profileId,
        mailbox: 'garden',
        id: 'message-1',
      });
      const app = await render(<RootLayout />);
      expect(
        screen.getByRole('header', { name: 'Message unavailable' }),
      ).toBeVisible();
      expect(screen.queryByLabelText('Search senders and subjects')).toBeNull();
      await act(() => {
        route.setParams({});
      });
      await expect(
        screen.findByRole('button', { name: /Garden plan/u }),
      ).resolves.toBeVisible();
      await app.unmount();
    },
  );

  it('brings the message list forward when Search Mail or Inbox runs from the Mailboxes header', async () => {
    expect.hasAssertions();
    showMail(defaultProfile);
    route.setParams({});
    await render(<RootLayout />);
    await screen.findByRole('button', { name: /Garden plan/u });
    // As on iPhone, where Mailboxes covers the list until a command brings it back.
    const run = async (name: string) => {
      await fireEvent(
        screen.getByRole('header', { name: 'Mailboxes' }),
        'accessibilityAction',
        { nativeEvent: { actionName: 'openCommandPalette' } },
      );
      const palette = within(screen.getByTestId('command-palette'));
      await act(async () => {
        await fireEvent.press(palette.getByRole('button', { name }));
      });
    };
    split.shown.length = 0;
    await run('Search Mail');
    expect(split.shown).toStrictEqual(['supplementary']);
    await run('Inbox');
    expect(split.shown).toStrictEqual(['supplementary', 'supplementary']);
    expect(screen.queryByTestId('command-palette')).toBeNull();
  });

  it('clears the previous Profile’s search and mailbox choice when the same window targets another Profile', async () => {
    expect.hasAssertions();
    showMail(defaultProfile);
    route.setParams({});
    await render(<RootLayout />);
    await fireEvent.press(
      await screen.findByRole('button', { name: 'Inbox. In garden' }),
    );
    await fireEvent.changeText(
      await screen.findByLabelText('Search senders and subjects'),
      'personal search',
    );
    showMail('work');
    await act(() => {
      route.setParams({ profileId: 'work' });
    });
    await expect(
      screen.findByLabelText('Search senders and subjects'),
    ).resolves.toHaveDisplayValue('');
    expect(screen.getByRole('button', { name: 'All Inboxes' })).toBeSelected();
    await expect(
      screen.findByRole('button', { name: /Garden plan/u }),
    ).resolves.toBeVisible();
    showMail(defaultProfile);
    await act(() => {
      route.setParams({});
    });
    await expect(
      screen.findByLabelText('Search senders and subjects'),
    ).resolves.toHaveDisplayValue('');
    expect(screen.getByRole('button', { name: 'All Inboxes' })).toBeSelected();
  });
});

describe('the mobile Profile Switcher', () => {
  const work = { id: 'work', name: 'Work' };
  const garden = {
    id: 'garden',
    address: 'alex@example.invalid',
    state: 'connected',
    profile: 'work',
    provider: 'gmail',
  } as const;
  // The device's saved interface preferences at the native boundary.
  const savedPreferences = (saved: Map<string, string>) => {
    const nativeRegistration = TurboModuleRegistry.getEnforcing<
      TurboModule & {
        preference: (key: string) => Promise<unknown>;
        setPreference: (key: string, value: string) => Promise<unknown>;
      }
    >('UnwiredRegistration');
    jest
      .spyOn(nativeRegistration, 'preference')
      .mockImplementation((key) =>
        Promise.resolve({ value: saved.get(key) ?? null }),
      );
    return jest
      .spyOn(nativeRegistration, 'setPreference')
      .mockImplementation((key, value) => {
        saved.set(key, value);
        return Promise.resolve({});
      });
  };
  const view = (
    createProfile: (
      name: string,
    ) => Promise<'upgrade-required' | undefined> = () =>
      Promise.resolve(undefined),
    account = 'synthetic-product-account',
  ) => (
    <AccountContext
      value={{
        mailboxes: [garden],
        openAccount: () => undefined,
        authorizeMailbox: () => Promise.resolve(),
        refreshInbox: (load) => load(),
        account,
        profiles: account === 'synthetic-product-account' ? [work] : [],
        createProfile,
        chooseFolders: () => Promise.resolve(true),
      }}>
      <RootLayout />
    </AccountContext>
  );
  const choose = async (switcher: string, item: string) => {
    await fireEvent(screen.getByLabelText(switcher), 'select', {
      nativeEvent: { id: item },
    });
  };

  it('owns the route through the real connected registration gate', async () => {
    expect.hasAssertions();
    const { registration, work: workId } = await createTwoProfileRegistration();
    const mode = jest.replaceProperty(
      jest.requireMock<{ previewInbox: boolean }>(
        '@private-email/mail-core/registration-mode',
      ),
      'previewInbox',
      false,
    );
    const store = jest.replaceProperty(
      jest.requireMock<{ registration: typeof registration }>(
        '../src/registration.ts',
      ),
      'registration',
      registration,
    );
    try {
      savedPreferences(new Map());
      showMail(defaultProfile);
      route.setParams({});
      await render(<RootLayout />);
      await screen.findByLabelText('Profile, Primary Profile');
      await choose('Profile, Primary Profile', `profile\n${workId}`);
      await expect(
        screen.findByLabelText('Profile, Work'),
      ).resolves.toBeVisible();
    } finally {
      store.restore();
      mode.restore();
      jest.restoreAllMocks();
    }
  });

  it('chooses List density in Settings for the window’s Mail Profile only', async () => {
    expect.hasAssertions();
    const { registration, work: workId } = await createTwoProfileRegistration();
    const { snapshot } = registration.getSnapshot();
    ok(snapshot.kind !== 'signed-out');
    const owner = snapshot.productAccountId;
    const kept = { revision: 0, document: null as string | null };
    const preferences = createInboxPreferences(
      {
        openInboxPreferences: async () => ({ owner, ...kept }),
        commitInboxPreferences: async (account, expectedRevision, document) => {
          Object.assign(kept, { revision: expectedRevision + 1, document });
          return { owner: account, revision: kept.revision };
        },
      },
      registration,
    );
    const mode = jest.replaceProperty(
      jest.requireMock<{ previewInbox: boolean }>(
        '@private-email/mail-core/registration-mode',
      ),
      'previewInbox',
      false,
    );
    const store = jest.replaceProperty(
      jest.requireMock<{ registration: typeof registration }>(
        '../src/registration.ts',
      ),
      'registration',
      registration,
    );
    try {
      savedPreferences(new Map());
      showMail(defaultProfile);
      route.setParams({});
      await render(
        <InboxPreferencesContext value={preferences}>
          <RootLayout />
        </InboxPreferencesContext>,
      );
      await screen.findByLabelText('Profile, Primary Profile');
      await choose('Profile, Primary Profile', `profile\n${workId}`);
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Account' }),
      );
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Appearance' }),
      );
      await fireEvent.press(screen.getByRole('radio', { name: 'Compact' }));
      await waitFor(() => {
        expect(screen.getByRole('radio', { name: 'Compact' })).toBeChecked();
      });
      expect([
        preferences.listDensity(workId),
        preferences.listDensity(defaultProfile),
      ]).toStrictEqual(['compact', 'comfortable']);
    } finally {
      store.restore();
      mode.restore();
      jest.restoreAllMocks();
    }
  });

  /* oxlint-disable vitest/max-expects -- One journey switches to a Profile without mailboxes and manages it. */
  it.each([
    { isPad: false, subtitle: 'Family · No mailboxes' },
    { isPad: true, subtitle: 'No mailboxes' },
  ])(
    'shows No Mailboxes for a Profile without mailboxes and opens Mail Profiles (isPad=$isPad)',
    async ({ isPad, subtitle }) => {
      expect.hasAssertions();
      const { registration } = await createTwoProfileRegistration();
      await registration.createProfile('Family');
      const family = profilesOf(registration.getSnapshot().snapshot).find(
        ({ name }) => name === 'Family',
      )?.id;
      ok(family !== undefined);
      const mode = jest.replaceProperty(
        jest.requireMock<{ previewInbox: boolean }>(
          '@private-email/mail-core/registration-mode',
        ),
        'previewInbox',
        false,
      );
      const store = jest.replaceProperty(
        jest.requireMock<{ registration: typeof registration }>(
          '../src/registration.ts',
        ),
        'registration',
        registration,
      );
      const platform = jest.replaceProperty(
        jest.requireActual<{ ipad: boolean }>('../src/inbox-styles.ts'),
        'ipad',
        isPad,
      );
      try {
        savedPreferences(new Map());
        showMail(defaultProfile);
        route.setParams({});
        await render(<RootLayout />);
        await expect(
          screen.findByRole('button', { name: /Garden plan/u }),
        ).resolves.toBeVisible();
        expect(screen.getByText('Gmail · garden')).toBeVisible();
        expect(screen.getByText('Encrypted on this device')).toBeVisible();
        await choose('Profile, Primary Profile', `profile\n${family}`);
        await expect(screen.findByText(subtitle)).resolves.toBeVisible();
        // The sidebar keeps Favorites only. No provider or sync status names the Inbox's scope, and
        // Primary's mail is gone.
        expect(screen.getByText('Favorites')).toBeVisible();
        expect(screen.queryByText(/Gmail|unread/u)).toBeNull();
        expect(
          screen.queryByRole('button', { name: /Garden plan/u }),
        ).toBeNull();
        expect(screen.getByText('No Mailboxes')).toBeVisible();
        expect(
          screen.getByText(
            'Move a mailbox into Family from its current Profile.',
          ),
        ).toBeVisible();
        expect(screen.queryByText('No Mail')).toBeNull();
        // Nothing is stored on this device for a Profile without mailboxes.
        expect(screen.queryByText('Encrypted on this device')).toBeNull();
        expect(
          screen.queryByRole('button', { name: /Add Mailbox/u }),
        ).toBeNull();
        await fireEvent.press(
          screen.getByRole('button', { name: 'Manage Profiles…' }),
        );
        // Settings opens on Mail Profiles, which lists the Profile without mailboxes.
        await waitFor(() => {
          expect(
            screen.getByRole('button', { name: 'Family' }).props
              .accessibilityHint,
          ).toBe('No mailboxes');
        });
        expect(
          screen.getByRole('button', { name: 'Primary Profile' }),
        ).toHaveAccessibilityValue({ text: 'Startup Profile' });
      } finally {
        platform.restore();
        store.restore();
        mode.restore();
        jest.restoreAllMocks();
      }
    },
  );
  /* oxlint-enable vitest/max-expects */

  /* oxlint-disable vitest/max-expects -- One journey opens, renames, adds and picks the Startup Profile. */
  it('manages Mail Profiles in Settings through the real registration', async () => {
    expect.hasAssertions();
    const { registration, work: workId } = await createTwoProfileRegistration();
    const { snapshot } = registration.getSnapshot();
    ok(snapshot.kind !== 'signed-out');
    const owner = snapshot.productAccountId;
    const mode = jest.replaceProperty(
      jest.requireMock<{ previewInbox: boolean }>(
        '@private-email/mail-core/registration-mode',
      ),
      'previewInbox',
      false,
    );
    const store = jest.replaceProperty(
      jest.requireMock<{ registration: typeof registration }>(
        '../src/registration.ts',
      ),
      'registration',
      registration,
    );
    try {
      const saving = savedPreferences(new Map());
      const prompt = jest.spyOn(Alert, 'prompt').mockReturnValue(undefined);
      showMail(defaultProfile);
      route.setParams({});
      const app = await render(<RootLayout />);
      await screen.findByLabelText('Profile, Primary Profile');
      await choose('Profile, Primary Profile', 'profile\nmanage');
      const work = await screen.findByRole('button', { name: 'Work' });
      expect(work.props.accessibilityHint).toBe('Gmail');
      // No Startup Profile is saved, so new windows open the Primary Profile.
      expect(
        screen.getByRole('button', { name: 'Primary Profile' }),
      ).toHaveAccessibilityValue({ text: 'Startup Profile' });
      // The Primary Profile keeps its name.
      expect(screen.queryByDisplayValue('Primary Profile')).toBeNull();
      await fireEvent.press(work);
      // iPhone keeps the selected Profile on the group's fill; a press shows until release or cancel.
      const primary = screen.getByRole('button', { name: 'Primary Profile' });
      expect([fills(work), fills(primary)]).toStrictEqual([0, 0]);
      expect(work).toBeSelected();
      await fireEvent(work, 'responderGrant', touch);
      expect(fills(work)).toBe(1);
      await fireEvent(work, 'responderRelease', touch);
      await waitFor(() => {
        expect(fills(work)).toBe(0);
      });
      await fireEvent(primary, 'responderGrant', touch);
      expect(fills(primary)).toBe(1);
      await fireEvent(primary, 'responderTerminate', touch);
      await waitFor(() => {
        expect(fills(primary)).toBe(0);
      });
      const name = screen.getByDisplayValue('Work');
      expect(name).toHaveProp('accessibilityLabel', 'Name');
      await fireEvent.changeText(name, '  Office ');
      await fireEvent(name, 'endEditing');
      await expect(
        screen.findByRole('header', { name: 'Office' }),
      ).resolves.toBeVisible();
      expect(screen.getByDisplayValue('Office')).toBeVisible();
      await choose('Startup Profile', workId);
      expect(saving).toHaveBeenCalledWith(`startup-profile:${owner}`, workId);
      expect(
        screen.getByRole('button', { name: 'Office' }),
      ).toHaveAccessibilityValue({ text: 'Startup Profile' });
      await fireEvent.press(
        screen.getByRole('button', { name: 'Add Profile…' }),
      );
      const buttons = prompt.mock.lastCall?.[2];
      ok(Array.isArray(buttons));
      await act(async () => {
        const create = buttons.find(({ text }) => text === 'Create')
          // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- React Native types the value per prompt type.
          ?.onPress as ((value: string) => void) | undefined;
        create?.('Family');
        await Promise.resolve();
      });
      const family = await screen.findByRole('button', { name: 'Family' });
      expect(family.props.accessibilityHint).toBe('No mailboxes');
      // Startup Profile is only for a new window, not the shell under Settings.
      await fireEvent.press(screen.getByRole('button', { name: 'Open Inbox' }));
      await expect(
        screen.findByLabelText('Profile, Primary Profile'),
      ).resolves.toBeVisible();
      await app.unmount();
      await render(<RootLayout />);
      await expect(
        screen.findByLabelText('Profile, Office'),
      ).resolves.toBeVisible();
    } finally {
      store.restore();
      mode.restore();
      jest.restoreAllMocks();
    }
  });
  /* oxlint-enable vitest/max-expects */

  it('duplicates a Mail Profile into a selected copy with its style, without its mailboxes', async () => {
    expect.hasAssertions();
    const { registration, vault, work } = await createTwoProfileRegistration();
    await registration.restyleProfile(work, { color: 'teal', icon: 'laptop' });
    const mode = jest.replaceProperty(
      jest.requireMock<{ previewInbox: boolean }>(
        '@private-email/mail-core/registration-mode',
      ),
      'previewInbox',
      false,
    );
    const store = jest.replaceProperty(
      jest.requireMock<{ registration: typeof registration }>(
        '../src/registration.ts',
      ),
      'registration',
      registration,
    );
    try {
      savedPreferences(new Map());
      showMail(defaultProfile);
      route.setParams({});
      await render(<RootLayout />);
      await screen.findByLabelText('Profile, Primary Profile');
      await choose('Profile, Primary Profile', 'profile\nmanage');
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Work' }),
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
      // Another New Mail Profile… finishes ahead of Duplicate.
      const family = registration.createProfile('Family');
      await admitted;
      await fireEvent.press(
        screen.getByRole('button', { name: 'Duplicate Profile' }),
      );
      release();
      await family;
      // The copy, not the Profile created elsewhere, is selected and opens for renaming.
      await expect(
        screen.findByRole('header', { name: 'Work Copy' }),
      ).resolves.toBeVisible();
      expect(screen.getByDisplayValue('Work Copy')).toBeVisible();
      expect(screen.getByRole('button', { name: 'Work Copy' })).toHaveProp(
        'accessibilityHint',
        'No mailboxes',
      );
      expect(screen.getByText('No mailboxes in this Profile')).toBeVisible();
      const { snapshot } = registration.getSnapshot();
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
      store.restore();
      mode.restore();
      jest.restoreAllMocks();
    }
  });

  it('shows each Profile Color with its swatch in Settings, and the Primary Profile’s defaults', async () => {
    expect.hasAssertions();
    const { registration } = await createTwoProfileRegistration();
    const mode = jest.replaceProperty(
      jest.requireMock<{ previewInbox: boolean }>(
        '@private-email/mail-core/registration-mode',
      ),
      'previewInbox',
      false,
    );
    const store = jest.replaceProperty(
      jest.requireMock<{ registration: typeof registration }>(
        '../src/registration.ts',
      ),
      'registration',
      registration,
    );
    try {
      savedPreferences(new Map());
      showMail(defaultProfile);
      route.setParams({});
      await render(<RootLayout />);
      await screen.findByLabelText('Profile, Primary Profile');
      await choose('Profile, Primary Profile', 'profile\nmanage');
      // The Primary Profile has no record to style; it shows the defaults.
      await expect(screen.findByText('Graphite')).resolves.toBeVisible();
      expect(screen.getByText('First Letter')).toBeVisible();
      expect(screen.queryByLabelText('Color')).toBeNull();
      await fireEvent.press(screen.getByRole('button', { name: 'Work' }));
      // Each Color's swatch trails its name; the current one is checked.
      expect(
        screen
          .getByLabelText('Color')
          .props.sections[0].items.map(
            ({
              title,
              symbolColor,
              checked,
            }: {
              title: string;
              symbolColor: string;
              checked: boolean;
            }) => [title, symbolColor, checked],
          ),
      ).toStrictEqual([
        ['Graphite', '#15171B', true],
        ['Blue', '#0A58CA', false],
        ['Indigo', '#3634A3', false],
        ['Purple', '#8944AB', false],
        ['Pink', '#C2185B', false],
        ['Teal', '#0E7490', false],
        ['Green', '#237A3A', false],
        ['Brown', '#7A5C3E', false],
      ]);
    } finally {
      store.restore();
      mode.restore();
      jest.restoreAllMocks();
    }
  });

  it('chooses a Mail Profile’s Color and Icon in Settings, keeping the other choice', async () => {
    expect.hasAssertions();
    const { registration, work } = await createTwoProfileRegistration();
    const mode = jest.replaceProperty(
      jest.requireMock<{ previewInbox: boolean }>(
        '@private-email/mail-core/registration-mode',
      ),
      'previewInbox',
      false,
    );
    const store = jest.replaceProperty(
      jest.requireMock<{ registration: typeof registration }>(
        '../src/registration.ts',
      ),
      'registration',
      registration,
    );
    const styleOf = () =>
      profilesOf(registration.getSnapshot().snapshot)
        .filter(({ id }) => id === work)
        .map(({ color, icon }) => ({ color, icon }));
    try {
      savedPreferences(new Map());
      showMail(defaultProfile);
      route.setParams({});
      await render(<RootLayout />);
      await screen.findByLabelText('Profile, Primary Profile');
      await choose('Profile, Primary Profile', 'profile\nmanage');
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Work' }),
      );
      await choose('Color', 'blue');
      await waitFor(() => {
        expect(styleOf()).toStrictEqual([{ color: 'blue', icon: undefined }]);
      });
      await choose('Icon', 'laptop');
      await waitFor(() => {
        expect(styleOf()).toStrictEqual([{ color: 'blue', icon: 'laptop' }]);
      });
      expect(screen.getByLabelText('Icon')).toHaveAccessibilityValue({
        text: 'Laptop',
      });
      // First Letter clears the Icon and keeps the Color.
      await choose('Icon', 'firstLetter');
      await waitFor(() => {
        expect(styleOf()).toStrictEqual([{ color: 'blue', icon: undefined }]);
      });
    } finally {
      store.restore();
      mode.restore();
      jest.restoreAllMocks();
    }
  });

  it('shows each Mail Profile’s styled monogram in the switcher and its menu', async () => {
    expect.hasAssertions();
    const { registration, work } = await createTwoProfileRegistration();
    const mode = jest.replaceProperty(
      jest.requireMock<{ previewInbox: boolean }>(
        '@private-email/mail-core/registration-mode',
      ),
      'previewInbox',
      false,
    );
    const store = jest.replaceProperty(
      jest.requireMock<{ registration: typeof registration }>(
        '../src/registration.ts',
      ),
      'registration',
      registration,
    );
    const monograms = () =>
      screen
        .getByLabelText(/^Profile, /u)
        .props.sections[0].items.map(
          ({ title, monogram }: { title: string; monogram: unknown }) => [
            title,
            monogram,
          ],
        );
    try {
      savedPreferences(new Map([['window-profile', work]]));
      showMail(work);
      route.setParams({});
      await render(<RootLayout />);
      const switcher = await screen.findByLabelText('Profile, Work');
      // The Primary Profile and an unstyled Profile show Graphite and their first letter.
      expect(
        within(switcher).getByText('W', { includeHiddenElements: true }),
      ).toHaveStyle({ color: '#FFFFFF' });
      expect(monograms()).toStrictEqual([
        ['Primary Profile', { color: '#15171B', symbol: '', letter: 'P' }],
        ['Work', { color: '#15171B', symbol: '', letter: 'W' }],
      ]);
      await registration.restyleProfile(work, {
        color: 'teal',
        icon: 'laptop',
      });
      await waitFor(() => {
        expect(monograms()).toStrictEqual([
          ['Primary Profile', { color: '#15171B', symbol: '', letter: 'P' }],
          ['Work', { color: '#0E7490', symbol: 'laptopcomputer', letter: 'W' }],
        ]);
      });
      // The switcher draws Work's Icon in place of its letter.
      expect(
        within(screen.getByLabelText('Profile, Work')).queryByText('W', {
          includeHiddenElements: true,
        }),
      ).toBeNull();
    } finally {
      store.restore();
      mode.restore();
      jest.restoreAllMocks();
    }
  });

  /* oxlint-disable vitest/max-expects -- One journey moves a mailbox both ways, then removes its Profile. */
  it('moves a mailbox between Profiles and removes a Profile with its mailboxes in Settings', async () => {
    expect.hasAssertions();
    const {
      registration,
      vault,
      work: workId,
    } = await createTwoProfileRegistration();
    const mode = jest.replaceProperty(
      jest.requireMock<{ previewInbox: boolean }>(
        '@private-email/mail-core/registration-mode',
      ),
      'previewInbox',
      false,
    );
    const store = jest.replaceProperty(
      jest.requireMock<{ registration: typeof registration }>(
        '../src/registration.ts',
      ),
      'registration',
      registration,
    );
    try {
      savedPreferences(new Map());
      const alert = jest.spyOn(Alert, 'alert').mockReturnValue(undefined);
      showMail(defaultProfile);
      route.setParams({});
      await render(<RootLayout />);
      await screen.findByLabelText('Profile, Primary Profile');
      await choose('Profile, Primary Profile', 'profile\nmanage');
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Work' }),
      );
      const moving = 'Profile for other@example.invalid';
      expect(screen.getByLabelText(moving)).toHaveAccessibilityValue({
        text: 'Work',
      });
      await fireEvent.changeText(screen.getByDisplayValue('Work'), 'Office');
      const { recordProfiles } = vault;
      const renaming = Promise.withResolvers<undefined>();
      const renameStarted = Promise.withResolvers<undefined>();
      const movingMailbox = Promise.withResolvers<undefined>();
      // Hold native persistence while the real store serializes the move and editing completion.
      jest
        .spyOn(vault, 'recordProfiles')
        .mockImplementationOnce(async (next) => {
          await movingMailbox.promise;
          return recordProfiles(next);
        })
        .mockImplementation(async (next) => {
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Refuse only the queued rename at the native persistence boundary.
          if (next.profiles.some(({ pending }) => pending === 'Office')) {
            renameStarted.resolve(undefined);
            await renaming.promise;
            throw Object.assign(new Error('Synthetic rename refused'), {
              code: 'profile-changed',
            });
          }
          return recordProfiles(next);
        });
      await choose(moving, defaultProfile);
      // Only the indicator replaces the pop-up; the other Profile changes wait for the move.
      expect(screen.getByLabelText('Moving to Primary Profile…')).toBeVisible();
      expect(screen.queryByLabelText(moving)).toBeNull();
      for (const name of [
        'Add Profile…',
        'Duplicate Profile',
        'Remove Profile…',
      ]) {
        expect(screen.getByRole('button', { name })).toBeDisabled();
      }
      expect(screen.getByDisplayValue('Office')).toHaveProp('editable', false);
      expect(
        screen.getByRole('button', { name: 'Primary Profile' }),
      ).toBeEnabled();
      // Disabling the edited native field can deliver its queued editing completion.
      await act(() => {
        screen.getByDisplayValue('Office').props.onEndEditing();
      });
      await fireEvent.press(
        screen.getByRole('button', { name: 'Primary Profile' }),
      );
      const otherMailbox = screen.getByLabelText(
        'Profile for alex@example.invalid',
      );
      expect(otherMailbox).toBeDisabled();
      // A native menu answer queued before disablement still reaches the event boundary.
      await act(() => {
        otherMailbox.props.onSelect({ nativeEvent: { id: workId } });
      });
      expect(otherMailbox).toHaveAccessibilityValue({
        text: 'Primary Profile',
      });
      await fireEvent.press(screen.getByRole('button', { name: 'Work' }));
      await act(async () => {
        movingMailbox.resolve(undefined);
        await renameStarted.promise;
      });
      await waitFor(() => {
        expect(
          screen.getByRole('button', { name: 'Work' }).props.accessibilityHint,
        ).toBe('No mailboxes');
      });
      expect(screen.queryByLabelText(moving)).toBeNull();
      expect(screen.queryByLabelText('Moving to Primary Profile…')).toBeNull();
      expect(
        screen.getByRole('button', { name: 'Add Profile…' }),
      ).toBeDisabled();
      await act(async () => {
        renaming.resolve(undefined);
        await Promise.resolve();
      });
      await waitFor(() => {
        expect(screen.getByDisplayValue('Work')).toBeVisible();
      });
      expect(
        mailboxesOf(registration.getSnapshot().snapshot).find(
          ({ address }) => address === 'alex@example.invalid',
        )?.profile,
      ).toBe(defaultProfile);
      expect(alert).toHaveBeenCalledWith(
        'Rename Profile',
        'Another device changed these Profiles first. Check them, then try again.',
        [{ text: 'OK' }],
      );
      alert.mockClear();
      expect(
        screen.getByRole('button', { name: 'Add Profile…' }),
      ).toBeEnabled();
      // The Primary Profile lists both mailboxes and cannot be removed.
      await fireEvent.press(
        screen.getByRole('button', { name: 'Primary Profile' }),
      );
      expect(
        screen.queryByRole('button', { name: 'Remove Profile…' }),
      ).toBeNull();
      await choose(moving, workId);
      await waitFor(() => {
        expect(
          screen.getByRole('button', { name: 'Work' }).props.accessibilityHint,
        ).toBe('Gmail');
      });
      expect(alert).not.toHaveBeenCalled();

      await fireEvent.press(screen.getByRole('button', { name: 'Work' }));
      await fireEvent.press(
        screen.getByRole('button', { name: 'Remove Profile…' }),
      );
      const asked = alert.mock.lastCall;
      ok(asked);
      const [title, message, buttons] = asked;
      expect([title, message]).toStrictEqual([
        'Remove “Work” and Its Mailboxes?',
        'other@example.invalid is also removed from Unwired Mail on all your devices. Its mail stays with Gmail.',
      ]);
      ok(Array.isArray(buttons));
      expect(buttons.map(({ text, style }) => [text, style])).toStrictEqual([
        ['Cancel', 'cancel'],
        ['Remove', 'destructive'],
      ]);
      await act(async () => {
        buttons.find(({ text }) => text === 'Remove')?.onPress?.();
        await Promise.resolve();
      });
      await waitFor(() => {
        expect(screen.queryByRole('button', { name: 'Work' })).toBeNull();
      });
      expect(
        screen.getByRole('header', { name: 'Primary Profile' }),
      ).toBeVisible();
      expect(
        mailboxesOf(registration.getSnapshot().snapshot).map(
          ({ address }) => address,
        ),
      ).toStrictEqual(['alex@example.invalid']);
      // No refusal followed the question.
      expect(alert.mock.lastCall?.[0]).toBe(title);
    } finally {
      store.restore();
      mode.restore();
      jest.restoreAllMocks();
    }
  });
  /* oxlint-enable vitest/max-expects */

  /* oxlint-disable vitest/max-expects -- One journey switches, saves and restores the window's Profile. */
  it('switches the window to the chosen Profile and restores it after relaunch', async () => {
    expect.hasAssertions();
    try {
      const saving = savedPreferences(new Map());
      showMail('work');
      route.setParams({});
      const app = await render(view());
      const switcher = await screen.findByLabelText('Profile, Primary Profile');
      // The Primary Profile owns no connection here, so Work's mail stays hidden.
      expect(screen.queryByRole('button', { name: /Garden plan/u })).toBeNull();
      expect(switcher.props.sections).toMatchObject([
        {
          items: [
            {
              title: 'Primary Profile',
              subtitle: 'No mailboxes',
              checked: true,
            },
            { title: 'Work', subtitle: 'Gmail · 2 unread', checked: false },
          ],
        },
        {
          items: [{ title: 'New Profile…' }, { title: 'Manage Profiles…' }],
        },
      ]);
      await choose('Profile, Primary Profile', 'profile\nwork');
      await expect(
        screen.findByRole('button', { name: /Garden plan/u }),
      ).resolves.toBeVisible();
      expect(screen.getByLabelText('Profile, Work')).toBeVisible();
      expect(route.params()).toStrictEqual({ profileId: 'work' });
      expect(saving).toHaveBeenCalledWith('window-profile', 'work');
      await app.unmount();
      // A relaunch opens no link, so the window restores the Profile it last showed.
      route.setParams({});
      await render(view());
      await expect(
        screen.findByRole('button', { name: /Garden plan/u }),
      ).resolves.toBeVisible();
      expect(screen.getByLabelText('Profile, Work')).toBeVisible();
    } finally {
      jest.restoreAllMocks();
    }
  });
  /* oxlint-enable vitest/max-expects */

  it.each([false, true])(
    'drops the previous Product Account’s switched Profile after signing into another account, after link %s',
    async (redelivered) => {
      expect.hasAssertions();
      try {
        jest
          .spyOn(Linking, 'addEventListener')
          .mockImplementation((type, listener) =>
            DeviceEventEmitter.addListener(type, listener),
          );
        savedPreferences(new Map());
        showMail('work');
        route.setParams({});
        const app = await render(view());
        await choose('Profile, Primary Profile', 'profile\nwork');
        await expect(
          screen.findByLabelText('Profile, Work'),
        ).resolves.toBeVisible();
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Each fixed table case checks route retirement with or without a preceding URL event.
        if (redelivered) {
          await act(() => {
            DeviceEventEmitter.emit('url', {
              url: 'unwired-mail://?profileId=work',
            });
          });
        }
        // The same window, after signing out and into another Product Account.
        await app.rerender(view(undefined, 'another-product-account'));
        await expect(
          screen.findByLabelText('Profile, Primary Profile'),
        ).resolves.toBeVisible();
        expect(route.params()).toStrictEqual({});
      } finally {
        jest.restoreAllMocks();
      }
    },
  );

  it.each([
    { profileId: defaultProfile, heading: 'Garden plan', redelivered: false },
    {
      profileId: ['work', 'work'],
      heading: 'Message unavailable',
      redelivered: false,
    },
    { profileId: defaultProfile, heading: 'Garden plan', redelivered: true },
    {
      profileId: ['work', 'work'],
      heading: 'Message unavailable',
      redelivered: true,
    },
  ])(
    'keeps a targeted link when another account opens: $heading, redelivered $redelivered',
    async ({ profileId, heading, redelivered }) => {
      expect.hasAssertions();
      try {
        jest
          .spyOn(Linking, 'addEventListener')
          .mockImplementation((type, listener) =>
            DeviceEventEmitter.addListener(type, listener),
          );
        savedPreferences(new Map());
        showMail('work');
        route.setParams({});
        const app = await render(view());
        await choose('Profile, Primary Profile', 'profile\nwork');
        await screen.findByLabelText('Profile, Work');
        const id = showMail(defaultProfile);
        const params = { mailbox: 'garden', id, profileId };
        // oxlint-disable-next-line vitest/no-conditional-in-test -- Each fixed table case checks a fresh or cached target without duplicating the journey.
        if (redelivered) {
          await act(() => {
            route.router.replace({ pathname: '/message/[id]', params });
          });
          await screen.findByRole('header', { name: heading });
        }
        // A new link arrives while the gate admits another account, replacing the old route.
        await act(async () => {
          DeviceEventEmitter.emit('url', {
            url: `unwired-mail://message/${id}?mailbox=garden&${[profileId]
              .flat()
              .map((selector) => `profileId=${selector}`)
              .join('&')}`,
          });
          // Expo Router interns identical route info, including its params object.
          route.router.replace({ pathname: '/message/[id]', params });
          await app.rerender(view(undefined, 'another-product-account'));
        });
        await expect(
          screen.findByRole('header', { name: heading }),
        ).resolves.toBeVisible();
        expect(route.params()).toStrictEqual(params);
      } finally {
        jest.restoreAllMocks();
      }
    },
  );

  it('opens the Startup Profile, while a message link from before Profiles opens the Default Profile', async () => {
    expect.hasAssertions();
    try {
      savedPreferences(
        new Map([['startup-profile:synthetic-product-account', 'work']]),
      );
      const id = showMail('work');
      route.setParams({});
      const app = await render(view());
      await expect(
        screen.findByRole('button', { name: /Garden plan/u }),
      ).resolves.toBeVisible();
      await app.unmount();
      route.setParams({ mailbox: 'garden', id });
      await render(view());
      await expect(
        screen.findByRole('header', { name: 'Message unavailable' }),
      ).resolves.toBeVisible();
      expect(screen.getByLabelText('Profile, Primary Profile')).toBeVisible();
    } finally {
      jest.restoreAllMocks();
    }
  });

  it('names a new Mail Profile and explains the upgrade-required refusal', async () => {
    expect.hasAssertions();
    try {
      savedPreferences(new Map());
      const prompt = jest.spyOn(Alert, 'prompt').mockReturnValue(undefined);
      const alert = jest.spyOn(Alert, 'alert').mockReturnValue(undefined);
      const createProfile = jest.fn((_name: string) =>
        Promise.resolve('upgrade-required' as const),
      );
      showMail('work');
      route.setParams({});
      await render(view(createProfile));
      await screen.findByLabelText('Profile, Primary Profile');
      await choose('Profile, Primary Profile', 'profile\nnew');
      const asked = prompt.mock.lastCall;
      ok(asked);
      const [title, message, buttons, type] = asked;
      expect([title, message, type]).toStrictEqual([
        'New Profile',
        'Name a Profile to keep a set of mailboxes apart from your other mail.',
        'plain-text',
      ]);
      ok(Array.isArray(buttons));
      const created = buttons.find(({ text }) => text === 'Create');
      await act(async () => {
        // A plain-text prompt hands its button the entered text.
        // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- React Native types the value per prompt type.
        (created?.onPress as ((value: string) => void) | undefined)?.('Family');
        await Promise.resolve();
      });
      expect(createProfile.mock.calls).toStrictEqual([['Family']]);
      await waitFor(() => {
        expect(alert).toHaveBeenCalledWith(
          'Update Your Other Devices',
          'Another of your devices runs a version of Unwired Mail that can’t keep Profiles apart. Update it, then create the Profile again.',
          [{ text: 'OK' }],
        );
      });
    } finally {
      jest.restoreAllMocks();
    }
  });
});

describe('composer recovery after relaunch', () => {
  /* oxlint-disable vitest/max-expects -- One relaunch offers, restores and discards records in turn. */
  it('offers each unsaved message the previous run left, one alert at a time', async () => {
    expect.hasAssertions();
    const connection = {
      id: syntheticMailboxes['alex@example.invalid'],
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
            mailboxes: JSON.stringify([connection]),
          },
          busy: false,
          failed: false,
        }) as const,
    };
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    // The previous run stored three Drafts and kept unsaved edits to each when it ended.
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
        previous.journal({ ...draft, subject: `${subject}, unsaved` }, draft),
      ).resolves.toBe(true);
      return id;
    };
    const restored = await stored('Restored plan');
    // The Draft was saved again after the version its unsaved edits started from.
    const saved = draftOf(previous.getSnapshot(), restored);
    ok(saved !== undefined);
    await previous.update({ ...saved, subject: 'Changed plan' }, saved);
    await expect(previous.save()).resolves.toBe(true);
    const discarded = await stored('Discarded plan');
    const edited = await stored('Edited plan');
    const drafts = createDrafts(storage.native, registration);
    jest.replaceProperty(
      jest.requireMock<{ drafts: typeof drafts }>('../src/registration.ts'),
      'drafts',
      drafts,
    );
    const alert = jest.spyOn(Alert, 'alert').mockReturnValue(undefined);
    const asked = () =>
      alert.mock.calls.map(([title, message, buttons]) => ({
        title,
        message,
        buttons: buttons?.map(({ text, style, isPreferred }) => ({
          text,
          style,
          isPreferred,
        })),
      }));
    const recover = {
      title: 'Recover unsaved message?',
      message: 'Your unsaved changes were kept on this device.',
      buttons: [
        { text: 'Restore', style: undefined, isPreferred: true },
        { text: 'Discard', style: 'destructive', isPreferred: undefined },
      ],
    };
    const answer = (text: string) =>
      act(async () => {
        alert.mock.lastCall?.[2]
          ?.find((button) => button.text === text)
          ?.onPress?.();
        await Promise.resolve();
      });
    const subjects = () => {
      const state = drafts.getSnapshot();
      ok(state.kind === 'ready');
      return state.drafts.map(({ id, subject }) => [id, subject]);
    };
    try {
      showMail(defaultProfile);
      route.setParams({});
      await render(
        <AccountContext
          value={{
            mailboxes: [connection],
            openAccount: () => undefined,
            authorizeMailbox: () => Promise.resolve(),
            refreshInbox: (load) => load(),
            account: 'synthetic-product-account',
            profiles: [],
            createProfile: () => Promise.resolve(undefined),
            chooseFolders: () => Promise.resolve(true),
          }}>
          <RootLayout />
        </AccountContext>,
      );
      await waitFor(() => {
        expect(asked()).toStrictEqual([recover]);
      });
      // The router commits the composer's route after the render that restores the record.
      const { replace } = route.router;
      jest.spyOn(route.router, 'replace').mockImplementationOnce((target) => {
        setTimeout(() => {
          replace(target);
        }, 0);
      });
      await answer('Restore');
      await expect(screen.findByLabelText('Subject')).resolves.toHaveProp(
        'value',
        'Restored plan, unsaved',
      );
      // The other records wait while the restored composer is open. An editor journals the third
      // Draft meanwhile, so its record is not offered in this run.
      const elsewhere = draftOf(drafts.getSnapshot(), edited);
      ok(elsewhere !== undefined);
      ok(await drafts.journal({ ...elsewhere, subject: 'Edited elsewhere' }));
      expect(asked()).toStrictEqual([recover]);
      // Close asks to save the restored edits, and Save Draft keeps them as a conflicting copy.
      await fireEvent.press(screen.getByRole('button', { name: 'Close' }));
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Save Draft' }),
      );
      await waitFor(() => {
        expect(alert).toHaveBeenCalledTimes(2);
      });
      expect(asked()).toStrictEqual([recover, recover]);
      expect(screen.queryByLabelText('Subject')).toBeNull();
      await answer('Discard');
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
      expect(alert).toHaveBeenCalledTimes(2);
    } finally {
      await cleanup();
      jest.restoreAllMocks();
    }
  });
  /* oxlint-enable vitest/max-expects */

  it('leaves a record unanswered while New Message is pending, and offers it once that composer closes', async () => {
    expect.hasAssertions();
    const connection = {
      id: syntheticMailboxes['alex@example.invalid'],
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
            mailboxes: JSON.stringify([connection]),
          },
          busy: false,
          failed: false,
        }) as const,
    };
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    // The previous run stored a Draft and kept unsaved edits to it when it ended.
    const previous = createDrafts(storage.native, registration);
    await previous.load();
    const id = await previous.create(connection);
    const created = draftOf(previous.getSnapshot(), id);
    ok(created !== undefined);
    const draft = { ...created, subject: 'Plan' };
    await previous.update(draft, created);
    await expect(previous.save()).resolves.toBe(true);
    await expect(
      previous.journal({ ...draft, subject: 'Plan, unsaved' }, draft),
    ).resolves.toBe(true);
    const drafts = createDrafts(storage.native, registration);
    jest.replaceProperty(
      jest.requireMock<{ drafts: typeof drafts }>('../src/registration.ts'),
      'drafts',
      drafts,
    );
    // The records are read only after New Message starts, and its Draft waits for storage.
    const { recovered, create } = drafts;
    let read: () => void = () => undefined;
    jest.spyOn(drafts, 'recovered').mockImplementationOnce(
      async () =>
        // oxlint-disable-next-line promise/avoid-new -- The test releases the read.
        new Promise((resolve) => {
          read = () => {
            resolve(recovered());
          };
        }),
    );
    let stored: () => void = () => undefined;
    jest.spyOn(drafts, 'create').mockImplementationOnce(
      async (...request) =>
        // oxlint-disable-next-line promise/avoid-new -- The test releases the creation.
        new Promise((resolve) => {
          stored = () => {
            resolve(create(...request));
          };
        }),
    );
    const alert = jest.spyOn(Alert, 'alert').mockReturnValue(undefined);
    try {
      showMail(defaultProfile);
      route.setParams({});
      await render(
        <AccountContext
          value={{
            mailboxes: [connection],
            openAccount: () => undefined,
            authorizeMailbox: () => Promise.resolve(),
            refreshInbox: (load) => load(),
            account: 'synthetic-product-account',
            profiles: [],
            createProfile: () => Promise.resolve(undefined),
            chooseFolders: () => Promise.resolve(true),
          }}>
          <RootLayout />
        </AccountContext>,
      );
      await waitFor(() => {
        expect(inboxNewMessage()).toBeEnabled();
      });
      // New Message's Draft is stored while the records are read, and the router commits its
      // composer's route only after the read.
      const { replace } = route.router;
      let commit: () => void = () => undefined;
      const routed = jest
        .spyOn(route.router, 'replace')
        .mockImplementationOnce((target) => {
          commit = () => {
            replace(target);
          };
        });
      await fireEvent.press(inboxNewMessage());
      await act(async () => {
        stored();
        await Promise.resolve();
      });
      await waitFor(() => {
        expect(routed).toHaveBeenCalledWith(
          expect.objectContaining({ pathname: '/compose/[draft]' }),
        );
      });
      await act(async () => {
        read();
        await drafts.recovered();
      });
      expect(alert).not.toHaveBeenCalled();
      // The record waits while that composer is open.
      await act(async () => {
        commit();
        await Promise.resolve();
      });
      await expect(screen.findByLabelText('Subject')).resolves.toHaveProp(
        'value',
        '',
      );
      expect(alert).not.toHaveBeenCalled();
      await fireEvent.press(screen.getByRole('button', { name: 'Close' }));
      await waitFor(() => {
        expect(alert).toHaveBeenCalledWith(
          'Recover unsaved message?',
          'Your unsaved changes were kept on this device.',
          expect.any(Array),
        );
      });
      expect(screen.queryByLabelText('Subject')).toBeNull();
      await act(async () => {
        alert.mock.lastCall?.[2]
          ?.find((button) => button.text === 'Restore')
          ?.onPress?.();
        await Promise.resolve();
      });
      await expect(screen.findByLabelText('Subject')).resolves.toHaveProp(
        'value',
        'Plan, unsaved',
      );
    } finally {
      await cleanup();
      jest.restoreAllMocks();
    }
  });
});
