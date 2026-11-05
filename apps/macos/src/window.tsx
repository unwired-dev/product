import type { openedTarget } from '@private-email/mail-core/notifications';
import type { ProfileChoicesStore } from '@private-email/mail-core/profile-windows';
import type { NativeSyntheticEvent, ViewProps } from 'react-native';

import {
  commandTarget,
  runWhenOffered,
} from '@private-email/mail-core/commands';
import { followOpenedNotifications } from '@private-email/mail-core/notifications';
import { windowProfile } from '@private-email/mail-core/profile-windows';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import { spacing } from '@private-email/mail-core/theme';
import {
  use,
  useCallback,
  useEffect,
  useMemo,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  Pressable,
  requireNativeComponent,
  StyleSheet,
  View,
} from 'react-native';

import type { Selection } from './inbox.tsx';
import type { MailboxView } from './sidebar.tsx';

import { CategorizationSpike } from './categorization-spike.ts';
import {
  CommandBar,
  CommandPaletteProvider,
  floatingInputWidth,
  OutsideClickLayer,
  useCommandRegistry,
} from './command-palette.tsx';
import { GlassGroup, SFSymbol } from './design.tsx';
import { DraftComposer } from './evaluation-composer.tsx';
import { FolderChoiceSheet } from './folder-choice.tsx';
import { BarOffsetContext, createBarOffset } from './inbox-bar.tsx';
import { listWidth } from './inbox-styles.ts';
import { Inbox } from './inbox.tsx';
import { OpenMessageContext } from './invitation.tsx';
import { useLocalization } from './localization.ts';
import {
  InboxProvider,
  ProfileScope,
  useMailboxes,
  useProfile,
  useLeaveComposer,
} from './mailbox.tsx';
import { LinkConfirmationProvider } from './message-body.tsx';
import { MessageDetail, ReaderToolbarWidthContext } from './message-detail.tsx';
import { createWindowProfileChoices } from './profile-choices.ts';
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

const sidebarWidth = 236;
const sidebarPaneWidth = sidebarWidth + 2 * spacing.s;
// The reader's toolbar row: the Command input at its leading end, clear of the reader's glass
// groups, whose laid-out width the reader reports, at its trailing end.
const commandsWidth = (readerWidth: number, toolbarWidth: number) =>
  Math.max(
    0,
    Math.min(
      floatingInputWidth,
      readerWidth -
        2 * spacing.l -
        (toolbarWidth > 0 ? toolbarWidth + spacing.s : 0),
    ),
  );
// The composer docks across the reading pane's full width at its bottom edge, as the Figma inline
// composer does, at 70% of the panes' height clamped from 420 to 720pt.
const composerHeight = (panesHeight: number) =>
  Math.min(panesHeight, Math.min(720, Math.max(420, panesHeight * 0.7)));

// The window's sidebar pane in AppKit's split view, which lays out its children beside the Inbox.
const NativeSidebar = requireNativeComponent<
  ViewProps & {
    // The pane's width, which the window's sidebar keeps.
    readonly thickness: number;
    readonly onCollapse: (
      event: NativeSyntheticEvent<{ readonly collapsed: boolean }>,
    ) => void;
    // Where the Inbox pane begins in the window, through each frame of AppKit's animation.
    readonly onInset: (
      event: NativeSyntheticEvent<{ readonly inset: number }>,
    ) => void;
  }
>('UnwiredSidebar');

