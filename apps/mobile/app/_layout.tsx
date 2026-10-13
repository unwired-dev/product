import type { SplitHostCommands } from 'react-native-screens/experimental';

import { readingProfile } from '@private-email/mail-core/mailboxes';
import { router, useGlobalSearchParams } from 'expo-router';
import { SplitView } from 'expo-router/unstable-split-view';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useRef, useState } from 'react';

import type { Selection } from '../src/inbox.tsx';
import type { MailboxView } from '../src/sidebar.tsx';

import {
  pollGmailWhileActive,
  scheduleGmailFreshness,
} from '../src/freshness.ts';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider, ProfileScope } from '../src/mailbox.tsx';
import { RegistrationGate } from '../src/registration-gate.tsx';
import { Mailboxes } from '../src/sidebar.tsx';

void scheduleGmailFreshness();
pollGmailWhileActive();

// Presentation choices live below ProfileScope, which retires them with the Profile.
function MailShell() {
  const splitView = useRef<SplitHostCommands>(null);
  const { id, mailbox, draft, profileId } = useGlobalSearchParams<{
    id?: string;
    mailbox?: string;
    draft?: string;
    profileId?: string | string[];
  }>();
  // The window's Mail Profile: a targeted deep link's, otherwise the Default Profile, which owns
  // every mailbox an old-form link from before Profiles names. An unknown Profile shows nothing.
  // shortcut: a new route without a Profile uses Default until #647 adds restoration preferences.
  const shownProfile = readingProfile(profileId);
  const detail = Boolean(id) || Boolean(draft);
  // The Mailboxes column's choice, which the message list column shows.
  const [view, setView] = useState<MailboxView>({});

  useEffect(() => {
    if (detail) {
      splitView.current?.show('secondary');
    }
  }, [detail]);

  function selectMessage(selection: Selection) {
    router.replace({
      pathname: '/message/[id]',
      params: { ...selection, profileId: shownProfile },
    });
    splitView.current?.show('secondary');
  }

  // A Draft opens in the detail column, a destination of its own on iPhone.
  function compose(opened: string) {
    router.replace({
      pathname: '/compose/[draft]',
      params: { draft: opened, profileId: shownProfile },
    });
    splitView.current?.show('secondary');
  }

  return (
    <>
      <StatusBar style="auto" />
      <SplitView
        ref={splitView}
        columnMetrics={{
          preferredPrimaryColumnWidthOrFraction: 236,
          preferredSupplementaryColumnWidthOrFraction: 340,
        }}
        // Both sidebars beside the reader in landscape; portrait hides Mailboxes, which the
        // system's sidebar button shows over the list.
        preferredDisplayMode="automatic"
        preferredSplitBehavior="tile"
        primaryBackgroundStyle="sidebar"
        topColumnForCollapsing={detail ? 'secondary' : 'supplementary'}>
        <SplitView.Column>
          <Mailboxes
            view={view}
            onView={(next) => {
              setView(next);
              // On iPhone a Mailbox opens its list; beside it, the list is already shown.
              splitView.current?.show('supplementary');
            }}
          />
        </SplitView.Column>
        <SplitView.Column>
          <Inbox
            composing={draft}
            onClose={() => {
              router.replace({
                pathname: '/',
                params: { profileId: shownProfile },
              });
            }}
            onCompose={compose}
            onSelect={selectMessage}
            onView={setView}
            selected={
              id === undefined || mailbox === undefined
                ? undefined
                : { mailbox, id }
            }
            view={view}
          />
        </SplitView.Column>
      </SplitView>
    </>
  );
}

export default function RootLayout() {
  const { profileId } = useGlobalSearchParams<{
    profileId?: string | string[];
  }>();
  return (
    <RegistrationGate>
      <InboxProvider>
        <ProfileScope profile={readingProfile(profileId)}>
          <MailShell />
        </ProfileScope>
      </InboxProvider>
    </RegistrationGate>
  );
}
