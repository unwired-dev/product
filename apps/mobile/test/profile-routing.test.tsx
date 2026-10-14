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
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-session';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from '@testing-library/react-native';
import { Keyboard } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import type ComposeRoute from '../app/compose/[draft].tsx';
import type MessageRoute from '../app/message/[id].tsx';
import type { MailboxList } from '../src/private-storage.ts';

import RootLayout from '../app/_layout.tsx';
import { AccountContext } from '../src/registration-gate.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Replace only the singleton with a real store over synthetic native storage.
jest.mock('../src/registration.ts', () => ({
  ...jest.requireActual('../src/registration.ts'),
  drafts: undefined,
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
// The column the native split host was last asked to show, which a collapsed host displays.
const mockShowColumn = jest.fn<undefined, [column: 'primary' | 'secondary']>();
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
  function SplitView({
    children,
    testID,
    ref,
  }: {
    readonly children: ReactNode;
    readonly testID?: string;
    readonly ref?: Ref<{ show: typeof mockShowColumn }>;
  }) {
    jest
      .requireActual<{ useImperativeHandle: typeof ReactUseImperativeHandle }>(
        'react',
      )
      .useImperativeHandle(ref, () => ({ show: mockShowColumn }));
    const { draft } = jest
      .requireMock<{ useGlobalSearchParams: () => { draft?: string } }>(
        'expo-router',
      )
      .useGlobalSearchParams();
    return createElement(
      View,
      { testID },
      children,
      createElement(draft === undefined ? Secondary : Compose),
    );
  }
  SplitView.Column = View;
  return { SplitView };
});
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Router state stands in for native URL delivery; views and stores are real.
jest.mock('expo-router', () => {
  const { useSyncExternalStore } = jest.requireActual<{
    useSyncExternalStore: typeof ReactUseSyncExternalStore;
  }>('react');
  let params: Readonly<Record<string, unknown>> = {};
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
    setParams,
    useGlobalSearchParams: useParams,
    useLocalSearchParams: useParams,
    router: {
      setParams: (next: typeof params) => setParams({ ...params, ...next }),
      replace: ({ params: next }: { readonly params?: typeof params }) =>
        setParams(next ?? {}),
    },
  };
});
// oxlint-disable-next-line vitest/prefer-import-in-mock -- The native safe-area wrapper supplies no routing behavior.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual<{ View: typeof NativeView }>('react-native')
    .View,
}));

const route = jest.requireMock<{
  setParams: (params: Readonly<Record<string, unknown>>) => void;
}>('expo-router');

function showMail(profile: string) {
  const gmail = createSyntheticGmail();
  gmail.deliver({
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
}

describe('profile-scoped mobile routes', () => {
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
          }}>
          <RootLayout />
        </AccountContext>
      </SafeAreaProvider>
    );
    // Delivers a native keyboard notification to every subscriber of that event.
    const addKeyboardListener = jest.spyOn(Keyboard, 'addListener');
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
      for (const [, listener] of addKeyboardListener.mock.calls.filter(
        ([subscribed]) => subscribed === type,
      )) {
        listener(event);
      }
    };
    const app = await render(view());
    try {
      await fireEvent.press(
        await screen.findByRole('button', { name: /Garden plan/u }),
      );
      await waitFor(() => {
        expect(
          screen.getByRole('button', { name: 'New Message' }),
        ).toBeEnabled();
      });
      await fireEvent.press(
        await screen.findByRole('button', { name: 'New Message' }),
      );
      await fireEvent(
        screen.getByTestId('mail-shell', { includeHiddenElements: true }),
        'layout',
        { nativeEvent: { layout: { x: 0, y: 0, width: 834, height: 1194 } } },
      );
      const overlay = () =>
        screen.getByTestId('composer-overlay', { includeHiddenElements: true });
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
      addKeyboardListener.mockRestore();
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
    { draft: 'with content', body: 'Keep this draft.' },
    // Leaving removes the empty Draft, which unmounts its editor before it finishes closing.
    { draft: 'untouched', body: '' },
  ])(
    'leaves an iPad composer overlay $draft for the Inbox from the Command Palette',
    async ({ body }) => {
      expect.hasAssertions();
      mockShowColumn.mockClear();
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
          expect(
            screen.getByRole('button', { name: 'New Message' }),
          ).toBeEnabled();
        });
        await fireEvent.press(
          screen.getByRole('button', { name: 'New Message' }),
        );
        await fireEvent.changeText(
          await screen.findByLabelText('Message body'),
          body,
        );
        await fireEvent(
          screen.getByRole('header', { name: 'Inbox' }),
          'accessibilityAction',
          { nativeEvent: { actionName: 'openCommandPalette' } },
        );
        await act(async () => {
          await fireEvent.press(
            within(screen.getByTestId('command-palette')).getByRole('button', {
              name: 'Inbox',
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
        expect(mockShowColumn).toHaveBeenLastCalledWith('primary');
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

  it.each([
    { name: 'legacy Default', profile: defaultProfile, params: {} },
    { name: 'Work', profile: 'work', params: { profileId: 'work' } },
  ])(
    'retains $name ownership through selection and reader close',
    async ({ profile, params }) => {
      expect.hasAssertions();
      showMail(profile);
      route.setParams(params);
      await render(<RootLayout />);
      await fireEvent.press(
        await screen.findByRole('button', { name: /Garden plan/u }),
      );
      await expect(
        screen.findByText('Synthetic garden body.'),
      ).resolves.toBeVisible();
      await fireEvent.press(screen.getByRole('button', { name: 'Archive' }));
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

  it('clears the previous Profile’s search when the same window targets another Profile', async () => {
    expect.hasAssertions();
    showMail(defaultProfile);
    route.setParams({});
    await render(<RootLayout />);
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
    await expect(
      screen.findByRole('button', { name: /Garden plan/u }),
    ).resolves.toBeVisible();
  });
});
