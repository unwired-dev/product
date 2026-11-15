import type { NativeInboxPreferences } from '@private-email/mail-core/inbox-preferences';
import type { ReactNode } from 'react';

import { fixtureMessages } from '@private-email/mail-core';
import { createInboxPreferences } from '@private-email/mail-core/inbox-preferences';
import { fireEvent, render } from '@testing-library/react-native';
import { Settings, StyleSheet } from 'react-native';

import { MessageRow } from '../src/inbox-rows.tsx';
import { ProfileScope } from '../src/mailbox.tsx';
import {
  InboxPreferencesContext,
  PreviewLinesSettings,
} from '../src/preview-lines.tsx';
import { chooseMenuItem, menuItems } from './native-menu.ts';

const [message] = fixtureMessages;

// Inbox preferences kept in memory for one signed-in Product Account, without Private Sync.
const preferences = () => {
  const kept: { revision: number; document: string | null } = {
    revision: 0,
    document: null,
  };
  const native: NativeInboxPreferences = {
    openInboxPreferences: () =>
      Promise.resolve({ owner: 'account-1', ...kept }),
    commitInboxPreferences: (owner, revision, document) => {
      Object.assign(kept, { revision: revision + 1, document });
      return Promise.resolve({ owner, revision: kept.revision });
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

describe('settings › Appearance › Message list', () => {
  it("sets every Profile's preview lines, which their rows show", async () => {
    expect.hasAssertions();
    const store = preferences();
    const row = (profile: string) => (
      <ProfileScope profile={profile}>
        <MessageRow
          message={message!}
          mailbox={undefined}
          status={undefined}
          selected={false}
          onSelect={jest.fn<() => void>()}
          now={Date.parse(message!.receivedAt)}
        />
      </ProfileScope>
    );
    const wrapper = ({ children }: { readonly children: ReactNode }) => (
      <InboxPreferencesContext value={store}>
        {children}
      </InboxPreferencesContext>
    );
    const app = await render(
      <>
        <PreviewLinesSettings profiles={['default', 'work']} />
        {row('work')}
        {row('home')}
      </>,
      { wrapper },
    );
    const previews = () =>
      app
        .queryAllByText(message!.preview)
        .map((preview) => preview.props.numberOfLines);
    const initial = previews();
    const footer = app.queryByText(
      'Row height follows the macOS sidebar icon size.',
    );
    await fireEvent.press(app.getByRole('button', { name: 'Preview lines' }));
    const offered = menuItems().map(({ title, checked }) => ({
      title,
      checked,
    }));
    await chooseMenuItem('3 lines');
    const chosen = previews();
    await fireEvent.press(app.getByRole('button', { name: 'Preview lines' }));
    await chooseMenuItem('None');
    expect({
      initial,
      footer: footer !== null,
      offered,
      chosen,
      none: previews(),
      stored: ['default', 'work', 'home'].map(store.previewLines),
    }).toStrictEqual({
      initial: [1, 1],
      footer: true,
      offered: [
        { title: 'None', checked: false },
        { title: '1 line', checked: true },
        { title: '2 lines', checked: false },
        { title: '3 lines', checked: false },
      ],
      // Home, which has no choice of its own, follows the default Profile's.
      chosen: [3, 3],
      none: [],
      stored: [0, 0, undefined],
    });
  });

  it.each([
    [1, 4, 5],
    [2, 6, 7],
    [3, 8, 9],
  ])(
    'gives rows at sidebar icon size %i %ipt above and %ipt below',
    async (size, top, bottom) => {
      expect.hasAssertions();
      Settings.set({ NSTableViewDefaultSizeMode: size });
      const app = await render(
        <MessageRow
          message={message!}
          mailbox={undefined}
          status={undefined}
          selected={false}
          onSelect={jest.fn<() => void>()}
          now={Date.parse(message!.receivedAt)}
        />,
      );
      const { paddingTop, paddingBottom } = StyleSheet.flatten(
        app.getByRole('button').props.style,
      );
      expect({ paddingTop, paddingBottom }).toStrictEqual({
        paddingTop: top,
        paddingBottom: bottom,
      });
    },
  );
});
