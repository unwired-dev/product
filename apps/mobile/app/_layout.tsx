import type { SplitHostCommands } from 'react-native-screens/experimental';

import { readingProfile } from '@private-email/mail-core/mailboxes';
import { radius, spacing } from '@private-email/mail-core/theme';
import { router, useGlobalSearchParams } from 'expo-router';
import { SplitView } from 'expo-router/unstable-split-view';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { Keyboard, StyleSheet, useWindowDimensions, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import type { Selection } from '../src/inbox.tsx';

import { CommandPaletteProvider } from '../src/command-palette.tsx';
import { ComposerLayoutContext } from '../src/composer.tsx';
import { DraftComposer } from '../src/evaluation-composer.tsx';
import {
  pollGmailWhileActive,
  scheduleGmailFreshness,
} from '../src/freshness.ts';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider, ProfileScope } from '../src/mailbox.tsx';
import { RegistrationGate } from '../src/registration-gate.tsx';
import { usePalette } from '../src/theme.ts';

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

void scheduleGmailFreshness();
pollGmailWhileActive();

export default function RootLayout() {
  const splitView = useRef<SplitHostCommands>(null);
  const { width } = useWindowDimensions();
  const [collapsed, setCollapsed] = useState(width < 600);
  const regular = width >= 600 && !collapsed;
  const [expanded, setExpanded] = useState(false);
  const [height, setHeight] = useState(0);
  const [sidebarWidth, setSidebarWidth] = useState(0);
  const colors = usePalette();
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
  // A docked software keyboard leaves the overlay only the height above it; a floating one is ignored.
  const [keyboardTop, setKeyboardTop] = useState<number>();
  useEffect(() => {
    const subscriptions = [
      Keyboard.addListener('keyboardWillChangeFrame', ({ endCoordinates }) => {
        setKeyboardTop(
          endCoordinates.width < width ? undefined : endCoordinates.screenY,
        );
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
  }, [width]);
  const available =
    keyboardTop === undefined ? height : Math.min(height, keyboardTop);
  const { id, mailbox, draft, profileId } = useGlobalSearchParams<{
    id?: string;
    mailbox?: string;
    draft?: string;
    profileId?: string | string[];
  }>();
  // The window's Mail Profile: a targeted deep link's, otherwise the Default Profile, which owns
  // every mailbox an old-form link from before Profiles names. An unknown Profile shows nothing.
  // shortcut: a new route without a Profile uses Default until #647 adds restoration preferences.
  const shownProfile = readingProfile(profileId);
  // Close or New Message can finish saving after the reader beneath it changes. The router
  // commits navigation after this render, so a handler that changes the reader updates this first.
  const reader = useRef({ id, mailbox, profile: shownProfile });
  useLayoutEffect(() => {
    reader.current = { id, mailbox, profile: shownProfile };
  }, [id, mailbox, shownProfile]);
  // Likewise the open composer's Draft: a command that leaves the composer and then closes the
  // reader runs both closes before the next render.
  const composing = useRef(draft);
  useLayoutEffect(() => {
    composing.current = draft;
  }, [draft]);
  const detail = Boolean(id) || Boolean(draft);

  // A collapsed split view keeps showing the detail column until told otherwise, so leaving the
  // reader or composer returns to the Inbox column.
  useEffect(() => {
    splitView.current?.show(detail ? 'secondary' : 'primary');
  }, [detail]);

  function selectMessage(selection: Selection) {
    router.replace({
      pathname: '/message/[id]',
      params: { ...selection, profileId: shownProfile },
    });
    splitView.current?.show('secondary');
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
        profileId: latest.profile,
      },
    });
    splitView.current?.show('secondary');
  }

  return (
    <RegistrationGate>
      <InboxProvider>
        <ProfileScope profile={shownProfile}>
          <StatusBar style="auto" />
          <CommandPaletteProvider>
            <View
              testID="mail-shell"
              onLayout={({ nativeEvent }) => {
                setHeight(nativeEvent.layout.height);
              }}
              style={styles.fill}>
              <SplitView
                ref={splitView}
                testID="mail-split"
                onCollapse={() => {
                  setCollapsed(true);
                }}
                onExpand={() => {
                  setCollapsed(false);
                }}
                style={styles.fill}
                preferredDisplayMode="oneBesideSecondary"
                preferredSplitBehavior="tile"
                topColumnForCollapsing={detail ? 'secondary' : 'primary'}>
                <SplitView.Column>
                  <View
                    style={styles.fill}
                    onLayout={({ nativeEvent }) => {
                      setSidebarWidth(nativeEvent.layout.width);
                    }}>
                    <Inbox
                      composing={draft}
                      onClose={() => {
                        reader.current = {
                          id: undefined,
                          mailbox: undefined,
                          profile: shownProfile,
                        };
                        const open = regular ? composing.current : undefined;
                        router.replace({
                          pathname:
                            open === undefined ? '/' : '/compose/[draft]',
                          params: {
                            ...(open === undefined ? {} : { draft: open }),
                            profileId: shownProfile,
                          },
                        });
                      }}
                      onCompose={compose}
                      onSelect={selectMessage}
                      onSelectBehindComposer={
                        regular && draft !== undefined
                          ? (selection) => {
                              reader.current = {
                                ...reader.current,
                                ...selection,
                              };
                              router.setParams(selection);
                            }
                          : undefined
                      }
                      selected={
                        id === undefined || mailbox === undefined
                          ? undefined
                          : { mailbox, id }
                      }
                    />
                  </View>
                </SplitView.Column>
              </SplitView>
              {draft === undefined ? null : (
                <View
                  testID="composer-overlay"
                  accessibilityViewIsModal={!regular || expanded}
                  style={
                    regular && !expanded
                      ? [
                          styles.overlay,
                          {
                            left: sidebarWidth + spacing.m,
                            bottom: spacing.m + height - available,
                            height: Math.min(
                              Math.max(
                                0,
                                available - insets.top - 2 * spacing.m,
                              ),
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
                        if (
                          latest.id === undefined ||
                          latest.mailbox === undefined
                        ) {
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
          </CommandPaletteProvider>
        </ProfileScope>
      </InboxProvider>
    </RegistrationGate>
  );
}
