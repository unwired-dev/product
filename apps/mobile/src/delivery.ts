import { deliveryTimeReleased } from '@private-email/mail-core/outbox';
import {
  BackgroundTaskResult,
  BackgroundTaskStatus,
  getStatusAsync,
  registerTaskAsync,
} from 'expo-background-task';
import { defineTask } from 'expo-task-manager';
import { AppState } from 'react-native';

import { native } from './host.ts';
import { drafts, outbox, registration } from './registration.ts';

const task = 'dev.unwired.mail.outbox';

// Headless refreshes and push wakes may read mail but do not grant a delivery opportunity.
// In-flight native submissions settle normally; a terminated request reopens as unknown, never as
// permission to send. An admitted Send holds bounded background time from the foreground, so
// switching apps or locking the device can finish its Undo Send Window and handoff; denial or
// expiry ends that opportunity. A delivery task the system grants holds the same time.
let held = false;
// Denied or expired time waits for the next activation or delivery task instead of asking again.
let spent = false;
const unsettled = () =>
  drafts
    .getOutbox()
    .some(
      ({ state }) =>
        state === 'waiting' ||
        state === 'queued' ||
        state === 'sending' ||
        state === 'filing',
    );
const hold = async (
  granted = AppState.currentState === 'active',
): Promise<void> => {
  if (held) {
    if (!unsettled()) {
      native().releaseDelivery();
    }
    return;
  }
  if (spent || !granted || !unsettled()) {
    return;
  }
  held = true;
  // A failed request counts as spent time, so the Outbox still pauses outside the foreground.
  const released = await Promise.resolve()
    .then(() => native().holdDelivery())
    .then(deliveryTimeReleased, () => false);
  held = false;
  spent = !released;
  if (AppState.currentState !== 'active') {
    outbox.pause();
  }
  await hold();
};
const follow = (state: string) => {
  if (state === 'active') {
    spent = false;
    void outbox.resume();
  } else if (!held) {
    outbox.pause();
  }
  void hold();
};
void drafts.load();
follow(AppState.currentState);
AppState.addEventListener('change', follow);
drafts.subscribe(() => {
  void hold();
});

// iOS runs the task when it chooses: never on a schedule, without a network or after force-quit.
// Registration verification and protected Draft storage gate it as on activation; the Outbox
// keeps every Undo Send deadline and claim, and runs one pass at a time across opportunities.
defineTask(task, async () => {
  if (AppState.currentState === 'active' || held) {
    return BackgroundTaskResult.Success;
  }
  try {
    await registration.resume();
    await drafts.load();
  } catch {
    // TaskManager would log the raw rejection, which can contain account data.
    console.error('Outbox background delivery failed');
    return BackgroundTaskResult.Failed;
  }
  spent = false;
  const delivering = hold(true);
  // Without background time native code refuses handoff, so the Outbox stays paused.
  if (held) {
    void outbox.resume();
  }
  await delivering;
  return BackgroundTaskResult.Success;
});

const schedule = async () => {
  // Restricted where the person turned Background App Refresh off, and on simulators.
  try {
    if ((await getStatusAsync()) === BackgroundTaskStatus.Available) {
      await registerTaskAsync(task, { minimumInterval: 15 });
    }
  } catch {
    // Native registration failures can contain account data. Activation still sends.
    console.error('Outbox background task registration failed');
  }
};
// oxlint-disable-next-line unicorn/prefer-top-level-await -- Awaiting would hold the application entry on the scheduler.
void schedule();
