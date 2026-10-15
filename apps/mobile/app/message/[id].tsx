import { router, useLocalSearchParams } from 'expo-router';

import { useProfile } from '../../src/mailbox.tsx';
import { MessageDetail } from '../../src/message-detail.tsx';
import { ReaderPane } from '../../src/reader-chrome.tsx';

export default function MessageRoute() {
  const profile = useProfile();
  const { id, mailbox } = useLocalSearchParams<{
    id: string;
    mailbox?: string;
  }>();
  return (
    <ReaderPane>
      <MessageDetail
        id={id}
        mailbox={mailbox}
        onClose={() => {
          router.replace({ pathname: '/', params: { profileId: profile } });
        }}
        onCompose={(draft) => {
          router.replace({
            pathname: '/compose/[draft]',
            params: { draft, id, mailbox, profileId: profile },
          });
        }}
      />
    </ReaderPane>
  );
}
