import type { ComponentProps, ReactNode, RefObject } from 'react';
import type { ViewProps } from 'react-native';

import { createContext, use, useLayoutEffect, useRef } from 'react';
import { ScreenStackItem } from 'react-native-screens';

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
  const nativeBack = use(NativeBackContext);
  useLayoutEffect(() => {
    if (nativeBack === undefined || onBack === undefined) {
      return;
    }
    nativeBack.current = onBack;
    return () => {
      if (nativeBack.current === onBack) {
        nativeBack.current = undefined;
      }
    };
  }, [nativeBack, onBack]);
  const style = [
    styles.fill,
    { backgroundColor: colors.surfaceContent },
    props.style,
  ];
  if (
    nativeBack !== undefined ||
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
