import type { RefObject } from 'react';
import type { TextInput } from 'react-native';

import { inboxCommands } from '@private-email/mail-core/commands';
import { Pressable, Text, View } from 'react-native';

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
  subtitle,
  detail,
  account,
  onAccount,
  onClose,
  onLeave,
  search,
}: {
  readonly subtitle: string;
  // Whether a reader or composer covers the Inbox on iPhone; Search Mail leaves it first.
  readonly detail: boolean;
  readonly account: Readonly<{ openAccount: () => void }> | undefined;
  readonly onAccount: (open: () => void) => Promise<void>;
  readonly onClose: (() => void) | undefined;
  readonly onLeave: () => Promise<boolean>;
  // The search field, once the Inbox can search.
  readonly search: RefObject<TextInput | null> | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const header = usePaletteHeader();
  return (
    <>
      <RegisterCommands
        offer={() =>
          inboxCommands(t, {
            search:
              search === undefined
                ? undefined
                : async () => {
                    if (detail && onClose !== undefined) {
                      if (!(await onLeave())) {
                        return;
                      }
                      onClose();
                    }
                    search.current?.focus();
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
                    void onAccount(account.openAccount);
                  },
          })
        }
      />
      <View
        style={styles.heading}
        {...header.swipe}>
        <CommandInput style={styles.commands} />
        <View style={styles.headingRow}>
          <View style={styles.headingText}>
            <Text
              accessibilityRole="header"
              style={[styles.title, { color: colors.textPrimary }]}
              {...header.action}>
              {t('inbox.title')}
            </Text>
            <Text style={[styles.subtitle, { color: colors.textSecondary }]}>
              {subtitle}
            </Text>
          </View>
          {account === undefined ? null : (
            <Pressable
              accessibilityRole="button"
              onPress={() => {
                void onAccount(account.openAccount);
              }}>
              <Text style={[styles.account, { color: colors.accentInk }]}>
                {t('inbox.account')}
              </Text>
            </Pressable>
          )}
        </View>
      </View>
      <PaletteHint />
    </>
  );
}
