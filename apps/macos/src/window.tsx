import type { openedTarget } from '@private-email/mail-core/notifications';

import {
  commandTarget,
  runWhenOffered,
} from '@private-email/mail-core/commands';
import { followOpenedNotifications } from '@private-email/mail-core/notifications';
import { windowProfile } from '@private-email/mail-core/profile-windows';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import { radius, spacing } from '@private-email/mail-core/theme';
import { use, useEffect, useState, useSyncExternalStore } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';

import type { Selection } from './inbox.tsx';
import type { MailboxView } from './sidebar.tsx';

import { CategorizationSpike } from './categorization-spike.ts';
import {
  CommandBar,
  CommandPaletteProvider,
  useCommandRegistry,
} from './command-palette.tsx';
import { GlassGroup, SFSymbol } from './design.tsx';
import { DraftComposer } from './evaluation-composer.tsx';
import { Inbox } from './inbox.tsx';
import { useLocalization } from './localization.ts';
import {
  InboxProvider,
  profileChoices,
  ProfileScope,
  useMailboxes,
  useProfile,
  useLeaveComposer,
} from './mailbox.tsx';
import { LinkConfirmationProvider } from './message-body.tsx';
import { MessageDetail } from './message-detail.tsx';
import {
  AccountContext,
  RegistrationGate,
  SettingsGate,
} from './registration-gate.tsx';
import { native, registration } from './registration.ts';
import { settingsHost, windowHost } from './settings-window-client.ts';
import { useSettingsRequest } from './settings-window.ts';
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
  // The Mail Profile AppKit restored with the window; a new window names none.
  profile?: string;
}>;

// A switcher's Profile or a notification's targeted message, owned by the window above its gate
// and kept only for the Product Account it was made in.
type ProfileChoice = Readonly<{
  account: string;
  choice: string | NonNullable<ReturnType<typeof openedTarget>>;
}>;

export function PreviewWindow({ windowId, profile }: WindowProps) {
  const [choice, setChoice] = useState<ProfileChoice>();
  return (
    <CommandPaletteProvider windowId={windowId}>
      <ProfileWindow
        windowId={windowId}
        profile={profile}
        choice={choice}
        onChoose={setChoice}
      />
    </CommandPaletteProvider>
  );
}

// The window's Mail Profile: the one its switcher or a tapped notification chose, then the one
// AppKit restored, then the Startup Profile, then the Default Profile. AppKit saves the chosen or
// restored Profile with the window, so an unlisted restored Profile returns once it is listed.
function ProfileWindow({
  windowId,
  profile: restored,
  choice,
  onChoose,
}: {
  readonly windowId: string;
  readonly profile: string | undefined;
  readonly choice: ProfileChoice | undefined;
  readonly onChoose: (choice: ProfileChoice) => void;
}) {
  const account = use(AccountContext);
  const profiles = account?.profiles;
  // Another Product Account's choice never names this one's Profile.
  const current =
    choice?.account === (account?.account ?? '') ? choice.choice : undefined;
  const opened = typeof current === 'string' ? undefined : current;
  const choose = (next: ProfileChoice['choice']) => {
    onChoose({ account: account?.account ?? '', choice: next });
  };
  const choices = useSyncExternalStore(
    profileChoices.subscribe,
    profileChoices.getSnapshot,
  );
  useEffect(() => {
    void profileChoices.load();
  }, []);
  const link = typeof current === 'string' ? current : current?.profile;
  const profile = windowProfile({
    link,
    restored,
    startup: choices?.startup,
    profiles: profiles ?? [],
  });
  const kept = link ?? restored ?? profile;
  useEffect(() => {
    windowHost()?.setWindowProfile(`inbox-window-${windowId}`, kept);
  }, [windowId, kept]);
  // A new window waits for the saved Startup Profile.
  if (choices === undefined && link === undefined && restored === undefined) {
    return null;
  }
  return (
    <InboxProvider>
      <ProfileScope profile={profile}>
        <WindowContents
          windowId={windowId}
          initialSelection={opened}
          onOpenProfile={choose}
          onProfile={choose}
        />
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

function WindowContents({
  windowId,
  initialSelection,
  onOpenProfile,
  onProfile,
}: {
  readonly windowId: string;
  readonly initialSelection: Selection | undefined;
  readonly onOpenProfile: (
    target: NonNullable<ReturnType<typeof openedTarget>>,
  ) => void;
  // Switches only this window to another Mail Profile.
  readonly onProfile: (profile: string) => void;
}) {
  const [selected, setSelected] = useState<Selection | undefined>(
    initialSelection,
  );
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
  const profile = useProfile();
  const leave = useLeaveComposer();
  const registry = useCommandRegistry();
  // A tapped New Mail Notification selects its message in this window's Inbox when the window
  // shows its Mail Profile; native code brings the window forward. Its Reply then starts a reply
  // as soon as the message's reader offers one.
  useEffect(() => {
    if (!previewInbox) {
      return followOpenedNotifications(native(), windowId, {
        snapshot: () => registration.getSnapshot().snapshot,
        leave,
        open: (target, reply, current) => {
          if (target.profile === profile) {
            setComposing(undefined);
            setView({});
            setSelected({ mailbox: target.mailbox, id: target.id });
          } else {
            onOpenProfile(target);
          }
          if (reply) {
            runWhenOffered(registry, {
              id: 'reply',
              target: commandTarget(target.mailbox, {
                id: target.id,
                subject: '',
              }).id,
              current,
            });
          }
        },
      });
    }
  }, [windowId, profile, leave, onOpenProfile, registry]);
  // Opening a Draft from either pane shows it in the window's composer, over the reader.
  const compose = (id: string) => {
    setComposing(id);
  };
  const switchProfile = async (next: string) => {
    if (await leave()) {
      onProfile(next);
    }
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
                  onProfile={(next) => {
                    void switchProfile(next);
                  }}
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

export function InboxWindow({ windowId, profile }: WindowProps) {
  const [choice, setChoice] = useState<ProfileChoice>();
  // The window's Command Palette stays above the gate, so the account page keeps it.
  return (
    <CommandPaletteProvider windowId={windowId}>
      <RegistrationGate>
        <ProfileWindow
          windowId={windowId}
          profile={profile}
          choice={choice}
          onChoose={setChoice}
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
