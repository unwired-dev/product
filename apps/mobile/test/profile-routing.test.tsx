import { ok } from 'node:assert/strict';

import type { router as ExpoRouter } from 'expo-router';
import type {
  createElement as ReactCreateElement,
  ReactNode,
  Ref,
  useImperativeHandle as ReactUseImperativeHandle,
  useSyncExternalStore as ReactUseSyncExternalStore,
} from 'react';
import type { KeyboardEvent, View as NativeView } from 'react-native';
import type { useWindowDimensions } from 'react-native';

import { createDrafts } from '@private-email/mail-core/drafts';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { defaultProfile } from '@private-email/mail-core/registration';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-vault';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from '@testing-library/react-native';
import { DeviceEventEmitter, StyleSheet } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import type ComposeRoute from '../app/compose/[draft].tsx';
import type MessageRoute from '../app/message/[id].tsx';
import type ThreadRoute from '../app/thread/[id].tsx';
import type { MailboxList } from '../src/private-storage.ts';

import RootLayout from '../app/_layout.tsx';
import { AccountContext } from '../src/registration-gate.tsx';

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
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Substitute the native split host; mount its actual secondary route.
jest.mock('expo-router/unstable-split-view', () => {
  const { createElement } = jest.requireActual<{
    createElement: typeof ReactCreateElement;
  }>('react');
  const { View } = jest.requireActual<{ View: typeof NativeView }>(
    'react-native',
  );
  const Secondary = jest.requireActual<{ default: typeof MessageRoute }>(
    '../app/message/[id].tsx',
  ).default;
  const Compose = jest.requireActual<{ default: typeof ComposeRoute }>(
    '../app/compose/[draft].tsx',
  ).default;
  const Thread = jest.requireActual<{ default: typeof ThreadRoute }>(
    '../app/thread/[id].tsx',
  ).default;
  const { usePathname, useGlobalSearchParams } = jest.requireMock<{
    usePathname: () => string;
    useGlobalSearchParams: () => { draft?: string };
  }>('expo-router');
  const { useImperativeHandle } = jest.requireActual<{
    useImperativeHandle: typeof ReactUseImperativeHandle;
  }>('react');
  // The columns the shell asked the split view to show, in order.
  const shown: string[] = [];
  let renders = 0;
  function SplitView({
    children,
    testID,
    ref,
  }: {
    readonly children: ReactNode;
    readonly testID?: string;
    readonly ref: Ref<Readonly<{ show: (column: string) => void }>>;
  }) {
    renders += 1;
    useImperativeHandle(ref, () => ({
      show: (column) => {
        shown.push(column);
      },
    }));
    const pathname = usePathname();
    const { draft } = useGlobalSearchParams();
    let detail = pathname === '/thread/[id]' ? Thread : Secondary;
    if (draft !== undefined) {
      detail = Compose;
    }
    return createElement(View, { testID }, children, createElement(detail));
  }
  SplitView.Column = View;
  return { SplitView, shown, renderCount: () => renders };
});
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Router state stands in for native URL delivery; views and stores are real.
jest.mock('expo-router', () => {
  const { useSyncExternalStore } = jest.requireActual<{
    useSyncExternalStore: typeof ReactUseSyncExternalStore;
  }>('react');
  let params: Readonly<Record<string, unknown>> = {};
  let pathname = '/';
  let previous: typeof params | undefined = undefined;
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
  return {
    params: getSnapshot,
    setParams: (next: typeof params) => {
      pathname = '/';
      previous = undefined;
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
      push: ({ params: next }: { readonly params: typeof params }) => {
        previous = params;
        pathname = '/thread/[id]';
        setParams(next);
      },
      canGoBack: () => previous !== undefined,
      back: () => {
        if (previous !== undefined) {
          pathname = '/message/[id]';
          const restored = previous;
          previous = undefined;
          setParams(restored);
        }
      },
    },
  };
});
// oxlint-disable-next-line vitest/prefer-import-in-mock -- The native safe-area wrapper supplies no routing behavior.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual<{ View: typeof NativeView }>('react-native')
    .View,
}));

const route = jest.requireMock<{
  params: () => Readonly<Record<string, unknown>>;
  setParams: (params: Readonly<Record<string, unknown>>) => void;
  router: typeof ExpoRouter;
}>('expo-router');
const split = jest.requireMock<{ shown: string[]; renderCount: () => number }>(
  'expo-router/unstable-split-view',
);

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
  const original = singleMailbox(createGmailInbox(gmail.native), 'garden');
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

const threadBackActions = [
  {
    name: 'button',
    back: () =>
      fireEvent.press(screen.getByRole('button', { name: 'Back, 2 unread' })),
  },
  {
    name: 'edge swipe',
    back: () => fireEvent(screen.getByTestId('thread-back-navigation'), 'back'),
  },
];

