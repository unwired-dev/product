import type { TurboModule, processColor } from 'react-native';

import * as Schema from 'effect/Schema';
import { NativeEventEmitter, TurboModuleRegistry } from 'react-native';

import type { DomainSender } from './block-domain.tsx';

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
  readonly addListener: (eventName: string) => void;
  readonly removeListeners: (count: number) => void;
  // AppKit saves the window's Mail Profile with its restorable state.
  readonly setWindowProfile: (window: string, profile: string) => void;
  // Opens a New Message window editing the Draft, in the Mail Profile's scope; its Save Draft
  // returns the Draft to the `origin` Inbox window.
  readonly openComposer: (
    draft: string,
    profile: string,
    origin: string | null,
  ) => void;
  // Opens an Inbox window of the Mail Profile with the Draft in its composer.
  readonly openInbox: (profile: string, draft: string) => void;
  // Brings the window forward.
  readonly focusWindow: (window: string) => void;
  // Closes the window once its composer allows it; a refusal cancels a pending Quit.
  readonly finishClose: (window: string, allowed: boolean) => void;
  // Opens an IMAP connection's Spam and Trash choice as a sheet on the window, in the Mail
  // Profile's scope.
  readonly openFolderChoice: (
    window: string,
    connection: string,
    profile: string,
  ) => void;
  // Opens Block Domain… for a sender's address as a sheet on the Inbox window.
  readonly openBlockDomain: (window: string, sender: DomainSender) => void;
  // Sizes a sheet to its content's height, and ends it.
  readonly fitSheet: (sheet: string, height: number) => void;
  readonly closeSheet: (sheet: string) => void;
  // Reveals a saved file's `file://` URL in Finder.
  readonly showInFinder: (url: string) => void;
  // Shows or hides the Inbox window's sidebar, as its Show Sidebar / Hide Sidebar button does.
  readonly toggleSidebar: (window: string) => void;
  // Ends the marks the composer body shows for typing before a render, after a control edits it;
  // `body` is the body's testID.
  readonly forgetComposerTyping: (body: string) => void;
  // Highlights the body's `selection` in `color` while the body is not first responder; an empty
  // selection removes the highlight.
  readonly showComposerSelection: (
    body: string,
    selection: { readonly start: number; readonly end: number },
    // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- React Native's processed color type is mutable.
    color: ReturnType<typeof processColor>,
  ) => void;
  // Offers Format › Decrease Indent and Increase Indent while the body has focus; their choice
  // arrives as an `indent` event naming the body and the direction.
  readonly setComposerIndents: (
    body: string,
    outdent: boolean,
    indent: boolean,
  ) => void;
  // Where the body shows the character at `index`, in its own coordinates from its top left;
  // null once that body or character is gone.
  readonly composerCharacterFrame: (
    body: string,
    index: number,
  ) => Promise<{
    readonly x: number;
    readonly y: number;
    readonly width: number;
    readonly height: number;
  } | null>;
  // `Testing` builds only: writes one note of the Draft editor page's typing probe to the journey
  // evidence, its times converted from the page's clock to the app's (#2962).
  readonly recordPageProbe?: (
    note: Readonly<{
      event: 'text-edit' | 'text-drawn';
      epoch: number;
      frameEpoch?: number;
      text?: string;
      marks?: string;
    }>,
  ) => void;
  // `Testing` builds only: records when the next mount of the `rootTag` surface shows a
  // composer's format bar with its body's latest selection, for the selection-change journey;
  // `linkable` when the Link control is available.
  readonly recordSelectionShown?: (linkable: boolean, rootTag: number) => void;
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
