import type {
  createElement as ReactCreateElement,
  ReactNode,
  Ref,
  useImperativeHandle as ReactUseImperativeHandle,
  useSyncExternalStore as ReactUseSyncExternalStore,
} from 'react';
import type { View as NativeView } from 'react-native';

import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { defaultProfile } from '@private-email/mail-core/registration';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import {
  act,
  fireEvent,
  render,
  screen,
  within,
} from '@testing-library/react-native';

import type MessageRoute from '../app/message/[id].tsx';
import type { MailboxList } from '../src/private-storage.ts';

import RootLayout from '../app/_layout.tsx';

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
  const { useImperativeHandle } = jest.requireActual<{
    useImperativeHandle: typeof ReactUseImperativeHandle;
  }>('react');
  // The columns the shell asked the split view to show, in order.
  const shown: string[] = [];
  function SplitView({
    children,
    ref,
  }: {
    readonly children: ReactNode;
    readonly ref: Ref<Readonly<{ show: (column: string) => void }>>;
  }) {
    useImperativeHandle(ref, () => ({
      show: (column) => {
        shown.push(column);
      },
    }));
    return createElement(View, null, children, createElement(Secondary));
  }
  SplitView.Column = View;
  return { SplitView, shown };
});
// oxlint-disable-next-line vitest/prefer-import-in-mock -- The palette sheet clears the status bar itself; the host has no inset here.
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, left: 0, right: 0, bottom: 0 }),
}));
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
const split = jest.requireMock<{ shown: string[] }>(
  'expo-router/unstable-split-view',
);

function showMail(profile: string) {
  const gmail = createSyntheticGmail();
  gmail.deliver({
    subject: 'Garden plan',
    content: { text: 'Synthetic garden body.' },
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
