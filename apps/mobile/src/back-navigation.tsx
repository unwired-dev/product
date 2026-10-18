import type { ComponentProps, ReactNode, RefObject } from 'react';
import type { ViewProps } from 'react-native';

import { createContext, use, useLayoutEffect, useRef } from 'react';
import {
  Platform,
  requireNativeComponent,
  StyleSheet,
  View,
} from 'react-native';
import { ScreenStackItem } from 'react-native-screens';

import { usePalette } from './theme.ts';

const NativeBackNavigation = requireNativeComponent<
  ViewProps & { readonly onBack: () => void }
>('UnwiredBackNavigation');

const styles = StyleSheet.create({ fill: { flex: 1 } });
const NativeBackContext = createContext<
  RefObject<(() => void) | undefined> | undefined
>(undefined);

// Native destinations retain the actual preceding screen during an interactive pop.
export function BackScreen({
  children,
  onDismissed,
  ...props
}: ComponentProps<typeof ScreenStackItem> & { readonly children: ReactNode }) {
  const back = useRef<(() => void) | undefined>(undefined);
  return (
    <NativeBackContext value={back}>
      <ScreenStackItem
        {...props}
        style={[StyleSheet.absoluteFill, props.style]}
        onDismissed={(event) => {
          back.current?.();
          onDismissed?.(event);
        }}
        onNativeDismissCancelled={() => {
          back.current?.();
        }}>
        {children}
      </ScreenStackItem>
    </NativeBackContext>
  );
}

// Existing Back actions keep ownership of routing and guarded Draft closure.
export function BackNavigation({
  onBack,
  children,
  ...props
}: ViewProps & { readonly onBack?: (() => void) | undefined }) {
  const colors = usePalette();
  const nativeBackRef = use(NativeBackContext);
  useLayoutEffect(() => {
    if (nativeBackRef === undefined || onBack === undefined) {
      return;
    }
    nativeBackRef.current = onBack;
    return () => {
      if (nativeBackRef.current === onBack) {
        nativeBackRef.current = undefined;
      }
    };
  }, [nativeBackRef, onBack]);
  const style = [
    styles.fill,
    { backgroundColor: colors.surfaceContent },
    props.style,
  ];
  if (
    nativeBackRef !== undefined ||
    Platform.OS !== 'ios' ||
    Platform.isPad ||
    onBack === undefined
  ) {
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
