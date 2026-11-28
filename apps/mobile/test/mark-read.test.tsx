import type {
  MarkRead,
  NativeInboxPreferences,
} from '@private-email/mail-core/inbox-preferences';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type { AppStateStatus } from 'react-native';

import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { createInboxPreferences } from '@private-email/mail-core/inbox-preferences';
import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { defaultProfile } from '@private-email/mail-core/registration';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { AppState } from 'react-native';

import { InboxProvider } from '../src/mailbox.tsx';
import {
  MarkReadSettings,
  ReadingPreferencesContext,
} from '../src/mark-read.tsx';
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

// oxlint-disable-next-line vitest/prefer-import-in-mock -- The reader clears no inset here.
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, left: 0, right: 0, bottom: 0 }),
}));

// Inbox preferences kept for one signed-in Product Account, as native storage keeps them; while
// `refusing`, storage refuses each write.
const preferences = () => {
  const kept = { revision: 0, document: null as string | null };
  const storage = { refusing: false };
  const native: NativeInboxPreferences = {
    openInboxPreferences: async () => ({ owner: 'account-1', ...kept }),
    commitInboxPreferences: async (owner, expectedRevision, document) => {
      if (storage.refusing) {
        throw Object.assign(new Error('locked'), { code: 'locked' });
      }
      Object.assign(kept, { revision: expectedRevision + 1, document });
      return { owner, revision: kept.revision };
    },
  };
  const store = createInboxPreferences(native, {
    getSnapshot: () => ({
      snapshot: {
        kind: 'connected',
        productAccountId: 'account-1',
        signInProvider: 'google',
        mailboxes: '[]',
      } satisfies RegistrationSnapshot,
      busy: false,
      failed: false,
    }),
  });
  return { store, storage };
};

// The menu of the pop-up labelled `label`: each choice's title, line and check.
const menu = (label: RegExp) => {
  const sections: ReadonlyArray<{
    items: ReadonlyArray<{
      id: string;
      title: string;
      subtitle?: string;
      checked?: boolean;
    }>;
  }> = screen.getByLabelText(label).props.sections;
  return sections.flatMap((section) => section.items);
};
const choose = async (label: RegExp, title: string) => {
  const item = menu(label).find((each) => each.title === title);
  if (item === undefined) {
    throw new Error(`Expected ${title}`);
  }
  await fireEvent(screen.getByLabelText(label), 'select', {
    nativeEvent: { id: item.id },
  });
};

