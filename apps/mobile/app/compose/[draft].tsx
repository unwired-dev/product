import { useLocalSearchParams } from 'expo-router';

import { MessageDetail } from '../../src/message-detail.tsx';
import { ReaderPane } from '../../src/reader-chrome.tsx';

export default function ComposeRoute() {
  const { id, mailbox } = useLocalSearchParams<{
    id?: string;
    mailbox?: string;
  }>();
  return (
    <ReaderPane
      testID="compose-reader-pane"
      pointerEvents="none"
      accessibilityElementsHidden>
      <MessageDetail
        id={id}
        mailbox={mailbox}
      />
    </ReaderPane>
  );
}
