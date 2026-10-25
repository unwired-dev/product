import { act, render, screen } from '@testing-library/react-native';
import { AccessibilityInfo } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

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

// The seal's breathing is the screen's only repeating animation.
const breathing = () =>
  JSON.stringify(screen.toJSON()).includes(
    '"animationIterationCount":"infinite"',
  );

describe('restoring', () => {
  it('stops and resumes the seal breathing as Reduce Motion changes', async () => {
    expect.hasAssertions();
    await render(
      <SafeAreaProvider
        initialMetrics={{
          frame: { x: 0, y: 0, width: 393, height: 852 },
          insets: { top: 59, bottom: 34, left: 0, right: 0 },
        }}>
        <Restoring />
      </SafeAreaProvider>,
    );
    await act(async () => {
      await Promise.resolve();
    });
    const shown = breathing();
    const [seal] = screen.container.queryAll((node) =>
      JSON.stringify([node.props.jestInlineStyle]).includes(
        '"animationIterationCount":"infinite"',
      ),
    );
    const status = screen.getByText('Opening your mail…', {
      includeHiddenElements: true,
    });
    expect(seal).toBeOnTheScreen();

    await act(() => {
      changeReduceMotion(true);
    });
    const reduced = breathing();
    // A fresh native seal discards the opacity retained by a detached CSS animation.
    expect(seal).not.toBeOnTheScreen();
    expect(
      screen.getByText('Opening your mail…', { includeHiddenElements: true }),
    ).toBe(status);
    await act(() => {
      changeReduceMotion(false);
    });

    expect([shown, reduced, breathing()]).toStrictEqual([true, false, true]);
    expect(
      screen.getByText('Opening your mail…', { includeHiddenElements: true }),
    ).toBe(status);
  });
});
