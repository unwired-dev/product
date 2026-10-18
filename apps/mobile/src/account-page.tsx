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
import { Glass, SFSymbol } from './design.tsx';
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
// accessibility action or, on iPad, the command input. iPhone centers the title between the way
// back and the accessory. The gate renders outside any screen, so on iPhone the header clears
// the status bar with the root's insets, as the palette sheet does; the iPad workspace has
// already cleared it.
export function AccountHeader({
  title,
  onBack,
  backLabel,
  accessory,
}: {
  readonly title: string;
  readonly onBack?: (() => void) | undefined;
  readonly backLabel?: string;
  readonly accessory?: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
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
        {pad && onBack === undefined ? null : (
          <View style={pad ? undefined : styles.phoneHeaderSlot}>
            {onBack === undefined ? null : (
              <Pressable
                accessibilityLabel={backLabel ?? t('settings.back')}
                accessibilityRole="button"
                onPress={onBack}
                style={[styles.back, { boxShadow: colors.smallGlassShadow }]}>
                <Glass cornerRadius={22} />
                <SFSymbol
                  name="chevron.left"
                  size={17}
                  color={colors.textPrimary}
                />
              </Pressable>
            )}
          </View>
        )}
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
