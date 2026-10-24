import type { LayoutAnimationConfig } from 'react-native';

import { AccessibilityInfo, LayoutAnimation } from 'react-native';

import type { InboxMailbox, MailboxList } from './private-storage.ts';

// A leaving row fades while the rows below close over it; a returning row fades in as they part.
const motion = LayoutAnimation.create(200, 'easeOut', 'opacity');
// Reduce Motion removes a row at once and only fades a returning one in.
const reducedMotion: LayoutAnimationConfig = {
  duration: 150,
  create: { type: 'easeOut', property: 'opacity' },
};

// The organizing outcome a mailbox shows, which only an action, its Undo or its reconciliation
// changes; synchronization keeps it.
const outcome = (state: InboxMailbox['state']) =>
  state.kind === 'ready' && 'notice' in state ? state.notice : undefined;

// Animates the rows each organizing outcome moves, in the commit that shows it: a removal, its
// Undo, a refused or rolled-back change and a discarded one. Synchronization and switching views
// change the list without motion. Returns the unsubscribe function.
export function animateOrganizing(mailboxes: MailboxList) {
  let reduced = false;
  let shown = mailboxes.getSnapshot();
  const read = async () => {
    reduced = await AccessibilityInfo.isReduceMotionEnabled();
  };
  void read();
  const preference = AccessibilityInfo.addEventListener(
    'reduceMotionChanged',
    (enabled) => {
      reduced = enabled;
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
      LayoutAnimation.configureNext(reduced ? reducedMotion : motion);
    }
  });
  return () => {
    preference.remove();
    unsubscribe();
  };
}
