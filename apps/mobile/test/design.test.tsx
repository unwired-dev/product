import { render, screen } from '@testing-library/react-native';

import { Chip } from '../src/design.tsx';

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
});
