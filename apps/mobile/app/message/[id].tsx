import { router, useLocalSearchParams } from 'expo-router';

import { MessageDetail } from '../../src/message-detail.tsx';

export default function MessageRoute() {
  const { id, mailbox } = useLocalSearchParams<{
    id: string;
    mailbox?: string;
  }>();
  return (
    <MessageDetail
      id={id}
      mailbox={mailbox}
      onClose={() => {
        router.replace('/');
      }}
      onCompose={(draft) => {
        router.replace({ pathname: '/compose/[draft]', params: { draft } });
      }}
    />
  );
}
