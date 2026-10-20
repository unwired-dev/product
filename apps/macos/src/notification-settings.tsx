import type {
  MailboxConnection,
  Registration,
} from '@private-email/mail-core/registration';

import { createContext, use, useEffect, useSyncExternalStore } from 'react';
import { AppState, Switch, Text } from 'react-native';

import type { SettingsButton } from './settings.tsx';

import { useLocalization } from './localization.ts';
import { notifications } from './registration.ts';
import { SettingsGroup, SettingsRow } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

type NotificationSettingsStore = Omit<typeof notifications, 'arrived'>;

export const NotificationsContext =
  createContext<NotificationSettingsStore>(notifications);

// This device's notification permission and previews, then each Gmail connection's synchronized
// New Mail Notification switch. Turning a mailbox on asks for permission the first time.
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
  const { busy, notificationFailure } = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
  );
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
  const gmail = mailboxes.filter(({ provider }) => provider === 'gmail');
  const value = (text: string) => (
    <Text style={[textStyles.body, { color: colors.textSecondary }]}>
      {text}
    </Text>
  );
  const track = { false: colors.fillTrack, true: colors.accentFill };
  return (
    <>
      <SettingsGroup
        title={t('notifications.onThisDevice')}
        footer={t('notifications.previewsDetail')}>
        <SettingsRow title={t('notifications.authorization')}>
          {settings?.authorization === 'authorized'
            ? value(t('notifications.allowed'))
            : null}
          {settings?.authorization === 'denied' ? (
            <>
              {value(t('notifications.denied'))}
              {button(t('notifications.openSettings'), device.openSettings)}
            </>
          ) : null}
          {settings?.authorization === 'undetermined'
            ? button(t('notifications.allow'), device.request)
            : null}
        </SettingsRow>
        <SettingsRow title={t('notifications.previews')}>
          <Switch
            accessibilityLabel={t('notifications.previews')}
            disabled={settings === undefined}
            value={settings?.previews ?? false}
            trackColor={track}
            onValueChange={(previews) => {
              void device.setPreviews(previews);
            }}
          />
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup
        title={t('notifications.perMailbox')}
        footer={t(
          gmail.length === 0
            ? 'notifications.noMailboxes'
            : 'notifications.perMailboxDetail',
        )}>
        {gmail.length === 0
          ? undefined
          : gmail.map(({ id, address, notifications: on }) => {
              const title = t('notifications.mailbox', {
                provider: t('mailProviders.gmail'),
                address,
              });
              return (
                <SettingsRow
                  key={id}
                  title={title}
                  subtitle={
                    notificationFailure === id
                      ? t('notifications.changeFailed')
                      : undefined
                  }
                  subtitleTone="warning">
                  <Switch
                    accessibilityLabel={title}
                    accessibilityState={{ disabled: busy, busy }}
                    disabled={busy}
                    value={on === true}
                    trackColor={track}
                    onValueChange={(enabled) => {
                      if (
                        enabled &&
                        settings?.authorization === 'undetermined'
                      ) {
                        void device.request();
                      }
                      void store.notifyMailbox(id, enabled);
                    }}
                  />
                </SettingsRow>
              );
            })}
      </SettingsGroup>
    </>
  );
}
