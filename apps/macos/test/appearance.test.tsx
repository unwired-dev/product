import { fireEvent, render } from '@testing-library/react-native';
import { Appearance } from 'react-native';

import { AppearanceSettings } from '../src/appearance-settings.tsx';

// The checked rows of Settings › Appearance.
const checked = (app: Awaited<ReturnType<typeof render>>) =>
  app
    .getAllByRole('radio')
    .filter((row) => row.props.accessibilityState?.checked === true)
    .map((row) => row.props.accessibilityLabel);

it('starts on System, applies a choice to the app, keeps it for the next launch and follows the system again', async () => {
  expect.hasAssertions();
  const applied = jest.spyOn(Appearance, 'setColorScheme');
  const first = await render(<AppearanceSettings />);
  const initial = checked(first);
  const footer = first.queryByText(
    'System follows macOS. Increase Contrast and Reduce Transparency apply in every choice.',
  );
  await fireEvent.press(first.getByRole('radio', { name: 'Dark' }));
  const chosen = checked(first);
  await first.unmount();
  const relaunched = await render(<AppearanceSettings />);
  const kept = checked(relaunched);
  await fireEvent.press(relaunched.getByRole('radio', { name: 'System' }));
  expect({
    initial,
    footer: footer !== null,
    chosen,
    kept,
    system: checked(relaunched),
    applied: applied.mock.calls,
  }).toStrictEqual({
    initial: ['System'],
    footer: true,
    chosen: ['Dark'],
    kept: ['Dark'],
    system: ['System'],
    applied: [['dark'], [null]],
  });
});
