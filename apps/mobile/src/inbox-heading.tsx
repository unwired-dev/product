import type { RefObject } from 'react';
import type { TextInput } from 'react-native';

import { inboxCommands } from '@private-email/mail-core/commands';
import { Text, View } from 'react-native';

import {
  CommandInput,
  PaletteHint,
  RegisterCommands,
  usePaletteHeader,
} from './command-palette.tsx';
import { styles } from './inbox-styles.ts';
import { useLocalization } from './localization.ts';
import { usePalette } from './theme.ts';

// The Inbox heading, which opens the Command Palette by a downward swipe, its accessibility
// action or, on iPad, its command input, with the one-time hint beneath it; and the app-wide and
// navigation commands the Inbox offers while each of their controls is available.
export function InboxHeading({
  title,
  subtitle,
  detail,
  account,
  onAccount,
  onClose,
  onLeave,
  search,
  searchable,
}: {
  readonly title: string;
  readonly subtitle: string;
  // Whether a reader or composer is open; Search Mail leaves it first, since on iPhone and in
  // compact iPad layouts it covers the Inbox.
  readonly detail: boolean;
  readonly account: Readonly<{ openAccount: () => void }> | undefined;
  readonly onAccount: (open: () => void) => Promise<void>;
  readonly onClose: (() => void) | undefined;
  readonly onLeave: () => Promise<boolean>;
  // The search field, which Search Mail focuses while the Inbox can search.
  readonly search: RefObject<TextInput | null>;
  readonly searchable: boolean;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const header = usePaletteHeader();
  return (
    <>
      <RegisterCommands
        offer={() =>
          inboxCommands(t, {
            search: searchable
              ? async () => {
                  if (detail && onClose !== undefined) {
                    if (!(await onLeave())) {
                      return;
                    }
                    onClose();
                  }
                  search.current?.focus();
                }
              : undefined,
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
                    void onAccount(account.openAccount);
                  },
          })
        }
      />
      <View {...header.swipe}>
        <CommandInput style={styles.commands} />
        <View style={styles.heading}>
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
        </View>
      </View>
      <PaletteHint />
    </>
  );
}
