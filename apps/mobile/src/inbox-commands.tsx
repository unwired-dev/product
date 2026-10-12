import { use, useLayoutEffect, useRef } from 'react';

import type { InboxMailbox } from './private-storage.ts';

import { Commands } from './command-palette.tsx';
import { useLocalization } from './localization.ts';
import { useComposerNavigation, useProfile } from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';

export function InboxCommands({
  scope,
  hasSelection,
  selectionMailbox,
  selectionMessage,
  stars,
  mailboxes,
  onInbox,
  onScope,
}: {
  readonly scope: string | undefined;
  readonly hasSelection: boolean;
  readonly selectionMailbox: InboxMailbox | undefined;
  readonly selectionMessage:
    | Readonly<{
        unread: boolean;
        labels?: readonly string[];
      }>
    | undefined;
  readonly stars: boolean;
  readonly mailboxes: readonly InboxMailbox[];
  readonly onInbox: () => void;
  readonly onScope: (scope: string) => void;
}) {
  const { t } = useLocalization();
  const account = use(AccountContext);
  const accountId = account?.productAccountId;
  const navigation = useComposerNavigation();
  const profile = useProfile();
  const scopeOwner = useRef<object | undefined>(undefined);
  useLayoutEffect(() => {
    scopeOwner.current = { accountId, navigation, profile, scope };
    return () => {
      scopeOwner.current = undefined;
    };
  }, [accountId, navigation, profile, scope]);
  const selectionState = selectionMailbox?.state;
  const selectionReasons = {
    loading: t('message.loading'),
    locked: t('storage.locked'),
    failed: t('storage.failed'),
    ready: t('commandPalette.unsupported'),
  };
  const selectionReason = hasSelection
    ? selectionReasons[selectionState?.kind ?? 'ready']
    : t('commandPalette.select');
  const keywords: Readonly<Record<string, string>> = {
    archive: t('commandPalette.archiveKeywords'),
    read: t('commandPalette.readKeywords'),
    unread: t('commandPalette.readKeywords'),
  };
  const savedOnly =
    hasSelection &&
    selectionState?.kind === 'ready' &&
    'organize' in selectionState &&
    !selectionState.organize;
  const organizeReason = savedOnly
    ? t('gmailActions.savedOnly', {
        provider: t(`mailProviders.${selectionMailbox?.provider ?? 'gmail'}`),
      })
    : selectionReason;
  const actionReason = (kind: string) => {
    if (savedOnly) {
      return organizeReason;
    }
    if (selectionState?.kind !== 'ready' || selectionMessage === undefined) {
      return selectionReason;
    }
    if (kind === 'read' && !selectionMessage.unread) {
      return t('commandPalette.alreadyRead');
    }
    if (kind === 'unread' && selectionMessage.unread) {
      return t('commandPalette.alreadyUnread');
    }
    if (selectionMessage.labels !== undefined) {
      const starred = selectionMessage.labels.includes('STARRED');
      if (kind === 'star' && starred) {
        return t('commandPalette.alreadyStarred');
      }
      if (kind === 'unstar' && !starred) {
        return t('commandPalette.notStarred');
      }
    }
    return selectionReason;
  };
  const leave = async (open: () => void) => {
    const owner = scopeOwner.current;
    const result = await navigation.leaveResult();
    if (owner !== scopeOwner.current) {
      return false;
    }
    if (result === 'failed') {
      throw new Error('Composer could not finish');
    }
    if (!result) {
      return false;
    }
    open();
    return true;
  };
  return (
    <Commands
      commands={[
        {
          id: 'inbox',
          label: t('commandPalette.inbox'),
          keywords: t('commandPalette.inboxKeywords'),
          group: 'navigation',
          onRun: () => leave(onInbox),
        },
        ...(account === undefined
          ? []
          : [
              {
                id: 'settings',
                label: t('commandPalette.settings'),
                keywords: t('commandPalette.settingsKeywords'),
                group: 'navigation' as const,
                onRun: () => leave(account.openAccount),
              },
            ]),
        ...(
          [
            ['archive', t('gmailActions.label.archive')],
            ['read', t('message.markRead')],
            ['unread', t('message.markUnread')],
            ['trash', t('gmailActions.label.trash')],
            ['spam', t('gmailActions.label.spam')],
            ...(stars
              ? ([
                  ['star', t('gmailActions.label.star')],
                  ['unstar', t('gmailActions.label.unstar')],
                ] as const)
              : []),
          ] as const
        ).map(([kind, label]) => ({
          id: kind,
          label,
          keywords: keywords[kind] ?? '',
          group: 'selection' as const,
          disabled: actionReason(kind),
          onRun: () => false,
        })),
        {
          id: 'move',
          label: t('commandPalette.move'),
          keywords: t('commandPalette.moveKeywords'),
          group: 'selection',
          disabled: organizeReason,
          choices: [],
        },
        {
          id: 'reply',
          label: t('message.reply'),
          keywords: t('commandPalette.replyKeywords'),
          group: 'selection',
          disabled: selectionReason,
          onRun: () => false,
        },
        {
          id: 'replyAll',
          label: t('message.replyAll'),
          keywords: t('commandPalette.replyKeywords'),
          group: 'selection',
          disabled: selectionReason,
          onRun: () => false,
        },
        {
          id: 'forward',
          label: t('message.forward'),
          keywords: t('commandPalette.forwardKeywords'),
          group: 'selection',
          disabled: selectionReason,
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
                  onRun: () =>
                    leave(() => {
                      onInbox();
                      onScope(mailbox.id);
                    }),
                })),
              },
            ]
          : []),
      ]}
    />
  );
}
