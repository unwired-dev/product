import type {
  MailboxConnection,
  Registration,
} from '@private-email/mail-core/registration';
import type { ReactNode } from 'react';

import { Host, Button as SwiftUIButton } from '@expo/ui/swift-ui';
import {
  accessibilityHint,
  accessibilityLabel,
  buttonStyle,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import { folderSummary } from '@private-email/mail-core/mailboxes';
import { Pressable } from 'react-native';

import { SFSymbol } from './design.tsx';
import { FolderChoice, saveFolders } from './folder-choice.tsx';
import { useLocalization } from './localization.ts';
import { useAllMailboxes } from './mailbox-state.ts';
import { settingsColumns, SettingsGroup, SettingsRow } from './settings.tsx';
import { usePalette } from './theme.ts';

// Each IMAP connection whose server leaves Spam or Trash unmarked, with the folders chosen for
// them. iPad rows end in a native push button; iPhone rows open the sheet from the whole row,
// a Pressable around the house row until Settings rows are native list rows (#1057).
export function SpamTrashFolders({
  mailboxes,
  store,
}: {
  readonly mailboxes: readonly MailboxConnection[];
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const inboxes = useAllMailboxes();
  const rows = mailboxes.flatMap((mailbox) => {
    const state = inboxes.find(({ id }) => id === mailbox.id)?.state;
    if (
      mailbox.provider !== 'imap' ||
      mailbox.state !== 'connected' ||
      state?.kind !== 'ready' ||
      !('folders' in state)
    ) {
      return [];
    }
    const summary = folderSummary(t, state);
    return summary === undefined ? [] : [{ mailbox, state, summary }];
  });
  if (rows.length === 0) {
    return null;
  }
  const save = saveFolders(store);
  return (
    <SettingsGroup
      title={t('mailboxes.folders.settings.title')}
      footer={t(
        rows.every(({ summary }) => summary.chosen)
          ? 'mailboxes.folders.settings.chosenFooter'
          : 'mailboxes.folders.settings.neededFooter',
      )}>
      {rows.map(({ mailbox, state, summary }) => {
        const row = (children?: ReactNode) => (
          <SettingsRow
            icon={summary.chosen ? 'folder' : 'folder.badge.questionmark'}
            title={mailbox.address}
            subtitle={summary.subtitle}
            subtitleTone={summary.chosen ? undefined : 'warning'}>
            {children}
          </SettingsRow>
        );
        const label = t(
          summary.chosen
            ? 'mailboxes.folders.settings.change'
            : 'mailboxes.folders.choose',
        );
        return (
          <FolderChoice
            key={mailbox.id}
            address={mailbox.address}
            folders={state.folders}
            marked={state.marked}
            saved={mailbox.folders}
            onSave={(chosen) => save(mailbox.id, chosen)}>
            {(open) =>
              settingsColumns ? (
                row(
                  <Host matchContents>
                    <SwiftUIButton
                      label={label}
                      // A Secondary push button: the quiet fill with primary text. Its name
                      // retains the visible action and identifies the connection.
                      modifiers={[
                        buttonStyle('bordered'),
                        tint(colors.textPrimary),
                        accessibilityLabel(`${label} ${mailbox.address}`),
                        accessibilityHint(label),
                      ]}
                      onPress={open}
                    />
                  </Host>,
                )
              ) : (
                <Pressable
                  accessibilityLabel={mailbox.address}
                  accessibilityHint={label}
                  accessibilityRole="button"
                  accessibilityValue={{ text: summary.subtitle }}
                  onPress={open}
                  style={({ pressed }) =>
                    pressed && {
                      backgroundColor: colors.accentSelectionSubtle,
                    }
                  }>
                  {row(
                    <SFSymbol
                      name="chevron.right"
                      size={14}
                      color={colors.textSecondary}
                    />,
                  )}
                </Pressable>
              )
            }
          </FolderChoice>
        );
      })}
    </SettingsGroup>
  );
}
