import type {
  MarkRead,
  NativeInboxPreferences,
} from '@private-email/mail-core/inbox-preferences';

import { createInboxPreferences } from '@private-email/mail-core/inbox-preferences';
import { createInboxStore } from '@private-email/mail-core/inbox-store';
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
import { AppState, View } from 'react-native';

import { InboxProvider } from '../src/mailbox.tsx';
import {
  MarkReadSettings,
  ReadingPreferencesContext,
} from '../src/mark-read.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
import { chooseMenuItem, menuItems } from './native-menu.ts';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// Inbox preferences kept in memory for one signed-in Product Account, without Private Sync.
const preferences = () => {
  const kept = { revision: 0, document: null as string | null };
  const native: NativeInboxPreferences = {
    openInboxPreferences: async () => ({ owner: 'account-1', ...kept }),
    commitInboxPreferences: async (owner, revision, document) => {
      Object.assign(kept, { revision: revision + 1, document });
      return { owner, revision: kept.revision };
    },
  };
  return createInboxPreferences(native, {
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
  });
};

describe('settings › Reading › Mark as Read on the Mac', () => {
  it("chooses each Profile's Mark as Read from its pop-up, Immediately by default", async () => {
    expect.hasAssertions();
    const store = preferences();
    await render(
      <ReadingPreferencesContext value={store}>
        <MarkReadSettings profiles={[{ id: 'work', name: 'Work' }]} />
      </ReadingPreferencesContext>,
    );
    await act(store.load);
    await fireEvent.press(
      screen.getByRole('button', { name: 'Mark as Read for Work' }),
    );
    const offered = menuItems().map(({ title, subtitle, checked }) => ({
      title,
      subtitle,
      checked,
    }));
    await chooseMenuItem('After 2 seconds');
    expect({
      offered,
      stored: [store.markRead(defaultProfile), store.markRead('work')],
    }).toStrictEqual({
      offered: [
        {
          title: 'Immediately',
          subtitle: 'As soon as you open a message',
          checked: true,
        },
        {
          title: 'After 2 seconds',
          subtitle: 'If a message stays open for 2 seconds',
          checked: false,
        },
        {
          title: 'Manually',
          subtitle: 'Mail stays unread until you mark it read',
          checked: false,
        },
      ],
      stored: ['immediately', 'afterTwoSeconds'],
    });
  });

  it('marks an opened message read only as its Profile chose', async () => {
    expect.hasAssertions();
    const initial = AppState.currentState;
    // The Mac is using Unwired.
    AppState.currentState = 'active';
    jest.useFakeTimers({
      doNotFake: ['nextTick', 'setImmediate', 'queueMicrotask'],
    });
    const wait = async (milliseconds: number) => {
      await act(async () => {
        await jest.advanceTimersByTimeAsync(milliseconds);
      });
    };
    // Whether the reader of an unread message, opened with `choice`, marked it read after `open`
    // milliseconds.
    const readAfter = async (choice: MarkRead, open: number) => {
      const store = preferences();
      await store.setMarkRead(defaultProfile, choice);
      const gmail = createSyntheticGmail();
      const id = gmail.deliver({ subject: 'Report' });
      const inbox = createInboxStore(gmail.native);
      await inbox.load();
      const app = await render(
        <ReadingPreferencesContext value={store}>
          <InboxProvider mailboxes={singleMailbox(inbox, 'mailbox')}>
            <MessageDetail
              mailbox="mailbox"
              id={id}
            />
          </InboxProvider>
        </ReadingPreferencesContext>,
      );
      await wait(open);
      // The mailbox holds only this message.
      const read = gmail.modifies.some(({ remove }) =>
        remove.includes('UNREAD'),
      );
      await app.unmount();
      return read;
    };
    const outcome = {
      immediately: await readAfter('immediately', 0),
      early: await readAfter('afterTwoSeconds', 1900),
      afterTwoSeconds: await readAfter('afterTwoSeconds', 2100),
      manually: await readAfter('manually', 5000),
    };
    jest.useRealTimers();
    AppState.currentState = initial;
    expect(outcome).toStrictEqual({
      immediately: true,
      early: false,
      afterTwoSeconds: true,
      manually: false,
    });
  });

  // How many times Gmail was asked to read an unread message opened with After 2 seconds in a first
  // window, then in a second as `steps` say. Gmail answers the first change only once `release`
  // runs.
  const readsInTwoWindows = async (
    steps: (
      control: Readonly<{
        wait: (milliseconds: number) => Promise<void>;
        openSecond: () => Promise<void>;
        markUnread: () => Promise<void>;
        release: () => void;
      }>,
    ) => Promise<void>,
  ) => {
    const initial = AppState.currentState;
    AppState.currentState = 'active';
    jest.useFakeTimers({
      doNotFake: ['nextTick', 'setImmediate', 'queueMicrotask'],
    });
    const wait = async (milliseconds: number) => {
      await act(async () => {
        await jest.advanceTimersByTimeAsync(milliseconds);
      });
    };
    const store = preferences();
    await store.setMarkRead(defaultProfile, 'afterTwoSeconds');
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({ subject: 'Report' });
    let release: () => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Hold Gmail's answer until the test releases it.
    const answered = new Promise<void>((resolve) => {
      release = resolve;
    });
    const held = [answered];
    const inbox = createInboxStore({
      ...gmail.native,
      gmailModify: async (change, owner) => {
        await held.shift();
        return gmail.native.gmailModify(change, owner);
      },
    });
    await inbox.load();
    // A reader window for each test ID.
    const windows = (ids: readonly string[]) => (
      <ReadingPreferencesContext value={store}>
        <InboxProvider mailboxes={singleMailbox(inbox, 'mailbox')}>
          {ids.map((testID) => (
            <View
              key={testID}
              testID={testID}>
              <MessageDetail
                mailbox="mailbox"
                id={id}
              />
            </View>
          ))}
        </InboxProvider>
      </ReadingPreferencesContext>
    );
    const app = await render(windows(['first']));
    await steps({
      wait,
      openSecond: async () => {
        await app.rerender(windows(['first', 'second']));
      },
      markUnread: async () => {
        await fireEvent.press(
          within(app.getByTestId('first')).getByRole('button', {
            name: 'Mark as Unread',
          }),
        );
      },
      release,
    });
    release();
    await wait(100);
    const reads = gmail.modifies.filter(({ remove }) =>
      remove.includes('UNREAD'),
    ).length;
    await app.unmount();
    jest.useRealTimers();
    AppState.currentState = initial;
    return reads;
  };

  it('leaves a Mark as Unread alone when another window opened the message earlier', async () => {
    expect.hasAssertions();
    const reads = await readsInTwoWindows(
      async ({ wait, openSecond, markUnread }) => {
        await wait(1000);
        await openSecond();
        // The first window reads it at 2 seconds; while Gmail has not answered, the person marks
        // it unread before the second window's wait ends.
        await wait(1100);
        await markUnread();
        await wait(1500);
      },
    );
    expect(reads).toBe(1);
  });

  it('leaves a Mark as Unread alone when another window opened the message already read', async () => {
    expect.hasAssertions();
    const reads = await readsInTwoWindows(
      async ({ wait, openSecond, markUnread, release }) => {
        // The first window reads it at 2 seconds, which Gmail saves.
        await wait(2000);
        release();
        await wait(50);
        await openSecond();
        await markUnread();
        await wait(2500);
      },
    );
    expect(reads).toBe(1);
  });
});
