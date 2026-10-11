import {
  createFreshness,
  followWakes,
  pushCovers,
} from '@private-email/mail-core/freshness';
import { previewInbox } from '@private-email/mail-core/registration-mode';

import { gmailMailboxes, registration, wakes } from './registration.ts';

// The application, not a window, owns Gmail synchronization: it continues after the last window
// closes and ends with the process on Quit. No helper process runs. Push wakes synchronize each
// routed mailbox; the five-minute interval runs while a usable mailbox has no current route, and
// activation still catches up on a wake that never arrived.
export const keepGmailFresh = () => {
  if (!previewInbox) {
    const freshness = createFreshness(
      gmailMailboxes,
      registration.refreshInbox,
    );
    void followWakes(freshness, wakes);
    freshness.keepAlive(5, () => pushCovers(wakes));
  }
};
