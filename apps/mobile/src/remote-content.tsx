import type { MailboxConnection } from '@private-email/mail-core/registration';
import type {
  NativeRemoteContent,
  RemoteContentPolicy,
  RemoteContentSettingsStore,
} from '@private-email/mail-core/remote-content';
import type { ReactNode } from 'react';
import type { TurboModule } from 'react-native';

import {
  createRemoteContentSettings,
  remoteContentPolicy,
} from '@private-email/mail-core/remote-content';
import { spacing } from '@private-email/mail-core/theme';
import { createContext, use, useState, useSyncExternalStore } from 'react';
import {
  Pressable,
  StyleSheet,
  Text,
  TurboModuleRegistry,
  View,
} from 'react-native';

import { useLocalization } from './localization.ts';
import { usePalette } from './theme.ts';

interface RemoteContentModule extends TurboModule, NativeRemoteContent {}

const native = () =>
  TurboModuleRegistry.getEnforcing<RemoteContentModule>('UnwiredRegistration');

// This device's remote content policies; a host without the native module has none saved.
export const remoteContent = createRemoteContentSettings({
  remoteContentSettings: () =>
    TurboModuleRegistry.get<RemoteContentModule>(
      'UnwiredRegistration',
    )?.remoteContentSettings() ?? Promise.resolve({ settings: null }),
  setRemoteContentSettings: (settings) =>
    native().setRemoteContentSettings(settings),
  clearRemoteContent: () => native().clearRemoteContent(),
});

export const RemoteContentContext = createContext<
  RemoteContentSettingsStore | undefined
>(undefined);

const noSubscription = () => () => undefined;

// The policy for a mailbox's messages; without settings, every presentation asks.
export function useRemoteContentPolicy(
  connection: string | undefined,
): RemoteContentPolicy {
  const store = use(RemoteContentContext);
  return useSyncExternalStore(store?.subscribe ?? noSubscription, () =>
    store === undefined || connection === undefined
      ? 'ask'
      : remoteContentPolicy(store.getSnapshot(), connection),
  );
}

const styles = StyleSheet.create({
  choices: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.small },
  choice: {
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: spacing.medium,
    borderWidth: 1,
    borderRadius: 10,
    borderCurve: 'continuous',
  },
  label: { fontSize: 15 },
  heading: { fontSize: 20, fontWeight: '600' },
  text: { fontSize: 17, lineHeight: 25 },
});

type Choice = RemoteContentPolicy | 'device';

// The policy choices as buttons that report which one is selected; `device` follows the
// device's choice for one mailbox.
export function PolicyChoice({
  label,
  selected,
  choices,
  onChoose,
}: {
  // Names the setting for each button's accessibility label.
  readonly label: string;
  readonly selected: Choice;
  readonly choices: readonly Choice[];
  readonly onChoose: (choice: Choice) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <View style={styles.choices}>
      {choices.map((choice) => (
        <Pressable
          key={choice}
          accessibilityRole="radio"
          accessibilityLabel={`${label}: ${t(`remoteContent.policies.${choice}`)}`}
          accessibilityState={{ checked: choice === selected }}
          focusable
          onPress={() => {
            onChoose(choice);
          }}
          style={[
            styles.choice,
            {
              borderColor:
                choice === selected ? colors.accent : colors.separator,
            },
          ]}>
          <Text
            style={[
              styles.label,
              {
                color: choice === selected ? colors.accent : colors.foreground,
              },
            ]}>
            {t(`remoteContent.policies.${choice}`)}
          </Text>
        </Pressable>
      ))}
    </View>
  );
}

// The device's remote image policy and Clear Remote Content; each mailbox row offers its own
// override.
export function RemoteContentSettings({
  button,
}: {
  readonly button: (label: string, action: () => Promise<void>) => ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const store = use(RemoteContentContext);
  const settings = useSyncExternalStore(
    store?.subscribe ?? noSubscription,
    () => store?.getSnapshot(),
  );
  const [cleared, setCleared] = useState<boolean>();
  if (store === undefined || settings === undefined) {
    return null;
  }
  return (
    <>
      <Text
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        {t('remoteContent.title')}
      </Text>
      <Text style={[styles.text, { color: colors.secondary }]}>
        {t('remoteContent.description')}
      </Text>
      <PolicyChoice
        label={t('remoteContent.device')}
        selected={settings.policy}
        choices={['ask', 'never', 'always']}
        onChoose={(choice) => {
          if (choice !== 'device') {
            void store.setPolicy(choice);
          }
        }}
      />
      {button(t('remoteContent.clear'), async () => {
        setCleared(await store.clear());
      })}
      {cleared === undefined ? null : (
        <Text
          accessibilityRole="alert"
          style={[styles.text, { color: colors.secondary }]}>
          {cleared
            ? t('remoteContent.cleared')
            : t('remoteContent.clearFailed')}
        </Text>
      )}
    </>
  );
}

// One mailbox's remote image policy, or the device's.
export function MailboxRemoteContent({ id, address }: MailboxConnection) {
  const { t } = useLocalization();
  const store = use(RemoteContentContext);
  const override = useSyncExternalStore(
    store?.subscribe ?? noSubscription,
    () => store?.getSnapshot().overrides[id],
  );
  if (store === undefined) {
    return null;
  }
  return (
    <PolicyChoice
      label={t('remoteContent.mailbox', { address })}
      selected={override ?? 'device'}
      choices={['device', 'ask', 'never', 'always']}
      onChoose={(choice) => {
        void store.setOverride(id, choice === 'device' ? undefined : choice);
      }}
    />
  );
}
