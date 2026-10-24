import type {
  RowMotionState,
  ShownRows,
} from '@private-email/mail-core/mailboxes';
import type { ReactNode } from 'react';
import type { LayoutChangeEvent } from 'react-native';

import {
  advanceRowMotion,
  placeLeavingRows,
  sameOrganizingOutcomes,
} from '@private-email/mail-core/mailboxes';
import { useEffect, useRef, useState } from 'react';
import { AccessibilityInfo, StyleSheet, View } from 'react-native';
import Animated, {
  Easing,
  ReduceMotion,
  useAnimatedStyle,
  useSharedValue,
  withDelay,
  withTiming,
} from 'react-native-reanimated';
import { scheduleOnRN } from 'react-native-worklets';

import { ipad } from './inbox-styles.ts';

// The approved removal and Undo motion. Rows apply Reduce Motion themselves, so Reanimated's own
// reading of it must not skip the fade that remains.
const timing = {
  duration: 200,
  easing: Easing.bezier(0.23, 1, 0.32, 1),
  reduceMotion: ReduceMotion.Never,
};
const reducedFade = { ...timing, duration: 150 };
// The reader's Back transition on iPhone, which shows the list again before a row leaves it.
const backTransition = 350;

export type RowMotion = Readonly<{
  kind: 'leaving' | 'returning';
  // The reader covered the list when the row left.
  wait: boolean;
  reduced: boolean;
}>;

type Shown<I> = Omit<ShownRows<I>, 'covered'> & Readonly<{ reading: boolean }>;

// Reduce Motion, following changes while the list is shown.
function useReducedMotion() {
  const [reduced, setReduced] = useState(false);
  useEffect(() => {
    let current = true;
    const read = async () => {
      const enabled = await AccessibilityInfo.isReduceMotionEnabled();
      if (current) {
        setReduced(enabled);
      }
    };
    void read();
    const subscription = AccessibilityInfo.addEventListener(
      'reduceMotionChanged',
      (enabled) => {
        current = false;
        setReduced(enabled);
      },
    );
    return () => {
      current = false;
      subscription.remove();
    };
  }, []);
  return reduced;
}

// Removal and Undo continuity for a list: the sections with leaving rows still in place, each
// row's motion, and the interruptions that finish rows still leaving.
export function useRowMotion<I>(shown: Shown<I>) {
  const reduced = useReducedMotion();
  const [tracked, setTracked] = useState<RowMotionState<I>>(() => ({
    order: shown.sections.flatMap(({ data }) => data.map(shown.keyOf)),
    sections: shown.sections,
    outcomes: shown.outcomes,
    covered: shown.reading && !ipad,
    leaving: [],
    returning: new Set(),
  }));
  if (
    shown.sections.flatMap(({ data }) => data.map(shown.keyOf)).join('\n') !==
      tracked.order.join('\n') ||
    !sameOrganizingOutcomes(shown.outcomes, tracked.outcomes) ||
    (shown.reading !== tracked.covered && !ipad)
  ) {
    setTracked(
      advanceRowMotion(tracked, { ...shown, covered: shown.reading && !ipad }),
    );
  }
  const leaving = new Map(tracked.leaving.map((row) => [row.key, row]));
  return {
    place: () => placeLeavingRows(shown.sections, tracked.leaving, shown.keyOf),
    motionOf: (key: string): RowMotion | undefined => {
      const row = leaving.get(key);
      if (row !== undefined) {
        return { kind: 'leaving', wait: row.wait, reduced };
      }
      return tracked.returning.has(key)
        ? { kind: 'returning', wait: false, reduced }
        : undefined;
    },
    // A row finished leaving or returning.
    settle: (key: string) => {
      setTracked((current) => ({
        ...current,
        leaving: current.leaving.filter((row) => row.key !== key),
        returning: new Set([...current.returning].filter((k) => k !== key)),
      }));
    },
    // A scroll or a selection takes effect at once, so rows still leaving finish.
    interrupt: () => {
      setTracked((current) =>
        current.leaving.length === 0 ? current : { ...current, leaving: [] },
      );
    },
  };
}

const styles = StyleSheet.create({
  clip: { overflow: 'hidden' },
  // A moving row's content keeps its own height while the row around it changes.
  moving: { position: 'absolute', top: 0, left: 0, right: 0 },
  collapsed: { height: 0, opacity: 0 },
});

// A list row that collapses and fades as it leaves, and grows back from its current height when it
// returns. Reduce Motion removes a leaving row at once and only fades a returning one in.
export function MovingRow({
  motion,
  onSettled,
  children,
}: {
  readonly motion: RowMotion | undefined;
  readonly onSettled: () => void;
  readonly children: ReactNode;
}) {
  const kind = motion?.kind;
  const wait = motion?.wait === true;
  const reduced = motion?.reduced === true;
  // The content's own height once measured, and the share of it the row shows.
  const [natural, setNatural] = useState<number>();
  const size = useSharedValue(kind === 'returning' ? 0 : 1);
  const opacity = useSharedValue(kind === 'returning' ? 0 : 1);
  const settle = useRef(onSettled);
  useEffect(() => {
    settle.current = onSettled;
  });
  useEffect(() => {
    if (kind === undefined) {
      return;
    }
    const settled = () => {
      settle.current();
    };
    const done = (finished?: boolean) => {
      'worklet';
      if (finished === true) {
        scheduleOnRN(settled);
      }
    };
    if (kind === 'leaving') {
      if (reduced) {
        settled();
        return;
      }
      const delay = wait ? backTransition : 0;
      size.set(withDelay(delay, withTiming(0, timing)));
      opacity.set(withDelay(delay, withTiming(0, timing, done)));
      return;
    }
    if (reduced) {
      size.set(1);
      opacity.set(withTiming(1, reducedFade, done));
      return;
    }
    size.set(withTiming(1, timing));
    opacity.set(withTiming(1, timing, done));
  }, [kind, wait, reduced, size, opacity, settle]);
  const shown = useAnimatedStyle(
    () => ({ height: (natural ?? 0) * size.value, opacity: opacity.value }),
    [natural],
  );
  const measure = ({ nativeEvent }: LayoutChangeEvent) => {
    setNatural(nativeEvent.layout.height);
  };
  // Until its content is measured, a returning row stays collapsed and any other row keeps its own
  // height.
  const unmeasured = kind === 'returning' ? styles.collapsed : undefined;
  const gone = kind === 'leaving';
  return (
    <Animated.View
      style={[styles.clip, natural === undefined ? unmeasured : shown]}
      pointerEvents={gone ? 'none' : 'auto'}
      accessibilityElementsHidden={gone}
      importantForAccessibility={gone ? 'no-hide-descendants' : 'auto'}>
      <View
        style={kind === undefined ? undefined : styles.moving}
        onLayout={measure}>
        {children}
      </View>
    </Animated.View>
  );
}
