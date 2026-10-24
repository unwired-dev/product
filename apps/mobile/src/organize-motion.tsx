import type { ReactNode } from 'react';
import type { LayoutChangeEvent, StyleProp, ViewStyle } from 'react-native';
import type {
  EntryExitAnimationFunction,
  LayoutAnimationFunction,
} from 'react-native-reanimated';

import { useLayoutEffect } from 'react';
import { AccessibilityInfo } from 'react-native';
import Animated, {
  Easing,
  LinearTransition,
  makeMutable,
  ReduceMotion,
  withTiming,
} from 'react-native-reanimated';

import type { InboxMailbox, MailboxList } from './private-storage.ts';

// Reanimated replaces Fabric's layout animation delegate, so React Native's LayoutAnimation does
// nothing here; the Inbox's cells animate through Reanimated instead.
const timing = { duration: 200, easing: Easing.bezier(0.23, 1, 0.32, 1) };
// This opacity-only alternative must still fade when Reanimated reads the system preference.
const reducedTiming = {
  ...timing,
  duration: 150,
  reduceMotion: ReduceMotion.Never,
};
const shift = LinearTransition.duration(timing.duration)
  .easing(timing.easing)
  .build();
// Set from an organizing outcome until the Inbox lays out the commit that shows it; the cells'
// worklets read it on the UI thread as that commit mounts.
const moving = makeMutable(false);
const reduced = makeMutable(false);
const still = { initialValues: {}, animations: {} };

// A leaving row fades while the rows below close over it; Reduce Motion removes it at once.
const leave: EntryExitAnimationFunction = () => {
  'worklet';
  return moving.value && !reduced.value
    ? {
        initialValues: { opacity: 1 },
        animations: { opacity: withTiming(0, timing) },
      }
    : still;
};
// A returning row fades in as the rows below part; Reduce Motion only fades it in.
const enter: EntryExitAnimationFunction = () => {
  'worklet';
  return moving.value
    ? {
        initialValues: { opacity: 0 },
        animations: {
          opacity: withTiming(1, reduced.value ? reducedTiming : timing),
        },
      }
    : still;
};
const move: LayoutAnimationFunction = (values) => {
  'worklet';
  return moving.value && !reduced.value ? shift(values) : still;
};

// The Inbox list's cell, which moves only with an organizing outcome.
export function MovingCell({
  style,
  onLayout,
  children,
}: {
  readonly style?: StyleProp<ViewStyle> | undefined;
  readonly onLayout?: ((event: LayoutChangeEvent) => void) | undefined;
  readonly children?: ReactNode;
}) {
  return (
    <Animated.View
      entering={enter}
      exiting={leave}
      layout={move}
      style={style}
      onLayout={onLayout}>
      {children}
    </Animated.View>
  );
}

// Only the commit that shows an organizing outcome moves rows: once the Inbox has laid it out,
// later synchronization and view changes replace the list without motion.
export function useSettledMotion() {
  useLayoutEffect(() => {
    moving.value = false;
  });
}

const readReducedMotion = async () => {
  reduced.value = await AccessibilityInfo.isReduceMotionEnabled();
};

// The organizing outcome a mailbox shows, which only an action, its Undo or its reconciliation
// changes; synchronization keeps it.
const outcome = (state: InboxMailbox['state']) =>
  state.kind === 'ready' && 'notice' in state ? state.notice : undefined;

// Moves the rows each organizing outcome changes, in the commit that shows it: a removal, its
// Undo, a refused or rolled-back change and a discarded one. Synchronization and switching views
// change the list without motion. Returns the unsubscribe function.
export function animateOrganizing(mailboxes: MailboxList) {
  let shown = mailboxes.getSnapshot();
  void readReducedMotion();
  const preference = AccessibilityInfo.addEventListener(
    'reduceMotionChanged',
    (enabled) => {
      reduced.value = enabled;
    },
  );
  const unsubscribe = mailboxes.subscribe(() => {
    const next = mailboxes.getSnapshot();
    const changed = next.some((mailbox) => {
      const before = shown.find(({ id }) => id === mailbox.id);
      return (
        before?.state.kind === 'ready' &&
        mailbox.state.kind === 'ready' &&
        outcome(before.state) !== outcome(mailbox.state)
      );
    });
    shown = next;
    if (changed) {
      moving.value = true;
    }
  });
  return () => {
    moving.value = false;
    preference.remove();
    unsubscribe();
  };
}
