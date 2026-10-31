import type { Translate } from '@private-email/localization';
import type { MenuItem } from '@private-email/mail-core/context-menu';
import type {
  MailboxConnection,
  MailProfile,
  ProfileFailure,
  ProfileStyle,
  Registration,
} from '@private-email/mail-core/registration';

import {
  profileColors,
  profileConnections,
  profileIcons,
  profileIconSymbol,
  profileName,
  profileRefusalText,
  profileRemoval,
  windowProfile,
} from '@private-email/mail-core/profile-windows';
import { defaultProfile } from '@private-email/mail-core/registration';
import { spacing, typography } from '@private-email/mail-core/theme';
import { useEffect, useState, useSyncExternalStore } from 'react';
import {
  ActivityIndicator,
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
import { textStyles, usePalette, useProfilePalette } from './theme.ts';

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
  // iPhone's 30pt monogram, iPad's 28pt. The frames draw it 4pt into the row's leading inset, with
  // its title 10pt (iPad 8pt) after it, in line with the mailbox rows' titles.
  monogram: {
    width: settingsColumns ? 28 : 30,
    height: settingsColumns ? 28 : 30,
    borderRadius: settingsColumns ? 14 : 15,
    marginLeft: -4,
    marginRight: settingsColumns ? -4 : -2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  monogramText: {
    fontSize: settingsColumns ? 13 : 14,
    fontWeight: '600',
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

// A system menu choosing one item, labeled with the current one; it ignores a choice once disabled.
function PopUp({
  accessibilityLabel,
  label,
  items,
  disabled = false,
}: {
  readonly accessibilityLabel: string;
  readonly label: string;
  readonly items: readonly MenuItem[];
  readonly disabled?: boolean;
}) {
  const colors = usePalette();
  return (
    <MenuButton
      style={styles.menu}
      disabled={disabled}
      accessibilityLabel={accessibilityLabel}
      accessibilityValue={{ text: label }}
      sections={[
        {
          items: items.map((item) =>
            'run' in item
              ? {
                  ...item,
                  run: () => {
                    if (!disabled) {
                      void item.run();
                    }
                  },
                }
              : item,
          ),
        },
      ]}>
      <View style={styles.popUp}>
        <Text style={[styles.value, { color: colors.textPrimary }]}>
          {label}
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

// A system menu choosing one Mail Profile, labeled with the current one.
function ProfilePopUp({
  accessibilityLabel,
  current,
  ids,
  nameOf,
  onChoose,
  disabled = false,
}: {
  readonly accessibilityLabel: string;
  readonly current: string;
  readonly ids: readonly string[];
  readonly nameOf: (id: string) => string;
  readonly onChoose: (id: string) => void;
  readonly disabled?: boolean;
}) {
  return (
    <PopUp
      accessibilityLabel={accessibilityLabel}
      label={nameOf(current)}
      disabled={disabled}
      items={ids.map((id) => ({
        key: id,
        title: nameOf(id),
        symbol: '',
        checked: id === current,
        run: () => {
          onChoose(id);
        },
      }))}
    />
  );
}

// A Mail Profile's monogram: its Color filling the circle under its Icon, or its name's first letter.
function ProfileMonogram({
  name,
  style: { color = 'graphite', icon },
}: {
  readonly name: string;
  readonly style: ProfileStyle;
}) {
  const colors = usePalette();
  const fills = useProfilePalette();
  return (
    <View
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      style={[styles.monogram, { backgroundColor: fills[color] }]}>
      {icon === undefined ? (
        <Text style={[styles.monogramText, { color: colors.brandOnDeep }]}>
          {[...name][0]?.toLocaleUpperCase() ?? ''}
        </Text>
      ) : (
        <SFSymbol
          name={profileIconSymbol[icon]}
          size={12}
          color={colors.brandOnDeep}
        />
      )}
    </View>
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
      returnKeyType="done"
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
  // The Primary Profile has no record, so it keeps Graphite and First Letter.
  const styleOf = (id: string): ProfileStyle =>
    profiles.find((profile) => profile.id === id) ?? {};
  const { color = 'graphite', icon } = styleOf(selected);
  const fills = useProfilePalette();
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
        accessibilityLabel={
          pending.find((each) => each.control === control)?.progress
        }
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
  // Each change stores the whole style, keeping the other choice.
  const restyle = async (control: string, style: ProfileStyle) => {
    const failure = await change({ control }, () =>
      store.restyleProfile(selected, style),
    );
    if (failure !== undefined) {
      refused(t, 'restyle', failure);
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
              icon={
                <ProfileMonogram
                  name={nameOf(id)}
                  style={styleOf(id)}
                />
              }
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
          disabled={busy}
          onPress={() => {
            promptNewProfile(t, (name) =>
              change({ control: 'new' }, () => store.createProfile(name)),
            );
          }}
          style={({ pressed }) =>
            pressed && {
              backgroundColor: colors.accentSelectionSubtle,
            }
          }>
          <SettingsRow
            title={t('profiles.add')}
            titleTone="accent"
            disabled={busy}>
            {progress('new')}
          </SettingsRow>
        </Pressable>
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
        <SettingsRow title={t('profiles.color')}>
          {progress('color')}
          {selected === defaultProfile ? (
            <Text style={[styles.value, { color: colors.textSecondary }]}>
              {t(`profiles.colors.${color}`)}
            </Text>
          ) : (
            <PopUp
              accessibilityLabel={t('profiles.color')}
              disabled={busy}
              label={t(`profiles.colors.${color}`)}
              items={profileColors.map((each) => ({
                key: each,
                title: t(`profiles.colors.${each}`),
                symbol: 'circle.fill',
                symbolColor: fills[each],
                checked: each === color,
                run: () => {
                  if (each !== color) {
                    void restyle('color', {
                      color: each,
                      ...(icon === undefined ? {} : { icon }),
                    });
                  }
                },
              }))}
            />
          )}
        </SettingsRow>
        <SettingsRow title={t('profiles.icon')}>
          {progress('icon')}
          {selected === defaultProfile ? (
            <Text style={[styles.value, { color: colors.textSecondary }]}>
              {t('profiles.icons.firstLetter')}
            </Text>
          ) : (
            <PopUp
              accessibilityLabel={t('profiles.icon')}
              disabled={busy}
              label={t(`profiles.icons.${icon ?? 'firstLetter'}`)}
              items={[undefined, ...profileIcons].map((each) => ({
                key: each ?? 'firstLetter',
                title: t(`profiles.icons.${each ?? 'firstLetter'}`),
                symbol:
                  each === undefined ? 'character' : profileIconSymbol[each],
                checked: each === icon,
                run: () => {
                  if (each !== icon) {
                    void restyle('icon', {
                      color,
                      ...(each === undefined ? {} : { icon: each }),
                    });
                  }
                },
              }))}
            />
          )}
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
              titleNumberOfLines={1}
              subtitle={t(`mailProviders.${mailbox.provider}`)}>
              {/* A pending move shows only the indicator in place of the pop-up. */}
              {progress(mailbox.id) ?? (
                <ProfilePopUp
                  accessibilityLabel={t('profiles.moveMailbox', {
                    address: mailbox.address,
                  })}
                  current={selected}
                  ids={ids}
                  nameOf={nameOf}
                  disabled={busy}
                  onChoose={(id) => {
                    if (id !== selected) {
                      void move(mailbox.id, id);
                    }
                  }}
                />
              )}
            </SettingsRow>
          ))}
        </SettingsGroup>
      )}
      <SettingsGroup footer={t('profiles.settings.duplicateFooter')}>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={t('profiles.duplicate')}
          disabled={busy}
          onPress={() => {
            void duplicate();
          }}
          style={({ pressed }) =>
            pressed && {
              backgroundColor: colors.accentSelectionSubtle,
            }
          }>
          <SettingsRow
            title={t('profiles.duplicate')}
            disabled={busy}>
            {progress('duplicate')}
          </SettingsRow>
        </Pressable>
      </SettingsGroup>
      {selected === defaultProfile ? null : (
        <SettingsGroup footer={t('profiles.settings.removeFooter')}>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={t('profiles.remove')}
            disabled={busy}
            onPress={confirmRemoval}
            style={({ pressed }) =>
              pressed && {
                backgroundColor: colors.accentSelectionSubtle,
              }
            }>
            <SettingsRow
              title={t('profiles.remove')}
              titleTone="destructive"
              disabled={busy}>
              {progress('remove')}
            </SettingsRow>
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
