import type { ReactNode } from 'react';

import { inboxCommands } from '@private-email/mail-core/commands';
import { Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import {
  CommandInput,
  CommandPaletteProvider,
  RegisterCommands,
  usePaletteHeader,
} from './command-palette.tsx';
import { useLocalization } from './localization.ts';
import { registrationStyles as styles } from './registration-styles.ts';
import { usePalette } from './theme.ts';

// The account page of a connected Inbox keeps the Command Palette, which offers the way back to
// the Inbox. The page has its own palette, so an open one leaves with the page when the gate
// replaces it.
export function AccountPage({
  title,
  onInbox,
  children,
}: {
  readonly title: string;
  readonly onInbox: () => void;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <CommandPaletteProvider>
      <View style={[styles.page, { backgroundColor: colors.surfaceContent }]}>
        <RegisterCommands offer={() => inboxCommands(t, { inbox: onInbox })} />
        <AccountHeader title={title} />
        {children}
      </View>
    </CommandPaletteProvider>
  );
}

// The page's title as a fixed header that opens the palette by a downward swipe, its
// accessibility action or, on iPad, the command input. The gate renders outside any screen, so
// the header clears the status bar with the root's insets, as the palette sheet does.
function AccountHeader({ title }: { readonly title: string }) {
  const colors = usePalette();
  const header = usePaletteHeader();
  const insets = useSafeAreaInsets();
  return (
    <View
      style={[
        styles.accountHeader,
        {
          marginTop: insets.top,
          marginLeft: insets.left,
          marginRight: insets.right,
        },
      ]}
      {...header.swipe}>
      <View style={styles.accountHeading}>
        <Text
          accessibilityRole="header"
          style={[styles.title, styles.grow, { color: colors.textPrimary }]}
          {...header.action}>
          {title}
        </Text>
        <CommandInput />
      </View>
    </View>
  );
}
