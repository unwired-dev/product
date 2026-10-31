import { radius } from '@private-email/mail-core/theme';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  target: { minHeight: 44, minWidth: 44, justifyContent: 'center' },
  // A reader action's capsule reaches past its label, which stays aligned with the text around it.
  outset: { marginHorizontal: -8 },
  capsule: {
    alignSelf: 'flex-start',
    paddingHorizontal: 8,
    paddingVertical: 4,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
});

// A text button: pressed fills, disabled greys. Composer actions are padded
// controls at the body size of its fields; list actions, such as online search, keep the reader's
// alignment at the body size of the list's notices.
export function Action({
  label,
  accessibilityLabel,
  onPress,
  disabled = false,
  destructive = false,
  expanded,
  variant = 'reader',
}: {
  readonly label: string;
  readonly accessibilityLabel?: string;
  readonly onPress: () => void;
  readonly disabled?: boolean;
  readonly destructive?: boolean;
  readonly expanded?: boolean;
  readonly variant?: 'reader' | 'composer' | 'list';
}) {
  const colors = usePalette();
  let color = destructive ? colors.statusDestructive : colors.accentInk;
  if (disabled) {
    color = colors.textSecondary;
  }
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel ?? label}
      accessibilityState={{ disabled, expanded }}
      disabled={disabled}
      focusable
      onPress={onPress}
      style={styles.target}>
      {({ pressed }) => (
        <View
          style={[
            styles.capsule,
            variant === 'composer' ? null : styles.outset,
            {
              backgroundColor: pressed
                ? colors.accentSelectionSubtle
                : 'transparent',
            },
          ]}>
          <Text
            style={[
              variant === 'reader' ? textStyles.subheadline : textStyles.body,
              { color },
            ]}>
            {label}
          </Text>
        </View>
      )}
    </Pressable>
  );
}
