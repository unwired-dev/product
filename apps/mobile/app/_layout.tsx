import type { SplitHostCommands } from 'react-native-screens/experimental';

import { router, useGlobalSearchParams } from 'expo-router';
import { SplitView } from 'expo-router/unstable-split-view';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useRef } from 'react';

import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';

export default function RootLayout() {
  const splitView = useRef<SplitHostCommands>(null);
  const { id } = useGlobalSearchParams<{ id?: string }>();

  useEffect(() => {
    if (id) {
      splitView.current?.show('secondary');
    }
  }, [id]);

  function selectMessage(messageId: string) {
    router.replace({ pathname: '/message/[id]', params: { id: messageId } });
    splitView.current?.show('secondary');
  }

  return (
    <InboxProvider>
      <StatusBar style="auto" />
      <SplitView
        ref={splitView}
        preferredDisplayMode="oneBesideSecondary"
        preferredSplitBehavior="tile"
        topColumnForCollapsing={id ? 'secondary' : 'primary'}>
        <SplitView.Column>
          <Inbox
            onSelect={selectMessage}
            selectedId={id}
          />
        </SplitView.Column>
      </SplitView>
    </InboxProvider>
  );
}
