import { AppState } from 'react-native';

import { drafts, outbox } from './registration.ts';

// The process owns delivery, including with no windows. Explicit Quit ends it with the process;
// reopening recovers the durable Outbox rather than creating a second delivery owner.
void drafts.load();
void outbox.resume();
AppState.addEventListener('change', (state) => {
  if (state === 'active') {
    void outbox.process();
  }
});
