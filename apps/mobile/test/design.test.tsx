import { palette } from '@private-email/mail-core/theme';
import {
  act,
  fireEvent,
  render,
  screen,
  within,
} from '@testing-library/react-native';
import { Animated, StyleSheet } from 'react-native';

import type { usePalette } from '../src/theme.ts';

import {
  Button,
  Glass,
  GlassGroup,
  GlassPanel,
  ToolbarButton,
} from '../src/design.tsx';

// The component's outermost host element.
const renderedRoot = () => {
  const { root } = screen;
  if (root === null) {
    throw new Error('Expected the component to render');
  }
  return root;
};

describe('design components', () => {
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

  it('retires closing menu controls immediately and keeps an interrupted exit open', async () => {
    expect.hasAssertions();
    let finishExit: Parameters<ReturnType<typeof Animated.timing>['start']>[0] =
      undefined;
    const timing = jest.spyOn(Animated, 'timing').mockImplementation(() => ({
      start: (complete) => {
        finishExit = complete;
      },
      stop: () => {
        finishExit?.({ finished: false });
      },
      reset: () => undefined,
    }));
    try {
      const panel = (open: boolean) => (
        <GlassPanel open={open}>
          <Button
            label="Menu action"
            onPress={() => undefined}
          />
        </GlassPanel>
      );
      const app = await render(panel(true));
      expect(
        screen.getByRole('button', { name: 'Menu action' }),
      ).toBeOnTheScreen();
      await app.rerender(panel(false));
      expect(screen.queryByRole('button', { name: 'Menu action' })).toBeNull();
      expect(
        screen.getByRole('button', {
          name: 'Menu action',
          includeHiddenElements: true,
        }),
      ).toBeOnTheScreen();
      await app.rerender(panel(true));
      expect(
        screen.getByRole('button', { name: 'Menu action' }),
      ).toBeOnTheScreen();
      await app.rerender(panel(false));
      await act(() => {
        finishExit?.({ finished: true });
      });
      expect(
        screen.queryByRole('button', {
          name: 'Menu action',
          includeHiddenElements: true,
        }),
      ).toBeNull();
    } finally {
      timing.mockRestore();
    }
  });

  it('puts grouped controls inside interactive glass that content shows through', async () => {
    expect.hasAssertions();
    const archive = jest.fn();
    await render(
      <GlassGroup>
        <ToolbarButton
          icon="archivebox"
          label="Archive"
          onPress={archive}
        />
      </GlassGroup>,
    );
    const material = renderedRoot();
    expect(material).toHaveProp('isInteractive', true);
    expect(StyleSheet.flatten(material.props.style)).not.toHaveProperty(
      'backgroundColor',
    );
    await fireEvent.press(
      within(material).getByRole('button', { name: 'Archive' }),
    );
    // oxlint-disable-next-line vitest/prefer-called-once -- Jest has no toHaveBeenCalledOnce matcher.
    expect(archive).toHaveBeenCalledTimes(1);
  });

  it('keeps structural glass passive', async () => {
    expect.hasAssertions();
    await render(<Glass cornerRadius={22} />);
    expect(screen.root).toHaveProp('isInteractive', false);
  });
});
