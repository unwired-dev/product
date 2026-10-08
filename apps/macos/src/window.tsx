import { useState } from 'react';
import { StyleSheet, View } from 'react-native';

import type { Selection } from './inbox.tsx';

import { Composer } from './composer.tsx';
import { Inbox } from './inbox.tsx';
import { InboxProvider } from './mailbox.tsx';
import { MessageDetail } from './message-detail.tsx';
import { RegistrationGate } from './registration-gate.tsx';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  window: { flex: 1, flexDirection: 'row' },
  sidebar: { width: 320, borderRightWidth: StyleSheet.hairlineWidth },
  detail: { flex: 1 },
});

export function PreviewWindow({ windowId }: { readonly windowId: string }) {
  const [selected, setSelected] = useState<Selection>();
  // The window's one composer replaces the reader while it is open.
  const [composing, setComposing] = useState<string>();
  const colors = usePalette();
  // Either pane closes the reader when its message leaves the Inbox.
  const close = () => {
    setSelected(undefined);
  };
  return (
    <InboxProvider>
      <View
        testID={`inbox-window-${windowId}`}
        style={styles.window}>
        <View style={[styles.sidebar, { borderRightColor: colors.separator }]}>
          <Inbox
            composing={composing}
            selected={selected}
            onClose={close}
            onCompose={(id) => {
              setSelected(undefined);
              setComposing(id);
            }}
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
    </InboxProvider>
  );
}

export function InboxWindow({ windowId }: { readonly windowId: string }) {
  return (
    <RegistrationGate>
      <PreviewWindow windowId={windowId} />
    </RegistrationGate>
  );
}
