import { pushCovers } from '@private-email/mail-core/freshness';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import { AppState } from 'react-native';

import {
  followWakes,
  freshness,
  gmailMailboxes,
  wakes,
} from './registration.ts';

// The application, not a window, owns Gmail synchronization: it continues after the last window
// closes and ends with the process on Quit. No helper process runs. Push wakes synchronize each
// routed mailbox. While the app is active, the five-minute interval supplements them, so a dropped
// wake is never left unread; otherwise it runs only while a usable mailbox has no current route,
// and activation catches up on a wake that never arrived. IMAP servers that advertise IDLE report
// new mail while the application runs.
export const keepGmailFresh = () => {
  if (!previewInbox) {
    gmailMailboxes.watch();
    followWakes();
    freshness.keepAlive(
      5,
      async () =>
        AppState.currentState !== 'active' && (await pushCovers(wakes)),
    );
  }
};
