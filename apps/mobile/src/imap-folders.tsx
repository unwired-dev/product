import {
  imapFolderFailed,
  imapFolderName,
  inboxFolder,
} from '@private-email/mail-core/imap-inbox';
import { useMemo, useState, useSyncExternalStore } from 'react';
import { Text, View } from 'react-native';

import type { InboxMailbox } from './private-storage.ts';

import { Chip } from './design.tsx';
import { styles } from './inbox-styles.ts';
import { useLocalization } from './localization.ts';
import { usePalette } from './theme.ts';

// An IMAP mailbox's folders, Inbox first; each window chooses its own.
export function FolderPicker({
  mailbox,
  folder,
  failed,
  onFolder,
}: {
  // The IMAP mailbox shown on its own, if any.
  readonly mailbox: InboxMailbox | undefined;
  readonly folder: string;
  // The chosen folder could not be read; any cached messages still show.
  readonly failed: boolean;
  readonly onFolder: (folder: string) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const state = mailbox?.state;
  if (
    state?.kind !== 'ready' ||
    !('folders' in state) ||
    state.folders.length < 2
  ) {
    return null;
  }
  return (
    <>
      <View
        accessibilityLabel={t('imap.folders')}
        style={styles.scopes}>
        {state.folders
          .filter(({ selectable }) => selectable)
          .map(({ name }) => (
            <Chip
              key={name}
              icon={name === inboxFolder ? 'tray' : 'folder'}
              label={name === inboxFolder ? t('inbox.title') : name}
              selected={name === folder}
              onPress={() => {
                onFolder(name);
              }}
            />
          ))}
      </View>
      {failed ? (
        <Text
          accessibilityRole="alert"
          style={[styles.notice, { color: colors.textSecondary }]}>
          {t('imap.foldersUnavailable')}
        </Text>
      ) : null}
    </>
  );
}

const noSubscription = () => () => undefined;

// An IMAP mailbox shown on its own offers its folders; the Inbox is listed otherwise. Each
// window chooses its own folder.
export function useImapFolder<E>(
  shown: readonly InboxMailbox[],
  // The Inbox entries listed when no other folder is chosen.
  inbox: readonly E[],
) {
  const [choice, setChoice] =
    useState<Readonly<{ mailbox: string; folder: string }>>();
  const [single] = shown;
  const imap =
    shown.length === 1 && single !== undefined && 'openFolder' in single.inbox
      ? single
      : undefined;
  const requested =
    imap !== undefined && choice?.mailbox === imap.id
      ? choice.folder
      : inboxFolder;
  const state = imap?.state;
  const folder = imapFolderName(
    state?.kind === 'ready' && 'folders' in state ? state : undefined,
    requested,
  );
  if (folder !== requested && choice !== undefined) {
    setChoice(undefined);
  }
  const browsing = useFolderEntries(imap, folder);
  return {
    imap,
    folder,
    listed: browsing?.entries ?? inbox,
    failed: imapFolderFailed(browsing?.view),
    chooseFolder: (name: string) => {
      if (imap === undefined || !('openFolder' in imap.inbox)) {
        return;
      }
      setChoice({ mailbox: imap.id, folder: name });
      void imap.inbox.openFolder(name);
    },
  };
}

// The chosen folder's messages as list entries, or undefined for the Inbox.
function useFolderEntries(
  mailbox: InboxMailbox | undefined,
  folder: string | undefined,
) {
  const inbox =
    mailbox !== undefined && 'openFolder' in mailbox.inbox
      ? mailbox.inbox
      : undefined;
  const view = useSyncExternalStore(inbox?.subscribe ?? noSubscription, () =>
    inbox === undefined || folder === undefined || folder === inboxFolder
      ? undefined
      : inbox.folder(folder),
  );
  return useMemo(
    () =>
      mailbox === undefined || view === undefined
        ? undefined
        : {
            view,
            entries:
              view.kind === 'ready'
                ? view.messages.map((message) => ({ mailbox, message }))
                : [],
          },
    [mailbox, view],
  );
}
