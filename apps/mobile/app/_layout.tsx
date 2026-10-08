import type { SplitHostCommands } from 'react-native-screens/experimental';

import { router, useGlobalSearchParams } from 'expo-router';
import { SplitView } from 'expo-router/unstable-split-view';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useRef } from 'react';

import type { Selection } from '../src/inbox.tsx';

import { scheduleGmailFreshness } from '../src/freshness.ts';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { RegistrationGate } from '../src/registration-gate.tsx';

void scheduleGmailFreshness();

export default function RootLayout() {
  const splitView = useRef<SplitHostCommands>(null);
  const { id, mailbox } = useGlobalSearchParams<{
    id?: string;
    mailbox?: string;
  }>();

  useEffect(() => {
    if (id) {
      splitView.current?.show('secondary');
    }
  }, [id]);

  function selectMessage(selection: Selection) {
    router.replace({ pathname: '/message/[id]', params: selection });
    splitView.current?.show('secondary');
  }

  return (
    <RegistrationGate>
      <InboxProvider>
        <StatusBar style="auto" />
        <SplitView
          ref={splitView}
          preferredDisplayMode="oneBesideSecondary"
          preferredSplitBehavior="tile"
          topColumnForCollapsing={id ? 'secondary' : 'primary'}>
          <SplitView.Column>
            <Inbox
              onClose={() => {
                router.replace('/');
              }}
              onSelect={selectMessage}
              selected={
                id === undefined || mailbox === undefined
                  ? undefined
                  : { mailbox, id }
              }
            />
          </SplitView.Column>
        </SplitView>
      </InboxProvider>
    </RegistrationGate>
  );
}
