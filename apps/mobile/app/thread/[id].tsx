import { useLocalSearchParams } from 'expo-router';

import { ThreadView } from '../../src/message-detail.tsx';

export default function ThreadRoute() {
  const { id, mailbox } = useLocalSearchParams<{
    id: string;
    mailbox?: string;
  }>();
  return (
    <ThreadView
      id={id}
      mailbox={mailbox}
    />
  );
}
