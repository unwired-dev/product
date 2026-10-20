import type {
  MailboxConnection,
  Registration,
} from '@private-email/mail-core/registration';

import { typography } from '@private-email/mail-core/theme';
import { createContext, use, useEffect, useSyncExternalStore } from 'react';
import { AppState, Switch, Text } from 'react-native';

import type { SettingsButton } from './settings.tsx';

import { useLocalization } from './localization.ts';
import { notifications } from './registration.ts';
import { settingsColumns, SettingsGroup, SettingsRow } from './settings.tsx';
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

// One Gmail connection's synchronized switch; turning it on asks for permission the first time.
function MailboxNotifications({
  mailbox: { id, address, notifications: on },
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
    provider: t('mailProviders.gmail'),
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

// The Per Mailbox group: a switch for each Gmail connection, which only Gmail notifies for yet.
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
  const gmail = mailboxes.filter(({ provider }) => provider === 'gmail');
  return gmail.length === 0 ? (
    <SettingsGroup
      title={t('notifications.perMailbox')}
      footer={t('notifications.noMailboxes')}
    />
  ) : (
    <SettingsGroup
      title={t('notifications.perMailbox')}
      footer={t('notifications.perMailboxDetail')}>
      {gmail.map((mailbox) => (
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

// This device's notification permission and previews, which never synchronize, then each Gmail
// connection's synchronized New Mail Notification switch.
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
      <PerMailbox
        mailboxes={mailboxes}
        device={device}
        settings={settings}
        store={store}
      />
    </>
  );
}
