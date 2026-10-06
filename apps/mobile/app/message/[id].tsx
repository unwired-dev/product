import { router, useLocalSearchParams } from 'expo-router';

import { MessageDetail } from '../../src/message-detail.tsx';

export default function MessageRoute() {
  const { id } = useLocalSearchParams<{ id: string }>();
  return (
    <MessageDetail
      id={id}
      onClose={() => {
        router.replace('/');
      }}
    />
  );
}
