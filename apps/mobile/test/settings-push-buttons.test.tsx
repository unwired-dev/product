import { fireEvent, render, screen } from '@testing-library/react-native';
import { Dimensions, Text } from 'react-native';

import { PushButtonRow } from '../src/settings.tsx';

const layout = (width: number) => ({
  nativeEvent: { layout: { x: 0, y: 0, width, height: 44 } },
});

const present = <T,>(value: T | null) => {
  if (value === null) {
    throw new Error('Not rendered');
  }
  return value;
};

// A long mailbox address makes Remove wider than the row: Remove and Cancel then stack.
describe('settings push button row', () => {
  it('keeps buttons side by side while they fit, stacks them once they need the whole row and measures again when they change', async () => {
    expect.hasAssertions();
    const window = Dimensions.get('window');
    // At the default text size: Jest's window reports an accessibility size, which always stacks.
    Dimensions.set({ window: { ...window, fontScale: 1 } });
    try {
      await render(
        <PushButtonRow
          buttons="remove"
          style={{ flexDirection: 'row' }}>
          <Text>Remove</Text>
          <Text>Cancel</Text>
        </PushButtonRow>,
      );
      const root = present(screen.root);
      const row = () => present(screen.getByText('Remove').parent);
      await fireEvent(root, 'layout', layout(600));
      await fireEvent(row(), 'layout', layout(160));

      expect(row()).not.toBe(root);

      await fireEvent(row(), 'layout', layout(600));

      expect(row()).toBe(root);

      // New buttons measure again side by side.
      await screen.rerender(
        <PushButtonRow
          buttons="cancel"
          style={{ flexDirection: 'row' }}>
          <Text>Cancel</Text>
        </PushButtonRow>,
      );

      expect(screen.getByText('Cancel').parent).not.toBe(screen.root);
    } finally {
      await screen.unmount();
      Dimensions.set({ window });
    }
  });
});
