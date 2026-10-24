import { radius } from '@private-email/mail-core/theme';
import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  target: { minHeight: 28, minWidth: 28, justifyContent: 'center' },
  // A reader action's capsule reaches past its label, which stays aligned with the text around it.
  outset: { marginHorizontal: -8 },
  capsule: {
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderWidth: 2,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  label: { ...textStyles.body },
});

// A text button: pressed fills, keyboard focus rings, disabled greys. Composer actions are padded
// controls.
export function Action({
  label,
  accessibilityLabel,
  onPress,
  disabled = false,
  destructive = false,
  variant = 'reader',
}: {
  readonly label: string;
  readonly accessibilityLabel?: string;
  readonly onPress: () => void;
  readonly disabled?: boolean;
  readonly destructive?: boolean;
  readonly variant?: 'reader' | 'composer';
}) {
  const colors = usePalette();
  const [focused, setFocused] = useState(false);
  let color = destructive ? colors.statusDestructive : colors.accentInk;
  if (disabled) {
    color = colors.textSecondary;
  }
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel ?? label}
      accessibilityState={{ disabled }}
      disabled={disabled}
      focusable
      onBlur={() => {
        setFocused(false);
      }}
      onFocus={() => {
        setFocused(true);
      }}
      onPress={onPress}
      style={[styles.target, variant === 'reader' ? styles.outset : null]}>
      {({ pressed }) => (
        <View
          style={[
            styles.capsule,
            {
              backgroundColor: pressed
                ? colors.accentSelectionSubtle
                : 'transparent',
              borderColor:
                focused && !disabled ? colors.accentInk : 'transparent',
            },
          ]}>
          <Text style={[styles.label, { color }]}>{label}</Text>
        </View>
      )}
    </Pressable>
  );
}
