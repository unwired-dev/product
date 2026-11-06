import { router, useLocalSearchParams } from 'expo-router';

import { OpenMessageContext } from '../../src/invitation.tsx';
import { useProfile } from '../../src/mailbox.tsx';
import { MessageDetail } from '../../src/message-detail.tsx';
import { ReaderPane } from '../../src/reader-chrome.tsx';

export default function MessageRoute() {
  const profile = useProfile();
  const { id, mailbox, folder } = useLocalSearchParams<{
    id: string;
    mailbox?: string;
    folder?: string;
  }>();
  return (
    <ReaderPane>
      {/* Another message of the same mailbox replaces this one in the reader. */}
      <OpenMessageContext
        value={(latest) => {
          router.replace({
            pathname: '/message/[id]',
            params: { id: latest, mailbox, profileId: profile },
          });
        }}>
        <MessageDetail
          id={id}
          mailbox={mailbox}
          folder={folder}
          onClose={() => {
            router.replace({ pathname: '/', params: { profileId: profile } });
          }}
          onCompose={(draft) => {
            router.replace({
              pathname: '/compose/[draft]',
              params: { draft, id, mailbox, folder, profileId: profile },
            });
          }}
        />
      </OpenMessageContext>
    </ReaderPane>
  );
}
