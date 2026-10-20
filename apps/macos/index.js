import 'fast-text-encoding';
import './src/reporting-bootstrap.js';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import { AppRegistry } from 'react-native';

import './src/delivery.ts';
import { keepGmailFresh } from './src/freshness.ts';
import { followNotificationActions, start } from './src/registration.ts';
import { InboxWindow, SettingsWindowRoot } from './src/window.tsx';

AppRegistry.registerComponent('UnwiredMail', () => InboxWindow);
AppRegistry.registerComponent('UnwiredSettings', () => SettingsWindowRoot);
// Starts the process-owned stores for a background launch without mounting an Inbox.
function Background() {
  return null;
}
AppRegistry.registerComponent('UnwiredBackground', () => Background);
// Every window's gate shows the Registration and remote content settings the host restores once
// here.
if (!previewInbox) {
  void start();
  // Archive and Mark as Read chosen on a notification act with no window open.
  followNotificationActions();
}
keepGmailFresh();
