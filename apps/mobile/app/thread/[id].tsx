import { router, useLocalSearchParams } from 'expo-router';

import { useProfile } from '../../src/mailbox.tsx';
import { ThreadView } from '../../src/message-detail.tsx';
import { ReaderPane } from '../../src/reader-chrome.tsx';

export default function ThreadRoute() {
  const profile = useProfile();
  const { id, mailbox } = useLocalSearchParams<{
    id: string;
    mailbox?: string;
  }>();
  return (
    <ReaderPane>
      <ThreadView
        id={id}
        mailbox={mailbox}
        onClose={() => {
          // A Thread opened from Catch Up returns there; one cold-opened from its deep link has
          // no history, so Back shows the Inbox.
          if (router.canGoBack()) {
            router.back();
          } else {
            router.replace({ pathname: '/', params: { profileId: profile } });
          }
        }}
      />
    </ReaderPane>
  );
}