const styles = StyleSheet.create({
  fill: { flex: 1 },
  window: { flex: 1 },
  panes: { flex: 1, flexDirection: 'row' },
  // The sidebar's children fill its pane; the host itself takes no space in the Inbox.
  sidebarHost: { position: 'absolute', top: 0, bottom: 0, left: 0, width: 0 },
  sidebarPane: { width: sidebarPaneWidth, height: '100%' },
  // The floating glass sidebar, inset from the pane's edges, with the frames' 18pt corners.
  sidebar: {
    flex: 1,
    margin: spacing.s,
    padding: 0,
    borderRadius: 18,
    borderCurve: 'continuous',
    backgroundColor: 'transparent',
  },
  sidebarBacking: {
    ...StyleSheet.absoluteFillObject,
    borderRadius: 18,
    borderCurve: 'continuous',
  },
  detail: { flex: 1 },
  composer: {
    position: 'absolute',
    overflow: 'hidden',
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  composerOverlay: { left: 0, right: 0, bottom: 0 },
  toggleTarget: {
    width: 28,
    height: 28,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 2,
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
  const savedChoices = useMemo(() => createWindowProfileChoices(), []);
  return (
    <CommandPaletteProvider windowId={windowId}>
      <ProfileWindow
        windowId={windowId}
        profile={profile}
        choice={choice}
        savedChoices={savedChoices}
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
  savedChoices,
  onChoose,
}: {
  readonly windowId: string;
  readonly profile: string | undefined;
  readonly choice: ProfileChoice | undefined;
  readonly savedChoices: ProfileChoicesStore;
  readonly onChoose: (choice: ProfileChoice) => void;
}) {
  const account = use(AccountContext);
  const profiles = account?.profiles;
  const owner = account?.account ?? '';
  // Another Product Account's choice never names this one's Profile.
  const current =
    choice?.account === (account?.account ?? '') ? choice.choice : undefined;
  const opened = typeof current === 'string' ? undefined : current;
  const choose = (next: ProfileChoice['choice']) => {
    onChoose({ account: account?.account ?? '', choice: next });
  };
  const choices = useSyncExternalStore(savedChoices.subscribe, () =>
    savedChoices.getSnapshot(owner),
  );
  useEffect(() => {
    if (savedChoices.getSnapshot(owner) === undefined) {
      void savedChoices.load(owner);
    }
  }, [owner, savedChoices]);
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
    <Pressable
      accessibilityLabel={t(
        shown ? 'native.hideSidebar' : 'native.showSidebar',
      )}
      accessibilityRole="button"
      // The control's accent/ink ring replaces the system focus ring.
      enableFocusRing={false}
      focusable
      onBlur={() => {
        setFocused(false);
      }}
      onFocus={() => {
        setFocused(true);
      }}
      onPress={onPress}
      style={({ pressed }) => [
        styles.toggleTarget,
        {
          backgroundColor: pressed
            ? colors.accentSelectionSubtle
            : 'transparent',
          borderColor: focused ? colors.accentInk : 'transparent',
        },
      ]}>
      <SFSymbol
        name="sidebar.leading"
        color={colors.textSecondary}
      />
    </Pressable>
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
  const [panes, setPanes] = useState({ width: 0, height: 0 });
  // Half the sidebar's visible width, which only the floating bar follows through the animation.
  const barOffset = useMemo(() => createBarOffset(), []);
  const [toolbarWidth, setToolbarWidth] = useState(0);
  const [view, setView] = useState<MailboxView>({});
  // AppKit owns the sidebar's collapse, including by window resizing; the toggle follows it.
  const [collapsed, setCollapsed] = useState(false);
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
  const toggle = (
    <SidebarToggle
      shown={!collapsed}
      onPress={() => {
        windowHost()?.toggleSidebar(`inbox-window-${windowId}`);
      }}
    />
  );
  return (
    <View
      testID={`inbox-window-${windowId}`}
      style={styles.fill}>
      <NativeSidebar
        thickness={sidebarPaneWidth}
        onCollapse={({ nativeEvent }) => {
          setCollapsed(nativeEvent.collapsed);
        }}
        onInset={({ nativeEvent }) => {
          barOffset.set(nativeEvent.inset / 2);
        }}
        style={styles.sidebarHost}>
        <View
          style={[
            styles.sidebarPane,
            // The window's own surface shows around the floating glass sidebar, as in the frames.
            { backgroundColor: colors.surfaceContent },
          ]}>
          <GlassGroup
            style={[styles.sidebar, { boxShadow: colors.largeGlassShadow }]}>
            <View
              style={[
                styles.sidebarBacking,
                { backgroundColor: colors.materialSidebarBacking },
              ]}
            />
            <Mailboxes
              toggle={collapsed ? undefined : toggle}
              view={view}
              onView={setView}
              onProfile={(next) => {
                void switchProfile(next);
              }}
            />
          </GlassGroup>
          <OutsideClickLayer />
        </View>
      </NativeSidebar>
      <LinkConfirmationProvider
        inbox={inbox}
        id={selected?.id}>
        <View
          style={[styles.window, { backgroundColor: colors.surfaceContent }]}>
          <View
            testID={`window-panes-${windowId}`}
            onLayout={({ nativeEvent }) => {
              setPanes({
                width: nativeEvent.layout.width,
                height: nativeEvent.layout.height,
              });
            }}
            style={styles.panes}>
            <BarOffsetContext value={barOffset}>
              <Inbox
                composing={composing}
                leading={collapsed ? toggle : undefined}
                reader={
                  <View
                    // The reader's toolbar and the rest left uncovered stay interactive above the
                    // overlay.
                    style={[
                      styles.detail,
                      { backgroundColor: colors.surfaceContent },
                    ]}>
                    {/* Only the categorization-spike build has a page for the empty reader. */}
                    {selected === undefined &&
                    CategorizationSpike !== undefined ? (
                      <CategorizationSpike />
                    ) : (
                      <ReaderToolbarWidthContext value={setToolbarWidth}>
                        {/* Another message of the same mailbox replaces the reader's, beneath an
                            open composer. */}
                        <OpenMessageContext
                          value={(id) => {
                            if (selected !== undefined) {
                              setSelected({ mailbox: selected.mailbox, id });
                            }
                          }}>
                          <MessageDetail
                            id={selected?.id}
                            mailbox={selected?.mailbox}
                            folder={selected?.folder}
                            onClose={close}
                            onCompose={compose}
                          />
                        </OpenMessageContext>
                      </ReaderToolbarWidthContext>
                    )}
                    {composing === undefined ? null : (
                      <View
                        testID="composer-overlay"
                        style={[
                          styles.composer,
                          styles.composerOverlay,
                          {
                            height: composerHeight(panes.height),
                            borderColor: colors.separator,
                            boxShadow: colors.menuShadow,
                          },
                        ]}>
                        <DraftComposer
                          id={composing}
                          onClose={() => {
                            setComposing(undefined);
                          }}
                          // Expand moves the saved Draft into its own New Message window.
                          onExpand={(id) => {
                            windowHost()?.openComposer(id, profile);
                            setComposing(undefined);
                          }}
                          onRebind={setComposing}
                        />
                      </View>
                    )}
                  </View>
                }
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
                onView={setView}
                view={view}
              />
            </BarOffsetContext>
          </View>
          <CommandBar
            floating={{
              left: listWidth + spacing.l,
              availableWidth: Math.max(
                0,
                panes.width - listWidth - 2 * spacing.l,
              ),
              width: commandsWidth(panes.width - listWidth, toolbarWidth),
            }}
          />
        </View>
      </LinkConfirmationProvider>
    </View>
  );
}

export function InboxWindow({ windowId, profile }: WindowProps) {
  const [choice, setChoice] = useState<ProfileChoice>();
  const savedChoices = useMemo(() => createWindowProfileChoices(), []);
  // The window's Command Palette stays above the gate, so the account page keeps it.
  return (
    <CommandPaletteProvider windowId={windowId}>
      <RegistrationGate>
        <ProfileWindow
          windowId={windowId}
          profile={profile}
          choice={choice}
          savedChoices={savedChoices}
          onChoose={setChoice}
        />
      </RegistrationGate>
    </CommandPaletteProvider>
  );
}

// A New Message window: the Draft Expand moved out of an Inbox window's composer, alone in its own
// window. Closing it runs the composer's own Close guards, as in the Inbox window.
export function ComposerWindow({
  windowId,
  draft,
  profile,
}: {
  readonly windowId: string;
  readonly draft: string;
  readonly profile: string;
}) {
  const identifier = `composer-window-${windowId}`;
  const [id, setId] = useState(draft);
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <CommandPaletteProvider
      windowId={windowId}
      identifier={identifier}>
      <InboxProvider>
        <ProfileScope profile={profile}>
          <View
            style={[styles.window, { backgroundColor: colors.surfaceContent }]}>
            <DraftComposer
              id={id}
              onClose={() => {
                windowHost()?.finishClose(identifier, true);
              }}
              onRebind={setId}
              renderToolbar={(from, actions) => (
                <CommandBar
                  title={t('drafts.newMessage')}
                  from={from}
                  actions={actions}
                />
              )}
            />
          </View>
        </ProfileScope>
      </InboxProvider>
    </CommandPaletteProvider>
  );
}

// The New Message window closes, rather than showing account pages, once no Inbox can open.
export function ComposerWindowRoot(
  props: Parameters<typeof ComposerWindow>[0],
) {
  const identifier = `composer-window-${props.windowId}`;
  const close = useCallback(() => {
    windowHost()?.finishClose(identifier, true);
  }, [identifier]);
  return (
    <RegistrationGate onClose={close}>
      <ComposerWindow {...props} />
    </RegistrationGate>
  );
}

// An IMAP connection's Spam and Trash choice, in the sheet Choose Folders… opens on an Inbox
// window; the sheet ends rather than showing account pages once no Inbox can open.
export function FolderChoiceWindowRoot({
  window,
  connection,
  profile,
  inbox,
  ...gate
}: Omit<Parameters<typeof RegistrationGate>[0], 'children' | 'onClose'> & {
  readonly window: string;
  readonly connection: string;
  readonly profile: string;
  // The Inbox's mailboxes, drafts and Outbox, which default to this process's.
  readonly inbox?: Omit<Parameters<typeof InboxProvider>[0], 'children'>;
}) {
  const close = useCallback(() => {
    windowHost()?.closeSheet(window);
  }, [window]);
  return (
    <RegistrationGate
      {...gate}
      onClose={close}>
      <InboxProvider {...inbox}>
        <ProfileScope profile={profile}>
          <FolderChoiceSheet
            window={window}
            connection={connection}
          />
        </ProfileScope>
      </InboxProvider>
    </RegistrationGate>
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
