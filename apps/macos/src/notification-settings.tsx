import type {
  MailboxConnection,
  Registration,
} from '@private-email/mail-core/registration';

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

// What the Dock badge counts. While notifications are off, the choice stays, dimmed, until they
// are allowed again.
function DockBadge({
  device,
  settings,
}: {
  readonly device: NotificationSettingsStore;
  readonly settings: DeviceSettings;
}) {
  const { t } = useLocalization();
  const denied = settings?.authorization === 'denied';
  return (
    <SettingsGroup
      footer={t(
        denied ? 'notifications.badgeKept' : 'notifications.badgeDetail',
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

// This device's notification permission, previews and Dock badge, which never synchronize, then
// each connection's synchronized New Mail Notification switch.
export function NotificationSettings({
  button,
  mailboxes,
  store,
}: {
  readonly button: SettingsButton;
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
      <DockBadge
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
