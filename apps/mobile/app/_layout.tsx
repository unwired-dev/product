import type { SplitHostCommands } from 'react-native-screens/experimental';

import { router, useGlobalSearchParams } from 'expo-router';
import { SplitView } from 'expo-router/unstable-split-view';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useRef } from 'react';

import type { Selection } from '../src/inbox.tsx';

import {
  pollGmailWhileActive,
  scheduleGmailFreshness,
} from '../src/freshness.ts';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { RegistrationGate } from '../src/registration-gate.tsx';

void scheduleGmailFreshness();
pollGmailWhileActive();

export default function RootLayout() {
  const splitView = useRef<SplitHostCommands>(null);
  const { id, mailbox, draft } = useGlobalSearchParams<{
    id?: string;
    mailbox?: string;
    draft?: string;
  }>();
  const detail = Boolean(id) || Boolean(draft);

  useEffect(() => {
    if (detail) {
      splitView.current?.show('secondary');
    }
  }, [detail]);

  function selectMessage(selection: Selection) {
    router.replace({ pathname: '/message/[id]', params: selection });
    splitView.current?.show('secondary');
  }

  // A Draft opens in the detail column, a destination of its own on iPhone.
  function compose(opened: string) {
    router.replace({ pathname: '/compose/[draft]', params: { draft: opened } });
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
          topColumnForCollapsing={detail ? 'secondary' : 'primary'}>
          <SplitView.Column>
            <Inbox
              composing={draft}
              onClose={() => {
                router.replace('/');
              }}
              onCompose={compose}
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
