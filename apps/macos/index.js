import 'fast-text-encoding';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import { AppRegistry } from 'react-native';

import './src/delivery.ts';
import ExceptionsManager from 'react-native/Libraries/Core/ExceptionsManager';

import { keepGmailFresh } from './src/freshness.ts';
import { errorReporting } from './src/registration.ts';
import { start } from './src/registration.ts';
import { InboxWindow, SettingsWindowRoot } from './src/window.tsx';

AppRegistry.registerComponent('UnwiredMail', () => InboxWindow);
AppRegistry.registerComponent('UnwiredSettings', () => SettingsWindowRoot);
// Every window's gate shows the Registration and remote content settings the host restores once
// here.
if (!previewInbox) {
  void start();
}
keepGmailFresh();

const previousErrorHandler = globalThis.ErrorUtils?.getGlobalHandler();
// oxlint-disable-next-line promise/prefer-await-to-callbacks -- React Native requires a synchronous global exception handler.
globalThis.ErrorUtils?.setGlobalHandler((error, fatal) => {
  errorReporting.capture(error);
  previousErrorHandler?.(error, fatal);
});
// Capture React Native's explicit exception path before native handling, including
// rejection errors surfaced by the runtime. Console reporting has its own path.
const previousExceptionHandler = ExceptionsManager.handleException;
ExceptionsManager.handleException = (error, fatal) => {
  errorReporting.capture(error);
  previousExceptionHandler(error, fatal);
};
