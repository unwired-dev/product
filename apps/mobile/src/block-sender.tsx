import type { ReactNode } from 'react';

import { Alert, Button, Host, Spacer, Text } from '@expo/ui/swift-ui';
import { frame } from '@expo/ui/swift-ui/modifiers';
import { blockedAddress } from '@private-email/mail-core/blocked-senders';
import { profileName } from '@private-email/mail-core/profile-windows';
import { use, useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { BlockedSendersContext } from './blocked-senders.tsx';
import { useLocalization } from './localization.ts';
import { useMailboxes, useProfile } from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';

const styles = StyleSheet.create({
  // The alert's anchor takes no room beside the sender.
  anchor: { position: 'absolute' },
});

type Asking = Readonly<
  | { kind: 'confirm'; address: string; profile: string; count: number }
  | { kind: 'failed'; address: string }
>;

// The system alert, anchored on a zero-size spacer as SwiftUI drops one attached to an empty view.
// It owns presentation, focus and Escape; Cancel's role makes it the dismissal choice.
function SenderAlert({
  title,
  message,
  children,
}: {
  readonly title: string;
  readonly message: string;
  readonly children: ReactNode;
}) {
  return (
    <View style={styles.anchor}>
      <Host matchContents>
        <Alert
          title={title}
          isPresented>
          <Alert.Trigger>
            <Spacer modifiers={[frame({ width: 0, height: 0 })]} />
          </Alert.Trigger>
          <Alert.Actions>{children}</Alert.Actions>
          <Alert.Message>
            <Text>{message}</Text>
          </Alert.Message>
        </Alert>
      </Host>
    </View>
  );
}

// Block Sender… for a sender's menu: after the person confirms in the system alert, blocks the
// sender's exact address for the reader's Mail Profile. `alert` shows the confirmation or failure.
export function useBlockSender() {
  const store = use(BlockedSendersContext);
  const account = use(AccountContext);
  const profile = useProfile();
  const mailboxes = useMailboxes();
  const { t } = useLocalization();
  const [asking, setAsking] = useState<Asking>();
  const done = () => {
    setAsking(undefined);
  };
  const block = async (owner: string, address: string) => {
    done();
    if (!(await store.block(owner, address))) {
      setAsking({ kind: 'failed', address });
    }
  };
  let alert: ReactNode = null;
  if (asking?.kind === 'confirm') {
    alert = (
      <SenderAlert
        title={t('blockedSenders.confirmTitle', { address: asking.address })}
        message={t('blockedSenders.confirm', {
          profile: profileName(t, asking.profile, account?.profiles ?? []),
          count: asking.count,
        })}>
        <Button
          // oxlint-disable-next-line jsx-a11y/aria-role -- SwiftUI button role, not ARIA.
          role="cancel"
          label={t('common.cancel')}
          onPress={done}
        />
        <Button
          // oxlint-disable-next-line jsx-a11y/aria-role -- SwiftUI button role, not ARIA.
          role="destructive"
          label={t('blockedSenders.action')}
          onPress={() => {
            void block(asking.profile, asking.address);
          }}
        />
      </SenderAlert>
    );
  } else if (asking?.kind === 'failed') {
    alert = (
      <SenderAlert
        title={t('blockedSenders.blockFailed', { address: asking.address })}
        message={t('blockedSenders.tryAgain')}>
        <Button
          // oxlint-disable-next-line jsx-a11y/aria-role -- SwiftUI button role, not ARIA.
          role="cancel"
          label={t('common.ok')}
          onPress={done}
        />
      </SenderAlert>
    );
  }
  // The menu item for `sender` of the open message `message` of `connection`, none unless the
  // sender is one plain address.
  const items = (sender: string, connection: string, message: string) => {
    const address = blockedAddress(sender);
    return address === undefined
      ? []
      : [
          {
            key: `block\n${address}`,
            title: t('blockedSenders.block'),
            symbol: 'hand.raised.slash',
            run: () => {
              // The Profile's loaded Inbox mail from the address and the open message, which
              // blocking leaves in place.
              const count = new Set([
                `${connection}\n${message}`,
                ...mailboxes.flatMap(({ id, state }) =>
                  state.kind === 'ready'
                    ? state.messages
                        .filter(
                          (each) => blockedAddress(each.address) === address,
                        )
                        .map((each) => `${id}\n${each.id}`)
                    : [],
                ),
              ]).size;
              setAsking({ kind: 'confirm', address, profile, count });
            },
          },
        ];
  };
  return { alert, items };
}
