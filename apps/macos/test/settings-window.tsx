import type { ReactNode } from 'react';

import { act, screen, within } from '@testing-library/react-native';
import { useSyncExternalStore } from 'react';
import { TurboModuleRegistry, View } from 'react-native';

import { SettingsWindowRoot } from '../src/window.tsx';

// AppKit's Settings window beside the Inbox windows: UnwiredCommands' openSettings shows its React
// surface, and closeSettings or its close button removes it.
let shown = false;
let focused = 0;
const listeners = new Set<() => void>();
const show = (next: boolean) => {
  shown = next;
  for (const listener of listeners) {
    listener();
  }
};
const host = {
  openSettings: () => {
    show(true);
  },
  closeSettings: () => {
    show(false);
  },
  focusInbox: () => {
    focused += 1;
  },
  // The rest of UnwiredCommands, which the windows' Command Palettes use.
  addListener: () => undefined,
  removeListeners: () => undefined,
  saveFocus: () => undefined,
  restoreFocus: () => undefined,
  guardClose: () => undefined,
  finishClose: () => undefined,
};

const { get } = TurboModuleRegistry;
beforeEach(() => {
  Reflect.set(TurboModuleRegistry, 'get', (name: string) =>
    name === 'UnwiredCommands' ? host : get(name),
  );
});
afterEach(() => {
  Reflect.set(TurboModuleRegistry, 'get', get);
  shown = false;
  focused = 0;
});

// The app's windows: the given Inbox window, and the Settings window while it is open.
export function MacWindows({
  children,
  ...gate
}: Parameters<typeof SettingsWindowRoot>[0] & {
  readonly children: ReactNode;
}) {
  const open = useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    () => shown,
  );
  return (
    <>
      {children}
      {open ? (
        <View testID="settings-window">
          <SettingsWindowRoot {...gate} />
        </View>
      ) : null}
    </>
  );
}

export const settingsWindow = () =>
  within(screen.getByTestId('settings-window'));

export const settingsOpen = () =>
  screen.queryByTestId('settings-window') !== null;

// How often the Settings window brought an Inbox window forward.
export const inboxFocused = () => focused;

// Command-, opens the Settings window, or brings it forward, without naming a destination.
export const commandComma = async () => {
  await act(async () => {
    host.openSettings();
    await Promise.resolve();
  });
};

// The Settings window's close button.
export const closeSettings = async () => {
  await act(async () => {
    show(false);
    await Promise.resolve();
  });
};
