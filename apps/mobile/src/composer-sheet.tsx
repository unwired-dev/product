import type { ReactNode } from 'react';

import { useState } from 'react';
import { Modal, StyleSheet, View } from 'react-native';

import {
  InSheet,
  SheetPalette,
  useCloseSheetPalette,
} from './command-palette.tsx';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({ fill: { flex: 1 } });

// On iPhone and in a compact iPad window the composer is the system sheet over the mail. Its
// dismissal gesture leaves the composer as Close does: the sheet stays up while the composer asks
// about changes. The sheet sliding away still shows the composer it closed.
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
  const closePalette = useCloseSheetPalette();
  const [shown, setShown] = useState(draft);
  if (draft !== undefined && draft !== shown) {
    setShown(draft);
  }
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
      onRequestClose={() => {
        closePalette();
        onLeave();
      }}
      onDismiss={() => {
        setShown(draft);
      }}>
      {shown === undefined ? null : (
        <View
          testID="composer-overlay"
          pointerEvents={draft === undefined ? 'none' : 'auto'}
          style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
          <InSheet value>{composer(shown)}</InSheet>
          <SheetPalette />
        </View>
      )}
    </Modal>
  );
}
