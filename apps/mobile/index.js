import ExceptionsManager from 'react-native/Libraries/Core/ExceptionsManager';

import { errorReporting } from './src/registration.ts';
// Headless launches evaluate the entry without mounting Router layouts.
import './src/delivery.ts';
import './src/freshness.ts';
import 'expo-router/entry';

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
