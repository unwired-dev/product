import 'fast-text-encoding';
import './src/reporting-bootstrap.js';
import { startAssistanceQualification } from '@private-email/mail-core/assistance-qualification';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import { AppRegistry, TurboModuleRegistry } from 'react-native';

import './src/delivery.ts';
import { keepGmailFresh } from './src/freshness.ts';
import { followNotificationActions, start } from './src/registration.ts';
import { InboxWindow, SettingsWindowRoot } from './src/window.tsx';

AppRegistry.registerComponent('UnwiredMail', () => InboxWindow);
AppRegistry.registerComponent('UnwiredSettings', () => SettingsWindowRoot);
// Every window's gate shows the Registration and remote content settings the host restores once
// here.
if (!previewInbox) {
  void start();
  // Archive and Mark as Read chosen on a notification act with no window open.
  followNotificationActions();
}
keepGmailFresh();
// Only the assistance qualification build runs its synthetic corpus, once per launch.
startAssistanceQualification(() => ({
  assistance: TurboModuleRegistry.getEnforcing('UnwiredAssistance'),
  qualification: TurboModuleRegistry.getEnforcing(
    'UnwiredAssistanceQualification',
  ),
}));
