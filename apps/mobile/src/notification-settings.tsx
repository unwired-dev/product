import type {
  MailboxConnection,
  MailProfile,
  Registration,
} from '@private-email/mail-core/registration';

import { profileName } from '@private-email/mail-core/profile-windows';
import { defaultProfile } from '@private-email/mail-core/registration';
import { typography } from '@private-email/mail-core/theme';
import { createContext, use, useEffect, useSyncExternalStore } from 'react';
import { AppState, Switch, Text } from 'react-native';

import type { SettingsButton } from './settings.tsx';

import { useLocalization } from './localization.ts';
import { notifications } from './registration.ts';
import {
  PopUpChoice,
  settingsColumns,
  SettingsGroup,
  SettingsRow,
  switchRowHeight,
} from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

type NotificationSettingsStore = Omit<typeof notifications, 'arrived'>;

export const NotificationsContext =
  createContext<NotificationSettingsStore>(notifications);

type DeviceSettings = ReturnType<NotificationSettingsStore['getSnapshot']>;

// The operating system's permission: its state, and the way to change it.
function Authorization({
  button,
  device,
  settings,
}: {
  readonly button: SettingsButton;
  readonly device: NotificationSettingsStore;
  readonly settings: DeviceSettings;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const value = (text: string) => (
    <Text
      style={[
        settingsColumns ? typography.ipadList.body : textStyles.body,
        { color: colors.textSecondary },
      ]}>
      {text}
    </Text>
  );
  const shown = {
    authorized: () => value(t('notifications.allowed')),
    denied: () => (
      <>
        {value(t('notifications.denied'))}
        {button(t('notifications.openSettings'), device.openSettings)}
      </>
    ),
    undetermined: () => button(t('notifications.allow'), device.request),
  };
  return settings === undefined ? null : shown[settings.authorization]();
}

// One connection's synchronized switch; turning it on asks for permission the first time.
function MailboxNotifications({
  mailbox: { id, provider, address, notifications: on },
  device,
  settings,
  store,
}: {
  readonly mailbox: MailboxConnection;
  readonly device: NotificationSettingsStore;
  readonly settings: DeviceSettings;
  readonly store: Registration;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const { busy, notificationFailure } = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
  );
  const title = t('notifications.mailbox', {
    provider: t(`mailProviders.${provider}`),
    address,
  });
  return (
    <SettingsRow
      title={title}
      subtitle={
        notificationFailure === id ? t('notifications.changeFailed') : undefined
      }
      subtitleTone="warning"
      minHeight={switchRowHeight}>
      <Switch
        accessibilityLabel={title}
        // Until permission is known, a first enable could not ask for it.
        accessibilityState={{ disabled: busy || settings === undefined, busy }}
        disabled={busy || settings === undefined}
        value={on === true}
        trackColor={{ false: colors.fillTrack, true: colors.accentFill }}
        onValueChange={(enabled) => {
          if (enabled && settings?.authorization === 'undetermined') {
            void device.request();
          }
          void store.notifyMailbox(id, enabled);
        }}
      />
    </SettingsRow>
  );
}

// What the App Icon Badge counts and the sound a shown New Mail Notification plays. While
// notifications are off, the choices stay, dimmed, until they are allowed again.
function BadgeAndSound({
  device,
  settings,
}: {
  readonly device: NotificationSettingsStore;
  readonly settings: DeviceSettings;
}) {
  const { t } = useLocalization();
  const denied = settings?.authorization === 'denied';
  const context = settingsColumns ? 'ipad' : 'iphone';
  return (
    <SettingsGroup
      title={t('notifications.thisDevice', { context })}
      footer={t(
        denied ? 'notifications.badgeKept' : 'notifications.badgeSoundDetail',
      )}>
      <SettingsRow
        title={t('notifications.badge', { context })}
        disabled={denied}>
        {settings === undefined ? null : (
          <PopUpChoice
            label={t('notifications.badge', { context })}
            selected={settings.badge}
            choices={['off', 'inbox']}
            title={(badge) => t(`notifications.badges.${badge}`)}
            disabled={denied}
            onChoose={(badge) => {
              if (
                badge === 'inbox' &&
                settings.authorization === 'undetermined'
              ) {
                void device.request();
              }
              void device.setBadge(badge);
            }}
          />
        )}
      </SettingsRow>
      <SettingsRow
        title={t('notifications.sound', { context })}
        disabled={denied}>
        {settings === undefined ? null : (
          <PopUpChoice
            label={t('notifications.sound', { context })}
            // Only the Mac offers its alert sounds.
            selected={settings.sound === 'none' ? 'none' : 'default'}
            choices={['default', 'none']}
            title={(sound) => t(`notifications.sounds.${sound}`)}
            disabled={denied}
            onChoose={(sound) => {
              void device.setSound(sound);
            }}
          />
        )}
      </SettingsRow>
    </SettingsGroup>
  );
}

// Each Mail Profile's Badge and sound switch. Until notifications are allowed the group is not
// shown, and the choices stay until then.
function Profiles({
  account,
  profiles,
  device,
  settings,
}: {
  readonly account: string;
  readonly profiles: readonly MailProfile[];
  readonly device: NotificationSettingsStore;
  readonly settings: DeviceSettings;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  if (settings?.authorization !== 'authorized') {
    return null;
  }
  return (
    <SettingsGroup title={t('notifications.profiles')}>
      {[defaultProfile, ...profiles.map(({ id }) => id)].map((profile) => {
        const name = profileName(t, profile, profiles);
        return (
          <SettingsRow
            key={profile}
            title={name}
            subtitle={t('notifications.badgeAndSound')}
            subtitleTone="detail"
            minHeight={switchRowHeight}>
            <Switch
              accessibilityLabel={t('notifications.badgeAndSoundFor', {
                name,
              })}
              value={!settings.badgeSoundOff.includes(profile)}
              trackColor={{ false: colors.fillTrack, true: colors.accentFill }}
              onValueChange={(on) => {
                void device.setProfileBadgeSound(account, profile, on);
              }}
            />
          </SettingsRow>
        );
      })}
    </SettingsGroup>
  );
}

// The Per Mailbox group: a switch for each connection.
function PerMailbox({
  mailboxes,
  device,
  settings,
  store,
}: {
  readonly mailboxes: readonly MailboxConnection[];
  readonly device: NotificationSettingsStore;
  readonly settings: DeviceSettings;
  readonly store: Registration;
}) {
  const { t } = useLocalization();
  return mailboxes.length === 0 ? (
    <SettingsGroup
      title={t('notifications.perMailbox')}
      footer={t('notifications.noMailboxes')}
    />
  ) : (
    <SettingsGroup
      title={t('notifications.perMailbox')}
      footer={t('notifications.perMailboxDetail')}>
      {mailboxes.map((mailbox) => (
        <MailboxNotifications
          key={mailbox.id}
          mailbox={mailbox}
          device={device}
          settings={settings}
          store={store}
        />
      ))}
    </SettingsGroup>
  );
}

// This device's notification permission, previews, App Icon Badge, New Mail Sound and each
// Profile's Badge and sound switch, which never synchronize, then each connection's synchronized
// New Mail Notification switch.
export function NotificationSettings({
  button,
  account,
  profiles,
  mailboxes,
  store,
}: {
  readonly button: SettingsButton;
  readonly account: string;
  readonly profiles: readonly MailProfile[];
  readonly mailboxes: readonly MailboxConnection[];
  readonly store: Registration;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const device = use(NotificationsContext);
  const settings = useSyncExternalStore(device.subscribe, device.getSnapshot);
  // Permission can change in the system's settings while the application is away.
  useEffect(() => {
    void device.load();
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        void device.load();
      }
    });
    return () => {
      subscription.remove();
    };
  }, [device]);
  return (
    <>
      <SettingsGroup
        title={t('notifications.onThisDevice')}
        footer={t('notifications.previewsDetail')}>
        <SettingsRow title={t('notifications.authorization')}>
          <Authorization
            button={button}
            device={device}
            settings={settings}
          />
        </SettingsRow>
        <SettingsRow
          title={t('notifications.previews')}
          minHeight={switchRowHeight}>
          <Switch
            accessibilityLabel={t('notifications.previews')}
            disabled={settings === undefined}
            value={settings?.previews === true}
            trackColor={{ false: colors.fillTrack, true: colors.accentFill }}
            onValueChange={(previews) => {
              void device.setPreviews(previews);
            }}
          />
        </SettingsRow>
      </SettingsGroup>
      <BadgeAndSound
        device={device}
        settings={settings}
      />
      <Profiles
        account={account}
        profiles={profiles}
        device={device}
        settings={settings}
      />
      <PerMailbox
        mailboxes={mailboxes}
        device={device}
        settings={settings}
        store={store}
      />
    </>
  );
}
