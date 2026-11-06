import type { MailboxConnection } from '@private-email/mail-core/registration';

import { folderSummary } from '@private-email/mail-core/mailboxes';

import type { SettingsButton } from './settings.tsx';

import { useWindowIdentifier } from './command-palette.tsx';
import { useLocalization } from './localization.ts';
import { useAllMailboxes } from './mailbox-list.ts';
import { windowHost } from './settings-window-client.ts';
import { SettingsGroup, SettingsRow } from './settings.tsx';

// Settings › Email Accounts: each IMAP connection whose server leaves Spam or Trash unmarked, with
// the folders chosen for them; its button opens the choice as a sheet on this window (folder-choice.tsx).
export function SpamTrashFolders({
  mailboxes,
  button,
}: {
  readonly mailboxes: readonly MailboxConnection[];
  readonly button: SettingsButton;
}) {
  const { t } = useLocalization();
  const window = useWindowIdentifier();
  const inboxes = useAllMailboxes();
  const rows = mailboxes.flatMap((mailbox) => {
    const inbox = inboxes.find(({ id }) => id === mailbox.id);
    const state = inbox?.state;
    if (
      inbox === undefined ||
      mailbox.provider !== 'imap' ||
      mailbox.state !== 'connected' ||
      state?.kind !== 'ready' ||
      !('folders' in state)
    ) {
      return [];
    }
    const summary = folderSummary(t, state);
    return summary === undefined
      ? []
      : [{ mailbox, profile: inbox.profile, summary }];
  });
  if (rows.length === 0) {
    return null;
  }
  return (
    <SettingsGroup
      title={t('mailboxes.folders.settings.title')}
      footer={t(
        rows.every(({ summary }) => summary.chosen)
          ? 'mailboxes.folders.settings.chosenFooter'
          : 'mailboxes.folders.settings.neededFooter',
      )}>
      {rows.map(({ mailbox, profile, summary }) => {
        const label = t(
          summary.chosen
            ? 'mailboxes.folders.settings.change'
            : 'mailboxes.folders.choose',
        );
        return (
          <SettingsRow
            key={mailbox.id}
            icon={summary.chosen ? 'folder' : 'folder.badge.questionmark'}
            title={mailbox.address}
            subtitle={summary.subtitle}
            subtitleTone={summary.chosen ? undefined : 'warning'}>
            {button(
              `${label} ${mailbox.address}`,
              async () => {
                windowHost()?.openFolderChoice(window, mailbox.id, profile);
              },
              { title: label },
            )}
          </SettingsRow>
        );
      })}
    </SettingsGroup>
  );
}
