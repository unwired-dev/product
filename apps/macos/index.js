import 'fast-text-encoding';
import './src/reporting-bootstrap.js';
import { startAssistanceQualification } from '@private-email/mail-core/assistance-qualification';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import { AppRegistry, TurboModuleRegistry } from 'react-native';

import './src/delivery.ts';
import { keepGmailFresh } from './src/freshness.ts';
import { followNotificationActions, start } from './src/registration.ts';
import { windowHost } from './src/settings-window-client.ts';
import {
  ComposerWindowRoot,
  FolderChoiceWindowRoot,
  InboxWindow,
  SettingsWindowRoot,
} from './src/window.tsx';

AppRegistry.registerComponent('UnwiredMail', () => InboxWindow);
AppRegistry.registerComponent('UnwiredSettings', () => SettingsWindowRoot);
AppRegistry.registerComponent('UnwiredComposer', () => ComposerWindowRoot);
AppRegistry.registerComponent(
  'UnwiredFolderChoice',
  () => FolderChoiceWindowRoot,
);
// Every window's gate shows the Registration and remote content settings the host restores once
// here.
if (!previewInbox) {
  void start();
  // Archive, Mark as Read and a typed reply chosen on a notification act with no window open;
  // Open Draft opens the reply's Draft in its own New Message window.
  followNotificationActions((draft, profile) => {
    windowHost()?.openComposer(draft, profile);
  });
}
keepGmailFresh();
// Only the assistance qualification build runs its synthetic corpus, once per launch.
startAssistanceQualification(() => ({
  assistance: TurboModuleRegistry.getEnforcing('UnwiredAssistance'),
  qualification: TurboModuleRegistry.getEnforcing(
    'UnwiredAssistanceQualification',
  ),
}));
