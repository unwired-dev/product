import type { MenuItem } from '@private-email/mail-core/context-menu';

import { blockedAddress } from '@private-email/mail-core/blocked-senders';
import { profileName } from '@private-email/mail-core/profile-windows';
import { use } from 'react';

import { BlockedSendersContext } from './blocked-senders.tsx';
import { askInSheet, useConfirmation } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useMailboxes, useProfile } from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';

// Block Sender… for a sender's menu: after the person confirms, blocks the sender's exact address
// for the window's Mail Profile. `anchor` is the view the confirmation sheet attaches to.
export function useBlockSender() {
  const store = use(BlockedSendersContext);
  const account = use(AccountContext);
  const profile = useProfile();
  const mailboxes = useMailboxes();
  const { t } = useLocalization();
  const { anchor, confirm } = useConfirmation();
  const block = async (address: string, open: string) => {
    // The Profile's loaded Inbox mail from the address and the open message, which blocking leaves
    // in place.
    const count = new Set([
      open,
      ...mailboxes.flatMap(({ id, state }) =>
        state.kind === 'ready'
          ? state.messages
              .filter((each) => blockedAddress(each.address) === address)
              .map((each) => `${id}\n${each.id}`)
          : [],
      ),
    ]).size;
    const name = profileName(t, profile, account?.profiles ?? []);
    if (
      (await confirm({
        title: t('blockedSenders.confirmTitle', { address }),
        detail: t('blockedSenders.confirm', { profile: name, count }),
        cancel: t('common.cancel'),
        action: t('blockedSenders.action'),
        destructive: false,
      })) &&
      !(await store.block(profile, address))
    ) {
      await askInSheet(anchor.current, {
        title: t('blockedSenders.blockFailed', { address }),
        detail: t('blockedSenders.tryAgain'),
        buttons: [t('common.ok')],
      }).answer;
    }
  };
  // The menu item for `sender` of the open message `message` of `connection`, none unless the
  // sender is one plain address.
  const items = (
    sender: string,
    connection: string,
    message: string,
  ): MenuItem[] => {
    const address = blockedAddress(sender);
    return address === undefined
      ? []
      : [
          {
            key: `block\n${address}`,
            title: t('blockedSenders.block'),
            symbol: 'hand.raised.slash',
            run: () => block(address, `${connection}\n${message}`),
          },
        ];
  };
  return { anchor, items };
}
