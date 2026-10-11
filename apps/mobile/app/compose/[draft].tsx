import { router, useLocalSearchParams } from 'expo-router';

import { DraftComposer } from '../../src/evaluation-composer.tsx';
import { useProfile } from '../../src/mailbox.tsx';

export default function ComposeRoute() {
  const profile = useProfile();
  const { draft } = useLocalSearchParams<{ draft: string }>();
  return (
    <DraftComposer
      id={draft}
      onClose={() => {
        router.replace({ pathname: '/', params: { profileId: profile } });
      }}
      onRebind={(copy) => {
        router.setParams({ draft: copy });
      }}
    />
  );
}
