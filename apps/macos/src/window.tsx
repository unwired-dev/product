import { defaultProfile } from '@private-email/mail-core/registration';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useState } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';

import type { Selection } from './inbox.tsx';
import type { MailboxView } from './sidebar.tsx';

import { CategorizationSpike } from './categorization-spike.ts';
import { CommandBar, CommandPaletteProvider } from './command-palette.tsx';
import { GlassGroup, SFSymbol } from './design.tsx';
import { DraftComposer } from './evaluation-composer.tsx';
import { Inbox } from './inbox.tsx';
import { useLocalization } from './localization.ts';
import { InboxProvider, ProfileScope, useMailboxes } from './mailbox.tsx';
import { LinkConfirmationProvider } from './message-body.tsx';
import { MessageDetail } from './message-detail.tsx';
import { RegistrationGate, SettingsGate } from './registration-gate.tsx';
import { settingsHost, useSettingsRequest } from './settings-window.ts';
import { Mailboxes } from './sidebar.tsx';
import { usePalette } from './theme.ts';

// A window narrower than this hides the sidebar until it is shown again.
const narrowWindow = 900;
const sidebarWidth = 236;
const listWidth = 340;
// The composer overlays the reading pane with 12pt insets at 70% of the panes' height,
// clamped from 420 to 720pt; expanded, it takes over the panes beneath the command bar.
const composerInset = spacing.m;
const composerHeight = (panesHeight: number) =>
  Math.min(
    Math.max(0, panesHeight - 2 * composerInset),
    Math.min(720, Math.max(420, panesHeight * 0.7)),
  );

const styles = StyleSheet.create({
  fill: { flex: 1 },
  window: { flex: 1 },
  panes: { flex: 1, flexDirection: 'row' },
  // The floating glass sidebar, inset from the window edges.
  sidebar: {
    alignSelf: 'stretch',
    width: sidebarWidth,
    margin: spacing.s,
    padding: 0,
    borderRadius: radius.window,
    borderCurve: 'continuous',
    backgroundColor: 'transparent',
  },
  list: { width: listWidth, borderRightWidth: StyleSheet.hairlineWidth },
  detail: { flex: 1 },
  composer: {
    position: 'absolute',
    overflow: 'hidden',
    borderWidth: StyleSheet.hairlineWidth,
  },
  composerOverlay: {
    right: composerInset,
    bottom: composerInset,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  toggle: {
    margin: spacing.m,
    marginRight: 0,
    backgroundColor: 'transparent',
  },
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
  // The window's one composer overlays the reader while it is open.
  const [composing, setComposing] = useState<string>();
  const [expanded, setExpanded] = useState(false);
  const [height, setHeight] = useState(0);
  const [view, setView] = useState<MailboxView>({});
  const [width, setWidth] = useState<number>();
  // The sidebar follows the window width until the toggle chooses for it.
  const [sidebar, setSidebar] = useState<boolean>();
  const sidebarShown = sidebar ?? (width === undefined || width > narrowWindow);
  const inbox = useMailboxes().find(
    (mailbox) => mailbox.id === selected?.mailbox,
  )?.inbox;
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
        setWidth(nativeEvent.layout.width);
      }}
      style={styles.fill}>
      <LinkConfirmationProvider
        inbox={inbox}
        id={selected?.id}>
        <View
          style={[styles.window, { backgroundColor: colors.surfaceSidebar }]}>
          <CommandBar />
          <View
            testID={`window-panes-${windowId}`}
            onLayout={({ nativeEvent }) => {
              setHeight(nativeEvent.layout.height);
            }}
            style={styles.panes}>
            {/* The expanded composer covers the panes, so the glass sidebar steps aside. */}
            {sidebarShown && !expanded ? (
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
              pointerEvents={expanded ? 'none' : 'auto'}
              accessibilityElementsHidden={expanded}
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
                onReveal={() => {
                  setExpanded(false);
                }}
                onCompose={compose}
                onSelectBehindComposer={
                  composing === undefined ? undefined : setSelected
                }
                onSelect={(selection) => {
                  setComposing(undefined);
                  setSelected(selection);
                }}
                onView={setView}
                view={view}
              />
            </View>
            <View
              // The covered reader waits; the sidebar and list stay interactive beneath the overlay.
              pointerEvents={composing === undefined ? 'auto' : 'none'}
              accessibilityElementsHidden={composing !== undefined}
              style={[
                styles.detail,
                { backgroundColor: colors.surfaceContent },
              ]}>
              {/* Only the categorization-spike build has a page for the empty reader. */}
              {selected === undefined && CategorizationSpike !== undefined ? (
                <CategorizationSpike />
              ) : (
                <MessageDetail
                  id={selected?.id}
                  mailbox={selected?.mailbox}
                  folder={selected?.folder}
                  onClose={close}
                  onCompose={compose}
                />
              )}
            </View>
            {composing === undefined ? null : (
              <View
                testID="composer-overlay"
                style={[
                  styles.composer,
                  expanded
                    ? StyleSheet.absoluteFill
                    : [
                        styles.composerOverlay,
                        {
                          left:
                            (sidebarShown ? sidebarWidth + 2 * spacing.s : 0) +
                            listWidth +
                            composerInset,
                          height: composerHeight(height),
                        },
                      ],
                  {
                    borderColor: colors.separator,
                    boxShadow: colors.menuShadow,
                  },
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

const focusInbox = () => {
  settingsHost()?.focusInbox();
};
const closeSettings = () => {
  settingsHost()?.closeSettings();
};

// The Settings window, which AppKit opens with Command-, and every Inbox window's Settings entry
// points open; its Command Palette offers the way back to an Inbox window.
export function SettingsWindowRoot(
  props: Omit<
    Parameters<typeof SettingsGate>[0],
    'request' | 'onInbox' | 'onClose'
  >,
) {
  const request = useSettingsRequest();
  return (
    <CommandPaletteProvider
      windowId="settings"
      identifier="settings-window">
      <SettingsGate
        {...props}
        request={request}
        onInbox={focusInbox}
        onClose={closeSettings}
      />
    </CommandPaletteProvider>
  );
}
