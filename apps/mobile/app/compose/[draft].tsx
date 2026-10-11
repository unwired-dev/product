import { router, useLocalSearchParams } from 'expo-router';

import { DraftComposer } from '../../src/evaluation-composer.tsx';

export default function ComposeRoute() {
  const { draft } = useLocalSearchParams<{ draft: string }>();
  return (
    <DraftComposer
      id={draft}
      onClose={() => {
        router.replace('/');
      }}
      onRebind={(copy) => {
        router.setParams({ draft: copy });
      }}
    />
  );
}
