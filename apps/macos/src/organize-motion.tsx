import type {
  RowMotionState,
  ShownRows,
} from '@private-email/mail-core/mailboxes';
import type { ReactNode } from 'react';
import type { LayoutChangeEvent } from 'react-native';

import {
  advanceRowMotion,
  placeLeavingRows,
  restingRowMotion,
} from '@private-email/mail-core/mailboxes';
import { useEffect, useRef, useState } from 'react';
import {
  AccessibilityInfo,
  Animated,
  Easing,
  StyleSheet,
  useAnimatedValue,
  View,
} from 'react-native';

import { ModalBackground } from './design.tsx';

// Core macOS views ignore accessibilityElementsHidden; the existing native container hides its subtree.
const AnimatedRow = Animated.createAnimatedComponent(ModalBackground);

// The approved removal and Undo motion. Height is a layout property, so it runs on the JavaScript
// driver.
const timing = {
  duration: 200,
  easing: Easing.bezier(0.23, 1, 0.32, 1),
  useNativeDriver: false,
};
const reducedFade = { ...timing, duration: 150 };

export type RowMotion = Readonly<{
  kind: 'leaving' | 'returning';
  reduced: boolean;
}>;

type Shown<I> = Omit<ShownRows<I>, 'covered'> &
  Readonly<{
    selected:
      | Readonly<{ mailbox: string; id: string; folder?: string }>
      | undefined;
  }>;

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
  const [tracked, setTracked] = useState<RowMotionState<I>>(() =>
    restingRowMotion({ ...shown, covered: false }),
  );
  const next = advanceRowMotion(tracked, { ...shown, covered: false });
  if (next !== tracked) {
    setTracked(next);
  }
  // Notification navigation can select without the row handler. Clearing a removed reader keeps
  // that action's own exit; a new selected message finishes it.
  const { selected } = shown;
  const [previousSelection, setPreviousSelection] = useState(selected);
  if (
    selected?.mailbox !== previousSelection?.mailbox ||
    selected?.id !== previousSelection?.id ||
    selected?.folder !== previousSelection?.folder
  ) {
    setPreviousSelection(selected);
    if (selected !== undefined) {
      setTracked((current) =>
        current.leaving.length === 0 ? current : { ...current, leaving: [] },
      );
    }
  }
  const leaving = new Map(tracked.leaving.map((row) => [row.key, row]));
  return {
    place: () => placeLeavingRows(shown.sections, tracked.leaving, shown.keyOf),
    motionOf: (key: string): RowMotion | undefined => {
      const row = leaving.get(key);
      if (row !== undefined) {
        return { kind: 'leaving', reduced };
      }
      return tracked.returning.has(key)
        ? { kind: 'returning', reduced }
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

// Until the content is measured, a returning row stays collapsed and any other row keeps its own
// height.
const unmeasured = (kind: RowMotion['kind'] | undefined) =>
  kind === 'returning' ? 0 : undefined;

const styles = StyleSheet.create({
  clip: { overflow: 'hidden' },
  // A moving row's content keeps its own height while the row around it changes.
  moving: { position: 'absolute', top: 0, left: 0, right: 0 },
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
  const reduced = motion?.reduced === true;
  // The content's own height once measured, and the share of it the row shows.
  const [natural, setNatural] = useState<number>();
  const size = useAnimatedValue(1);
  const opacity = useAnimatedValue(1);
  const measured = useRef(false);
  const settle = useRef(onSettled);
  // Whether this row has moved since it last rested.
  const moved = useRef(false);
  useEffect(() => {
    settle.current = onSettled;
  });
  useEffect(() => {
    // A motion cleared before it finished, as when another outcome replaces it, leaves the row whole.
    if (kind === undefined) {
      if (moved.current) {
        moved.current = false;
        size.setValue(1);
        opacity.setValue(1);
      }
      return undefined;
    }
    moved.current = true;
    const settled = ({ finished }: Readonly<{ finished: boolean }>) => {
      if (finished) {
        settle.current();
      }
    };
    if (kind === 'leaving' && reduced) {
      settle.current();
      return undefined;
    }
    // A row mounted to return grows from nothing; one still leaving reverses from where it is.
    if (kind === 'returning' && !measured.current) {
      size.setValue(0);
      opacity.setValue(0);
    }
    const target = kind === 'leaving' ? 0 : 1;
    if (reduced) {
      size.setValue(1);
    }
    const animation = Animated.parallel([
      ...(reduced
        ? []
        : [Animated.timing(size, { ...timing, toValue: target })]),
      Animated.timing(opacity, {
        ...(reduced ? reducedFade : timing),
        toValue: target,
      }),
    ]);
    animation.start(settled);
    return () => {
      animation.stop();
    };
  }, [kind, reduced, size, opacity]);
  const measure = ({ nativeEvent }: LayoutChangeEvent) => {
    measured.current = true;
    setNatural(nativeEvent.layout.height);
  };
  const height =
    natural === undefined
      ? unmeasured(kind)
      : size.interpolate({ inputRange: [0, 1], outputRange: [0, natural] });
  const gone = kind === 'leaving';
  return (
    <AnimatedRow
      style={[styles.clip, { height, opacity }]}
      pointerEvents={gone ? 'none' : 'auto'}
      accessibilityElementsHidden={gone}
      importantForAccessibility={gone ? 'no-hide-descendants' : 'auto'}>
      <View
        style={kind === undefined ? undefined : styles.moving}
        onLayout={measure}>
        {children}
      </View>
    </AnimatedRow>
  );
}
