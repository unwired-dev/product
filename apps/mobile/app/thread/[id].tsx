import { useLocalSearchParams } from 'expo-router';

import { ThreadView } from '../../src/message-detail.tsx';
import { ReaderPane } from '../../src/reader-chrome.tsx';

export default function ThreadRoute() {
  const { id, mailbox } = useLocalSearchParams<{
    id: string;
    mailbox?: string;
  }>();
  return (
    <ReaderPane>
      <ThreadView
        id={id}
        mailbox={mailbox}
      />
    </ReaderPane>
  );
}
