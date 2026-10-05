import type { ComponentProps } from 'react';

import { View } from 'react-native';

// The isolated WebKit view at the Jest native boundary. Tests read its configuration and drive
// its native events: content size, navigation requests and content-process termination.
export function WebView(props: ComponentProps<typeof View>) {
  return (
    <View
      testID="message-webview"
      {...props}
    />
  );
}
