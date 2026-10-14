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
import type { MailboxView } from '../src/sidebar.tsx';

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
import { Mailboxes } from '../src/sidebar.tsx';
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

// Presentation choices live below ProfileScope, which retires them with the Profile.
function MailShell() {
  const splitView = useRef<SplitHostCommands>(null);
  const { width } = useWindowDimensions();
  const [collapsed, setCollapsed] = useState(width < 600);
  const regular = width >= 600 && !collapsed;
  const [expanded, setExpanded] = useState(false);
  const [height, setHeight] = useState(0);
  // Where the reading pane starts: after the message list, and after Mailboxes when it is beside.
  const list = useRef<View>(null);
  const [readerLeft, setReaderLeft] = useState(0);
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
  // The Mailboxes column's choice, which the message list column shows.
  const [view, setView] = useState<MailboxView>({});

  // A collapsed split view keeps showing a column until told otherwise, so leaving the reader or
  // composer returns to the message list.
  useEffect(() => {
    splitView.current?.show(detail ? 'secondary' : 'supplementary');
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
    <CommandPaletteProvider>
      <StatusBar style="auto" />
      <View
        testID="mail-shell"
        onLayout={({ nativeEvent }) => {
          setHeight(nativeEvent.layout.height);
        }}
        style={styles.fill}>
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
              onView={(next) => {
                setView(next);
                // On iPhone a Mailbox opens its list; beside it, the list is already shown.
                splitView.current?.show('supplementary');
              }}
            />
          </SplitView.Column>
          <SplitView.Column>
            <View
              ref={list}
              style={styles.fill}
              onLayout={() => {
                list.current?.measureInWindow((x, _y, listWidth) => {
                  setReaderLeft(x + listWidth);
                });
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
                    pathname: open === undefined ? '/' : '/compose/[draft]',
                    params: {
                      ...(open === undefined ? {} : { draft: open }),
                      profileId: shownProfile,
                    },
                  });
                  // On iPhone the list returns over the reader, or over Mailboxes for the palette.
                  splitView.current?.show('supplementary');
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
                onView={setView}
                selected={
                  id === undefined || mailbox === undefined
                    ? undefined
                    : { mailbox, id }
                }
                view={view}
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
                      left: readerLeft + spacing.m,
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
  );
}

export default function RootLayout() {
  const { profileId } = useGlobalSearchParams<{
    profileId?: string | string[];
  }>();
  return (
    <RegistrationGate>
      <InboxProvider>
        <ProfileScope profile={readingProfile(profileId)}>
          <MailShell />
        </ProfileScope>
      </InboxProvider>
    </RegistrationGate>
  );
}
