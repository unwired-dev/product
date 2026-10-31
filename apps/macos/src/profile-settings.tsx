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
import { spacing } from '@private-email/mail-core/theme';
import { useEffect, useState, useSyncExternalStore } from 'react';
import {
  ActivityIndicator,
  Alert,
  StyleSheet,
  Text,
  TextInput,
} from 'react-native';

import { PopUp } from './composer-controls.tsx';
import { SFSymbol, useConfirmation } from './design.tsx';
import { useLocalization } from './localization.ts';
import { profileChoices } from './profile-choices.ts';
import { SettingsGroup, SettingsRow, SettingsRowButton } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  value: { ...textStyles.body },
  name: {
    ...textStyles.body,
    minWidth: 200,
    minHeight: 28,
    marginVertical: -spacing.s,
    textAlign: 'right',
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
  disabled,
  rename,
}: {
  readonly profile: string;
  readonly name: string;
  readonly disabled: boolean;
  readonly rename: (name: string) => Promise<ProfileFailure | undefined>;
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
  const submit = async () => {
    const chosen = entry.trim();
    if (chosen === '' || chosen === name) {
      setEntry(name);
      return;
    }
    const failure = await rename(chosen);
    if (failure !== undefined) {
      setEntry(name);
      refused(t, 'rename', failure);
    }
  };
  return (
    <TextInput
      accessibilityLabel={t('profiles.name')}
      autoCorrect={false}
      editable={!disabled}
      onEndEditing={() => {
        void submit();
      }}
      onChangeText={setEntry}
      style={[styles.name, { color: colors.textSecondary }]}
      value={entry}
    />
  );
}

// A queued Mail Profile change: the control that started it and, for a move, its progress text.
type Pending = Readonly<{ control: string; progress?: string }>;

