import {
  Host,
  Button as SwiftUIButton,
  Text as SwiftUIText,
} from '@expo/ui/swift-ui';
import {
  background,
  buttonStyle,
  contentShape,
  font,
  foregroundStyle,
  frame,
  padding,
  shapes,
} from '@expo/ui/swift-ui/modifiers';
import { radius } from '@private-email/mail-core/theme';
import { StyleSheet } from 'react-native';

import { useLargeText, usePalette } from './theme.ts';

const styles = StyleSheet.create({ wide: { width: '100%' } });

// The system button on the quiet fill, with the system's press feedback (#3140). A wide one, and
// every one at the large text sizes, fills its row so its title wraps.
export function ActionButton({
  label,
  onPress,
  wide = false,
}: {
  readonly label: string;
  readonly onPress: () => void;
  readonly wide?: boolean;
}) {
  const colors = usePalette();
  const fill = useLargeText() || wide;
  return (
    <Host
      key={fill ? 'fill' : 'ideal'}
      matchContents={fill ? { vertical: true } : true}
      style={fill ? styles.wide : null}>
      <SwiftUIButton
        onPress={onPress}
        modifiers={[buttonStyle('plain')]}>
        <SwiftUIText
          modifiers={[
            font({ textStyle: 'subheadline' }),
            foregroundStyle(colors.textPrimary),
            padding({ horizontal: 14 }),
            frame({
              minWidth: 44,
              maxWidth: fill ? Infinity : undefined,
              minHeight: 44,
              alignment: 'leading',
            }),
            background(
              colors.fillQuiet,
              shapes.roundedRectangle({ cornerRadius: radius.control }),
            ),
            contentShape(shapes.rectangle()),
          ]}>
          {label}
        </SwiftUIText>
      </SwiftUIButton>
    </Host>
  );
}
