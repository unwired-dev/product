import { defaultProfile } from '@private-email/mail-core/registration';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useState } from 'react';
import { StyleSheet, View } from 'react-native';

import type { Selection } from './inbox.tsx';

import { DraftComposer } from './evaluation-composer.tsx';
import { Inbox } from './inbox.tsx';
import { InboxProvider, ProfileScope } from './mailbox.tsx';
import { MessageDetail } from './message-detail.tsx';
import { RegistrationGate } from './registration-gate.tsx';
import { usePalette } from './theme.ts';

// The composer overlays the reading pane with 12pt insets at 70% of the window's height,
// clamped from 420 to 720pt; expanded, it takes over the window.
const sidebarWidth = 320;
const composerInset = spacing.m;
const composerHeight = (windowHeight: number) =>
  Math.min(
    Math.max(0, windowHeight - 2 * composerInset),
    Math.min(720, Math.max(420, windowHeight * 0.7)),
  );

const styles = StyleSheet.create({
  window: { flex: 1, flexDirection: 'row' },
  sidebar: { width: sidebarWidth, borderRightWidth: StyleSheet.hairlineWidth },
  detail: { flex: 1 },
  composer: {
    position: 'absolute',
    overflow: 'hidden',
    borderWidth: StyleSheet.hairlineWidth,
  },
  composerOverlay: {
    left: sidebarWidth + composerInset,
    right: composerInset,
    bottom: composerInset,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
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
  // The window's one composer overlays the reader while it is open.
  const [composing, setComposing] = useState<string>();
  const [expanded, setExpanded] = useState(false);
  const [height, setHeight] = useState(0);
  const colors = usePalette();
  // Opening a Draft from either pane shows it in the window's composer, over the reader.
  const compose = (id: string) => {
    setComposing(id);
  };
  // Either pane closes the reader when its message leaves the Inbox.
  const close = () => {
    setSelected(undefined);
  };
  return (
    <View
      testID={`inbox-window-${windowId}`}
      onLayout={({ nativeEvent }) => {
        setHeight(nativeEvent.layout.height);
      }}
      style={styles.window}>
      <View
        pointerEvents={expanded ? 'none' : 'auto'}
        accessibilityElementsHidden={expanded}
        style={[styles.sidebar, { borderRightColor: colors.separator }]}>
        <Inbox
          composing={composing}
          selected={selected}
          onClose={close}
          onCompose={compose}
          onSelectBehindComposer={
            composing === undefined ? undefined : setSelected
          }
          onSelect={(selection) => {
            setComposing(undefined);
            setSelected(selection);
          }}
        />
      </View>
      <View
        // The covered reader waits; the sidebar stays interactive beneath the overlay.
        pointerEvents={composing === undefined ? 'auto' : 'none'}
        accessibilityElementsHidden={composing !== undefined}
        style={styles.detail}>
        <MessageDetail
          id={selected?.id}
          mailbox={selected?.mailbox}
          onClose={close}
          onCompose={compose}
        />
      </View>
      {composing === undefined ? null : (
        <View
          testID="composer-overlay"
          style={[
            styles.composer,
            expanded
              ? StyleSheet.absoluteFill
              : [styles.composerOverlay, { height: composerHeight(height) }],
            { borderColor: colors.separator, boxShadow: colors.sheetShadow },
          ]}>
          <DraftComposer
            id={composing}
            expanded={expanded}
            onClose={() => {
              setComposing(undefined);
              setExpanded(false);
            }}
            onExpand={() => {
              setExpanded((current) => !current);
            }}
            onRebind={setComposing}
          />
        </View>
      )}
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
