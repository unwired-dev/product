import type { ReactNode } from 'react';
import type { LayoutChangeEvent } from 'react-native';

import { useEffect, useRef, useState } from 'react';
import { AccessibilityInfo, StyleSheet } from 'react-native';
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

type Leaving<I> = Readonly<{
  item: I;
  key: string;
  // The neighbours it had, which place it while it leaves.
  after: string | undefined;
  before: string | undefined;
  wait: boolean;
}>;

type Tracked<I> = Readonly<{
  order: readonly string[];
  items: readonly I[];
  outcomes: readonly unknown[];
  covered: boolean;
  leaving: ReadonlyArray<Leaving<I>>;
  returning: ReadonlySet<string>;
}>;

type Shown<I> = Readonly<{
  items: readonly I[];
  keyOf: (item: I) => string;
  // Each shown mailbox's organizing outcome. Only an action, its Undo or their reconciliation
  // changes one; synchronization and view changes never do.
  outcomes: readonly unknown[];
  // Whether a message is open in the reader, which covers the list on iPhone.
  reading: boolean;
}>;

// The same mailboxes show the same outcomes; a changed set of mailboxes is not an outcome.
const sameOutcomes = (a: readonly unknown[], b: readonly unknown[]) =>
  a.length !== b.length || a.every((outcome, index) => outcome === b[index]);

// The nearest key on one side of `index` that the list still shows.
const neighbour = (
  {
    order,
    shown,
  }: Readonly<{ order: readonly string[]; shown: ReadonlySet<string> }>,
  index: number,
  step: -1 | 1,
) => {
  for (let at = index + step; at >= 0 && at < order.length; at += step) {
    const key = order[at];
    if (key !== undefined && shown.has(key)) {
      return key;
    }
  }
  return undefined;
};

// The list after a render. Rows an outcome removed keep leaving and rows it brought back return;
// a new outcome finishes rows still leaving, unless they return. Other changes replace the list.
function advance<I>(tracked: Tracked<I>, shown: Shown<I>): Tracked<I> {
  const order = shown.items.map(shown.keyOf);
  const now = new Set(order);
  const next = {
    order,
    items: shown.items,
    outcomes: shown.outcomes,
    covered: shown.reading && !ipad,
  };
  if (sameOutcomes(shown.outcomes, tracked.outcomes)) {
    return {
      ...tracked,
      ...next,
      leaving: tracked.leaving.filter(({ key }) => !now.has(key)),
    };
  }
  const before = new Set(tracked.order);
  const leaving = tracked.order.flatMap((key, index): Array<Leaving<I>> => {
    const item = tracked.items[index];
    return now.has(key) || item === undefined
      ? []
      : [
          {
            item,
            key,
            after: neighbour({ order: tracked.order, shown: now }, index, -1),
            before: neighbour({ order: tracked.order, shown: now }, index, 1),
            wait: tracked.covered,
          },
        ];
  });
  const reversing = new Set(
    tracked.leaving.filter(({ key }) => now.has(key)).map(({ key }) => key),
  );
  return {
    ...next,
    leaving,
    returning: new Set(
      order.filter((key) => !before.has(key) || reversing.has(key)),
    ),
  };
}

// The sections with each leaving row beside the neighbours it had.
function place<I, S extends Readonly<{ key: string; data: readonly I[] }>>(
  sections: readonly S[],
  leaving: ReadonlyArray<Leaving<I>>,
  keyOf: (item: I) => string,
): S[] {
  if (leaving.length === 0) {
    return [...sections];
  }
  const placed = sections.map((section) => ({
    ...section,
    data: [...section.data],
  }));
  for (const row of leaving) {
    const anchor = row.after ?? row.before;
    const section =
      placed.find(({ data }) => data.some((item) => keyOf(item) === anchor)) ??
      placed.at(-1);
    if (section !== undefined) {
      const index = section.data.findIndex((item) => keyOf(item) === anchor);
      const offset = row.after === undefined ? 0 : 1;
      section.data.splice(
        index === -1 ? section.data.length : index + offset,
        0,
        row.item,
      );
    }
  }
  return placed;
}

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
  const [tracked, setTracked] = useState<Tracked<I>>(() => ({
    order: shown.items.map(shown.keyOf),
    items: shown.items,
    outcomes: shown.outcomes,
    covered: shown.reading && !ipad,
    leaving: [],
    returning: new Set(),
  }));
  if (
    shown.items.map(shown.keyOf).join('\n') !== tracked.order.join('\n') ||
    !sameOutcomes(shown.outcomes, tracked.outcomes) ||
    (shown.reading !== tracked.covered && !ipad)
  ) {
    setTracked(advance(tracked, shown));
  }
  const leaving = new Map(tracked.leaving.map((row) => [row.key, row]));
  return {
    place: <S extends Readonly<{ key: string; data: readonly I[] }>>(
      sections: readonly S[],
    ) => place(sections, tracked.leaving, shown.keyOf),
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

const styles = StyleSheet.create({ clip: { overflow: 'hidden' } });

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
  // The content's own height, and the share of it the row shows.
  const natural = useSharedValue(-1);
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
  // Until the content is measured, a row that returns stays collapsed and any other row keeps its
  // own height.
  const shown = useAnimatedStyle(() => {
    if (natural.value >= 0) {
      return { height: natural.value * size.value, opacity: opacity.value };
    }
    return size.value < 1
      ? { height: 0, opacity: opacity.value }
      : { opacity: opacity.value };
  });
  const measure = ({ nativeEvent }: LayoutChangeEvent) => {
    natural.set(nativeEvent.layout.height);
  };
  const gone = kind === 'leaving';
  return (
    <Animated.View
      style={[styles.clip, shown]}
      pointerEvents={gone ? 'none' : 'auto'}
      accessibilityElementsHidden={gone}
      importantForAccessibility={gone ? 'no-hide-descendants' : 'auto'}>
      <Animated.View onLayout={measure}>{children}</Animated.View>
    </Animated.View>
  );
}
