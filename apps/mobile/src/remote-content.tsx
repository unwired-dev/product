import type { MailboxConnection } from '@private-email/mail-core/registration';
import type {
  RemoteContentPolicy,
  RemoteContentSettingsStore,
} from '@private-email/mail-core/remote-content';
import type { ReactNode } from 'react';

import { remoteContentPolicy } from '@private-email/mail-core/remote-content';
import { radius, spacing, typography } from '@private-email/mail-core/theme';
import { createContext, use, useState, useSyncExternalStore } from 'react';
import {
  Pressable,
  StyleSheet,
  Text,
  useWindowDimensions,
  View,
} from 'react-native';

import type { SettingsButton } from './settings.tsx';

import { SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import {
  settingsColumns,
  SettingsBlock,
  SettingsGroup,
  SettingsRow,
} from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

export const RemoteContentContext = createContext<
  RemoteContentSettingsStore | undefined
>(undefined);

const noSubscription = () => () => undefined;

// The policy for a mailbox's messages: without a settings store every presentation asks, and
// while saved settings are read remote content stays hidden.
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
  policyHeading: { flexDirection: 'row', alignItems: 'center', gap: spacing.m },
  policyTitle: {
    ...(settingsColumns ? typography.ipadList.body : textStyles.body),
    flex: 1,
  },
  choices: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    justifyContent: 'flex-end',
    gap: spacing.xs,
  },
  choice: {
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: spacing.m,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  label: { ...textStyles.subheadline },
  text: { ...textStyles.body },
});

type Choice = RemoteContentPolicy | 'device';

// Narrow panes give the full setting label its own line before the choices.
function PolicyRow({
  icon,
  title,
  children,
}: {
  readonly icon: string;
  readonly title: string;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  const { width, height } = useWindowDimensions();
  if (settingsColumns && width > height) {
    return (
      <SettingsRow
        icon={icon}
        title={title}>
        {children}
      </SettingsRow>
    );
  }
  return (
    <SettingsBlock>
      <View style={styles.policyHeading}>
        <SFSymbol
          name={icon}
          size={20}
          color={colors.accentInk}
        />
        <Text style={[styles.policyTitle, { color: colors.textPrimary }]}>
          {title}
        </Text>
      </View>
      {children}
    </SettingsBlock>
  );
}

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
              backgroundColor:
                choice === selected ? colors.accentFill : colors.fillQuiet,
            },
          ]}>
          <Text
            style={[
              styles.label,
              {
                color:
                  choice === selected
                    ? colors.accentOnFill
                    : colors.textPrimary,
                fontWeight: choice === selected ? '600' : '400',
              },
            ]}>
            {t(`remoteContent.policies.${choice}`)}
          </Text>
        </Pressable>
      ))}
    </View>
  );
}

// The device's remote image policy, each mailbox's override and Clear Remote Content.
export function RemoteContentSettings({
  button,
  mailboxes,
}: {
  readonly button: SettingsButton;
  readonly mailboxes: readonly MailboxConnection[];
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
    <SettingsGroup
      title={t('remoteContent.title')}
      footer={t('remoteContent.description')}>
      <PolicyRow
        icon="photo"
        title={t('settings.remoteContent')}>
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
      </PolicyRow>
      {/* Remote Message Content never loads for IMAP mail yet. */}
      {mailboxes
        .filter(({ provider }) => provider !== 'imap')
        .map((mailbox) => (
          <PolicyRow
            key={mailbox.id}
            icon="at"
            title={mailbox.address}>
            <MailboxRemoteContent {...mailbox} />
          </PolicyRow>
        ))}
      <SettingsRow
        title={t('settings.trackingPixels')}
        subtitle={t('settings.trackingPixelsDetail')}>
        <Text style={[styles.label, { color: colors.textSecondary }]}>
          {t('settings.alwaysBlocked')}
        </Text>
      </SettingsRow>
      <SettingsBlock>
        {button(t('remoteContent.clear'), async () => {
          setCleared(await store.clear());
        })}
        {cleared === undefined ? null : (
          <Text
            accessibilityRole="alert"
            style={[styles.text, { color: colors.textSecondary }]}>
            {cleared
              ? t('remoteContent.cleared')
              : t('remoteContent.clearFailed')}
          </Text>
        )}
      </SettingsBlock>
    </SettingsGroup>
  );
}

// One mailbox's remote image policy, or the device's.
function MailboxRemoteContent({ id, address }: MailboxConnection) {
  const { t } = useLocalization();
  const store = use(RemoteContentContext);
  const override = useSyncExternalStore(
    store?.subscribe ?? noSubscription,
    () => store?.getSnapshot()?.overrides[id],
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
