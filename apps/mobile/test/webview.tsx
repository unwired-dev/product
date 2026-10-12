import type { ComponentProps, Ref } from 'react';

import { useImperativeHandle } from 'react';
import { View } from 'react-native';

// Scripts the host ran in its page, in order.
export const injectedScripts: string[] = [];

// The isolated WebKit view at the Jest native boundary. Tests read its configuration and drive
// its native events: content size, navigation requests and content-process termination.
export function WebView({
  ref,
  ...props
}: ComponentProps<typeof View> & {
  readonly ref?: Ref<{ injectJavaScript: (script: string) => void }>;
}) {
  useImperativeHandle(ref, () => ({
    injectJavaScript: (script) => {
      injectedScripts.push(script);
    },
  }));
  return (
    <View
      testID="message-webview"
      {...props}
    />
  );
}
