import { fireEvent, render, screen } from '@testing-library/react-native';
import { useState } from 'react';
import { Text } from 'react-native';

import type { SettingsDestination } from '../src/settings.tsx';

import { SettingsWorkspace } from '../src/settings.tsx';

jest.mock(
  // oxlint-disable-next-line vitest/prefer-import-in-mock -- The library's stand-in for native inset measurement.
  'react-native-safe-area-context',
  () =>
    jest.requireActual<{ default: object }>(
      'react-native-safe-area-context/jest/mock',
    ).default,
);

function Settings() {
  const [destination, setDestination] = useState<SettingsDestination>();
  return (
    <SettingsWorkspace
      account="Work"
      destination={destination}
      onDestination={setDestination}>
      {destination === undefined ? null : <Text>Retained settings</Text>}
    </SettingsWorkspace>
  );
}

describe('iPhone back navigation', () => {
  it('returns a Settings detail to the destination list and permits reopening it', async () => {
    expect.hasAssertions();
    await render(<Settings />);
    await fireEvent.press(
      screen.getByRole('button', { name: 'Privacy & Data' }),
    );
    expect(screen.getByText('Retained settings')).toBeVisible();
    await fireEvent(screen.getByTestId('settings-detail-screen'), 'dismissed', {
      nativeEvent: { dismissCount: 1 },
    });
    expect(screen.queryByText('Retained settings')).toBeNull();
    await fireEvent.press(
      screen.getByRole('button', { name: 'Privacy & Data' }),
    );
    expect(screen.getByText('Retained settings')).toBeVisible();
    await fireEvent.press(
      screen.getByRole('button', { name: 'Back to Settings' }),
    );
    expect(screen.getByRole('header', { name: 'Settings' })).toBeVisible();
  });
});
