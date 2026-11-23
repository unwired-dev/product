import type { ReactNode } from 'react';

import {
  inboxCommands,
  sidebarCommands,
} from '@private-email/mail-core/commands';
import { use } from 'react';
import {
  Platform,
  Pressable,
  Text,
  useWindowDimensions,
  View,
} from 'react-native';

import type { MailboxView } from './sidebar.tsx';

import {
  CommandInput,
  RegisterCommands,
  usePaletteHeader,
} from './command-palette.tsx';
import { NavigationChrome } from './design.tsx';
import { WindowBarContext } from './inbox-bar.tsx';
import { barInset, styles } from './inbox-styles.ts';
import { useLocalization } from './localization.ts';
import { SidebarToggle, SidebarToggleContext } from './sidebar-toggle.tsx';
import { useLargeText, usePalette } from './theme.ts';

const pad = Platform.OS === 'ios' && Platform.isPad;

// The Inbox's title and status line, centered in iPhone's navigation bar clear of its Back. The
// bar keeps them at its own size, as UIKit's bar titles do; elsewhere they take up to two lines at
// accessibility text sizes.
export function HeadingTitle({
  title,
  subtitle,
  bar,
}: {
  readonly title: string;
  readonly subtitle: string;
  readonly bar: boolean | undefined;
}) {
  const colors = usePalette();
  const header = usePaletteHeader();
  const { width } = useWindowDimensions();
  // The heading stays put above the list, so a long folder name leaves the list room.
  const lines = useLargeText() && !bar ? 2 : 1;
  const scale = bar ? 1 : undefined;
  const text = (
    // The bar takes one native view as its title, so layout must not flatten this one away.
    <View
      collapsable={false}
      style={
        bar
          ? [styles.barTitle, { width: width - 2 * barInset }]
          : styles.headingText
      }>
      <Text
        accessibilityRole="header"
        maxFontSizeMultiplier={scale}
        numberOfLines={lines}
        style={[styles.title, { color: colors.textPrimary }]}
        {...header.action}>
        {title}
      </Text>
      <View style={styles.subtitle}>
        <Text
          accessibilityLiveRegion="polite"
          maxFontSizeMultiplier={scale}
          numberOfLines={lines}
          style={[styles.subtitleText, { color: colors.textSecondary }]}>
          {subtitle}
        </Text>
      </View>
    </View>
  );
  return bar ? text : <View style={styles.heading}>{text}</View>;
}

// Search's choice between the shown mailbox and every Inbox of the Profile.
export function SearchScope({
  all,
  onAll,
}: {
  readonly all: boolean;
  readonly onAll: (all: boolean) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const segment = (label: string, selected: boolean, value: boolean) => (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="tab"
      accessibilityState={{ selected }}
      hitSlop={4}
      onPress={() => {
        onAll(value);
      }}
      style={[
        styles.segment,
        selected && { backgroundColor: colors.accentFill },
      ]}>
      <Text
        numberOfLines={1}
        style={[
          styles.segmentLabel,
          selected
            ? { color: colors.accentOnFill, fontWeight: '600' }
            : { color: colors.textPrimary },
        ]}>
        {label}
      </Text>
    </Pressable>
  );
  return (
    <View
      accessibilityRole="tablist"
      style={[styles.segments, { backgroundColor: colors.fillQuiet }]}>
      {segment(t('search.allMailboxes'), all, true)}
      {segment(t('search.currentMailbox'), !all, false)}
    </View>
  );
}

// The Inbox heading, which opens the Command Palette by a downward swipe, its accessibility
// action or, on iPad, its command input; and the app-wide and navigation commands the Inbox offers
// while each of their controls is available.
export function InboxHeading({
  children,
  detail,
  account,
  onClose,
  bar,
  searching,
  onLeave,
  onSearch,
  onView,
  covered,
}: {
  // The title, or search's scope while searching.
  readonly children: ReactNode;
  // On iPhone's single column, the system navigation bar shows the title and owns Back to
  // Mailboxes and its edge swipe; searching hides it.
  readonly bar: boolean | undefined;
  readonly searching: boolean;
  // Whether a reader or composer is open; Search Mail leaves it first, since on iPhone and in
  // compact iPad layouts it covers the Inbox.
  readonly detail: boolean;
  readonly account: Readonly<{ openAccount: () => void }> | undefined;
  readonly onClose: (() => void) | undefined;
  readonly onLeave: () => Promise<boolean>;
  // Opens search; absent until the Inbox can search.
  readonly onSearch: (() => void) | undefined;
  // Shows another mailbox in the list.
  readonly onView: (view: MailboxView) => void;
  // Whether the composer, expanded to the regular-width window, covers the list.
  readonly covered: boolean | undefined;
}) {
  const { t } = useLocalization();
  const sidebar = use(SidebarToggleContext);
  // The regular-width shell, whose list stays in view beside the reader and the composer.
  const regular = use(WindowBarContext) !== undefined;
  const colors = usePalette();
  const header = usePaletteHeader();
  const inBar = bar === true && !searching;
  return (
    <>
      <RegisterCommands
        offer={() =>
          inboxCommands(t, {
            search:
              onSearch === undefined
                ? undefined
                : async () => {
                    // Closing also brings the list forward when Mailboxes covers it on iPhone.
                    if (onClose !== undefined) {
                      if (detail && !(await onLeave())) {
                        return;
                      }
                      onClose();
                    }
                    sidebar?.showList?.();
                    onSearch();
                  },
            inbox:
              onClose === undefined
                ? undefined
                : async () => {
                    if (await onLeave()) {
                      sidebar?.showList?.();
                      onClose();
                    }
                  },
            account:
              account === undefined
                ? undefined
                : () => {
                    account.openAccount();
                  },
          })
        }
      />
      {/* Go To each Unified Mailbox, which stays reachable here when Favorites hides it. Where a
        reader or composer covers the list, it leaves it first, as Search Mail does; beside them it
        shows the mailbox, as its row does. */}
      <RegisterCommands
        offer={() =>
          sidebarCommands(t, {
            unified: async (role) => {
              if ((!regular || covered === true) && onClose !== undefined) {
                if (detail && !(await onLeave())) {
                  return;
                }
                onClose();
              }
              sidebar?.showList?.();
              onView({ unified: role });
            },
          })
        }
      />
      {/* The bar's title stays inside the swipe's responder, which follows React's tree. */}
      <View {...header.swipe}>
        {bar === true ? (
          <NavigationChrome
            backLabel={inBar ? t('mailboxes.back') : undefined}
            surface={colors.surfaceContent}>
            {inBar ? children : null}
          </NavigationChrome>
        ) : null}
        {pad ? (
          // While Mailboxes hides, its toggle leads the list's command row.
          <View style={styles.commandRow}>
            {sidebar?.shown === false ? <SidebarToggle /> : null}
            <CommandInput style={styles.commands} />
          </View>
        ) : null}
        {inBar ? null : children}
      </View>
    </>
  );
}