// A Gmail, Microsoft or IMAP mailbox holding one unread message, and whether the provider was asked
// to mark it read.
const mailbox = async (provider: 'gmail' | 'microsoft' | 'imap') => {
  if (provider === 'imap') {
    const imap = createSyntheticImap({ address: 'alex@example.invalid' });
    const uid = imap.deliver('INBOX', { subject: 'Report', body: 'Numbers.' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    return {
      inbox,
      id: `7.${uid}.INBOX`,
      read: () => imap.server.changes.includes(`read INBOX ${uid}`),
    };
  }
  if (provider === 'microsoft') {
    const graph = createSyntheticGraph();
    const id = graph.deliver({ subject: 'Report' });
    const inbox = createInboxStore(graph.native, {
      provider: 'microsoft-graph',
    });
    await inbox.load();
    return {
      inbox,
      id,
      read: () =>
        graph.modifies.some(
          (change) => change.message === id && 'read' in change && change.read,
        ),
    };
  }
  const gmail = createSyntheticGmail();
  const id = gmail.deliver({ subject: 'Report' });
  const inbox = createInboxStore(gmail.native);
  await inbox.load();
  return {
    inbox,
    id,
    read: () =>
      gmail.modifies.some(
        (change) => change.id === id && change.remove.includes('UNREAD'),
      ),
  };
};

describe('settings › Reading › Mark as Read', () => {
  it("chooses each Profile's Mark as Read from its pop-up, Immediately by default", async () => {
    expect.hasAssertions();
    const { store } = preferences();
    await render(
      <ReadingPreferencesContext value={store}>
        <MarkReadSettings profiles={[{ id: 'work', name: 'Work' }]} />
      </ReadingPreferencesContext>,
    );
    await act(store.load);
    const primary = /^Mark as Read for Primary Profile: /u;
    const offered = menu(primary).map(({ title, subtitle, checked }) => ({
      title,
      subtitle,
      checked,
    }));
    await choose(/^Mark as Read for Work: /u, 'After 2 Seconds');
    expect({
      header: screen.queryByRole('header', { name: 'Mark as Read' }) !== null,
      rows: [
        screen.getByLabelText(primary).props.accessibilityLabel,
        screen.getByLabelText(/^Mark as Read for Work: /u).props
          .accessibilityLabel,
      ],
      offered,
      footer:
        screen.queryByText(
          'Each Profile keeps its own choice on all its devices. Notifications and downloads never mark mail read.',
        ) !== null,
      stored: [store.markRead(defaultProfile), store.markRead('work')],
    }).toStrictEqual({
      header: true,
      rows: [
        'Mark as Read for Primary Profile: Immediately',
        'Mark as Read for Work: After 2 Seconds',
      ],
      offered: [
        {
          title: 'Immediately',
          subtitle: 'As soon as you open a message',
          checked: true,
        },
        {
          title: 'After 2 Seconds',
          subtitle: 'If a message stays open for 2 seconds',
          checked: false,
        },
        {
          title: 'Manually',
          subtitle: 'Mail stays unread until you mark it read',
          checked: false,
        },
      ],
      footer: true,
      stored: ['immediately', 'afterTwoSeconds'],
    });
  });

  it('says a choice was not saved on this device and saves it on Try Again', async () => {
    expect.hasAssertions();
    jest.spyOn(console, 'error').mockReturnValue(undefined);
    const { store, storage } = preferences();
    await render(
      <ReadingPreferencesContext value={store}>
        <MarkReadSettings profiles={[]} />
      </ReadingPreferencesContext>,
    );
    await act(store.load);
    storage.refusing = true;
    const label = /^Mark as Read for Primary Profile: /u;
    await choose(label, 'Manually');
    const alert = screen.queryByRole('alert', {
      name: 'Your change wasn’t saved on this device. Choose Try Again.',
    });
    const unsaved = store.markRead(defaultProfile);
    storage.refusing = false;
    await fireEvent.press(screen.getByRole('button', { name: 'Try Again' }));
    expect({
      alert: alert !== null,
      unsaved,
      saved: store.markRead(defaultProfile),
      cleared: screen.queryByRole('button', { name: 'Try Again' }),
    }).toStrictEqual({
      alert: true,
      unsaved: 'immediately',
      saved: 'manually',
      cleared: null,
    });
  });
});

describe('opening a message with each Mark as Read choice', () => {
  // The reader of `provider`'s unread message, opened with the Primary Profile's `choice`: IMAP
  // mail opens on its own, Gmail and Microsoft mail in its Thread.
  const open = async (
    provider: 'gmail' | 'microsoft' | 'imap',
    choice: MarkRead,
  ) => {
    jest.useFakeTimers({
      doNotFake: ['nextTick', 'setImmediate', 'queueMicrotask'],
    });
    const { store } = preferences();
    await store.setMarkRead(defaultProfile, choice);
    const opened = await mailbox(provider);
    const Reader = provider === 'imap' ? MessageDetail : ThreadView;
    const app = await render(
      <ReadingPreferencesContext value={store}>
        <InboxProvider mailboxes={singleMailbox(opened.inbox, 'mailbox')}>
          <Reader
            id={opened.id}
            mailbox="mailbox"
          />
        </InboxProvider>
      </ReadingPreferencesContext>,
    );
    await act(async () => {
      await Promise.resolve();
    });
    return { ...opened, app };
  };
  const wait = async (milliseconds: number) => {
    await act(async () => {
      await jest.advanceTimersByTimeAsync(milliseconds);
    });
  };

  it.each(['gmail', 'microsoft', 'imap'] as const)(
    'marks a %s message read as soon as it opens with Immediately, and never with Manually',
    async (provider) => {
      expect.hasAssertions();
      const immediately = await open(provider, 'immediately');
      await wait(0);
      const opened = immediately.read();
      await immediately.app.unmount();
      const manually = await open(provider, 'manually');
      await wait(5000);
      const notMarked = manually.read();
      jest.useRealTimers();
      expect({ immediately: opened, manually: notMarked }).toStrictEqual({
        immediately: true,
        manually: false,
      });
    },
  );

  it.each(['gmail', 'microsoft', 'imap'] as const)(
    'marks a %s message read with After 2 seconds only once it stayed open 2 seconds with the app in front',
    async (provider) => {
      expect.hasAssertions();
      const listeners: Array<(state: AppStateStatus) => void> = [];
      jest
        .spyOn(AppState, 'addEventListener')
        .mockImplementation((_type, listener) => {
          listeners.push(listener);
          return { remove: () => undefined };
        });
      const initial = AppState.currentState;
      // The person is using Unwired.
      AppState.currentState = 'active';
      // As React Native does, the state changes before listeners hear of it.
      const leave = async (state: 'active' | 'background') => {
        await act(async () => {
          AppState.currentState = state;
          for (const listener of listeners) {
            listener(state);
          }
        });
      };
      // Closed before 2 seconds: it stays unread.
      const closed = await open(provider, 'afterTwoSeconds');
      await wait(1900);
      await closed.app.unmount();
      const afterClosing = closed.read();

      const reader = await open(provider, 'afterTwoSeconds');
      await wait(1500);
      // Leaving the app stops the wait; returning starts it again.
      await leave('background');
      await wait(5000);
      const whileAway = reader.read();
      await leave('active');
      await wait(1900);
      const early = reader.read();
      await wait(100);
      const marked = reader.read();
      jest.useRealTimers();
      AppState.currentState = initial;
      expect({
        afterClosing,
        whileAway,
        early,
        marked,
      }).toStrictEqual({
        afterClosing: false,
        whileAway: false,
        early: false,
        marked: true,
      });
    },
  );
});
