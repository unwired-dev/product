import { router, useLocalSearchParams } from 'expo-router';

import { BackNavigation } from '../../src/back-navigation.tsx';
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
  const close = () => {
    router.replace({ pathname: '/', params: { profileId: profile } });
  };
  return (
    <BackNavigation
      testID="message-back-navigation"
      onBack={close}>
      <ReaderPane>
        <MessageDetail
          id={id}
          mailbox={mailbox}
          folder={folder}
          onClose={close}
          onCompose={(draft) => {
            router.replace({
              pathname: '/compose/[draft]',
              params: { draft, id, mailbox, folder, profileId: profile },
            });
          }}
        />
      </ReaderPane>
    </BackNavigation>
  );
}
