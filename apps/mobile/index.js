import ExceptionsManager from 'react-native/Libraries/Core/ExceptionsManager';

import { errorReporting } from './src/registration.ts';
// Headless launches evaluate the entry without mounting Router layouts.
import './src/delivery.ts';
import './src/freshness.ts';
import 'expo-router/entry';

const forwardingGlobalErrors = [];
const previousErrorHandler = globalThis.ErrorUtils?.getGlobalHandler();
// oxlint-disable-next-line promise/prefer-await-to-callbacks -- React Native requires a synchronous global exception handler.
globalThis.ErrorUtils?.setGlobalHandler((error, fatal) => {
  errorReporting.capture(error);
  forwardingGlobalErrors.push(error);
  try {
    previousErrorHandler?.(error, fatal);
  } finally {
    forwardingGlobalErrors.pop();
  }
});
// Some runtime handlers bypass ExceptionsManager; others forward the same value.
const previousExceptionHandler = ExceptionsManager.handleException;
ExceptionsManager.handleException = (error, fatal) => {
  if (!forwardingGlobalErrors.includes(error)) {
    errorReporting.capture(error);
  }
  previousExceptionHandler(error, fatal);
};
