import type { ViewProps } from 'react-native';

import {
  Platform,
  requireNativeComponent,
  StyleSheet,
  View,
} from 'react-native';

import { usePalette } from './theme.ts';

const NativeBackNavigation = requireNativeComponent<
  ViewProps & { readonly onBack: () => void }
>('UnwiredBackNavigation');

const styles = StyleSheet.create({ fill: { flex: 1 } });

// Existing Back actions keep ownership of routing and guarded Draft closure.
export function BackNavigation({
  onBack,
  children,
  ...props
}: ViewProps & { readonly onBack?: (() => void) | undefined }) {
  const colors = usePalette();
  const style = [
    styles.fill,
    { backgroundColor: colors.surfaceContent },
    props.style,
  ];
  if (Platform.OS !== 'ios' || Platform.isPad || onBack === undefined) {
    return (
      <View
        {...props}
        style={style}>
        {children}
      </View>
    );
  }
  return (
    <NativeBackNavigation
      {...props}
      onBack={onBack}
      style={style}>
      {children}
    </NativeBackNavigation>
  );
}
