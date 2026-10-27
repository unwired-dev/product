import { deliveryTimeReleased } from '@private-email/mail-core/outbox';
import { AppState } from 'react-native';

import { native } from './host.ts';
import { drafts, outbox } from './registration.ts';

// Headless refreshes may read mail but do not grant a new delivery opportunity. In-flight native
// submissions settle normally; a terminated request reopens as unknown, never as permission to send.
// An admitted Send holds bounded background time from the foreground, so switching apps or locking
// the device can finish its Undo Send Window and handoff; denial or expiry ends that opportunity.
let held = false;
// Denied or expired time waits for the next activation instead of asking again.
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
const hold = async (): Promise<void> => {
  if (held) {
    if (!unsettled()) {
      native().releaseDelivery();
    }
    return;
  }
  if (spent || AppState.currentState !== 'active' || !unsettled()) {
    return;
  }
  held = true;
  const released = deliveryTimeReleased(await native().holdDelivery());
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
