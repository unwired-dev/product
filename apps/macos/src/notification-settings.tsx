import type { SoundChoice } from '@private-email/mail-core/notifications';
import type {
  MailboxConnection,
  MailProfile,
  Registration,
} from '@private-email/mail-core/registration';

import { macAlertSounds } from '@private-email/mail-core/notifications';
import { profileName } from '@private-email/mail-core/profile-windows';
import { defaultProfile } from '@private-email/mail-core/registration';
import { createContext, use, useEffect, useSyncExternalStore } from 'react';
import { AppState, Switch } from 'react-native';

import type { SettingsButton } from './settings.tsx';

import { PopUp } from './composer-controls.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { notifications } from './registration.ts';
import { SettingsGroup, SettingsRow } from './settings.tsx';
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
    <Label
      style={[
        textStyles.body,
        { alignSelf: 'center', color: colors.textSecondary },
      ]}>
      {text}
    </Label>
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

// Default, the Mac's alert sounds and None, each in its own section of the pop-up.
const soundSections: ReadonlyArray<readonly SoundChoice[]> = [
  ['default'],
  macAlertSounds,
  ['none'],
];

// What the Dock badge counts and the sound a shown New Mail Notification plays. While
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
  const soundTitle = (sound: SoundChoice) =>
    sound === 'default' || sound === 'none'
      ? t(`notifications.sounds.${sound}`)
      : sound;
  return (
    <SettingsGroup
      title={t('notifications.thisDevice', { context: 'mac' })}
      footer={t(
        denied ? 'notifications.badgeKept' : 'notifications.badgeSoundDetail',
      )}>
      <SettingsRow
        title={t('notifications.dockBadge')}
        disabled={denied}>
        {settings === undefined ? null : (
          <PopUp
            variant="inline"
            accessibilityLabel={t('notifications.dockBadge')}
            label={t(`notifications.badges.${settings.badge}`)}
            disabled={denied}
            items={(['off', 'inbox'] as const).map((badge) => ({
              key: badge,
              title: t(`notifications.badges.${badge}`),
              checked: badge === settings.badge,
              run: () => {
                if (
                  badge === 'inbox' &&
                  settings.authorization === 'undetermined'
                ) {
                  void device.request();
                }
                void device.setBadge(badge);
              },
            }))}
          />
        )}
      </SettingsRow>
      <SettingsRow
        title={t('notifications.sound', { context: 'mac' })}
        disabled={denied}>
        {settings === undefined ? null : (
          <PopUp
            variant="inline"
            accessibilityLabel={t('notifications.sound', { context: 'mac' })}
            label={soundTitle(settings.sound)}
            disabled={denied}
            sections={soundSections.map((sounds) => ({
              items: sounds.map((sound) => ({
                key: sound,
                title: soundTitle(sound),
                checked: sound === settings.sound,
                run: () => {
                  void device.setSound(sound);
                },
              })),
            }))}
          />
        )}
      </SettingsRow>
    </SettingsGroup>
  );
}

// Each Mail Profile's Badge and sound switch. Until notifications are first allowed the group is
// not shown; while they are off it stays, dimmed, and the choices are kept.
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
  if (settings === undefined || settings.authorization === 'undetermined') {
    return null;
  }
  const denied = settings.authorization === 'denied';
  return (
    <SettingsGroup title={t('notifications.profiles')}>
      {[defaultProfile, ...profiles.map(({ id }) => id)].map((profile) => {
        const name = profileName(t, profile, profiles);
        return (
          <SettingsRow
            key={profile}
            title={name}
            subtitle={t('notifications.badgeAndSound')}
            disabled={denied}>
            <Switch
              accessibilityLabel={t('notifications.badgeAndSoundFor', {
                name,
              })}
              disabled={denied}
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
      subtitleTone="warning">
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

// This device's notification permission, previews, Dock badge, New Mail Sound and each Profile's
// Badge and sound switch, which never synchronize, then each connection's synchronized New Mail
// Notification switch.
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
        <SettingsRow title={t('notifications.previews')}>
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
