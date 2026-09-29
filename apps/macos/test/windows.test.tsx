import { makeMockInboxStorage } from '@private-email/mail-core/mock-storage';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { fireEvent, renderAsync, within } from '@testing-library/react-native';
import { View } from 'react-native';

import * as privateStorage from '../src/private-storage.ts';
import { InboxWindow } from '../src/window.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  inbox: undefined,
}));

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

beforeEach(() => {
  jest.replaceProperty(
    privateStorage,
    'inbox',
    createPersistentInbox(makeMockInboxStorage()),
  );
});

afterEach(async () => {
  await privateStorage.inbox.dispose();
});

describe('mac window selection with the shared mock mailbox', () => {
  it('keeps selections independent and preserves the remaining window when another closes', async () => {
    expect.hasAssertions();
    const app = await renderAsync(
      <Windows
        first
        second
      />,
    );
    const first = within(app.getByTestId('inbox-window-first'));
    const second = within(app.getByTestId('inbox-window-second'));
    fireEvent.press(await first.findByRole('button', { name: maya }));
    fireEvent.press(await second.findByRole('button', { name: oliver }));
    expect(first.getByText('maya@example.com')).toBeVisible();
    expect(second.getByText('oliver@example.com')).toBeVisible();
    await app.rerenderAsync(
      <Windows
        first={false}
        second
      />,
    );
    expect(app.getByText('oliver@example.com')).toBeVisible();
    await app.rerenderAsync(
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
    const app = await renderAsync(
      <Windows
        first
        second={false}
      />,
    );
    fireEvent.press(await app.findByRole('button', { name: maya }));
    expect(app.getByText('maya@example.com')).toBeVisible();
    await app.rerenderAsync(
      <Windows
        first={false}
        second={false}
      />,
    );
    await app.rerenderAsync(
      <Windows
        first={false}
        second
      />,
    );
    await expect(
      app.findByText('Select a message to start reading.'),
    ).resolves.toBeVisible();
    fireEvent.press(await app.findByRole('button', { name: oliver }));
    expect(app.getByText('oliver@example.com')).toBeVisible();
    expect(app.queryByText('maya@example.com')).toBeNull();
  });

  it('shares committed read state while each window keeps its selection', async () => {
    expect.hasAssertions();
    const app = await renderAsync(
      <Windows
        first
        second
      />,
    );
    const first = within(app.getByTestId('inbox-window-first'));
    const second = within(app.getByTestId('inbox-window-second'));
    fireEvent.press(await first.findByRole('button', { name: maya }));
    fireEvent.press(await second.findByRole('button', { name: oliver }));
    fireEvent.press(first.getByRole('button', { name: 'Mark as read' }));
    await second.findByRole('button', {
      name: 'Maya Chen. A little more room to think',
    });
    expect(first.getByText('maya@example.com')).toBeVisible();
    expect(second.getByText('oliver@example.com')).toBeVisible();
    fireEvent.press(second.getByRole('button', { name: 'Mark as read' }));
    await expect(
      first.findByRole('button', {
        name: 'Oliver Park. Saturday, by the river?',
      }),
    ).resolves.toBeVisible();
    await app.rerenderAsync(
      <Windows
        first={false}
        second={false}
      />,
    );
    await app.rerenderAsync(
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
});
