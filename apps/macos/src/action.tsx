import { Pressable, StyleSheet, Text } from 'react-native';

import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  target: { minHeight: 28, minWidth: 28, justifyContent: 'center' },
  label: { ...textStyles.body },
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
      onPress={onPress}
      style={styles.target}>
      <Text style={[styles.label, { color: colors.accentInk }]}>{label}</Text>
    </Pressable>
  );
}
