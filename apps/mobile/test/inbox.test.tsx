import { makeMockInboxStorage } from '@private-email/mail-core/mock-storage';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { fireEvent, render, screen } from '@testing-library/react-native';
import { useState } from 'react';

import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { MessageDetail } from '../src/message-detail.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => {
  const { createPersistentInbox } = jest.requireActual(
    '@private-email/mail-core/persistent-inbox',
  );
  const { makeMockInboxStorage } = jest.requireActual(
    '@private-email/mail-core/mock-storage',
  );
  return { inbox: createPersistentInbox(makeMockInboxStorage()) };
});

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

function InboxJourney() {
  const [selectedId, setSelectedId] = useState<string>();
  return (
    <InboxProvider>
      <Inbox
        onSelect={setSelectedId}
        selectedId={selectedId}
      />
      <MessageDetail id={selectedId} />
    </InboxProvider>
  );
}

describe('preview Inbox', () => {
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
        <MessageDetail id="not-in-this-mailbox" />
      </InboxProvider>,
    );
    await expect(
      screen.findByRole('header', { name: 'Message unavailable' }),
    ).resolves.toBeVisible();
    expect(screen.queryByText('maya@example.com')).toBeNull();
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
    try {
      await render(
        <InboxProvider store={store}>
          <MessageDetail id="studio-review" />
        </InboxProvider>,
      );
      await expect(screen.findByRole('alert')).resolves.toHaveTextContent(
        /Private storage is locked/u,
      );
      expect(screen.queryByText('maya@example.com')).toBeNull();
      currentOpen = () => storage.open('[]');
      await fireEvent.press(screen.getByRole('button', { name: 'Try again' }));
      await expect(
        screen.findByText('maya@example.com'),
      ).resolves.toBeVisible();
    } finally {
      await store.dispose();
    }
  });
});
