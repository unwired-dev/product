import { defaultProfile } from '@private-email/mail-core/registration';
import { useState } from 'react';
import { StyleSheet, View } from 'react-native';

import type { Selection } from './inbox.tsx';

import { CommandBar, CommandPaletteProvider } from './command-palette.tsx';
import { DraftComposer } from './evaluation-composer.tsx';
import { Inbox } from './inbox.tsx';
import { InboxProvider, ProfileScope, useMailboxes } from './mailbox.tsx';
import { LinkConfirmationProvider } from './message-body.tsx';
import { MessageDetail } from './message-detail.tsx';
import { RegistrationGate } from './registration-gate.tsx';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  fill: { flex: 1 },
  window: { flex: 1 },
  panes: { flex: 1, flexDirection: 'row' },
  sidebar: { width: 320, borderRightWidth: StyleSheet.hairlineWidth },
  detail: { flex: 1 },
});

type WindowProps = Readonly<{
  windowId: string;
  // The window's Mail Profile. Native windows name none and show the Default Profile until #647
  // lets the person open another.
  profile?: string;
}>;

export function PreviewWindow({
  windowId,
  profile = defaultProfile,
}: WindowProps) {
  return (
    <CommandPaletteProvider windowId={windowId}>
      <ProfileWindow
        windowId={windowId}
        profile={profile}
      />
    </CommandPaletteProvider>
  );
}

function ProfileWindow({
  windowId,
  profile,
}: {
  readonly windowId: string;
  readonly profile: string;
}) {
  return (
    <InboxProvider>
      <ProfileScope profile={profile}>
        <WindowContents windowId={windowId} />
      </ProfileScope>
    </InboxProvider>
  );
}

function WindowContents({ windowId }: { readonly windowId: string }) {
  const [selected, setSelected] = useState<Selection>();
  // The window's one composer replaces the reader while it is open.
  const [composing, setComposing] = useState<string>();
  const inbox = useMailboxes().find(
    (mailbox) => mailbox.id === selected?.mailbox,
  )?.inbox;
  const colors = usePalette();
  // Opening a Draft from either pane replaces the reader with the window's composer.
  const compose = (id: string) => {
    setSelected(undefined);
    setComposing(id);
  };
  // Either pane closes the reader when its message leaves the Inbox.
  const close = () => {
    setSelected(undefined);
  };
  return (
    <View
      testID={`inbox-window-${windowId}`}
      style={styles.fill}>
      <LinkConfirmationProvider
        inbox={inbox}
        id={selected?.id}>
        <View style={styles.window}>
          <CommandBar />
          <View style={styles.panes}>
            <View
              style={[styles.sidebar, { borderRightColor: colors.separator }]}>
              <Inbox
                composing={composing}
                selected={selected}
                onClose={close}
                onCompose={compose}
                onSelect={(selection) => {
                  setComposing(undefined);
                  setSelected(selection);
                }}
              />
            </View>
            <View style={styles.detail}>
              {composing === undefined ? (
                <MessageDetail
                  id={selected?.id}
                  mailbox={selected?.mailbox}
                  onClose={close}
                  onCompose={compose}
                />
              ) : (
                <DraftComposer
                  id={composing}
                  onClose={() => {
                    setComposing(undefined);
                  }}
                  onRebind={setComposing}
                />
              )}
            </View>
          </View>
        </View>
      </LinkConfirmationProvider>
    </View>
  );
}

export function InboxWindow({
  windowId,
  profile = defaultProfile,
}: WindowProps) {
  // The window's Command Palette stays above the gate, so the account page keeps it.
  return (
    <CommandPaletteProvider windowId={windowId}>
      <RegistrationGate>
        <ProfileWindow
          windowId={windowId}
          profile={profile}
        />
      </RegistrationGate>
    </CommandPaletteProvider>
  );
}
