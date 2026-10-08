import { router, useLocalSearchParams } from 'expo-router';

import { Composer } from '../../src/composer.tsx';

export default function ComposeRoute() {
  const { draft } = useLocalSearchParams<{ draft: string }>();
  return (
    <Composer
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