// Settings › Mail Profiles: every Profile with its connections, Add Mail Profile…, the selected
// Profile's name, mailboxes and Duplicate, and this device's Startup Profile.
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
  const { anchor, confirm } = useConfirmation();
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
  const [pending, setPending] = useState<readonly Pending[]>([]);
  const busy = pending.length > 0;
  // Editing completion can arrive after another control starts a change.
  const change = async (started: Pending, run: () => Promise<unknown>) => {
    setPending((current) => [...current, started]);
    await run().finally(() => {
      setPending((current) => current.filter((each) => each !== started));
    });
    return store.getSnapshot().profileFailure;
  };
  const progress = (control: string) =>
    pending.some((each) => each.control === control) ? (
      <ActivityIndicator
        size="small"
        color={colors.textSecondary}
      />
    ) : undefined;
  const move = async (mailbox: string, profile: string) => {
    const failure = await change(
      {
        control: mailbox,
        progress: t('profiles.moving', { name: nameOf(profile) }),
      },
      () => store.moveMailbox(mailbox, profile),
    );
    if (failure !== undefined) {
      refused(t, 'move', failure);
    }
  };
  // Duplicate copies the name, Color and Icon into a new Profile, then opens it for renaming.
  const duplicate = async () => {
    const created = store.createProfile(
      t('profiles.copyName', { name: nameOf(selected) }),
      profiles.find(({ id }) => id === selected),
    );
    const failure = await change({ control: 'duplicate' }, () => created);
    if (failure !== undefined) {
      refused(t, 'new', failure);
      return;
    }
    const id = await created;
    if (id !== undefined) {
      setChosen(id);
    }
  };
  const remove = async (profile: string, confirmed: readonly string[]) => {
    const failure = await change({ control: 'remove' }, () =>
      store.removeProfile(profile, confirmed),
    );
    if (failure !== undefined) {
      refused(t, 'remove', failure);
    }
  };
  // Removing a Profile also removes the mailboxes the question names, after the person confirms.
  const confirmRemoval = () => {
    const profile = selected;
    const confirmed = owned.map(({ id }) => id);
    const { title, message } = profileRemoval(t, nameOf(profile), owned);
    const answer = async () => {
      if (
        await confirm({
          title,
          detail: message,
          cancel: t('common.cancel'),
          action: t('profiles.removeAction'),
        })
      ) {
        await remove(profile, confirmed);
      }
    };
    void answer();
  };
  return (
    <>
      <SettingsGroup title={t('profiles.settings.profiles')}>
        {ids.map((id) => (
          <SettingsRowButton
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
            }}>
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
                size={10}
                color={colors.textSecondary}
              />
            </SettingsRow>
          </SettingsRowButton>
        ))}
        <SettingsRowButton
          accessibilityRole="button"
          accessibilityLabel={t('profiles.add')}
          disabled={busy}
          onPress={() => {
            promptNewProfile(t, (name) =>
              change({ control: 'new' }, () => store.createProfile(name)),
            );
          }}>
          <SettingsRow
            title={t('profiles.add')}
            titleTone="accent"
            disabled={busy}>
            {progress('new')}
          </SettingsRow>
        </SettingsRowButton>
      </SettingsGroup>
      <SettingsGroup
        title={nameOf(selected)}
        footer={t('profiles.settings.synchronized')}>
        <SettingsRow title={t('profiles.name')}>
          {progress('rename')}
          <ProfileName
            // A rename elsewhere, or another selected Profile, starts from the listed name.
            key={`${selected}\n${nameOf(selected)}`}
            profile={selected}
            name={nameOf(selected)}
            disabled={busy}
            rename={(name) =>
              change({ control: 'rename' }, () =>
                store.renameProfile(selected, name),
              )
            }
          />
        </SettingsRow>
      </SettingsGroup>
      {mailboxes.length === 0 ? null : (
        <SettingsGroup
          title={t('profiles.settings.mailboxes')}
          footer={t('profiles.settings.moveFooter')}>
          {owned.length === 0 ? (
            <SettingsRow
              title={t('profiles.settings.emptyMailboxes')}
              subtitle={t('profiles.settings.emptyMailboxesDetail')}
            />
          ) : null}
          {owned.map((mailbox) => (
            <SettingsRow
              key={mailbox.id}
              icon="at"
              title={mailbox.address}
              subtitle={t(`mailProviders.${mailbox.provider}`)}>
              {progress(mailbox.id)}
              <PopUp
                accessibilityLabel={t('profiles.moveMailbox', {
                  address: mailbox.address,
                })}
                disabled={busy}
                label={
                  pending.find((each) => each.control === mailbox.id)
                    ?.progress ?? nameOf(selected)
                }
                items={ids.map((id) => ({
                  key: id,
                  title: nameOf(id),
                  checked: id === selected,
                  run: () => {
                    if (id !== selected) {
                      void move(mailbox.id, id);
                    }
                  },
                }))}
              />
            </SettingsRow>
          ))}
        </SettingsGroup>
      )}
      <SettingsGroup footer={t('profiles.settings.duplicateFooter')}>
        <SettingsRowButton
          accessibilityRole="button"
          accessibilityLabel={t('profiles.duplicate')}
          disabled={busy}
          onPress={() => {
            void duplicate();
          }}>
          <SettingsRow
            title={t('profiles.duplicate')}
            disabled={busy}>
            {progress('duplicate')}
          </SettingsRow>
        </SettingsRowButton>
      </SettingsGroup>
      {selected === defaultProfile ? null : (
        <SettingsGroup
          ref={anchor}
          footer={t('profiles.settings.removeFooter')}>
          <SettingsRowButton
            accessibilityRole="button"
            accessibilityLabel={t('profiles.remove')}
            disabled={busy}
            onPress={confirmRemoval}>
            <SettingsRow
              title={t('profiles.remove')}
              titleTone="destructive"
              disabled={busy}>
              {progress('remove')}
            </SettingsRow>
          </SettingsRowButton>
        </SettingsGroup>
      )}
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
                  void profileChoices.chooseStartup(account, id);
                },
              }))}
            />
          </SettingsRow>
        </SettingsGroup>
      )}
    </>
  );
}
