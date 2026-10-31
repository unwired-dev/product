import { radius, spacing } from '@private-email/mail-core/theme';
import { Pressable, StyleSheet, Text } from 'react-native';

import { SFSymbol } from './design.tsx';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  button: {
    minHeight: 44,
    minWidth: 44,
    maxWidth: '100%',
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    paddingHorizontal: 14,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  label: { ...textStyles.subheadline, flexShrink: 1 },
});

// A keyboard-focusable control; a checked state makes it a checkbox.
export function ActionButton({
  label,
  onPress,
  checked,
}: {
  readonly label: string;
  readonly onPress: () => void;
  readonly checked?: boolean;
}) {
  const colors = usePalette();
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole={checked === undefined ? 'button' : 'checkbox'}
      accessibilityState={checked === undefined ? undefined : { checked }}
      focusable
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        {
          backgroundColor: pressed
            ? colors.accentSelectionSubtle
            : colors.fillQuiet,
        },
      ]}>
      {checked === true ? (
        <SFSymbol
          name="checkmark"
          color={colors.textPrimary}
        />
      ) : null}
      <Text style={[styles.label, { color: colors.textPrimary }]}>{label}</Text>
    </Pressable>
  );
}
