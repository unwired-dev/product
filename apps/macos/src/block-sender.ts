import type { MenuItem } from '@private-email/mail-core/context-menu';

import {
  blockedAddress,
  offeredDomain,
} from '@private-email/mail-core/blocked-senders';
import { profileName } from '@private-email/mail-core/profile-windows';
import { use } from 'react';

import { BlockedSendersContext } from './blocked-senders.tsx';
import { useWindowIdentifier } from './command-palette.tsx';
import { askInSheet, useConfirmation } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useMailboxes, useProfile } from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { windowHost } from './settings-window-client.ts';

// Block Sender… and Block Domain… for a sender's menu. Block Sender…, after the person confirms,
// blocks the sender's exact address for the window's Mail Profile; Block Domain… opens the sheet
// that blocks the address's exact domain. `anchor` is the view the confirmation sheet attaches to.
export function useBlockSender() {
  const store = use(BlockedSendersContext);
  const window = useWindowIdentifier();
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
  // The menu items for `from` of the open message `message` of `connection`: none unless its
  // address is one plain address, and Block Domain… only when its domain is one a Blocked Domain
  // matches.
  const items = (
    from: Readonly<{ sender: string; address: string }>,
    connection: string,
    message: string,
  ): MenuItem[] => {
    const address = blockedAddress(from.address);
    const domain = offeredDomain(from.address);
    return address === undefined
      ? []
      : [
          {
            key: `block\n${address}`,
            title: t('blockedSenders.block'),
            symbol: 'hand.raised.slash',
            run: () => block(address, `${connection}\n${message}`),
          },
          ...(domain === undefined
            ? []
            : [
                {
                  key: `block-domain\n${domain}`,
                  title: t('blockedSenders.blockDomain'),
                  symbol: 'hand.raised.slash',
                  run: () => {
                    windowHost()?.openBlockDomain(window, {
                      sender: from.sender,
                      address,
                      domain,
                      profile,
                    });
                  },
                },
              ]),
        ];
  };
  return { anchor, items };
}
