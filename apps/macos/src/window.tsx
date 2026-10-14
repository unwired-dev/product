import { defaultProfile } from '@private-email/mail-core/registration';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useState } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';

import type { Selection } from './inbox.tsx';
import type { MailboxView } from './sidebar.tsx';

import { CommandBar, CommandPaletteProvider } from './command-palette.tsx';
import { GlassGroup, SFSymbol } from './design.tsx';
import { DraftComposer } from './evaluation-composer.tsx';
import { Inbox } from './inbox.tsx';
import { useLocalization } from './localization.ts';
import { InboxProvider, ProfileScope, useMailboxes } from './mailbox.tsx';
import { LinkConfirmationProvider } from './message-body.tsx';
import { MessageDetail } from './message-detail.tsx';
import { RegistrationGate } from './registration-gate.tsx';
import { Mailboxes } from './sidebar.tsx';
import { usePalette } from './theme.ts';

// A window narrower than this hides the sidebar until it is shown again.
const narrowWindow = 900;

const styles = StyleSheet.create({
  fill: { flex: 1 },
  window: { flex: 1 },
  panes: { flex: 1, flexDirection: 'row' },
  // The floating glass sidebar, inset from the window edges.
  sidebar: {
    alignSelf: 'stretch',
    width: 236,
    margin: spacing.s,
    padding: 0,
    borderRadius: radius.window,
    borderCurve: 'continuous',
  },
  list: { width: 340, borderRightWidth: StyleSheet.hairlineWidth },
  detail: { flex: 1 },
  toggle: { margin: spacing.m, marginRight: 0 },
  toggleTarget: {
    width: 28,
    height: 28,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 1,
    borderRadius: 14,
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

function SidebarToggle({
  shown,
  onPress,
}: {
  readonly shown: boolean;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [focused, setFocused] = useState(false);
  return (
    <GlassGroup style={styles.toggle}>
      <Pressable
        accessibilityLabel={t(
          shown ? 'native.hideSidebar' : 'native.showSidebar',
        )}
        accessibilityRole="button"
        focusable
        onBlur={() => {
          setFocused(false);
        }}
        onFocus={() => {
          setFocused(true);
        }}
        onPress={onPress}
        style={[
          styles.toggleTarget,
          { borderColor: focused ? colors.accentInk : 'transparent' },
        ]}>
        <SFSymbol
          name="sidebar.leading"
          color={colors.accentInk}
        />
      </Pressable>
    </GlassGroup>
  );
}

function WindowContents({ windowId }: { readonly windowId: string }) {
  const [selected, setSelected] = useState<Selection>();
  // The window's one composer replaces the reader while it is open.
  const [composing, setComposing] = useState<string>();
  const [view, setView] = useState<MailboxView>({});
  const [width, setWidth] = useState<number>();
  // The sidebar follows the window width until the toggle chooses for it.
  const [sidebar, setSidebar] = useState<boolean>();
  const sidebarShown = sidebar ?? (width === undefined || width > narrowWindow);
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
      onLayout={({ nativeEvent }) => {
        setWidth(nativeEvent.layout.width);
      }}
      style={styles.fill}>
      <LinkConfirmationProvider
        inbox={inbox}
        id={selected?.id}>
        <View
          style={[styles.window, { backgroundColor: colors.surfaceSidebar }]}>
          <CommandBar />
          <View style={styles.panes}>
            {sidebarShown ? (
              <GlassGroup
                style={[
                  styles.sidebar,
                  { boxShadow: colors.largeGlassShadow },
                ]}>
                <Mailboxes
                  view={view}
                  onView={setView}
                />
              </GlassGroup>
            ) : null}
            <View
              style={[
                styles.list,
                {
                  backgroundColor: colors.surfaceContent,
                  borderRightColor: colors.separator,
                },
              ]}>
              <Inbox
                composing={composing}
                leading={
                  <SidebarToggle
                    shown={sidebarShown}
                    onPress={() => {
                      setSidebar(!sidebarShown);
                    }}
                  />
                }
                selected={selected}
                onClose={close}
                onCompose={compose}
                onSelect={(selection) => {
                  setComposing(undefined);
                  setSelected(selection);
                }}
                onView={setView}
                view={view}
              />
            </View>
            <View
              style={[
                styles.detail,
                { backgroundColor: colors.surfaceContent },
              ]}>
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
