import { palette } from '@private-email/mail-core/theme';
import {
  fireEvent,
  render,
  screen,
  within,
} from '@testing-library/react-native';

import type { usePalette } from '../src/theme.ts';

import { Button, Chip } from '../src/design.tsx';

describe('design components', () => {
  it('gives filter chips a full touch target without relying on hit slop', async () => {
    expect.hasAssertions();
    await render(
      <Chip
        label="All Inboxes"
        icon="tray.2"
        selected
        onPress={() => undefined}
      />,
    );
    expect(screen.getByRole('button', { name: 'All Inboxes' })).toHaveStyle({
      minHeight: 44,
    });
  });

  it.each(['light', 'dark'] as const)(
    'keeps primary button text legible while pressed in %s appearance',
    async (appearance) => {
      expect.hasAssertions();
      const colors = palette[appearance];
      const paletteSpy = jest
        .spyOn(
          jest.requireActual<{ usePalette: typeof usePalette }>(
            '../src/theme.ts',
          ),
          'usePalette',
        )
        .mockReturnValue(colors);
      try {
        await render(
          <Button
            label="Allow Gmail access"
            fill="accent"
            onPress={() => undefined}
          />,
        );
        const button = screen.getByRole('button', {
          name: 'Allow Gmail access',
        });
        const touch = {
          persist: () => undefined,
          currentTarget: 1,
          nativeEvent: {
            pageX: 0,
            pageY: 0,
            locationX: 0,
            locationY: 0,
            timestamp: 0,
          },
        };
        await fireEvent(button, 'responderGrant', touch);
        expect(button).toHaveStyle({ backgroundColor: colors.accentFill });
        expect(within(button).getByText('Allow Gmail access')).toHaveStyle({
          color: colors.accentOnFill,
        });
      } finally {
        paletteSpy.mockRestore();
      }
    },
  );
});
