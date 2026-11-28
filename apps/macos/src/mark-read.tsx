import type { MarkRead } from '@private-email/mail-core/inbox-preferences';
import type { MailProfile } from '@private-email/mail-core/registration';

import { defaultProfile } from '@private-email/mail-core/registration';
import { use, useEffect, useState, useSyncExternalStore } from 'react';

import { PopUp } from './composer-controls.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { InboxPreferencesContext } from './preview-lines.tsx';
import {
  settingsButton,
  SettingsBlock,
  SettingsGroup,
  SettingsRow,
} from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

const choices: readonly MarkRead[] = [
  'immediately',
  'afterTwoSeconds',
  'manually',
];

// When opening a message of `profile` marks it read, which its other Trusted Devices share;
// undefined until the choice is read.
export function useMarkRead(profile: string) {
  const store = use(InboxPreferencesContext);
  const choice = useSyncExternalStore(store.subscribe, () =>
    store.markRead(profile),
  );
  useEffect(() => {
    if (choice === undefined) {
      void store.load();
    }
  }, [choice, store]);
  return choice;
}

// Settings › Reading › Mark as Read. The Settings window has no Mail Profile, so it shows one
// pop-up per Profile, the Primary Profile first.
export function MarkReadSettings({
  profiles,
}: {
  // The Mail Profiles besides the Default Profile.
  readonly profiles: readonly MailProfile[];
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const store = use(InboxPreferencesContext);
  const all = [
    { id: defaultProfile, name: t('profiles.primary') },
    ...profiles,
  ];
  const waiting = useSyncExternalStore(store.subscribe, () =>
    all.some(({ id }) => store.waiting(id)),
  );
  // The choice storage refused, which Try Again makes again.
  const [failed, setFailed] = useState<
    Readonly<{ profile: string; choice: MarkRead }> | undefined
  >(undefined);
  const choose = async (profile: string, choice: MarkRead) => {
    const stored = await store.setMarkRead(profile, choice);
    setFailed(stored ? undefined : { profile, choice });
  };
  const footer = t('markRead.footer');
  return (
    <SettingsGroup
      title={t('message.markRead')}
      footer={waiting ? `${footer} ${t('markRead.waiting')}` : footer}>
      {all.map(({ id, name }) => (
        <ProfileChoice
          key={id}
          profile={id}
          name={name}
          onChoose={(choice) => {
            void choose(id, choice);
          }}
        />
      ))}
      {failed === undefined ? null : (
        <SettingsBlock>
          <Label
            accessibilityRole="alert"
            style={[textStyles.body, { color: colors.textPrimary }]}>
            {t('markRead.saveFailed')}
          </Label>
          {settingsButton(false)(t('common.retry'), () =>
            choose(failed.profile, failed.choice),
          )}
        </SettingsBlock>
      )}
    </SettingsGroup>
  );
}

// One Mail Profile's Mark as Read pop-up, each choice with the line that explains it.
function ProfileChoice({
  profile,
  name,
  onChoose,
}: {
  readonly profile: string;
  readonly name: string;
  readonly onChoose: (choice: MarkRead) => void;
}) {
  const { t } = useLocalization();
  const selected = useMarkRead(profile) ?? 'immediately';
  return (
    <SettingsRow title={name}>
      <PopUp
        accessibilityLabel={t('markRead.profile', { name })}
        variant="inline"
        label={t(`markRead.${selected}`)}
        items={choices.map((choice) => ({
          key: choice,
          title: t(`markRead.${choice}`),
          subtitle: t(`markRead.${choice}Detail`),
          checked: choice === selected,
          run: () => {
            onChoose(choice);
          },
        }))}
      />
    </SettingsRow>
  );
}
