import {
  createFreshness,
  followWakes,
} from '@private-email/mail-core/freshness';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import {
  BackgroundTaskResult,
  BackgroundTaskStatus,
  getStatusAsync,
  registerTaskAsync,
} from 'expo-background-task';
import { defineTask } from 'expo-task-manager';
import { AppState } from 'react-native';

import { gmailMailboxes, registration, wakes } from './registration.ts';

const task = 'dev.unwired.mail.gmail-freshness';

// iOS grants background time when it chooses, never on a schedule or while the app is
// force-quit. Each opportunity verifies registration, then resumes every mailbox from its
// committed checkpoint; activation catches up on whatever none of them reached.
defineTask(task, async () => {
  try {
    await createFreshness(gmailMailboxes, registration.refreshInbox).refresh();
    return BackgroundTaskResult.Success;
  } catch {
    // TaskManager would log the raw rejection, which can contain account data.
    console.error('Gmail background refresh failed');
    return BackgroundTaskResult.Failed;
  }
});

// A content-free push wake, including one that launches the app in the background, synchronizes
// only its routed mailbox once registration verifies.
if (!previewInbox) {
  void followWakes(
    createFreshness(gmailMailboxes, registration.refreshInbox),
    wakes,
  );
}

export const scheduleGmailFreshness = async () => {
  // Restricted where the person turned Background App Refresh off, and on simulators.
  try {
    if (
      !previewInbox &&
      (await getStatusAsync()) === BackgroundTaskStatus.Available
    ) {
      await registerTaskAsync(task, { minimumInterval: 15 });
    }
  } catch {
    // Native registration failures can contain account data. Foreground catch-up remains usable.
    console.error('Gmail background task registration failed');
  }
};

// While the app stays active, a five-minute fallback poll keeps an open Inbox fresh between
// activations, and IMAP servers that advertise IDLE report new mail as it arrives. Both stop when
// the app leaves the foreground, where background tasks take over.
export const pollGmailWhileActive = () => {
  if (previewInbox) {
    return () => undefined;
  }
  const freshness = createFreshness(gmailMailboxes, registration.refreshInbox);
  let stop: (() => void) | undefined = undefined;
  const follow = (state: string) => {
    if (state === 'active') {
      if (stop === undefined) {
        const poll = freshness.keepAlive(5);
        const idle = gmailMailboxes.watch();
        stop = () => {
          poll();
          idle();
        };
      }
    } else {
      stop?.();
      stop = undefined;
    }
  };
  follow(AppState.currentState);
  const subscription = AppState.addEventListener('change', follow);
  return () => {
    subscription.remove();
    stop?.();
  };
};
