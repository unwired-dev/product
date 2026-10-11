import { defaultProfile } from '@private-email/mail-core/registration';
import { useState } from 'react';
import { StyleSheet, View } from 'react-native';

import type { Selection } from './inbox.tsx';

import { Composer } from './composer.tsx';
import { Inbox } from './inbox.tsx';
import { InboxProvider, ProfileScope } from './mailbox.tsx';
import { MessageDetail } from './message-detail.tsx';
import { RegistrationGate } from './registration-gate.tsx';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  window: { flex: 1, flexDirection: 'row' },
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
      style={styles.window}>
      <View style={[styles.sidebar, { borderRightColor: colors.separator }]}>
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
          <Composer
            id={composing}
            onClose={() => {
              setComposing(undefined);
            }}
            onRebind={setComposing}
          />
        )}
      </View>
    </View>
  );
}

export function InboxWindow(props: WindowProps) {
  return (
    <RegistrationGate>
      <PreviewWindow {...props} />
    </RegistrationGate>
  );
}
