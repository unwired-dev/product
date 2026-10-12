import type { Drafts } from '@private-email/mail-core/drafts';
import type { MailboxConnection } from '@private-email/mail-core/registration';

import { createComposerNavigation } from '@private-email/mail-core/composer-navigation';
import { sendingMailboxes } from '@private-email/mail-core/drafts';
import { useLayoutEffect, useMemo, useRef, useSyncExternalStore } from 'react';

import { Commands } from './command-palette.tsx';
import { useLocalization } from './localization.ts';

export function SettingsCompose({
  account,
  mailboxes,
  profile,
  drafts,
  onCompose,
  onInbox,
}: {
  readonly account: string | undefined;
  readonly mailboxes: readonly MailboxConnection[];
  readonly profile: string;
  readonly drafts: Drafts;
  readonly onCompose: ((id: string) => void) | undefined;
  readonly onInbox: () => void;
}) {
  const { t } = useLocalization();
  const state = useSyncExternalStore(drafts.subscribe, drafts.getSnapshot);
  const navigation = useMemo(() => createComposerNavigation(), []);
  const mounted = useRef(false);
  useLayoutEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  const [sender] = sendingMailboxes(mailboxes, profile);
  if (account === undefined) {
    return null;
  }
  return (
    <Commands
      commands={[
        {
          id: 'compose',
          label: t('drafts.newMessage'),
          keywords: t('commandPalette.composeKeywords'),
          group: 'app',
          disabled:
            state.kind !== 'ready' ||
            sender === undefined ||
            onCompose === undefined
              ? t('commandPalette.unavailable')
              : undefined,
          onRun: async () => {
            if (
              !mounted.current ||
              sender === undefined ||
              onCompose === undefined
            ) {
              return false;
            }
            const id = await navigation.create(drafts, sender, {
              before: async () => mounted.current,
            });
            if (id === undefined) {
              return false;
            }
            if (!mounted.current) {
              await drafts.abandon(id);
              return false;
            }
            onCompose(id);
            onInbox();
            return true;
          },
        },
      ]}
    />
  );
}
