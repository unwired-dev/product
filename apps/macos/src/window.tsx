import {
  defaultProfile,
  inboxLanding,
} from '@private-email/mail-core/registration';
import { useState, useSyncExternalStore } from 'react';
import { StyleSheet, View } from 'react-native';

import type { Selection } from './inbox.tsx';

import { CommandPalette } from './command-palette.tsx';
import { DraftComposer } from './evaluation-composer.tsx';
import { Inbox } from './inbox.tsx';
import { InboxProvider, ProfileScope } from './mailbox.tsx';
import { MessageDetail } from './message-detail.tsx';
import { RegistrationGate } from './registration-gate.tsx';
import { registration } from './registration.ts';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  window: { flex: 1, flexDirection: 'row' },
  sidebar: { width: 320, borderRightWidth: StyleSheet.hairlineWidth },
  detail: { flex: 1 },
});

type WindowProps = Readonly<{
  windowId: string;
  // The window's Mail Profile. Native windows name none and show the Default Profile until #647
  // lets the person open another.
  profile?: string;
}>;

function useWindowSelection(profile: string, account?: string) {
  const [owner, setOwner] = useState({ profile, account });
  const [selected, setSelected] = useState<Selection>();
  const [composing, setComposing] = useState<string>();
  if (owner.profile !== profile || owner.account !== account) {
    setOwner({ profile, account });
    setSelected(undefined);
    setComposing(undefined);
  }
  const compose = (id: string) => {
    setSelected(undefined);
    setComposing(id);
  };
  return { selected, setSelected, composing, setComposing, compose };
}

export function PreviewWindow({
  windowId,
  profile = defaultProfile,
}: WindowProps) {
  const selection = useWindowSelection(profile);
  return (
    <InboxProvider>
      <ProfileScope profile={profile}>
        <WindowContents
          windowId={windowId}
          selection={selection}
        />
      </ProfileScope>
    </InboxProvider>
  );
}

function WindowContents({
  windowId,
  selection,
}: {
  readonly windowId: string;
  readonly selection: ReturnType<typeof useWindowSelection>;
}) {
  const { selected, setSelected, composing, setComposing, compose } = selection;
  const colors = usePalette();
  // Either pane closes the reader when its message leaves the Inbox.
  const close = () => {
    setSelected(undefined);
  };
  return (
    <View
      testID={`inbox-window-${windowId}`}
      style={styles.window}>
      <View style={[styles.sidebar, { borderRightColor: colors.separator }]}>
        <Inbox
          onInbox={() => {
            setSelected(undefined);
            setComposing(undefined);
          }}
          composing={composing}
          selected={selected}
          onClose={close}
          onCompose={compose}
          onSelect={(target) => {
            setComposing(undefined);
            setSelected(target);
          }}
        />
      </View>
      <View style={styles.detail}>
        {composing === undefined ? (
          <MessageDetail
            id={selected?.id}
            mailbox={selected?.mailbox}
            onClose={close}
            onCompose={compose}
          />
        ) : (
          <DraftComposer
            id={composing}
            onClose={() => {
              setComposing(undefined);
            }}
            onRebind={setComposing}
          />
        )}
      </View>
    </View>
  );
}

export function InboxWindow({
  windowId,
  profile = defaultProfile,
}: WindowProps) {
  const { snapshot, locked } = useSyncExternalStore(
    registration.subscribe,
    registration.getSnapshot,
  );
  const selection = useWindowSelection(
    profile,
    locked ? undefined : inboxLanding(snapshot, undefined).account,
  );
  return (
    <CommandPalette>
      <RegistrationGate
        onCompose={(id) => {
          selection.compose(id);
        }}
        profile={profile}>
        <InboxProvider>
          <ProfileScope profile={profile}>
            <WindowContents
              windowId={windowId}
              selection={selection}
            />
          </ProfileScope>
        </InboxProvider>
      </RegistrationGate>
    </CommandPalette>
  );
}
