import type { StyleProp, TextStyle } from 'react-native';

import { Text, View } from 'react-native';

// React Native macOS exposes plain Text to accessibility only through an accessible parent.
export function Label({
  children,
  accessibilityRole = 'text',
  style,
}: {
  readonly children: string;
  readonly accessibilityRole?: 'alert' | 'header' | 'text';
  readonly style: StyleProp<TextStyle>;
}) {
  return (
    <View
      accessible
      accessibilityRole={accessibilityRole}
      accessibilityLabel={children}>
      <Text style={style}>{children}</Text>
    </View>
  );
}
