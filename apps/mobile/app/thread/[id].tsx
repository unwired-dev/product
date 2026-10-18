import { router, useLocalSearchParams } from 'expo-router';

import { BackNavigation } from '../../src/back-navigation.tsx';
import { useProfile } from '../../src/mailbox.tsx';
import { ThreadView } from '../../src/message-detail.tsx';
import { ReaderPane } from '../../src/reader-chrome.tsx';

export default function ThreadRoute() {
  const profile = useProfile();
  const { id, mailbox } = useLocalSearchParams<{
    id: string;
    mailbox?: string;
  }>();
  const close = () => {
    // A Thread opened from Catch Up returns there; a cold deep link returns to the Inbox.
    if (router.canGoBack()) {
      router.back();
    } else {
      router.replace({ pathname: '/', params: { profileId: profile } });
    }
  };
  return (
    <BackNavigation
      testID="thread-back-navigation"
      onBack={close}>
      <ReaderPane>
        <ThreadView
          id={id}
          mailbox={mailbox}
          onClose={close}
        />
      </ReaderPane>
    </BackNavigation>
  );
}
