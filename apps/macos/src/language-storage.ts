import type {
  LanguageSettings,
  LanguageStorage,
} from '@private-email/localization';
import type { TurboModule } from 'react-native';

import {
  AppState,
  NativeEventEmitter,
  TurboModuleRegistry,
} from 'react-native';

interface NativeLocalization extends TurboModule, LanguageStorage {
  readonly getConstants: () => LanguageSettings;
  readonly addListener: (eventName: string) => void;
  readonly removeListeners: (count: number) => void;
}

const native = TurboModuleRegistry.getEnforcing<NativeLocalization>(
  'UnwiredLocalization',
);
export const languageStorage = {
  initial: native.getConstants(),
  getSettings: () => native.getSettings(),
  setLanguage: (language: string | null) => native.setLanguage(language),
  subscribe(refresh: () => void) {
    AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        refresh();
      }
    });
    new NativeEventEmitter(native).addListener(
      'languageSettingsChanged',
      refresh,
    );
  },
};
