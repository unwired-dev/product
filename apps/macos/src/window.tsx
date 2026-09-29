import { useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { Inbox } from './inbox.tsx';
import { MessageDetail } from './message-detail.tsx';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  window: { flex: 1, flexDirection: 'row' },
  sidebar: { width: 320, borderRightWidth: StyleSheet.hairlineWidth },
  detail: { flex: 1 },
});

export function InboxWindow({ windowId }: { readonly windowId: string }) {
  const [selectedId, setSelectedId] = useState<string>();
  const colors = usePalette();
  return (
    <View
      testID={`inbox-window-${windowId}`}
      style={styles.window}>
      <View style={[styles.sidebar, { borderRightColor: colors.separator }]}>
        <Inbox
          selectedId={selectedId}
          onSelect={setSelectedId}
        />
      </View>
      <View style={styles.detail}>
        <MessageDetail id={selectedId} />
      </View>
    </View>
  );
}
