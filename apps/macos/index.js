import 'fast-text-encoding';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import { AppRegistry } from 'react-native';

import { keepGmailFresh } from './src/freshness.ts';
import { start } from './src/registration.ts';
import { InboxWindow } from './src/window.tsx';

AppRegistry.registerComponent('UnwiredMail', () => InboxWindow);
// Every window's gate shows the Registration and remote content settings the host restores once
// here.
if (!previewInbox) {
  void start();
}
keepGmailFresh();
