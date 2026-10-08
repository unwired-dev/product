import { createFreshness } from '@private-email/mail-core/freshness';
import { previewInbox } from '@private-email/mail-core/registration-mode';

import { gmailMailboxes, registration } from './registration.ts';

// The application, not a window, owns Gmail synchronization: it continues after the last window
// closes and ends with the process on Quit. No helper process runs.
// ponytail: fixed poll; content-free push wakes replace it once routes are registered (#781).
export const keepGmailFresh = () => {
  if (!previewInbox) {
    createFreshness(gmailMailboxes, registration.refreshInbox).keepAlive(5);
  }
};
