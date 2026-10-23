import { createProfileChoices } from '@private-email/mail-core/profile-windows';

import { native } from './host.ts';

// The window's last shown and Startup Profiles, saved on this device.
export const createWindowProfileChoices = () =>
  createProfileChoices({
    preference: (key) => native().preference(key),
    setPreference: (key, value) => native().setPreference(key, value),
  });

// Settings edits the device preference; each open window keeps its own launch choices.
export const profileChoices = createWindowProfileChoices();
