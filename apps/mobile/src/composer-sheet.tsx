import type { ReactNode } from 'react';

import { useEffect, useRef, useState } from 'react';
import { Modal, StyleSheet, View } from 'react-native';

import { InSheet, SheetPalette } from './command-palette.tsx';
import { ComposerPresentedContext } from './composer.tsx';
import { useComposerNavigation } from './mailbox.tsx';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({ fill: { flex: 1 } });

// On iPhone and in a compact iPad window the composer is the system sheet over the mail. Its
// dismissal gesture leaves the composer as Close does: the sheet stays up while the composer asks
// about changes. The sheet sliding away still shows the composer it closed, so a command chosen in
// its palette runs once the composer has closed, unless another destination was chosen meanwhile,
// such as the same Draft opened again.
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
  const navigation = useComposerNavigation();
  const [shown, setShown] = useState(draft);
  if (draft !== undefined && draft !== shown) {
    setShown(draft);
  }
  const presented = draft !== undefined;
  const open = useRef(presented);
  // Commands waiting for the composer to close; one left when the sheet goes away never runs.
  const closed = useRef<Array<(left: boolean) => void>>([]);
  const removed = useRef(false);
  useEffect(() => {
    open.current = presented;
    if (!presented) {
      for (const resolve of closed.current.splice(0)) {
        resolve(true);
      }
    }
  }, [presented]);
  useEffect(
    () => () => {
      removed.current = true;
      for (const resolve of closed.current.splice(0)) {
        resolve(false);
      }
    },
    [],
  );
  const leave = async () => {
    if (!(await navigation.leave())) {
      return false;
    }
    const turn = navigation.navigations();
    const left =
      !removed.current &&
      (!open.current ||
        // oxlint-disable-next-line promise/avoid-new -- The command waits for the composer to close.
        (await new Promise<boolean>((resolve) => {
          closed.current.push(resolve);
        })));
    return left && navigation.navigations() === turn;
  };
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
          <InSheet value>
            <ComposerPresentedContext value={presented}>
              {composer(shown)}
            </ComposerPresentedContext>
          </InSheet>
          <SheetPalette leave={leave} />
        </View>
      )}
    </Modal>
  );
}
