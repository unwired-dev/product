import type { ReactNode } from 'react';

import { useEffect, useRef, useState } from 'react';
import { Modal, Platform, StyleSheet, View } from 'react-native';

import { InSheet, SheetPalette } from './command-palette.tsx';
import { ComposerPresentedContext } from './composer.tsx';
import { SheetGrabber } from './design.tsx';
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
  // Commands waiting for the composer to close, each with the navigation it left at: a later one
  // chose another destination, and one left when the sheet goes away never runs.
  const closed = useRef<
    Array<Readonly<{ turn: number; resolve: (left: boolean) => void }>>
  >([]);
  const removed = useRef(false);
  const settle = () => {
    const turn = navigation.navigations();
    closed.current = closed.current.filter((waiting) => {
      const superseded = waiting.turn !== turn;
      if (superseded || !open.current) {
        waiting.resolve(!superseded);
      }
      return !superseded && open.current;
    });
  };
  useEffect(() => {
    open.current = presented;
    settle();
  });
  useEffect(
    () => () => {
      removed.current = true;
      for (const { resolve } of closed.current.splice(0)) {
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
    return (
      !removed.current &&
      (!open.current ||
        // oxlint-disable-next-line promise/avoid-new -- The command waits for the composer to close.
        new Promise<boolean>((resolve) => {
          closed.current.push({ turn, resolve });
        }))
    );
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
      // A command already closing the sheet stands for its swipe.
      onRequestClose={() => {
        settle();
        if (closed.current.length === 0) {
          onLeave();
        }
      }}
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
          {Platform.OS === 'ios' && !Platform.isPad ? <SheetGrabber /> : null}
        </View>
      )}
    </Modal>
  );
}
