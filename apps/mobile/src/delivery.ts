import { previewInbox } from '@private-email/mail-core/registration-mode';
import { AppState } from 'react-native';

import { drafts, outbox } from './registration.ts';

// Headless refreshes may read mail but do not grant a new delivery opportunity. In-flight native
// submissions settle normally; a terminated request reopens as unknown, never as permission to send.
const follow = (state: string) => {
  if (state === 'active') {
    void outbox.resume();
  } else {
    outbox.pause();
  }
};
if (!previewInbox) {
  void drafts.load();
  follow(AppState.currentState);
  AppState.addEventListener('change', follow);
}
