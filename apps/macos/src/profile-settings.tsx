import type { Translate } from '@private-email/localization';
import type {
  MailboxConnection,
  MailProfile,
  ProfileFailure,
  Registration,
} from '@private-email/mail-core/registration';

import {
  profileConnections,
  profileName,
  windowProfile,
} from '@private-email/mail-core/profile-windows';
import { defaultProfile } from '@private-email/mail-core/registration';
import { useEffect, useState, useSyncExternalStore } from 'react';
import { Alert, Pressable, StyleSheet, Text, TextInput } from 'react-native';

import { PopUp } from './composer-controls.tsx';
import { useLocalization } from './localization.ts';
import { profileChoices } from './profile-choices.ts';
import { SettingsGroup, SettingsRow } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  value: { ...textStyles.body },
  name: { ...textStyles.body, minWidth: 200, textAlign: 'right' },
});

// Explains a refused Mail Profile change; nothing changed.
const refused = (
  t: Translate,
  change: 'new' | 'rename',
  failure: ProfileFailure,
) => {
  Alert.alert(
    t(
      failure === 'upgrade-required'
        ? 'profiles.upgradeTitle'
        : `profiles.${change}Title`,
    ),
    t(
      failure === 'upgrade-required'
        ? 'profiles.upgradeMessage'
        : `profiles.${change}Failed`,
    ),
    [{ text: t('profiles.ok') }],
  );
};

// Asks for a new Mail Profile's name and creates it without switching to it.
export function promptNewProfile(
  t: Translate,
  create: (name: string) => Promise<ProfileFailure | undefined>,
) {
  const submit = async (name: string) => {
    const failure = await create(name);
    if (failure !== undefined) {
      refused(t, 'new', failure);
    }
  };
  Alert.promptMacOS(
    t('profiles.newTitle'),
    t('profiles.newMessage'),
    [
      {
        text: t('profiles.create'),
        onPress: (entered?: string) => {
          if (entered !== undefined && entered.trim() !== '') {
            void submit(entered);
          }
        },
      },
      { text: t('common.cancel'), style: 'cancel' },
    ],
    'plain-text',
    [{ placeholder: t('profiles.name') }],
  );
}

// The Profile's name, renamed when editing ends; the Default Profile keeps its Primary Profile name.
function ProfileName({
  profile,
  name,
  store,
}: {
  readonly profile: string;
  readonly name: string;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [entry, setEntry] = useState(name);
  if (profile === defaultProfile) {
    return (
      <Text style={[styles.value, { color: colors.textSecondary }]}>
        {name}
      </Text>
    );
  }
  const rename = async () => {
    const chosen = entry.trim();
    if (chosen === '' || chosen === name) {
      setEntry(name);
      return;
    }
    await store.renameProfile(profile, chosen);
    const failure = store.getSnapshot().profileFailure;
    if (failure !== undefined) {
      setEntry(name);
      refused(t, 'rename', failure);
    }
  };
  return (
    <TextInput
      accessibilityLabel={t('profiles.name')}
      autoCorrect={false}
      onEndEditing={() => {
        void rename();
      }}
      onChangeText={setEntry}
      style={[styles.name, { color: colors.textSecondary }]}
      value={entry}
    />
  );
}

// Settings › Mail Profiles: every Profile with its connections, Add Mail Profile…, the selected
// Profile's name, and this device's Startup Profile.
export function MailProfilesSettings({
  profiles,
  mailboxes,
  store,
}: {
  readonly profiles: readonly MailProfile[];
  readonly mailboxes: readonly MailboxConnection[];
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [chosen, setChosen] = useState(defaultProfile);
  const choices = useSyncExternalStore(
    profileChoices.subscribe,
    profileChoices.getSnapshot,
  );
  useEffect(() => {
    void profileChoices.load();
  }, []);
  const ids = [defaultProfile, ...profiles.map(({ id }) => id)];
  // A Profile removed elsewhere leaves the Primary Profile selected.
  const selected = ids.includes(chosen) ? chosen : defaultProfile;
  const startup = windowProfile({ startup: choices?.startup, profiles });
  const nameOf = (id: string) => profileName(t, id, profiles);
  return (
    <>
      <SettingsGroup title={t('profiles.settings.profiles')}>
        {ids.map((id) => (
          <Pressable
            key={id}
            accessibilityRole="button"
            accessibilityLabel={nameOf(id)}
            accessibilityHint={profileConnections(t, mailboxes, id)}
            accessibilityState={{ selected: id === selected }}
            accessibilityValue={
              id === startup && choices !== undefined
                ? { text: t('profiles.startup') }
                : undefined
            }
            focusable
            onPress={() => {
              setChosen(id);
            }}
            style={({ pressed }) =>
              (id === selected || pressed) && {
                backgroundColor: colors.accentSelectionSubtle,
              }
            }>
            <SettingsRow
              icon="person.crop.rectangle.stack"
              title={nameOf(id)}
              subtitle={profileConnections(t, mailboxes, id)}>
              {id === startup && choices !== undefined ? (
                <Text style={[styles.value, { color: colors.textSecondary }]}>
                  {t('profiles.startup')}
                </Text>
              ) : null}
            </SettingsRow>
          </Pressable>
        ))}
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={t('profiles.add')}
          focusable
          onPress={() => {
            promptNewProfile(t, async (name) => {
              await store.createProfile(name);
              return store.getSnapshot().profileFailure;
            });
          }}>
          <SettingsRow title={t('profiles.add')} />
        </Pressable>
      </SettingsGroup>
      <SettingsGroup
        title={nameOf(selected)}
        footer={t('profiles.settings.synchronized')}>
        <SettingsRow title={t('profiles.name')}>
          <ProfileName
            // A rename elsewhere, or another selected Profile, starts from the listed name.
            key={`${selected}\n${nameOf(selected)}`}
            profile={selected}
            name={nameOf(selected)}
            store={store}
          />
        </SettingsRow>
      </SettingsGroup>
      {choices === undefined ? null : (
        <SettingsGroup
          title={t('profiles.settings.device')}
          footer={t('profiles.settings.deviceFooter')}>
          <SettingsRow title={t('profiles.startup')}>
            <PopUp
              accessibilityLabel={t('profiles.startup')}
              label={nameOf(startup)}
              items={ids.map((id) => ({
                key: id,
                title: nameOf(id),
                checked: id === startup,
                run: () => {
                  void profileChoices.chooseStartup(id);
                },
              }))}
            />
          </SettingsRow>
        </SettingsGroup>
      )}
    </>
  );
}
