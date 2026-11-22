import type { ReactNode } from 'react';

import { useEffect, useRef, useState } from 'react';
import { Modal, StyleSheet, View } from 'react-native';

import { InSheet, SheetPalette } from './command-palette.tsx';
import { useLeaveComposer } from './mailbox.tsx';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({ fill: { flex: 1 } });

// On iPhone and in a compact iPad window the composer is the system sheet over the mail. Its
// dismissal gesture leaves the composer as Close does: the sheet stays up while the composer asks
// about changes. The sheet sliding away still shows the composer it closed, so a command chosen in
// its palette runs once the sheet is gone, and not at all when the sheet opens a Draft again.
export function ComposerSheet({
  draft,
  onLeave,
  composer,
}: Readonly<{
  draft: string | undefined;
  onLeave: () => void;
  composer: (draft: string) => ReactNode;
}>) {
  const colors = usePalette();
  const leaveComposer = useLeaveComposer();
  const [shown, setShown] = useState(draft);
  if (draft !== undefined && draft !== shown) {
    setShown(draft);
  }
  const gone = useRef<Array<(dismissed: boolean) => void>>([]);
  useEffect(() => {
    for (const resolve of gone.current.splice(0)) {
      resolve(shown === undefined);
    }
  }, [shown]);
  const leave = async () =>
    (await leaveComposer()) &&
    // oxlint-disable-next-line promise/avoid-new -- The command waits for the sheet to go.
    new Promise<boolean>((resolve) => {
      gone.current.push(resolve);
    });
  return (
    <Modal
      testID="composer-sheet"
      visible={draft !== undefined}
      presentationStyle="pageSheet"
      animationType="slide"
      // Without this the Modal holds iPhone in portrait; the app turns with the device.
      supportedOrientations={[
        'portrait',
        'portrait-upside-down',
        'landscape-left',
        'landscape-right',
      ]}
      onRequestClose={onLeave}
      onDismiss={() => {
        setShown(draft);
      }}>
      {shown === undefined ? null : (
        <View
          testID="composer-overlay"
          pointerEvents={draft === undefined ? 'none' : 'auto'}
          style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
          <InSheet value>{composer(shown)}</InSheet>
          <SheetPalette leave={leave} />
        </View>
      )}
    </Modal>
  );
}