describe('profile-scoped mobile routes', () => {
  it('retains the routed reader view when archiving its row from the Inbox', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const travel = gmail.createLabel('Travel');
    const id = gmail.deliver({ subject: 'Flight to Zagreb' });
    gmail.setLabel(id, travel, true);
    const inbox = createGmailInbox(gmail.native);
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
    let inboxRevealRequest: Readonly<{ account: string }> | undefined;
    const view = () => (
      <SafeAreaProvider
        initialMetrics={{
          frame: { x: 0, y: 0, width: 393, height: 852 },
          insets,
        }}>
        <AccountContext
          value={{
            mailboxes: [connection],
            inboxRevealRequest,
            openAccount: () => undefined,
            authorizeMailbox: () => Promise.resolve(),
            refreshInbox: (load) => load(),
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
      // UIKit changes the reader width while the 340pt list keeps its local bounds.
      await fireEvent(readerPane, 'layout', {
        nativeEvent: { layout: { x: 0, y: 0, width: 258, height: 1194 } },
      });
      expect(overlay()).toHaveStyle({ left: 588 });
      await fireEvent(readerPane, 'layout', {
        nativeEvent: { layout: { x: 0, y: 0, width: 494, height: 1194 } },
      });
      expect(overlay()).toHaveStyle({ left: 352 });
      // A regular split view can hide both leading columns without collapsing.
      await fireEvent(readerPane, 'layout', {
        nativeEvent: { layout: { x: 0, y: 0, width: 834, height: 1194 } },
      });
      expect(overlay()).toHaveStyle({ left: 12 });
      expect(overlay()).toHaveStyle({ bottom: 12, height: 720 });
      // A docked software keyboard leaves the overlay the height above it.
      await act(() => {
        keyboard('keyboardWillChangeFrame', 794, 400);
      });
      expect(overlay()).toHaveStyle({ bottom: 412, height: 794 * 0.7 });
      // A tall keyboard leaves less than the minimum; the overlay stays below the status bar.
      await act(() => {
        keyboard('keyboardWillChangeFrame', 450, 744);
      });
      expect(overlay()).toHaveStyle({
        bottom: 756,
        height: 450 - insets.top - 24,
      });
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
      expect(overlay()).toHaveStyle({ bottom: 12, height: 720 });
      // A conflict copy rebinds the open composer in place; its keyboard stays raised.
      await act(() => {
        keyboard('keyboardWillChangeFrame', 794, 400);
      });
      await act(() => {
        route.router.setParams({ draft: `${open}-copy` });
      });
      expect(overlay()).toHaveStyle({ bottom: 412 });
      await act(() => {
        route.router.setParams({ draft: open });
      });
      await act(() => {
        keyboard('keyboardWillHide', 1194, 0);
      });
      expect(overlay()).toHaveStyle({ bottom: 12, height: 720 });
      await fireEvent.changeText(
        await screen.findByLabelText('Message body'),
        'Keep this draft.',
      );
      await fireEvent.changeText(screen.getByLabelText('To'), 'unfinished');
      await fireEvent.press(screen.getByRole('button', { name: 'Expand' }));
      expect(screen.queryByLabelText('Search senders and subjects')).toBeNull();
      const retainedRoute = route.params();
      split.shown.length = 0;
      inboxRevealRequest = { account: 'synthetic-product-account' };
      await app.rerender(view());
      expect({ route: route.params(), columns: split.shown }).toStrictEqual({
        route: retainedRoute,
        columns: ['secondary'],
      });
      expect(screen.getByLabelText('To')).toHaveProp('value', 'unfinished');
      expect(screen.getByLabelText('Message body')).toHaveTextContent(
        'Keep this draft.',
      );
      expect(screen.queryByRole('button', { name: 'Expand' })).toBeNull();
      await fireEvent.press(screen.getByRole('button', { name: 'Collapse' }));
      await fireEvent.press(screen.getByRole('button', { name: 'Text style' }));
      // A landscape phone can be wide while UIKit still collapses its split view.
      await fireEvent(
        screen.getByTestId('mail-split', { includeHiddenElements: true }),
        'collapse',
      );
      expect(screen.queryByRole('button', { name: 'Expand' })).toBeNull();
      // The keyed format bar moves without retiring its open menu.
      expect(screen.getByRole('button', { name: 'Heading 1' })).toBeVisible();
      await fireEvent.press(screen.getByRole('button', { name: 'Text style' }));
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
      await fireEvent.press(screen.getByRole('button', { name: 'Close' }));
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
      // Outside the split view's screens, the compact composer clears the status bar itself.
      expect(
        screen.getByTestId('composer-overlay', { includeHiddenElements: true }),
      ).toHaveStyle({ paddingTop: insets.top, paddingBottom: insets.bottom });
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

  it.each([
    { draft: 'with content', body: 'Keep this draft.', command: 'Inbox' },
    // Leaving removes the empty Draft, which unmounts its editor before it finishes closing.
    { draft: 'untouched', body: '', command: 'Inbox' },
    {
      draft: 'expanded via Search Mail',
      body: 'Keep this draft.',
      command: 'Search Mail',
    },
  ])(
    'leaves an expanded iPad composer $draft for the Inbox from the Command Palette',
    async ({ body, command }) => {
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

  it.each(threadBackActions)(
    'returns a cold-opened Thread to its Work Profile Inbox via $name when Back has no history',
    async ({ back }) => {
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
      split.shown.length = 0;
      await back();
      expect(split.shown).toStrictEqual(['supplementary']);
      expect(screen.queryByText('Synthetic garden body.')).toBeNull();
      expect(
        screen.getByLabelText('Search senders and subjects'),
      ).toBeVisible();
      expect(
        screen.getByRole('button', { name: /Garden plan/u }),
      ).toBeVisible();
    },
  );

  it.each(threadBackActions)(
    'returns a pushed Thread to the previous reader via $name instead of replacing it with the Inbox',
    async ({ back }) => {
      expect.hasAssertions();
      const id = showMail('work');
      route.setParams({ profileId: 'work', mailbox: 'garden', id });
      await render(<RootLayout />);
      await expect(
        screen.findByRole('button', { name: 'Archive' }),
      ).resolves.toBeVisible();
      await act(() => {
        route.router.push({
          pathname: '/thread/[id]',
          params: { profileId: 'work', mailbox: 'garden', id },
        });
      });
      expect(screen.queryByRole('button', { name: 'Archive' })).toBeNull();
      await back();
      await expect(
        screen.findByRole('button', { name: 'Archive' }),
      ).resolves.toBeVisible();
      await expect(
        screen.findByText('Synthetic garden body.'),
      ).resolves.toBeVisible();
    },
  );

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
    { name: 'list', reader: false, column: 'supplementary' },
    { name: 'reader', reader: true, column: 'secondary' },
  ])(
    'reveals the retained Work $name for each Open Inbox request',
    async ({ reader, column }) => {
      expect.hasAssertions();
      const id = showMail('work');
      const params = reader
        ? { profileId: 'work', mailbox: 'garden', id }
        : { profileId: 'work' };
      route.setParams(params);
      const content = <RootLayout />;
      const view = (inboxRevealRequest?: Readonly<{ account: string }>) => (
        <AccountContext
          value={{
            mailboxes: [],
            inboxRevealRequest,
            openAccount: () => undefined,
            authorizeMailbox: () => Promise.resolve(),
            refreshInbox: (load) => load(),
          }}>
          {content}
        </AccountContext>
      );
      const app = await render(view());
      if (reader) {
        await screen.findByText('Synthetic garden body.');
      } else {
        await screen.findByRole('button', { name: /Garden plan/u });
        await fireEvent(screen.getByTestId('inbox-back-navigation'), 'back');
      }
      split.shown.length = 0;
      // The installed SplitView recreates its reader Slot type on every render.
      const renders = split.renderCount();
      const request = { account: 'synthetic-product-account' };
      await app.rerender(view(request));
      const first = [...split.shown];
      await app.rerender(view(request));
      const repeated = [...split.shown];
      await app.rerender(view({ ...request }));
      expect({
        first,
        repeated,
        latest: split.shown,
        params: route.params(),
        renders: split.renderCount(),
      }).toStrictEqual({
        first: [column],
        repeated: [column],
        latest: [column, column],
        params,
        renders,
      });
      expect(
        reader
          ? screen.getByText('Synthetic garden body.')
          : screen.getByRole('button', { name: /Garden plan/u }),
      ).toBeVisible();
    },
  );

  it('returns a Work reader to its Inbox by edge swipe, then its list to Mailboxes', async () => {
    expect.hasAssertions();
    const dimensions = jest
      .spyOn(
        jest.requireActual<{ useWindowDimensions: typeof useWindowDimensions }>(
          'react-native',
        ),
        'useWindowDimensions',
      )
      .mockReturnValue({ width: 390, height: 844, scale: 3, fontScale: 1 });
    try {
      const id = showMail('work');
      route.setParams({ profileId: 'work', mailbox: 'garden', id });
      await render(<RootLayout />);
      await screen.findByText('Synthetic garden body.');
      split.shown.length = 0;
      await fireEvent(screen.getByTestId('message-back-navigation'), 'back');
      expect(route.params()).toStrictEqual({ profileId: 'work' });
      expect(split.shown).toStrictEqual(['supplementary']);
      expect(screen.queryByText('Synthetic garden body.')).toBeNull();
      await fireEvent(screen.getByTestId('inbox-back-navigation'), 'back');
      expect(split.shown).toStrictEqual(['supplementary', 'primary']);
    } finally {
      dimensions.mockRestore();
    }
  });

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
    ).resolves.toHaveProp('value', '');
    expect(screen.getByRole('button', { name: 'All inboxes' })).toBeSelected();
    await expect(
      screen.findByRole('button', { name: /Garden plan/u }),
    ).resolves.toBeVisible();
    showMail(defaultProfile);
    await act(() => {
      route.setParams({});
    });
    await expect(
      screen.findByLabelText('Search senders and subjects'),
    ).resolves.toHaveProp('value', '');
    expect(screen.getByRole('button', { name: 'All inboxes' })).toBeSelected();
  });
});
