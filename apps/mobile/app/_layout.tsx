import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type { NativeQualification } from '@private-email/mail-core/assistance-qualification';
import type { NativeTranslation } from '@private-email/mail-core/translation';
import type { TurboModule } from 'react-native';
import type { SplitHostCommands } from 'react-native-screens/experimental';

import { startAssistanceQualification } from '@private-email/mail-core/assistance-qualification';
import {
  commandTarget,
  runWhenOffered,
} from '@private-email/mail-core/commands';
import { followOpenedNotifications } from '@private-email/mail-core/notifications';
import { defaultProfile } from '@private-email/mail-core/registration';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import { radius, spacing } from '@private-email/mail-core/theme';
import { router, useGlobalSearchParams } from 'expo-router';
import { SplitView } from 'expo-router/unstable-split-view';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import {
  Keyboard,
  Platform,
  StyleSheet,
  TurboModuleRegistry,
  useWindowDimensions,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import type { Selection } from '../src/inbox.tsx';
import type { MailboxView } from '../src/sidebar.tsx';

import {
  CommandPaletteProvider,
  useCommandRegistry,
  useCommandPalette,
} from '../src/command-palette.tsx';
import { ComposerLayoutContext } from '../src/composer.tsx';
import { DraftComposer } from '../src/evaluation-composer.tsx';
import {
  pollGmailWhileActive,
  scheduleGmailFreshness,
} from '../src/freshness.ts';
import {
  createWindowBar,
  WindowBarContext,
  WindowBarHost,
} from '../src/inbox-bar.tsx';
import { Inbox } from '../src/inbox.tsx';
import {
  InboxProvider,
  useLeaveComposer,
  useProfile,
  WindowProfileScope,
} from '../src/mailbox.tsx';
import { ReaderPaneWidthContext } from '../src/reader-chrome.tsx';
import { RegistrationGate } from '../src/registration-gate.tsx';
import { native, registration, start } from '../src/registration.ts';
import { Mailboxes } from '../src/sidebar.tsx';
import { usePalette } from '../src/theme.ts';

// iPhone's Inbox shows its own Back to Mailboxes in place of the native navigation bar.
const phone = Platform.OS === 'ios' && !Platform.isPad;

const styles = StyleSheet.create({
  fill: { flex: 1 },
  overlay: {
    position: 'absolute',
    right: spacing.m,
    bottom: spacing.m,
    overflow: 'hidden',
    borderWidth: StyleSheet.hairlineWidth,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
});

// Every gate shows the Registration and remote content settings the host restores once here.
if (!previewInbox) {
  void start();
}
void scheduleGmailFreshness();
pollGmailWhileActive();

interface AssistanceModule
  extends TurboModule, NativeAssistance, NativeTranslation {}
interface QualificationModule extends TurboModule, NativeQualification {}

// Only the assistance qualification build runs its synthetic corpus, once per interactive launch.
startAssistanceQualification(() => ({
  assistance:
    TurboModuleRegistry.getEnforcing<AssistanceModule>('UnwiredAssistance'),
  qualification: TurboModuleRegistry.getEnforcing<QualificationModule>(
    'UnwiredAssistanceQualification',
  ),
}));

// A tapped New Mail Notification opens its message once Registration admits the shell; its Reply
// then starts a reply as soon as the message's reader offers one.
function OpenedNotifications() {
  const leave = useLeaveComposer();
  const registry = useCommandRegistry();
  const { close } = useCommandPalette();
  useEffect(() => {
    if (!previewInbox) {
      return followOpenedNotifications(native(), '', {
        snapshot: () => registration.getSnapshot().snapshot,
        leave,
        open: (target, reply, current) => {
          close();
          router.navigate({
            pathname: '/message/[id]',
            params: {
              id: target.id,
              mailbox: target.mailbox,
              profileId: target.profile,
            },
          });
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
  }, [leave, registry, close]);
  return null;
}

// Presentation choices live below WindowProfileScope, which retires them with the Profile.
function MailShell() {
  const splitView = useRef<SplitHostCommands>(null);
  const leave = useLeaveComposer();
  const { width } = useWindowDimensions();
  const [collapsed, setCollapsed] = useState(width < 600);
  const regular = width >= 600 && !collapsed;
  const [expanded, setExpanded] = useState(false);
  const [height, setHeight] = useState(0);
  // UIKit changes the reading column's width when either leading column moves or hides; every
  // reading-column route reports it.
  const [readerWidth, setReaderWidth] = useState(width);
  const colors = usePalette();
  // A regular-width window shows the Inbox's floating bar across its bottom edge.
  const windowBar = useMemo(() => createWindowBar(), []);
  // The composer sits outside the split view's screens, so it keeps clear of the system bars here.
  const insets = useSafeAreaInsets();
  const composerLayout = useMemo(
    () =>
      ({
        size: regular ? 'regular' : 'compact',
        avoidKeyboard: !regular || expanded,
        top: insets.top,
      }) as const,
    [regular, expanded, insets.top],
  );
  const { id, mailbox, folder, draft } = useGlobalSearchParams<{
    id?: string;
    mailbox?: string;
    folder?: string;
    draft?: string;
  }>();
  // A docked software keyboard leaves the overlay and the window bar only the height above it; a
  // floating one is ignored. On iPhone only an open composer listens: re-rendering the shell for
  // every keyboard change remounts the reader beneath it, which would close a sheet whose field
  // raised the keyboard. A composer opened there starts without a keyboard, since one closed with
  // its keyboard up hears no hide; a conflict copy replacing the Draft in place keeps it.
  const [keyboardTop, setKeyboardTop] = useState<number>();
  const listening = regular || draft !== undefined;
  const [wasListening, setWasListening] = useState(listening);
  if (wasListening !== listening) {
    setWasListening(listening);
    setKeyboardTop(undefined);
  }
  useEffect(() => {
    if (!listening) {
      return undefined;
    }
    // React Native reports the frame in the key window's coordinates despite `screenY`'s name, so it
    // compares with the window-filling shell even in an iPad window below the top of the screen.
    const docked = (frame: { width: number; screenY: number }) =>
      frame.width < width ? undefined : frame.screenY;
    const subscriptions = [
      Keyboard.addListener('keyboardWillChangeFrame', ({ endCoordinates }) => {
        setKeyboardTop(docked(endCoordinates));
      }),
      Keyboard.addListener('keyboardWillHide', () => {
        setKeyboardTop(undefined);
      }),
    ];
    return () => {
      for (const subscription of subscriptions) {
        subscription.remove();
      }
    };
  }, [listening, width]);
  const available =
    keyboardTop === undefined ? height : Math.min(height, keyboardTop);
  // The window's Mail Profile, which WindowProfileScope chose.
  const shownProfile = useProfile();
  // Close or New Message can finish saving after the reader beneath it changes. The router
  // commits navigation after this render, so a handler that changes the reader updates this first.
  const reader = useRef({ id, mailbox, folder, profile: shownProfile });
  useLayoutEffect(() => {
    reader.current = { id, mailbox, folder, profile: shownProfile };
  }, [id, mailbox, folder, shownProfile]);
  // Likewise the open composer's Draft: a command that leaves the composer and then closes the
  // reader runs both closes before the next render.
  const composing = useRef(draft);
  useLayoutEffect(() => {
    composing.current = draft;
  }, [draft]);
  const detail = Boolean(id) || Boolean(draft);
  // The Mailboxes column's choice, which the message list column shows.
  const [view, setView] = useState<MailboxView>({});

  // A collapsed split view keeps showing a column until told otherwise, so leaving the reader or
  // composer returns to the message list.
  useEffect(() => {
    splitView.current?.show(detail ? 'secondary' : 'supplementary');
  }, [detail]);

  function selectMessage(selection: Selection) {
    reader.current = {
      ...selection,
      folder: selection.folder,
      profile: shownProfile,
    };
    router.replace({
      pathname: '/message/[id]',
      params: { ...selection, profileId: shownProfile },
    });
    splitView.current?.show('secondary');
  }

  async function switchProfile(profile: string) {
    if (await leave()) {
      router.replace({
        pathname: '/',
        params: { profileId: profile },
      });
    }
  }

  // The compose destination retains the reader's selection beneath its editor.
  function compose(opened: string) {
    setExpanded(false);
    composing.current = opened;
    const latest = reader.current;
    router.replace({
      pathname: '/compose/[draft]',
      params: {
        draft: opened,
        id: latest.id,
        mailbox: latest.mailbox,
        ...(latest.folder === undefined ? {} : { folder: latest.folder }),
        profileId: latest.profile,
      },
    });
    splitView.current?.show('secondary');
  }

  return (
    <>
      <StatusBar style="auto" />
      <View
        testID="mail-shell"
        onLayout={({ nativeEvent }) => {
          setHeight(nativeEvent.layout.height);
        }}
        style={styles.fill}>
        <WindowBarContext value={regular ? windowBar : undefined}>
          <ReaderPaneWidthContext value={setReaderWidth}>
            <SplitView
              ref={splitView}
              testID="mail-split"
              columnMetrics={{
                preferredPrimaryColumnWidthOrFraction: 236,
                preferredSupplementaryColumnWidthOrFraction: 340,
              }}
              onCollapse={() => {
                setCollapsed(true);
              }}
              onExpand={() => {
                setCollapsed(false);
              }}
              style={styles.fill}
              // Both sidebars beside the reader in landscape; portrait hides Mailboxes, which the
              // system's sidebar button shows over the list.
              preferredDisplayMode="automatic"
              preferredSplitBehavior="tile"
              primaryBackgroundStyle="sidebar"
              topColumnForCollapsing={detail ? 'secondary' : 'supplementary'}>
              <SplitView.Column>
                <Mailboxes
                  view={view}
                  onProfile={(profile) => {
                    void switchProfile(profile);
                  }}
                  onView={(next) => {
                    setView(next);
                    // On iPhone a Mailbox opens its list; beside it, the list is already shown.
                    splitView.current?.show('supplementary');
                  }}
                />
              </SplitView.Column>
              <SplitView.Column>
                <View style={styles.fill}>
                  <Inbox
                    composing={draft}
                    onClose={() => {
                      reader.current = {
                        id: undefined,
                        mailbox: undefined,
                        folder: undefined,
                        profile: shownProfile,
                      };
                      const open = regular ? composing.current : undefined;
                      router.replace({
                        pathname: open === undefined ? '/' : '/compose/[draft]',
                        params: {
                          ...(open === undefined ? {} : { draft: open }),
                          profileId: shownProfile,
                        },
                      });
                      // On iPhone the list returns over the reader, or over Mailboxes for the palette.
                      splitView.current?.show('supplementary');
                    }}
                    onBack={
                      phone
                        ? () => {
                            splitView.current?.show('primary');
                          }
                        : undefined
                    }
                    onCompose={compose}
                    onSelect={selectMessage}
                    onSelectBehindComposer={
                      regular && draft !== undefined
                        ? (selection) => {
                            // A message chosen in the Inbox clears the previous one's view.
                            const next = {
                              ...selection,
                              folder: selection.folder,
                            };
                            reader.current = { ...reader.current, ...next };
                            router.setParams(next);
                          }
                        : undefined
                    }
                    onView={setView}
                    selected={
                      id === undefined || mailbox === undefined
                        ? undefined
                        : {
                            mailbox,
                            id,
                            ...(folder === undefined ? {} : { folder }),
                          }
                    }
                    view={view}
                  />
                </View>
              </SplitView.Column>
            </SplitView>
          </ReaderPaneWidthContext>
          {regular ? (
            <WindowBarHost
              windowBar={windowBar}
              readerWidth={readerWidth}
              keyboardLift={height - available}
              // The bar sits on the home indicator's inset and rises above a docked keyboard.
              bottom={Math.max(insets.bottom, spacing.l) + height - available}
            />
          ) : null}
        </WindowBarContext>
        {draft === undefined ? null : (
          <View
            testID="composer-overlay"
            accessibilityViewIsModal={!regular || expanded}
            style={
              regular && !expanded
                ? [
                    styles.overlay,
                    {
                      left: Math.max(0, width - readerWidth) + spacing.m,
                      bottom: spacing.m + height - available,
                      height: Math.min(
                        Math.max(0, available - insets.top - 2 * spacing.m),
                        Math.min(720, Math.max(420, available * 0.7)),
                      ),
                      borderColor: colors.separator,
                      boxShadow: colors.menuShadow,
                    },
                  ]
                : [
                    StyleSheet.absoluteFill,
                    {
                      paddingTop: insets.top,
                      paddingBottom: insets.bottom,
                      paddingLeft: insets.left,
                      paddingRight: insets.right,
                      backgroundColor: colors.surfaceContent,
                    },
                  ]
            }>
            <ComposerLayoutContext value={composerLayout}>
              <DraftComposer
                id={draft}
                expanded={expanded}
                onExpand={
                  regular
                    ? () => {
                        setExpanded((current) => !current);
                      }
                    : undefined
                }
                onClose={() => {
                  setExpanded(false);
                  composing.current = undefined;
                  const latest = reader.current;
                  if (latest.id === undefined || latest.mailbox === undefined) {
                    router.replace({
                      pathname: '/',
                      params: { profileId: latest.profile },
                    });
                  } else {
                    router.replace({
                      pathname: '/message/[id]',
                      params: {
                        id: latest.id,
                        mailbox: latest.mailbox,
                        ...(latest.folder === undefined
                          ? {}
                          : { folder: latest.folder }),
                        profileId: latest.profile,
                      },
                    });
                  }
                }}
                onRebind={(copy) => {
                  composing.current = copy;
                  router.setParams({ draft: copy });
                }}
              />
            </ComposerLayoutContext>
          </View>
        )}
      </View>
    </>
  );
}

export default function RootLayout() {
  const { id, profileId } = useGlobalSearchParams<{
    id?: string;
    profileId?: string | string[];
  }>();
  // Outlives the registration gate, so signing into another account can tell its route apart.
  const [routeAccount, setRouteAccount] = useState<string>();
  return (
    <RegistrationGate>
      <InboxProvider>
        <CommandPaletteProvider>
          <OpenedNotifications />
          {/* A message or Thread link from before Profiles names none and opens in the Default
              Profile, which owns every mailbox it can name. */}
          <WindowProfileScope
            routeAccount={routeAccount}
            onRouteAccount={setRouteAccount}
            link={
              profileId === undefined && id !== undefined
                ? defaultProfile
                : profileId
            }>
            <MailShell />
          </WindowProfileScope>
        </CommandPaletteProvider>
      </InboxProvider>
    </RegistrationGate>
  );
}
