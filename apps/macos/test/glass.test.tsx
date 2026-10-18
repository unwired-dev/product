import { fireEvent, render, screen } from '@testing-library/react-native';

import { Glass, GlassGroup, ToolbarButton } from '../src/design.tsx';

describe('interactive glass controls', () => {
  it('keeps a structural glass surface passive', async () => {
    expect.hasAssertions();
    await render(<Glass cornerRadius={22} />);
    expect(screen.root).toHaveProp('interactive', false);
  });

  it('keeps grouped controls inside their native interactive material without an opaque backdrop', async () => {
    expect.hasAssertions();
    const activate = jest.fn();
    await render(
      <GlassGroup>
        <ToolbarButton
          icon="archivebox"
          label="Archive"
          onPress={activate}
        />
        <ToolbarButton
          icon="trash"
          label="Delete"
          disabled
          onPress={activate}
        />
      </GlassGroup>,
    );
    const material = screen.root;
    expect(material).toHaveProp('interactive', true);
    expect(material).toHaveStyle({ backgroundColor: undefined });
    const controls = screen;
    const touch = { nativeEvent: { pageX: 120, pageY: 240 } };
    await fireEvent.press(
      controls.getByRole('button', { name: 'Archive' }),
      touch,
    );
    expect(activate).toHaveBeenCalledWith(
      expect.objectContaining({
        nativeEvent: expect.objectContaining(touch.nativeEvent),
      }),
    );
    activate.mockClear();
    await fireEvent.press(controls.getByRole('button', { name: 'Delete' }));
    expect(activate).not.toHaveBeenCalled();
    expect(controls.getByRole('button', { name: 'Delete' })).toBeDisabled();
  });
});
