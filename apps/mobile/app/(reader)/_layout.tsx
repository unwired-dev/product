import { router, Slot, useGlobalSearchParams } from 'expo-router';

import { OpenMessageContext } from '../../src/invitation.tsx';
import { useProfile } from '../../src/mailbox.tsx';
import { MessageDetail } from '../../src/message-detail.tsx';
import { ReaderPane } from '../../src/reader-chrome.tsx';

// `message/[id]` and the reader beneath `compose/[draft]`'s composer are one view, so a composer
// opening or closing over a message keeps its laid-out body and scroll position (#2917). Beneath
// a composer the reader takes no input and offers no responses.
export default function ReaderLayout() {
  const profile = useProfile();
  const { id, mailbox, folder, draft } = useGlobalSearchParams<{
    id?: string;
    mailbox?: string;
    folder?: string;
    draft?: string;
  }>();
  const composing = draft !== undefined;
  const reader = composing ? (
    <MessageDetail
      id={id}
      mailbox={mailbox}
      folder={folder}
    />
  ) : (
    <MessageDetail
      id={id}
      mailbox={mailbox}
      folder={folder}
      onClose={() => {
        router.replace({ pathname: '/', params: { profileId: profile } });
      }}
      onCompose={(opened) => {
        router.replace({
          pathname: '/compose/[draft]',
          params: { draft: opened, id, mailbox, folder, profileId: profile },
        });
      }}
    />
  );
  return (
    <>
      <Slot />
      <ReaderPane
        testID={composing ? 'compose-reader-pane' : 'reader-pane'}
        pointerEvents={composing ? 'none' : 'auto'}
        accessibilityElementsHidden={composing}>
        {/* Another message of the same mailbox replaces this one in the reader. */}
        <OpenMessageContext
          value={
            composing
              ? undefined
              : (latest) => {
                  router.replace({
                    pathname: '/message/[id]',
                    params: { id: latest, mailbox, profileId: profile },
                  });
                }
          }>
          {reader}
        </OpenMessageContext>
      </ReaderPane>
    </>
  );
}
