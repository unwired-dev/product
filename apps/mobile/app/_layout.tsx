import type { SplitHostCommands } from 'react-native-screens/experimental';

import { readingProfile } from '@private-email/mail-core/mailboxes';
import { router, useGlobalSearchParams } from 'expo-router';
import { SplitView } from 'expo-router/unstable-split-view';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useRef } from 'react';

import type { Selection } from '../src/inbox.tsx';

import { CommandPaletteProvider } from '../src/command-palette.tsx';
import {
  pollGmailWhileActive,
  scheduleGmailFreshness,
} from '../src/freshness.ts';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider, ProfileScope } from '../src/mailbox.tsx';
import { RegistrationGate } from '../src/registration-gate.tsx';

void scheduleGmailFreshness();
pollGmailWhileActive();

export default function RootLayout() {
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
    <CommandPaletteProvider>
      <RegistrationGate>
        <InboxProvider>
          <ProfileScope profile={shownProfile}>
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
                    router.replace({
                      pathname: '/',
                      params: { profileId: shownProfile },
                    });
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
          </ProfileScope>
        </InboxProvider>
      </RegistrationGate>
    </CommandPaletteProvider>
  );
}
