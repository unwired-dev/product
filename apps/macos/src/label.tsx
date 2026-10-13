import type { StyleProp, TextStyle } from 'react-native';

import { Text, View } from 'react-native';

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
  return (
    <View
      accessible
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
