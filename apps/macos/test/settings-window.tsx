import type { ReactNode } from 'react';

import { act, screen, within } from '@testing-library/react-native';
import { useSyncExternalStore } from 'react';
import { DeviceEventEmitter, TurboModuleRegistry, View } from 'react-native';

import type { InboxProvider } from '../src/mailbox.tsx';

import { FolderChoiceWindowRoot, SettingsWindowRoot } from '../src/window.tsx';

// AppKit's Settings window beside the Inbox windows: UnwiredCommands' openSettings shows its React
// surface, and closeSettings or its close button removes it.
let shown = false;
let focused = 0;
let openings = 0;
let requestSerial = 0;
let holdOpen = false;
let pendingOpen: (() => void) | undefined = undefined;
// The New Message windows Expand asked AppKit to open, and the windows JavaScript closed.
const composers: Array<{ draft: string; profile: string }> = [];
const closed: string[] = [];
// The Inbox windows whose sidebar JavaScript asked AppKit to show or hide.
const sidebarToggles: string[] = [];
// The Choose Folders… sheet AppKit shows on an Inbox window.
let sheet: { window: string; connection: string; profile: string } | undefined =
  undefined;
const listeners = new Set<() => void>();
const show = (next: boolean) => {
  shown = next;
  for (const listener of listeners) {
    listener();
  }
};
const host = {
  openSettings: (serial?: number) => {
    openings += 1;
    const open = () => {
      requestSerial = serial ?? requestSerial;
      show(true);
    };
    if (holdOpen) {
      pendingOpen = open;
    } else {
      open();
    }
  },
  closeSettings: () => {
    DeviceEventEmitter.emit('settingsClosed', requestSerial);
    requestSerial = 0;
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
  finishClose: (window: string, allowed: boolean) => {
    if (allowed) {
      closed.push(window);
    }
  },
  setWindowProfile: () => undefined,
  openComposer: (draft: string, profile: string) => {
    composers.push({ draft, profile });
  },
  toggleSidebar: (window: string) => {
    sidebarToggles.push(window);
  },
  forgetComposerTyping: () => undefined,
  openFolderChoice: (window: string, connection: string, profile: string) => {
    if (sheet === undefined) {
      sheet = { window: `${window}-folder-choice`, connection, profile };
      show(shown);
    }
  },
  fitSheet: () => undefined,
  closeSheet: (window: string) => {
    if (sheet?.window === window) {
      sheet = undefined;
      show(shown);
    }
  },
};

const { get } = TurboModuleRegistry;
beforeEach(() => {
  Reflect.set(TurboModuleRegistry, 'get', (name: string) =>
    name === 'UnwiredCommands' ? host : get(name),
  );
});
afterEach(() => {
  host.closeSettings();
  Reflect.set(TurboModuleRegistry, 'get', get);
  shown = false;
  focused = 0;
  openings = 0;
  requestSerial = 0;
  holdOpen = false;
  pendingOpen = undefined;
  composers.length = 0;
  closed.length = 0;
  sidebarToggles.length = 0;
  sheet = undefined;
});

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};

// The app's windows: the given Inbox window, the Settings window while it is open, and the
// Choose Folders… sheet over `mailboxes` while AppKit shows it.
export function MacWindows({
  children,
  mailboxes,
  ...gate
}: Parameters<typeof SettingsWindowRoot>[0] & {
  readonly children: ReactNode;
  readonly mailboxes?: Parameters<typeof InboxProvider>[0]['mailboxes'];
}) {
  const open = useSyncExternalStore(subscribe, () => shown);
  const choice = useSyncExternalStore(subscribe, () => sheet);
  return (
    <>
      {children}
      {open ? (
        <View testID="settings-window">
          <SettingsWindowRoot {...gate} />
        </View>
      ) : null}
      {choice === undefined ? null : (
        <View testID="folder-choice-sheet">
          <FolderChoiceWindowRoot
            {...gate}
            {...(mailboxes === undefined ? {} : { inbox: { mailboxes } })}
            window={choice.window}
            connection={choice.connection}
            profile={choice.profile}
          />
        </View>
      )}
    </>
  );
}

export const folderChoiceSheet = () =>
  within(screen.getByTestId('folder-choice-sheet'));

// The Choose Folders… sheet, or null while none is shown.
export const folderChoice = () => screen.queryByTestId('folder-choice-sheet');

export const settingsWindow = () =>
  within(screen.getByTestId('settings-window'));

export const settingsOpen = () =>
  screen.queryByTestId('settings-window') !== null;

export const composerWindows = (): ReadonlyArray<{
  readonly draft: string;
  readonly profile: string;
}> => composers;
export const closedWindows = (): readonly string[] => closed;

export const toggledSidebars = (): readonly string[] => sidebarToggles;

// How often JavaScript asked AppKit to open the Settings window, or bring it forward.
export const settingsOpenings = () => openings;

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
    host.closeSettings();
    await Promise.resolve();
  });
};

// AppKit has closed the old window, but JS can render a new request before its root tears down.
// The native open and old close notification are deliberately delivered after that teardown.
export const reopenSettingsWhileClosing = async (reopen: () => void) => {
  const closedSerial = requestSerial;
  holdOpen = true;
  await act(async () => {
    reopen();
  });
  await act(async () => {
    show(false);
  });
  holdOpen = false;
  await act(async () => {
    pendingOpen?.();
    pendingOpen = undefined;
  });
  await act(async () => {
    DeviceEventEmitter.emit('settingsClosed', closedSerial);
  });
};
