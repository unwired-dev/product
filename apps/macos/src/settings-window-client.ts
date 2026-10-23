import type { TurboModule } from 'react-native';

import * as Schema from 'effect/Schema';
import { NativeEventEmitter, TurboModuleRegistry } from 'react-native';

interface SettingsHost extends TurboModule {
  readonly addListener: (eventName: string) => void;
  readonly removeListeners: (count: number) => void;
  readonly openSettings: (requestSerial: number) => void;
  readonly closeSettings: () => void;
  readonly focusInbox: () => void;
}

export const settingsHost = () =>
  TurboModuleRegistry.get<SettingsHost>('UnwiredCommands');

interface WindowHost extends TurboModule {
  // AppKit saves the window's Mail Profile with its restorable state.
  readonly setWindowProfile: (window: string, profile: string) => void;
}

export const windowHost = () =>
  TurboModuleRegistry.get<WindowHost>('UnwiredCommands');

const isRequestSerial = Schema.is(Schema.Int);
let observing = false;

// The process-wide request outlives window roots, including delayed native close events.
export function observeSettingsClose(retire: (serial: number) => void) {
  const host = settingsHost();
  if (observing || host === null) {
    return;
  }
  observing = true;
  new NativeEventEmitter(host).addListener(
    'settingsClosed',
    (value: unknown) => {
      if (isRequestSerial(value)) {
        retire(value);
      }
    },
  );
}
