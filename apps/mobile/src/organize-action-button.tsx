import { Host, Button as SwiftUIButton } from '@expo/ui/swift-ui';
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

import { usePalette } from './theme.ts';

// The system button on the quiet fill, with the system's press feedback (#3140).
export function ActionButton({
  label,
  onPress,
}: {
  readonly label: string;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  return (
    <Host matchContents>
      <SwiftUIButton
        label={label}
        onPress={onPress}
        modifiers={[
          buttonStyle('plain'),
          font({ textStyle: 'subheadline' }),
          foregroundStyle(colors.textPrimary),
          padding({ horizontal: 14 }),
          frame({ minWidth: 44, minHeight: 44 }),
          background(
            colors.fillQuiet,
            shapes.roundedRectangle({ cornerRadius: radius.control }),
          ),
          contentShape(shapes.rectangle()),
        ]}
      />
    </Host>
  );
}
