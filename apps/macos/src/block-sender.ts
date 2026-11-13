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
  const block = async (address: string) => {
    // The Profile's mail from the address this device holds now, which blocking leaves in place.
    const count = mailboxes
      .flatMap(({ state }) =>
        state.kind === 'ready'
          ? state.messages.map((each) => each.address)
          : [],
      )
      .filter((each) => blockedAddress(each) === address).length;
    const name = profileName(t, profile, account?.profiles ?? []);
    if (
      (await confirm({
        title: t('blockedSenders.confirmTitle', { address }),
        detail:
          count === 0
            ? t('blockedSenders.confirmNone', { profile: name })
            : t('blockedSenders.confirm', { profile: name, count }),
        cancel: t('common.cancel'),
        action: t('blockedSenders.action'),
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
  // The menu item for `sender`, none unless it is one plain address.
  const items = (sender: string): MenuItem[] => {
    const address = blockedAddress(sender);
    return address === undefined
      ? []
      : [
          {
            key: `block\n${address}`,
            title: t('blockedSenders.block'),
            symbol: 'hand.raised.slash',
            destructive: true,
            run: () => block(address),
          },
        ];
  };
  return { anchor, items };
}
