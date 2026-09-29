import { fireEvent, render, within } from '@testing-library/react-native';
import { View } from 'react-native';

import { InboxWindow } from '../src/window.tsx';

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

describe('mac window selection with the shared mock mailbox', () => {
  it('keeps selections independent and preserves the remaining window when another closes', async () => {
    expect.hasAssertions();
    const app = render(
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
    app.rerender(
      <Windows
        first={false}
        second
      />,
    );
    expect(app.getByText('oliver@example.com')).toBeVisible();
    app.rerender(
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
    const app = render(
      <Windows
        first
        second={false}
      />,
    );
    fireEvent.press(await app.findByRole('button', { name: maya }));
    expect(app.getByText('maya@example.com')).toBeVisible();
    app.rerender(
      <Windows
        first={false}
        second={false}
      />,
    );
    app.rerender(
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
});
