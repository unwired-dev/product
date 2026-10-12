import { fireEvent, render, screen } from '@testing-library/react-native';

import { CommandPalette, Commands } from '../src/command-palette.tsx';

it('exposes no matching commands to Mac assistive technology and recovers on search', async () => {
  expect.hasAssertions();
  await render(
    <CommandPalette>
      <Commands
        commands={[
          {
            id: 'inbox',
            label: 'Go to Inbox',
            group: 'navigation',
            onRun: () => false,
          },
        ]}
      />
    </CommandPalette>,
  );
  await fireEvent(screen.getByTestId('command-palette-host'), 'commandKey', {
    nativeEvent: { key: 'open' },
  });
  await fireEvent.changeText(
    screen.getByLabelText('Command Palette'),
    'zzzzzz',
  );
  expect(screen.getByRole('text', { name: 'No matching commands' })).toHaveProp(
    'accessibilityLabel',
    'No matching commands',
  );
  await fireEvent.changeText(screen.getByLabelText('Command Palette'), 'inbox');
  expect(
    screen.queryByRole('text', { name: 'No matching commands' }),
  ).toBeNull();
  expect(screen.getByRole('button', { name: 'Go to Inbox' })).toBeVisible();
});
