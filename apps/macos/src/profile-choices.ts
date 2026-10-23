import { createProfileChoices } from '@private-email/mail-core/profile-windows';

import { native } from './host.ts';

// The device's Startup Profile, which a new window opens. AppKit restores each window's own.
export const profileChoices = createProfileChoices({
  preference: (key) => native().preference(key),
  setPreference: (key, value) => native().setPreference(key, value),
});
