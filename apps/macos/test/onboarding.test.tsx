import { palette } from '@private-email/mail-core/theme';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { AccessibilityInfo, Animated } from 'react-native';

import { Restoring, Welcome } from '../src/onboarding.tsx';

// The system reports a Reduce Motion change to every registered listener. The mock's own types
// keep only the last event overload.
const changeReduceMotion = (enabled: boolean) => {
  const calls: ReadonlyArray<readonly [string, (value: never) => void]> =
    jest.mocked(AccessibilityInfo.addEventListener).mock.calls;
  for (const [event, listener] of calls) {
    if (event === 'reduceMotionChanged') {
      Reflect.apply(listener, undefined, [enabled]);
    }
  }
};

describe('restoring', () => {
  it('stops and resumes the seal breathing as Reduce Motion changes', async () => {
    expect.hasAssertions();
    const loops: Array<{ start: jest.Mock; stop: jest.Mock }> = [];
    const loop = jest.spyOn(Animated, 'loop').mockImplementation(() => {
      const breathing = { start: jest.fn(), stop: jest.fn(), reset: jest.fn() };
      loops.push(breathing);
      return breathing;
    });
    // The loop's stop leaves the seal wherever it was; Reduce Motion shows it opaque.
    const setValue = jest.spyOn(Animated.Value.prototype, 'setValue');
    try {
      await render(<Restoring />);
      await act(async () => {
        await Promise.resolve();
      });
      const breathing = () =>
        loops.map(({ start, stop }) => [
          start.mock.calls.length,
          stop.mock.calls.length,
        ]);
      const shown = breathing();
      setValue.mockClear();

      await act(() => {
        changeReduceMotion(true);
      });
      const reduced = breathing();
      const reset = [...setValue.mock.calls];
      await act(() => {
        changeReduceMotion(false);
      });

      expect([shown, reduced, reset, breathing()]).toStrictEqual([
        [[1, 0]],
        [[1, 1]],
        [[1]],
        [
          [1, 1],
          [1, 0],
        ],
      ]);
    } finally {
      setValue.mockRestore();
      loop.mockRestore();
    }
  });
});

describe('welcome', () => {
  it('fills Privacy & Data with the deep page’s Dark selection while pressed, keeping its focus ring', async () => {
    expect.hasAssertions();
    await render(
      <Welcome
        onContinue={() => undefined}
        onPrivacy={() => undefined}
      />,
    );
    const privacy = screen.getByRole('button', { name: 'Privacy & Data' });
    await fireEvent(privacy, 'focus');
    await fireEvent(privacy, 'responderGrant', {
      persist: () => undefined,
      currentTarget: 1,
      nativeEvent: {
        pageX: 0,
        pageY: 0,
        locationX: 0,
        locationY: 0,
        timestamp: 0,
      },
    });
    expect(privacy).toHaveStyle({
      backgroundColor: palette.dark.accentSelectionSubtle,
      outlineColor: palette.light.brandOnDeep,
    });
  });
});
