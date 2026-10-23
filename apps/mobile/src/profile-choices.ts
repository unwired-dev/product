import { createProfileChoices } from '@private-email/mail-core/profile-windows';

import { native } from './host.ts';

// The window's last shown and Startup Profiles, saved on this device.
export const profileChoices = createProfileChoices({
  preference: (key) => native().preference(key),
  setPreference: (key, value) => native().setPreference(key, value),
});
