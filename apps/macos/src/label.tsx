import type { StyleProp, TextStyle } from 'react-native';

import { StyleSheet, Text, View } from 'react-native';

// The accessibility frame is the wrapper's, so it hugs the text: the macOS contrast audit
// measures every pixel in that frame. A Label in a centred row passes alignSelf 'center'.
const hug = {
  auto: 'flex-start',
  left: 'flex-start',
  justify: 'flex-start',
  center: 'center',
  right: 'flex-end',
} as const;

// React Native macOS exposes plain Text to accessibility only through an accessible parent.
export function Label({
  children,
  accessibilityRole = 'text',
  accessibilityLiveRegion,
  style,
  numberOfLines,
}: {
  readonly children: string;
  readonly accessibilityRole?: 'alert' | 'header' | 'text';
  readonly accessibilityLiveRegion?: 'polite' | undefined;
  readonly style: StyleProp<TextStyle>;
  readonly numberOfLines?: number;
}) {
  const { alignSelf, textAlign } = StyleSheet.flatten(style);
  return (
    <View
      accessible
      style={{ alignSelf: alignSelf ?? hug[textAlign ?? 'auto'] }}
      accessibilityLiveRegion={accessibilityLiveRegion}
      accessibilityRole={accessibilityRole}
      accessibilityLabel={children}>
      <Text
        style={style}
        numberOfLines={numberOfLines}>
        {children}
      </Text>
    </View>
  );
}
