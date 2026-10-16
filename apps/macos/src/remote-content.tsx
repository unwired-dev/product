import type { GmailInbox } from '@private-email/mail-core/gmail-inbox';
import type { MailboxConnection } from '@private-email/mail-core/registration';
import type {
  RemoteContentPolicy,
  RemoteContentSettingsStore,
} from '@private-email/mail-core/remote-content';

import { remoteContentPolicy } from '@private-email/mail-core/remote-content';
import { radius, spacing } from '@private-email/mail-core/theme';
import {
  createContext,
  use,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { SettingsButton } from './settings.tsx';

import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { SettingsBlock, SettingsGroup, SettingsRow } from './settings.tsx';
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

// Consent belongs to this mounted reader; queued measurements must still match its policy.
export function useRemoteImages({
  inbox,
  id,
  reader,
  connection,
  current,
}: {
  readonly inbox: Pick<GmailInbox, 'loadRemoteImages' | 'forgetRemoteImages'>;
  readonly id: string;
  readonly reader: symbol;
  readonly connection: string | undefined;
  readonly current: () => boolean;
}) {
  const policy = useRemoteContentPolicy(connection);
  const [consent, setConsent] = useState<{
    readonly inbox: typeof inbox;
    readonly id: string;
  }>();
  if (
    consent !== undefined &&
    (policy === 'never' || consent.inbox !== inbox)
  ) {
    setConsent(undefined);
  }
  const consented = consent?.inbox === inbox && consent.id === id;
  // Retire network permission before queued native measurements see the new policy.
  useLayoutEffect(() => {
    if (policy === 'never') {
      inbox.forgetRemoteImages(id);
    } else if (policy === 'ask' && !consented) {
      void inbox.loadRemoteImages(id, [], { network: false, reader });
    }
  }, [inbox, id, policy, consented, reader]);
  const showing = useRef<{
    readonly policy: RemoteContentPolicy;
    readonly consented: boolean;
  }>(undefined);
  useLayoutEffect(() => {
    showing.current = { policy, consented };
    return () => {
      showing.current = undefined;
    };
  }, [policy, consented]);
  return {
    handleNear: (urls: readonly string[]) => {
      if (
        policy !== 'never' &&
        current() &&
        showing.current?.policy === policy &&
        showing.current.consented === consented
      ) {
        void inbox.loadRemoteImages(id, urls, {
          network: policy === 'always' || consented,
          reader,
        });
      }
    },
    handleLoadImages:
      policy === 'ask' && !consented
        ? () => {
            if (current()) {
              setConsent({ inbox, id });
            }
          }
        : undefined,
  };
}

const styles = StyleSheet.create({
  choices: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    justifyContent: 'flex-end',
    gap: spacing.xs,
  },
  choice: {
    minHeight: 28,
    justifyContent: 'center',
    paddingHorizontal: spacing.m,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  label: { ...textStyles.body },
  text: { ...textStyles.body },
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
      <SettingsRow
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
      </SettingsRow>
      {mailboxes.map((mailbox) => (
        <SettingsRow
          key={mailbox.id}
          icon="at"
          title={mailbox.address}>
          <MailboxRemoteContent {...mailbox} />
        </SettingsRow>
      ))}
      <SettingsRow
        title={t('settings.trackingPixels')}
        subtitle={t('settings.trackingPixelsDetail')}>
        <Label style={[styles.label, { color: colors.textSecondary }]}>
          {t('settings.alwaysBlocked')}
        </Label>
      </SettingsRow>
      <SettingsBlock>
        {button(t('remoteContent.clear'), async () => {
          setCleared(await store.clear());
        })}
        {cleared === undefined ? null : (
          <Label
            accessibilityRole="alert"
            style={[styles.text, { color: colors.textSecondary }]}>
            {cleared
              ? t('remoteContent.cleared')
              : t('remoteContent.clearFailed')}
          </Label>
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
