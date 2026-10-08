import { Pressable, StyleSheet, Text } from 'react-native';

import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  label: { fontSize: 14, lineHeight: 21 },
});

// A text button in the reader.
export function Action({
  label,
  accessibilityLabel,
  onPress,
}: {
  readonly label: string;
  readonly accessibilityLabel?: string;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
      focusable
      onPress={onPress}>
      <Text style={[styles.label, { color: colors.accent }]}>{label}</Text>
    </Pressable>
  );
}
