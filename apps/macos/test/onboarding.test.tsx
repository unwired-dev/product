import { act, render } from '@testing-library/react-native';
import { AccessibilityInfo, Animated } from 'react-native';

import { Restoring } from '../src/onboarding.tsx';

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

      await act(() => {
        changeReduceMotion(true);
      });
      const reduced = breathing();
      await act(() => {
        changeReduceMotion(false);
      });

      expect([shown, reduced, breathing()]).toStrictEqual([
        [[1, 0]],
        [[1, 1]],
        [
          [1, 1],
          [1, 0],
        ],
      ]);
    } finally {
      loop.mockRestore();
    }
  });
});
