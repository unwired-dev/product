import type { ReactNode } from 'react';

import { inboxCommands } from '@private-email/mail-core/commands';
import { Pressable, Text, View } from 'react-native';

import {
  CommandInput,
  PaletteHint,
  RegisterCommands,
  usePaletteHeader,
} from './command-palette.tsx';
import { Glass, NavigationChrome, SFSymbol } from './design.tsx';
import { styles } from './inbox-styles.ts';
import { useLocalization } from './localization.ts';
import { usePalette } from './theme.ts';

// The Inbox's title and status line, centered between Back and its balancing space on iPhone.
export function HeadingTitle({
  title,
  subtitle,
  onBack,
}: {
  readonly title: string;
  readonly subtitle: string;
  readonly onBack?: (() => void) | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const header = usePaletteHeader();
  return (
    <View style={styles.heading}>
      {onBack === undefined ? null : (
        <Glass
          interactive
          cornerRadius={22}
          style={{ boxShadow: colors.smallGlassShadow }}>
          <Pressable
            accessibilityLabel={t('mailboxes.back')}
            accessibilityRole="button"
            onPress={onBack}
            style={styles.back}>
            <SFSymbol
              name="chevron.left"
              size={17}
              color={colors.textPrimary}
            />
          </Pressable>
        </Glass>
      )}
      <View style={styles.headingText}>
        <Text
          accessibilityRole="header"
          numberOfLines={1}
          style={[styles.title, { color: colors.textPrimary }]}
          {...header.action}>
          {title}
        </Text>
        <View style={styles.subtitle}>
          <Text
            accessibilityLiveRegion="polite"
            numberOfLines={1}
            style={[styles.subtitleText, { color: colors.textSecondary }]}>
            {subtitle}
          </Text>
        </View>
      </View>
      {onBack === undefined ? null : <View style={styles.back} />}
    </View>
  );
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
// action or, on iPad, its command input, with the one-time hint beneath it; and the app-wide and
// navigation commands the Inbox offers while each of their controls is available.
export function InboxHeading({
  children,
  detail,
  account,
  onClose,
  onBack,
  onLeave,
  onSearch,
}: {
  // The title, or search's scope while searching.
  readonly children: ReactNode;
  // Whether a reader or composer is open; Search Mail leaves it first, since on iPhone and in
  // compact iPad layouts it covers the Inbox.
  readonly detail: boolean;
  readonly account: Readonly<{ openAccount: () => void }> | undefined;
  readonly onClose: (() => void) | undefined;
  // Present while the Inbox replaces the native navigation bar with its own Back.
  readonly onBack: (() => void) | undefined;
  readonly onLeave: () => Promise<boolean>;
  // Opens search; absent until the Inbox can search.
  readonly onSearch: (() => void) | undefined;
}) {
  const { t } = useLocalization();
  const header = usePaletteHeader();
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
                    onSearch();
                  },
            inbox:
              onClose === undefined
                ? undefined
                : async () => {
                    if (await onLeave()) {
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
      {onBack === undefined ? null : <NavigationChrome />}
      <View {...header.swipe}>
        <CommandInput style={styles.commands} />
        {children}
      </View>
      <PaletteHint />
    </>
  );
}
