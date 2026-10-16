import type { Registration } from '@private-email/mail-core/registration';

// The host restores Registration once at app start, before any gate mounts.
export const started = (store: Readonly<Registration>) => {
  void store.restoreOnce();
  return store;
};
