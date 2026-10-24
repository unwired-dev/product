import type { ReactNode } from 'react';

import { inboxCommands } from '@private-email/mail-core/commands';
import { Platform, Pressable, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import {
  CommandInput,
  CommandPaletteProvider,
  RegisterCommands,
  usePaletteHeader,
} from './command-palette.tsx';
import { GlassGroup, SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { registrationStyles as styles } from './registration-styles.ts';
import { textStyles, usePalette } from './theme.ts';

const pad = Platform.OS === 'ios' && Platform.isPad;

// The account page of a connected Inbox keeps the Command Palette, which offers the way back to
// the Inbox. The page has its own palette, so an open one leaves with the page when the gate
// replaces it.
export function AccountPage({
  onInbox,
  children,
}: {
  readonly onInbox: () => void;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <CommandPaletteProvider>
      <View style={[styles.page, { backgroundColor: colors.surfaceContent }]}>
        <RegisterCommands offer={() => inboxCommands(t, { inbox: onInbox })} />
        {children}
      </View>
    </CommandPaletteProvider>
  );
}

// A page's title as a fixed header that opens the palette by a downward swipe, its
// accessibility action or, on iPad, the command input. iPhone centers the title between the
// leading control, such as Back, and the accessory. The gate renders outside any screen, so on
// iPhone the header clears the status bar with the root's insets, as the palette sheet does; the
// iPad workspace has already cleared it.
export function AccountHeader({
  title,
  leading,
  accessory,
}: {
  readonly title: string;
  // Shown before the title on iPhone.
  readonly leading?: ReactNode;
  readonly accessory?: ReactNode;
}) {
  const colors = usePalette();
  const header = usePaletteHeader();
  const insets = useSafeAreaInsets();
  return (
    <View
      style={[
        styles.accountHeader,
        pad
          ? undefined
          : {
              marginTop: insets.top,
              marginLeft: insets.left,
              marginRight: insets.right,
            },
      ]}
      {...header.swipe}>
      <View style={styles.accountHeading}>
        {pad ? null : <View style={styles.phoneHeaderSlot}>{leading}</View>}
        <Text
          accessibilityRole="header"
          numberOfLines={1}
          style={[
            pad ? styles.padTitle : textStyles.headline,
            styles.grow,
            !pad && styles.centered,
            { color: colors.textPrimary },
          ]}
          {...header.action}>
          {title}
        </Text>
        {pad ? (
          accessory
        ) : (
          <View style={[styles.phoneHeaderSlot, styles.phoneAccessory]}>
            {accessory}
          </View>
        )}
        <CommandInput />
      </View>
    </View>
  );
}

// A 44pt interactive glass circle in a page's header, such as Back or Open Inbox.
export function HeaderButton({
  label,
  icon,
  disabled = false,
  onPress,
}: {
  readonly label: string;
  readonly icon: string;
  readonly disabled?: boolean;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  return (
    <GlassGroup style={[styles.headerButton, disabled && styles.dimmed]}>
      <Pressable
        accessibilityLabel={label}
        accessibilityRole="button"
        accessibilityState={{ disabled }}
        disabled={disabled}
        onPress={onPress}
        style={styles.back}>
        <SFSymbol
          name={icon}
          size={20}
          color={colors.textPrimary}
        />
      </Pressable>
    </GlassGroup>
  );
}
