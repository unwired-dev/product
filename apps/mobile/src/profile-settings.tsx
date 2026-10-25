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
  profileRefusalText,
  profileRemoval,
  windowProfile,
} from '@private-email/mail-core/profile-windows';
import { defaultProfile } from '@private-email/mail-core/registration';
import { spacing, typography } from '@private-email/mail-core/theme';
import { useEffect, useState, useSyncExternalStore } from 'react';
import {
  Alert,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import { MenuButton, SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { profileChoices } from './profile-choices.ts';
import { SettingsGroup, SettingsRow, settingsColumns } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

const value = settingsColumns ? typography.ipadList.body : textStyles.body;

const styles = StyleSheet.create({
  value,
  name: {
    ...value,
    minWidth: 160,
    minHeight: 44,
    marginVertical: -spacing.m,
    textAlign: 'right',
  },
  menu: {
    minWidth: 44,
    minHeight: 44,
    marginVertical: -spacing.m,
  },
  popUp: {
    minHeight: 44,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
  },
});

// Explains why a Mail Profile change did not complete.
const refused = (
  t: Translate,
  change: Parameters<typeof profileRefusalText>[1],
  failure: ProfileFailure,
) => {
  const { title, message } = profileRefusalText(t, change, failure);
  Alert.alert(title, message, [{ text: t('profiles.ok') }]);
};

// A system menu choosing one Mail Profile, labeled with the current one.
function ProfilePopUp({
  accessibilityLabel,
  current,
  ids,
  nameOf,
  onChoose,
}: {
  readonly accessibilityLabel: string;
  readonly current: string;
  readonly ids: readonly string[];
  readonly nameOf: (id: string) => string;
  readonly onChoose: (id: string) => void;
}) {
  const colors = usePalette();
  return (
    <MenuButton
      style={styles.menu}
      accessibilityLabel={accessibilityLabel}
      accessibilityValue={{ text: nameOf(current) }}
      sections={[
        {
          items: ids.map((id) => ({
            key: id,
            title: nameOf(id),
            symbol: '',
            checked: id === current,
            run: () => {
              onChoose(id);
            },
          })),
        },
      ]}>
      <View style={styles.popUp}>
        <Text style={[styles.value, { color: colors.textPrimary }]}>
          {nameOf(current)}
        </Text>
        <SFSymbol
          name="chevron.up.chevron.down"
          size={12}
          color={colors.textSecondary}
        />
      </View>
    </MenuButton>
  );
}

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
  Alert.prompt(
    t('profiles.newTitle'),
    t('profiles.newMessage'),
    [
      { text: t('common.cancel'), style: 'cancel' },
      {
        text: t('profiles.create'),
        isPreferred: true,
        onPress: (entered?: string) => {
          if (entered !== undefined && entered.trim() !== '') {
            void submit(entered);
          }
        },
      },
    ],
    'plain-text',
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
      returnKeyType="done"
      style={[styles.name, { color: colors.textSecondary }]}
      value={entry}
    />
  );
}

// Settings › Mail Profiles: every Profile with its connections, Add Mail Profile…, the selected
// Profile's name, and this device's Startup Profile.
export function MailProfilesSettings({
  account,
  profiles,
  mailboxes,
  store,
}: {
  readonly account: string;
  readonly profiles: readonly MailProfile[];
  readonly mailboxes: readonly MailboxConnection[];
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [chosen, setChosen] = useState(defaultProfile);
  const choices = useSyncExternalStore(profileChoices.subscribe, () =>
    profileChoices.getSnapshot(account),
  );
  useEffect(() => {
    void profileChoices.load(account);
  }, [account]);
  const ids = [defaultProfile, ...profiles.map(({ id }) => id)];
  // A Profile removed elsewhere leaves the Primary Profile selected.
  const selected = ids.includes(chosen) ? chosen : defaultProfile;
  const startup = windowProfile({ startup: choices?.startup, profiles });
  const nameOf = (id: string) => profileName(t, id, profiles);
  const owned = mailboxes.filter(({ profile }) => profile === selected);
  const move = async (mailbox: string, profile: string) => {
    await store.moveMailbox(mailbox, profile);
    const failure = store.getSnapshot().profileFailure;
    if (failure !== undefined) {
      refused(t, 'move', failure);
    }
  };
  const remove = async (profile: string, confirmed: readonly string[]) => {
    await store.removeProfile(profile, confirmed);
    const failure = store.getSnapshot().profileFailure;
    if (failure !== undefined) {
      refused(t, 'remove', failure);
    }
  };
  // Removing a Profile also removes the mailboxes the question names, after the person confirms.
  const confirmRemoval = () => {
    const profile = selected;
    const confirmed = owned.map(({ id }) => id);
    const { title, message } = profileRemoval(t, nameOf(profile), owned);
    Alert.alert(title, message, [
      { text: t('common.cancel'), style: 'cancel' },
      {
        text: t('profiles.removeAction'),
        style: 'destructive',
        onPress: () => {
          void remove(profile, confirmed);
        },
      },
    ]);
  };
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
            onPress={() => {
              setChosen(id);
            }}
            style={({ pressed }) =>
              pressed && {
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
              <SFSymbol
                name="chevron.right"
                size={12}
                color={colors.textSecondary}
              />
            </SettingsRow>
          </Pressable>
        ))}
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={t('profiles.add')}
          onPress={() => {
            promptNewProfile(t, async (name) => {
              await store.createProfile(name);
              return store.getSnapshot().profileFailure;
            });
          }}
          style={({ pressed }) =>
            pressed && {
              backgroundColor: colors.accentSelectionSubtle,
            }
          }>
          <SettingsRow
            title={t('profiles.add')}
            titleTone="accent"
          />
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
      {owned.length === 0 ? null : (
        <SettingsGroup
          title={t('profiles.settings.mailboxes')}
          footer={t('profiles.settings.moveFooter')}>
          {owned.map((mailbox) => (
            <SettingsRow
              key={mailbox.id}
              icon="at"
              title={mailbox.address}
              titleNumberOfLines={1}
              subtitle={t(`mailProviders.${mailbox.provider}`)}>
              <ProfilePopUp
                accessibilityLabel={t('profiles.moveMailbox', {
                  address: mailbox.address,
                })}
                current={selected}
                ids={ids}
                nameOf={nameOf}
                onChoose={(id) => {
                  if (id !== selected) {
                    void move(mailbox.id, id);
                  }
                }}
              />
            </SettingsRow>
          ))}
        </SettingsGroup>
      )}
      {selected === defaultProfile ? null : (
        <SettingsGroup footer={t('profiles.settings.removeFooter')}>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={t('profiles.remove')}
            onPress={confirmRemoval}
            style={({ pressed }) =>
              pressed && {
                backgroundColor: colors.accentSelectionSubtle,
              }
            }>
            <SettingsRow
              title={t('profiles.remove')}
              titleTone="destructive"
            />
          </Pressable>
        </SettingsGroup>
      )}
      {choices === undefined ? null : (
        <SettingsGroup
          title={t('profiles.settings.device')}
          footer={t('profiles.settings.deviceFooter')}>
          <SettingsRow title={t('profiles.startup')}>
            <ProfilePopUp
              accessibilityLabel={t('profiles.startup')}
              current={startup}
              ids={ids}
              nameOf={nameOf}
              onChoose={(id) => {
                void profileChoices.chooseStartup(account, id);
              }}
            />
          </SettingsRow>
        </SettingsGroup>
      )}
    </>
  );
}
