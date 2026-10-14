import { useLocalSearchParams } from 'expo-router';
import { use } from 'react';
import { View } from 'react-native';

import { MessageDetail } from '../../src/message-detail.tsx';
import { ReaderPaneWidthContext } from '../../src/reader-chrome.tsx';

export default function ComposeRoute() {
  const onWidth = use(ReaderPaneWidthContext);
  const { id, mailbox } = useLocalSearchParams<{
    id?: string;
    mailbox?: string;
  }>();
  return (
    <View
      testID="compose-reader-pane"
      onLayout={({ nativeEvent }) => {
        onWidth?.(nativeEvent.layout.width);
      }}
      pointerEvents="none"
      accessibilityElementsHidden
      style={{ flex: 1 }}>
      <MessageDetail
        id={id}
        mailbox={mailbox}
      />
    </View>
  );
}
