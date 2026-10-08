import { createFreshness } from '@private-email/mail-core/freshness';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import {
  BackgroundTaskResult,
  BackgroundTaskStatus,
  getStatusAsync,
  registerTaskAsync,
} from 'expo-background-task';
import { defineTask } from 'expo-task-manager';

import { gmailMailboxes, registration } from './registration.ts';

const task = 'dev.unwired.mail.gmail-freshness';

// iOS grants background time when it chooses, never on a schedule or while the app is
// force-quit. Each opportunity verifies registration, then resumes every mailbox from its
// committed checkpoint; activation catches up on whatever none of them reached.
defineTask(task, async () => {
  await createFreshness(gmailMailboxes, registration.refreshInbox).refresh();
  return BackgroundTaskResult.Success;
});

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
