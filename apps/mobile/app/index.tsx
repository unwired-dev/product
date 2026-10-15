import { MessageDetail } from '../src/message-detail.tsx';
import { ReaderPane } from '../src/reader-chrome.tsx';

export default function InboxWelcome() {
  return (
    <ReaderPane>
      <MessageDetail
        id={undefined}
        mailbox={undefined}
      />
    </ReaderPane>
  );
}
