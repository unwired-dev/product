import { useLocalSearchParams } from 'expo-router';
import { View } from 'react-native';

import { MessageDetail } from '../../src/message-detail.tsx';

export default function ComposeRoute() {
  const { id, mailbox } = useLocalSearchParams<{
    id?: string;
    mailbox?: string;
  }>();
  return (
    <View
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
