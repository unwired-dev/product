import { use } from 'react';

import type { InboxMailbox } from './private-storage.ts';

import { Commands } from './command-palette.tsx';
import { useLocalization } from './localization.ts';
import { useLeaveComposer } from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';

export function InboxCommands({
  hasSelection,
  mailboxes,
  onInbox,
  onScope,
}: {
  readonly hasSelection: boolean;
  readonly mailboxes: readonly InboxMailbox[];
  readonly onInbox: () => Promise<boolean>;
  readonly onScope: (scope: string) => void;
}) {
  const { t } = useLocalization();
  const account = use(AccountContext);
  const leave = useLeaveComposer();
  return (
    <Commands
      commands={[
        {
          id: 'inbox',
          label: t('commandPalette.inbox'),
          keywords: t('commandPalette.inboxKeywords'),
          group: 'navigation',
          onRun: onInbox,
        },
        ...(account === undefined
          ? []
          : [
              {
                id: 'settings',
                label: t('commandPalette.settings'),
                keywords: t('commandPalette.settingsKeywords'),
                group: 'navigation' as const,
                onRun: async () => {
                  if (!(await leave())) {
                    return false;
                  }
                  account.openAccount();
                  return true;
                },
              },
            ]),
        ...(
          [
            ['archive', t('gmailActions.label.archive')],
            ['read', t('message.markRead')],
            ['unread', t('message.markUnread')],
          ] as const
        ).map(([kind, label]) => ({
          id: kind,
          label,
          keywords: t(
            kind === 'archive'
              ? 'commandPalette.archiveKeywords'
              : 'commandPalette.readKeywords',
          ),
          group: 'selection' as const,
          disabled: t(
            hasSelection
              ? 'commandPalette.unsupported'
              : 'commandPalette.select',
          ),
          onRun: () => false,
        })),
        {
          id: 'move',
          label: t('commandPalette.move'),
          keywords: t('commandPalette.moveKeywords'),
          group: 'selection',
          disabled: t(
            hasSelection
              ? 'commandPalette.unsupported'
              : 'commandPalette.select',
          ),
          choices: [],
        },
        {
          id: 'reply',
          label: t('message.reply'),
          keywords: t('commandPalette.replyKeywords'),
          group: 'selection',
          disabled: t(
            hasSelection
              ? 'commandPalette.unsupported'
              : 'commandPalette.select',
          ),
          onRun: () => false,
        },
        {
          id: 'forward',
          label: t('message.forward'),
          keywords: t('commandPalette.forwardKeywords'),
          group: 'selection',
          disabled: t(
            hasSelection
              ? 'commandPalette.unsupported'
              : 'commandPalette.select',
          ),
          onRun: () => false,
        },
        ...(mailboxes.length > 1
          ? [
              {
                id: 'mailbox',
                label: t('inbox.title'),
                group: 'navigation' as const,
                choices: mailboxes.map((mailbox) => ({
                  id: mailbox.id,
                  label: mailbox.address ?? mailbox.id,
                  group: 'navigation' as const,
                  onRun: async () => {
                    if (!(await onInbox())) {
                      return false;
                    }
                    onScope(mailbox.id);
                    return true;
                  },
                })),
              },
            ]
          : []),
      ]}
    />
  );
}
